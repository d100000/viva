import Foundation

/// 调用 Viva 产品专用的文本润色/改口接口。
///
/// 客户端只发送原文和产品模式；模型、Prompt、供应商地址与供应商 API Key
/// 均由服务端固定和审计，不能再通过客户端构造任意大模型代理请求。
final class LLMPolisher {

    struct Result {
        let text: String
        let elapsedMs: Int
        let requestID: String?
        /// 保留这个字段兼容现有 UI；产品接口永远不会把思维链下发给客户端。
        var thoughtLeaked: Bool = false
    }

    enum PolishError: LocalizedError {
        case notConfigured, timeout, empty, tooLong, unsafeResult
        case badResponse(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Viva 服务地址无效"
            case .badResponse(let value): return "Viva 润色服务返回异常：\(value)"
            case .timeout: return "润色超时"
            case .empty: return "润色返回了空内容"
            case .tooLong: return "文本过长，单次最多处理 16000 个字符"
            case .unsafeResult: return "润色结果与原文差异过大，已按原文上屏"
            }
        }
    }

    private let config: Config

    /// 流式模式下，每收到一段增量就回调「到目前为止的完整文本」。
    /// 只用于悬浮条反馈，上屏仍必须等待 final。
    var onDelta: ((String) -> Void)?

    init(config: Config) { self.config = config }

    var isConfigured: Bool { config.llmPassReady }

    func polish(_ text: String) async throws -> Result {
        guard isConfigured,
              let baseURL = config.backendBaseURL,
              let url = config.polishEndpointURL(streaming: config.polishStream)
        else { throw PolishError.notConfigured }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw PolishError.empty }
        guard trimmed.count <= 16_000 else { throw PolishError.tooLong }

        let body: [String: Any] = [
            "text": trimmed,
            "mode": mode,
            "model_tier": "fast",
            "max_tokens": 2048,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if config.polishStream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // 总超时按文本长度放宽。流式响应会持续收到字节，URLSession 自身的 idle timeout
        // 无法限制总时长，因此 streamed() 仍有独立 deadline。
        let budgetMs = min(120_000, config.polishTimeoutMs + trimmed.count * 30)
        let clientRequestID = UUID().uuidString.lowercased()
        request.setValue(clientRequestID, forHTTPHeaderField: "X-Request-ID")
        request.setValue(String(budgetMs), forHTTPHeaderField: "X-Viva-Client-Timeout-Ms")
        request.timeoutInterval = Double(budgetMs) / 1000.0

        let startedAt = Date()
        let response: ManagedResponse
        do {
            response = config.polishStream
                ? try await streamed(request, budgetMs: budgetMs, baseURL: baseURL)
                : try await once(request, baseURL: baseURL)
        } catch {
            let measured = Int(Date().timeIntervalSince(startedAt) * 1000)
            let failure = Self.clientFailureOutcome(error: error)
            reportOutcome(requestID: clientRequestID, outcome: failure.outcome,
                          detail: failure.detail, elapsedMs: measured,
                          budgetMs: budgetMs, baseURL: baseURL)
            throw error
        }
        if let balanceAfter = response.balanceAfter {
            try? await ManagedBackendAuth.shared.recordAvailablePoints(
                balanceAfter, baseURL: baseURL)
        }
        var output = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 服务端已经有产品级护栏；客户端再保留最后一道防线，避免异常结果被直接注入
        // 用户正在编辑的文档。
        for pair in [("「", "」"), ("\"", "\""), ("“", "”")] {
            guard output.hasPrefix(pair.0), output.hasSuffix(pair.1), output.count > 2 else { continue }
            let inner = output.dropFirst().dropLast()
            if inner.contains(pair.0) || inner.contains(pair.1) { continue }
            output = String(inner)
        }
        guard !output.isEmpty else {
            reportOutcome(requestID: response.requestID ?? clientRequestID,
                          outcome: "rejected", detail: "empty_output",
                          elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                          budgetMs: budgetMs, baseURL: baseURL)
            throw PolishError.empty
        }
        guard Self.isSaneResult(original: trimmed, polished: output) else {
            Log.warn("托管润色结果未通过客户端护栏（原文 \(trimmed.count) 字 → 返回 \(output.count) 字）")
            reportOutcome(requestID: response.requestID ?? clientRequestID,
                          outcome: "rejected", detail: "client_output_guard",
                          elapsedMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                          budgetMs: budgetMs, baseURL: baseURL)
            throw PolishError.unsafeResult
        }

        let measured = Int(Date().timeIntervalSince(startedAt) * 1000)
        let requestID = response.requestID ?? clientRequestID
        reportOutcome(requestID: requestID, outcome: "received",
                      detail: "complete_response_validated", elapsedMs: measured,
                      budgetMs: budgetMs, baseURL: baseURL)
        return Result(text: output,
                      elapsedMs: response.elapsedMs ?? measured,
                      requestID: requestID,
                      thoughtLeaked: false)
    }

    private var mode: String {
        switch config.aiProcessingMode {
        case .both: return "both"
        case .correction: return "course_correction"
        case .polish, .off: return "polish"
        }
    }

    private struct ManagedResponse {
        var text: String
        var elapsedMs: Int?
        var balanceAfter: Int64?
        var requestID: String?
    }

    private func once(_ request: URLRequest, baseURL: URL) async throws -> ManagedResponse {
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await ManagedBackendAuth.shared.authorizedData(
                for: request, baseURL: baseURL)
        }
        catch let error as URLError where error.code == .timedOut { throw PolishError.timeout }

        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw PolishError.badResponse("响应不是合法 JSON")
        }
        return ManagedResponse(
            text: text,
            elapsedMs: object["elapsed_ms"] as? Int,
            balanceAfter: Self.balanceAfter(in: object),
            requestID: (object["request_id"] as? String)
                ?? response.value(forHTTPHeaderField: "X-Request-ID"))
    }

    /// 解析产品 SSE：meta → delta* → final → usage → done（或 error）。
    private func streamed(_ request: URLRequest, budgetMs: Int,
                          baseURL: URL) async throws -> ManagedResponse {
        let (bytes, http): (URLSession.AsyncBytes, HTTPURLResponse)
        do {
            (bytes, http) = try await ManagedBackendAuth.shared.authorizedBytes(
                for: request, baseURL: baseURL)
        }
        catch let error as URLError where error.code == .timedOut { throw PolishError.timeout }

        let deadline = Date().addingTimeInterval(Double(budgetMs) / 1000.0)
        var event = "message"
        var dataLines: [String] = []
        var accumulated = ""
        var finalText: String?
        var elapsedMs: Int?
        var balanceAfter: Int64?
        var requestID = http.value(forHTTPHeaderField: "X-Request-ID")
        var didReceiveDone = false

        func consumeEvent() async throws {
            defer {
                event = "message"
                dataLines.removeAll(keepingCapacity: true)
            }
            guard !dataLines.isEmpty else { return }
            let payload = dataLines.joined(separator: "\n")
            if payload == "[DONE]" {
                didReceiveDone = true
                return
            }
            guard let data = payload.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            if let reportedRequestID = object["request_id"] as? String,
               !reportedRequestID.isEmpty {
                requestID = reportedRequestID
            }

            switch event {
            case "delta":
                let delta = (object["delta"] as? String) ?? (object["text"] as? String) ?? ""
                guard !delta.isEmpty else { return }
                accumulated += delta
                let snapshot = accumulated
                await MainActor.run { self.onDelta?(snapshot) }

            case "final":
                finalText = object["text"] as? String
                elapsedMs = object["elapsed_ms"] as? Int

                balanceAfter = Self.balanceAfter(in: object) ?? balanceAfter

            case "usage":
                balanceAfter = Self.balanceAfter(in: object) ?? balanceAfter

            case "error":
                let nested = object["error"] as? [String: Any]
                let code = (nested?["code"] as? String)
                    ?? (object["code"] as? String) ?? "POLISH_ERROR"
                throw PolishError.badResponse(code)

            case "done":
                didReceiveDone = true
            default:
                break
            }
        }

        for try await line in bytes.lines {
            if Date() > deadline {
                Log.warn("托管润色流式超时（已收 \(accumulated.count) 字），丢弃半成品")
                throw PolishError.timeout
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await consumeEvent()
                if didReceiveDone { break }
                continue
            }
            if line.hasPrefix(":") { continue }
            if line.hasPrefix("event:") {
                let nextEvent = String(line.dropFirst(6))
                    .trimmingCharacters(in: .whitespaces)
                // AsyncBytes.lines 在不同系统版本上不保证把 SSE 空行作为空字符串
                // 交付；看到下一条 event 时也要提交上一事件。
                if !dataLines.isEmpty {
                    try await consumeEvent()
                    if didReceiveDone { break }
                }
                event = nextEvent
                continue
            }
            if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5))
                    .trimmingCharacters(in: .whitespaces))
            }
        }
        if !didReceiveDone, !dataLines.isEmpty { try await consumeEvent() }

        guard didReceiveDone, let text = finalText, !text.isEmpty else {
            Log.warn("托管润色流未收到完整 final/done，丢弃 \(accumulated.count) 字半成品")
            throw PolishError.badResponse("流式响应未完整结束")
        }
        return ManagedResponse(text: text, elapsedMs: elapsedMs,
                               balanceAfter: balanceAfter, requestID: requestID)
    }

    private func reportOutcome(requestID: String, outcome: String, detail: String,
                               elapsedMs: Int, budgetMs: Int, baseURL: URL) {
        Task.detached(priority: .utility) {
            try? await ManagedBackendAuth.shared.reportLLMOutcome(
                requestID: requestID, outcome: outcome, detail: detail,
                clientElapsedMS: elapsedMs, timeoutBudgetMS: budgetMs,
                baseURL: baseURL)
        }
    }

    private static func clientFailureOutcome(error: Error) -> (outcome: String, detail: String) {
        if error is CancellationError || Task.isCancelled {
            return ("cancelled", "client_task_cancelled")
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return ("cancelled", "url_session_cancelled")
        }
        if let polishError = error as? PolishError {
            switch polishError {
            case .timeout:
                return ("timeout", "client_timeout")
            case .empty:
                return ("rejected", "empty_output")
            case .unsafeResult:
                return ("rejected", "client_output_guard")
            case .badResponse:
                return ("fallback", "invalid_or_failed_response")
            case .notConfigured, .tooLong:
                return ("fallback", "request_not_sent")
            }
        }
        return ("fallback", "client_request_failed")
    }

    private static func balanceAfter(in object: [String: Any]) -> Int64? {
        guard let billing = object["billing"] as? [String: Any],
              let number = billing["balance_after"] as? NSNumber else { return nil }
        return number.int64Value
    }

    // MARK: - 客户端安全护栏

    static func isSaneResult(original: String, polished: String) -> Bool {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let polished = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !polished.isEmpty else { return false }
        if original == polished { return true }

        let ratio = Double(polished.count) / Double(original.count)
        guard ratio >= 0.55, ratio <= 1.6 else { return false }

        let source = Set(original.filter { !$0.isWhitespace && !$0.isPunctuation })
        let output = Set(polished.filter { !$0.isWhitespace && !$0.isPunctuation })
        guard !source.isEmpty else { return false }
        return Double(source.intersection(output).count) / Double(source.count) >= 0.6
    }
}
