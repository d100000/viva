import Foundation

/// 用大模型对识别结果做二次润色。
///
/// ⚠️ **只在整段识别结束后调用一次，绝不在流式过程中反复调。**
/// 流式吐出来的是未定稿文本，套 LLM 会让屏幕上的字反复跳变重写。
///
/// 请求/响应的具体结构交给 `APIFormat` 处理，所以 OpenAI 兼容、Anthropic Messages、
/// Ollama 原生、Gemini 都能接 —— 它们的鉴权头、请求体、响应结构完全不同。
final class LLMPolisher {

    struct Result {
        let text: String
        let elapsedMs: Int
        /// 返回里出现了思维链。若用户选了「关闭思考」却仍出现，说明参数没生效。
        var thoughtLeaked: Bool = false
    }

    enum PolishError: LocalizedError {
        case notConfigured, timeout, empty, unsafeResult
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "润色未配置：缺少 API Key 或模型名"
            case .badResponse(let s): return "润色服务返回异常：\(s)"
            case .timeout: return "润色超时"
            case .empty: return "润色返回了空内容"
            case .unsafeResult: return "润色结果与原文差异过大，已按原文上屏"
            }
        }
    }

    static let defaultPrompt = """
    你是语音输入的文本润色助手。下面是用户通过语音输入产生的原始识别文本，\
    可能包含同音错别字、口水词、重复、断句和标点问题。

    请你：
    1. 修正明显的同音错别字和语音识别错误（例如「流是」→「流式」、「尚平」→「上屏」）
    2. 去掉「嗯」「那个」「就是说」这类口水词和无意义重复
    3. 补全或修正标点，让断句自然
    4. 保持原意、语气和人称，不要扩写、不要解释、不要添加原文没有的信息
    5. 技术内容保持专业术语和英文标识符原样，不要翻译成中文
    6. 如果原文已经很干净，就原样返回

    只输出润色后的文本本身，不要任何前缀、后缀、引号或说明。
    """

    private let config: Config

    /// 流式模式下，每收到一段增量就回调「到目前为止的完整文本」。
    /// ⚠️ 只用于喂悬浮条做视觉反馈 —— **上屏必须等全文完成**，
    ///    把润色到一半的文本粘进输入框比不润色更糟。
    var onDelta: ((String) -> Void)?

    init(config: Config) { self.config = config }

    /// ⚠️ 必须与 Config.polishReady 完全一致。两边判据不同的话，
    ///    VoiceSession 会因为 polishReady==true 而推迟上屏、进入 .polishing，
    ///    然后 polish() 又因为 isConfigured==false 抛「未配置」——
    ///    用户每说一句都白等一次再收到一条红色报错。
    var isConfigured: Bool { config.polishReady }

    // MARK: -

    func polish(_ text: String, contextApp: String?) async throws -> Result {
        guard isConfigured else { throw PolishError.notConfigured }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PolishError.empty }

        let format = config.apiFormat
        let provider = LLMProvider.find(config.polishProvider)

        // ── URL ──
        var base = config.polishBaseURL
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        var path = config.polishPath.isEmpty ? format.defaultPath : config.polishPath
        if !path.hasPrefix("/") { path = "/" + path }
        // Gemini 把模型名拼在路径里
        path = path.replacingOccurrences(of: "{model}", with: config.polishModel)
        if config.polishStream { path = format.streamPath(from: path) }
        guard let url = URL(string: base + path) else {
            throw PolishError.badResponse("baseURL 或端点路径非法：\(base + path)")
        }

        // ── system ──
        var system = config.polishPrompt.isEmpty ? Self.defaultPrompt : config.polishPrompt
        if let app = contextApp, !app.isEmpty {
            // 同一句话在终端里和在微信里该润成不同风格
            system += "\n\n当前用户正在「\(app)」中输入，请让文本风格与该场景相符。"
        }

        // ── 关不关思考 ──
        // 默认关：润色一两句话不需要推理，开着会让延迟从 1 秒涨到几秒，
        // 思维链还按输出 token 计费。但这是用户可选的。
        let thinkingOff: LLMProvider.ThinkingOff
        if config.polishDisableThinking {
            thinkingOff = provider.id == "custom"
                ? (LLMProvider.ThinkingOff(rawValue: config.polishThinkingOff) ?? .none)
                : provider.thinkingOff
        } else {
            thinkingOff = .none
        }

        let opts = APIFormat.Options(
            model: config.polishModel,
            system: system,
            user: trimmed,
            maxTokens: max(200, trimmed.count * 3),
            temperature: provider.sendTemperature ? provider.temperature : nil,
            stream: config.polishStream,
            thinkingOff: thinkingOff,
            useMaxCompletionTokens: provider.useMaxCompletionTokens)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        for (k, v) in format.headers(apiKey: config.polishApiKey) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: format.body(opts))
        // ⚠️ timeoutInterval 的语义是「两次收到数据之间的空闲上限」，不是请求总时长。
        //    SSE 每收到一个 token、甚至一行 ": ping" 保活注释都会重置它，
        //    所以流式下它对总耗时**没有任何约束**。总时长由 streamed() 自己卡。
        req.timeoutInterval = Double(config.polishTimeoutMs) / 1000.0

        let t0 = Date()
        let (content, thinking) = config.polishStream
            ? try await streamed(req, format)
            : try await once(req, format)

        var out = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // 模型偶尔会自作主张加引号，剥掉
        for pair in [("「", "」"), ("\"", "\""), ("“", "”")] {
            if out.hasPrefix(pair.0), out.hasSuffix(pair.1), out.count > 2 {
                out = String(out.dropFirst().dropLast())
            }
        }
        guard !out.isEmpty else { throw PolishError.empty }

        // ⭐ 接上安全护栏。模型跑偏（扩写成一段、输出解释文字、翻成英文）或被
        //    max_tokens 截断时，结果会被一次性粘进用户正在写的文档 —— 而 deferCommit
        //    模式下原文根本没上屏，用户没有对照也没有撤销点。
        guard Self.isSaneResult(original: trimmed, polished: out) else {
            Log.warn("润色结果未通过护栏（原文 \(trimmed.count) 字 → 返回 \(out.count) 字），按原文处理")
            throw PolishError.unsafeResult
        }

        let leaked = !thinking.isEmpty
        if leaked, config.polishDisableThinking {
            Log.warn("已选择关闭思考，但返回里仍带思维链（format=\(format.rawValue) provider=\(config.polishProvider)）—— 该参数可能不被此服务支持")
        }
        return Result(text: out, elapsedMs: Int(Date().timeIntervalSince(t0) * 1000),
                      thoughtLeaked: leaked)
    }

    // MARK: - 收包

    private func once(_ req: URLRequest, _ format: APIFormat) async throws -> (String, String) {
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch let e as URLError where e.code == .timedOut { throw PolishError.timeout }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw PolishError.badResponse(
                "HTTP \(http.statusCode) " + (String(data: data, encoding: .utf8)?.prefix(300) ?? ""))
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parsed = format.parse(obj) else {
            throw PolishError.badResponse(String(String(data: data, encoding: .utf8)?.prefix(300) ?? ""))
        }
        return parsed
    }

    /// 流式。
    ///
    /// ⚠️ 两种分帧方式：SSE（`data:` 前缀，多数家）和 **NDJSON**（Ollama 原生，
    /// 一行就是一个完整 JSON）。按格式分别处理，混用会一行都解析不出来。
    ///
    /// 另外注意：**这不会让总耗时变快** —— 模型要生成的 token 数一样，
    /// 流式只是把「等全部生成完」改成「生成一个吐一个」。收益全在感知上。
    private func streamed(_ req: URLRequest, _ format: APIFormat) async throws -> (String, String) {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await URLSession.shared.bytes(for: req) }
        catch let e as URLError where e.code == .timedOut { throw PolishError.timeout }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // 出错时 body 不是流格式，得整个读出来才能给出有用的报错
            var raw = ""
            for try await line in bytes.lines { raw += line; if raw.count > 800 { break } }
            throw PolishError.badResponse("HTTP \(http.statusCode) \(raw)")
        }

        // 流式必须自己卡总时长，否则服务端慢速吐字能让 .polishing 无限期挂住，
        // 而 begin() 的 guard state == .idle 会让热键彻底失灵、且没有任何提示。
        let deadline = Date().addingTimeInterval(Double(config.polishTimeoutMs) / 1000.0)

        var text = "", thinking = ""
        for try await line in bytes.lines {
            if Date() > deadline {
                Log.warn("润色流式超时（已收 \(text.count) 字），按已收内容返回")
                break
            }
            var payload = line
            if format.streamIsSSE {
                guard line.hasPrefix("data:") else { continue }
                payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
            } else {
                payload = line.trimmingCharacters(in: .whitespaces)
                guard !payload.isEmpty, payload.hasPrefix("{") else { continue }
            }
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }

            let (t, k) = format.delta(obj)
            if !k.isEmpty { thinking += k }
            if !t.isEmpty {
                text += t
                let snapshot = text
                await MainActor.run { self.onDelta?(snapshot) }
            }
            if (obj["done"] as? Bool) == true { break }      // Ollama 的结束标记
        }
        guard !text.isEmpty else { throw PolishError.timeout }
        return (text, thinking)
    }

    // MARK: - 安全护栏

    /// 润色结果是否「可信到可以直接采用」。
    /// 模型偶尔会跑偏（把一句话扩写成一段、输出解释性文字、把中文翻成英文）。
    static func isSaneResult(original: String, polished: String) -> Bool {
        let o = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty, !p.isEmpty else { return false }
        if o == p { return true }

        let ratio = Double(p.count) / Double(o.count)
        guard ratio >= 0.55, ratio <= 1.6 else { return false }

        let oset = Set(o.filter { !$0.isWhitespace && !$0.isPunctuation })
        let pset = Set(p.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard !oset.isEmpty else { return false }
        return Double(oset.intersection(pset).count) / Double(oset.count) >= 0.6
    }
}
