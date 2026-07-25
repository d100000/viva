import Foundation

/// 大模型接口的**协议格式**。
///
/// 只让用户填 URL 和 Key 是不够的 —— 各家的请求体、响应结构、鉴权头都不一样：
/// - OpenAI Chat Completions：`Authorization: Bearer`，`choices[0].message.content`
/// - OpenAI Responses：同鉴权，但请求用 `input`、响应用 `output[].content[].text`
/// - Anthropic Messages：`x-api-key` + `anthropic-version` 头，system 是顶层字段，
///   响应是 `content[0].text`
/// - Ollama 原生：流式是 **NDJSON**（一行一个 JSON），不是 SSE
/// - Gemini：Key 走 `x-goog-api-key`，模型名拼在 URL 路径里
///
/// 猜错任何一处都是直接 400/404，所以做成显式选项而不是自动嗅探。
enum APIFormat: String, CaseIterable, Identifiable {
    case openAIChat = "openai-chat"
    case openAIResponses = "openai-responses"
    case anthropicMessages = "anthropic-messages"
    case ollamaNative = "ollama-native"
    case geminiGenerate = "gemini"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAIChat:        return "OpenAI Chat Completions（最通用）"
        case .openAIResponses:   return "OpenAI Responses"
        case .anthropicMessages: return "Anthropic Messages"
        case .ollamaNative:      return "Ollama 原生 /api/chat"
        case .geminiGenerate:    return "Google Gemini generateContent"
        }
    }

    var defaultPath: String {
        switch self {
        case .openAIChat:        return "/chat/completions"
        case .openAIResponses:   return "/responses"
        case .anthropicMessages: return "/messages"
        case .ollamaNative:      return "/api/chat"
        case .geminiGenerate:    return "/models/{model}:generateContent"
        }
    }

    var hint: String {
        switch self {
        case .openAIChat:
            return "绝大多数服务都兼容这个：火山方舟、DeepSeek、阿里百炼、智谱、硅基流动、Ollama 的 /v1 兼容层等。不确定就选它。"
        case .openAIResponses:
            return "OpenAI 较新的接口，火山方舟也提供。请求用 input 而不是 messages，响应结构也不同。"
        case .anthropicMessages:
            return "Claude 官方接口。鉴权用 x-api-key 头（不是 Bearer），system 提示词是顶层字段，响应取 content[0].text。必须带 anthropic-version 头。"
        case .ollamaNative:
            return "Ollama 的原生接口。⚠️ 流式返回是 NDJSON（一行一个 JSON）而不是 SSE，本工具已按此解析。不需要 Key。"
        case .geminiGenerate:
            return "⚠️ 未实测。Key 走 x-goog-api-key 头，模型名拼在 URL 路径里（{model} 会被自动替换）。流式路径需手动改成 :streamGenerateContent。"
        }
    }

    /// 是否用 SSE（`data:` 前缀）。Ollama 原生是 NDJSON，逐行就是完整 JSON。
    var streamIsSSE: Bool { self != .ollamaNative }

    // MARK: - 鉴权

    func headers(apiKey: String) -> [String: String] {
        var h = ["Content-Type": "application/json"]
        switch self {
        case .anthropicMessages:
            h["x-api-key"] = apiKey
            h["anthropic-version"] = "2023-06-01"
        case .geminiGenerate:
            h["x-goog-api-key"] = apiKey
        case .ollamaNative:
            break                                  // 本地不校验
        case .openAIChat, .openAIResponses:
            h["Authorization"] = "Bearer \(apiKey)"
        }
        return h
    }

    // MARK: - 请求体

    struct Options {
        var model: String
        var system: String
        var user: String
        var maxTokens: Int
        var temperature: Double?
        var stream: Bool
        var thinkingOff: LLMProvider.ThinkingOff
        var useMaxCompletionTokens: Bool
    }

    func body(_ o: Options) -> [String: Any] {
        var b: [String: Any] = [:]

        switch self {
        case .openAIChat:
            b["model"] = o.model
            b["messages"] = [["role": "system", "content": o.system],
                             ["role": "user", "content": o.user]]
            b["stream"] = o.stream
            if o.useMaxCompletionTokens { b["max_completion_tokens"] = o.maxTokens }
            else { b["max_tokens"] = o.maxTokens }
            if let t = o.temperature { b["temperature"] = t }
            applyThinkingOff(&b, o.thinkingOff)

        case .openAIResponses:
            b["model"] = o.model
            b["instructions"] = o.system
            b["input"] = o.user
            b["stream"] = o.stream
            b["max_output_tokens"] = o.maxTokens
            if let t = o.temperature { b["temperature"] = t }
            applyThinkingOff(&b, o.thinkingOff)

        case .anthropicMessages:
            b["model"] = o.model
            b["system"] = o.system                 // Anthropic 的 system 是顶层字段
            b["messages"] = [["role": "user", "content": o.user]]
            b["max_tokens"] = o.maxTokens          // 这里是必填
            b["stream"] = o.stream
            if let t = o.temperature { b["temperature"] = t }

        case .ollamaNative:
            b["model"] = o.model
            b["messages"] = [["role": "system", "content": o.system],
                             ["role": "user", "content": o.user]]
            b["stream"] = o.stream
            b["options"] = ["num_predict": o.maxTokens,
                            "temperature": o.temperature ?? 0.2]
            if o.thinkingOff != .none { b["think"] = false }

        case .geminiGenerate:
            b["contents"] = [["role": "user", "parts": [["text": o.user]]]]
            b["systemInstruction"] = ["parts": [["text": o.system]]]
            var gen: [String: Any] = ["maxOutputTokens": o.maxTokens]
            if let t = o.temperature { gen["temperature"] = t }
            b["generationConfig"] = gen
        }
        return b
    }

    private func applyThinkingOff(_ b: inout [String: Any], _ s: LLMProvider.ThinkingOff) {
        switch s {
        case .none: break
        case .thinkingDisabled:    b["thinking"] = ["type": "disabled"]
        case .enableThinkingFalse: b["enable_thinking"] = false
        case .reasoningEffortNone: b["reasoning_effort"] = "none"
        }
    }

    // MARK: - 响应解析（非流式）

    /// 返回 (正文, 思维链)
    func parse(_ obj: [String: Any]) -> (String, String)? {
        switch self {
        case .openAIChat:
            guard let ch = obj["choices"] as? [[String: Any]],
                  let msg = ch.first?["message"] as? [String: Any],
                  let c = msg["content"] as? String else { return nil }
            return (c, (msg["reasoning_content"] as? String) ?? "")

        case .openAIResponses:
            // 有的实现直接给 output_text，有的要从 output[] 里拼
            if let t = obj["output_text"] as? String, !t.isEmpty { return (t, "") }
            guard let out = obj["output"] as? [[String: Any]] else { return nil }
            var text = ""
            for item in out {
                guard let parts = item["content"] as? [[String: Any]] else { continue }
                for p in parts { if let t = p["text"] as? String { text += t } }
            }
            return text.isEmpty ? nil : (text, "")

        case .anthropicMessages:
            guard let parts = obj["content"] as? [[String: Any]] else { return nil }
            var text = "", think = ""
            for p in parts {
                let type = (p["type"] as? String) ?? "text"
                if type == "thinking" { think += (p["thinking"] as? String) ?? "" }
                else if let t = p["text"] as? String { text += t }
            }
            return text.isEmpty ? nil : (text, think)

        case .ollamaNative:
            guard let msg = obj["message"] as? [String: Any],
                  let c = msg["content"] as? String else { return nil }
            return (c, (msg["thinking"] as? String) ?? "")

        case .geminiGenerate:
            guard let cands = obj["candidates"] as? [[String: Any]],
                  let content = cands.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return nil }
            let text = parts.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : (text, "")
        }
    }

    // MARK: - 响应解析（流式增量）

    /// 从一帧里取出本次新增的正文/思维链
    func delta(_ obj: [String: Any]) -> (text: String, thinking: String) {
        switch self {
        case .openAIChat:
            guard let ch = obj["choices"] as? [[String: Any]],
                  let d = ch.first?["delta"] as? [String: Any] else { return ("", "") }
            return ((d["content"] as? String) ?? "", (d["reasoning_content"] as? String) ?? "")

        case .openAIResponses:
            // 事件流：type = response.output_text.delta
            if let type = obj["type"] as? String, type.hasSuffix("output_text.delta"),
               let d = obj["delta"] as? String { return (d, "") }
            return ("", "")

        case .anthropicMessages:
            guard (obj["type"] as? String) == "content_block_delta",
                  let d = obj["delta"] as? [String: Any] else { return ("", "") }
            return ((d["text"] as? String) ?? "", (d["thinking"] as? String) ?? "")

        case .ollamaNative:
            guard let msg = obj["message"] as? [String: Any] else { return ("", "") }
            return ((msg["content"] as? String) ?? "", (msg["thinking"] as? String) ?? "")

        case .geminiGenerate:
            guard let cands = obj["candidates"] as? [[String: Any]],
                  let content = cands.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return ("", "") }
            return (parts.compactMap { $0["text"] as? String }.joined(), "")
        }
    }
}
