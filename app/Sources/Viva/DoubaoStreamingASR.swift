import Foundation

/// 一次识别会话的结果回调
struct ASRUpdate {
    /// 本次新确定（definite）的文本，可直接上屏
    var newDefinite: String = ""
    /// 当前尚未定稿的文本，只用于 HUD 预览，**不要写进输入框**
    var partial: String = ""
    /// 到目前为止的完整文本（已定稿 + 未定稿）
    var fullText: String = ""
}

/// 豆包流式语音识别 WebSocket 客户端。
final class DoubaoStreamingASR: NSObject {

    enum State { case idle, connecting, streaming, finalizing, closed }

    private let config: Config
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    private(set) var state: State = .idle
    private(set) var logId: String = ""

    /// 已提交的 definite 分句数，用作游标（result_type = full 时避免重复上屏）
    private var committedUtteranceCount = 0
    private var lastPartial = ""
    private var audioPacketCount = 0
    private var didSendLastPacket = false

    var onUpdate: ((ASRUpdate) -> Void)?
    var onError: ((String) -> Void)?
    /// 流真正结束（收到帧头 flags 标记的 final 帧，或超时兜底）
    var onFinished: ((String) -> Void)?

    private var finalTimer: Timer?
    private var didFinish = false

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        guard state == .idle else { return }
        state = .connecting

        guard let url = URL(string: config.endpoint) else {
            fail("端点 URL 非法：\(config.endpoint)"); return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let headers = config.authHeaders(requestId: UUID().uuidString,
                                         connectId: UUID().uuidString)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        // ⚠️ 不要复用长时间空闲的连接：type4me 记录过「长空闲的共享 URLSession socket
        //    首次 write 会失败」，每次会话用全新 session 最稳。
        cfg.httpShouldUsePipelining = false
        // ⭐ delegateQueue 必须钉在 .main。本类的可变状态（state / didFinish /
        //   didSendLastPacket / lastPartial / logId / committedUtteranceCount…）
        //   原本在「MainActor 调用方 + URLSession 后台队列 + 主 RunLoop 定时器」
        //   三个隔离域之间无锁共享 —— 是实打实的数据竞争，String 的写时复制
        //   缓冲区还会产生 retain/release 竞争，可能过度释放而崩溃。
        //   把 receive/send 完成回调和 delegate 全部收敛到主线程，一次性消除。
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        session = s

        let t = s.webSocketTask(with: req)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()

        sendFullClientRequest()
        receiveLoop()
    }

    /// 送一包音频（16k / 16bit / 单声道 PCM）
    func send(audio: Data) {
        guard state == .streaming || state == .connecting else { return }
        audioPacketCount += 1
        let frame = Sauc.audioRequest(pcm: audio, isLast: false)
        task?.send(.data(frame)) { [weak self] err in
            if let err { self?.fail("发送音频失败：\(err.localizedDescription)") }
        }
    }

    /// 说完了：发末包，然后等最终结果（带超时兜底）
    func finish() {
        guard !didSendLastPacket, state == .streaming || state == .connecting else { return }
        didSendLastPacket = true
        state = .finalizing

        // 末包允许为空，但如果一包音频都没发过，服务端会回 45000002 空音频
        let frame = Sauc.audioRequest(pcm: Data(), isLast: true)
        task?.send(.data(frame)) { _ in }

        // openless 用 12s，这里给 6s —— 语音输入场景等太久用户会以为卡死
        finalTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
            guard let self, !self.didFinish else { return }
            Log.warn("等最终结果超时，用已有 partial 兜底")
            self.finishUp(self.lastPartial)
        }
    }

    func cancel() {
        // ⚠️ 必须置 didFinish：否则用户按 Esc 取消后，随后到达的最终帧
        //    仍会走 finishUp → onFinished → 文本照样被粘贴进光标处。
        didFinish = true
        finalTimer?.invalidate(); finalTimer = nil
        state = .closed
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - 发首包

    private func sendFullClientRequest() {
        var request: [String: Any] = [
            "model_name": "bigmodel",
            "enable_nonstream": config.enableNonstream,
            "show_utterances": true,          // 必开，否则拿不到 definite
            "result_type": "full",            // 全量返回 + 游标计数，比 single 更好对齐
            "end_window_size": config.endWindowSize,
            "force_to_speech_time": config.forceToSpeechTime,
            "enable_punc": config.enablePunc,
            "enable_itn": config.enableItn,
            "enable_ddc": config.enableDdc,
        ]

        if !config.hotwords.isEmpty {
            // 热词直传要求 payload 是 JSON string（内层需要自己序列化）
            let words = config.hotwords.prefix(60).map { ["word": $0] }
            if let inner = try? JSONSerialization.data(withJSONObject: ["hotwords": words]),
               let s = String(data: inner, encoding: .utf8) {
                request["corpus"] = ["context": s]
            }
        }

        let payload: [String: Any] = [
            "user": ["uid": Host.current().localizedName ?? "mac",
                     "platform": "macOS"],
            "audio": ["format": "pcm", "codec": "raw",
                      "rate": 16000, "bits": 16, "channel": 1],
            "request": request,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            fail("首包 JSON 序列化失败"); return
        }
        task?.send(.data(Sauc.fullClientRequest(json: json))) { [weak self] err in
            if let err { self?.fail("发送首包失败：\(err.localizedDescription)") }
        }
    }

    // MARK: - 收包

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                // 已经发过末包 → 多半是服务端正常关流，不当错误
                if self.didSendLastPacket {
                    if !self.didFinish { self.finishUp(self.lastPartial) }
                } else if self.state != .closed {
                    self.fail("连接中断：\(err.localizedDescription)")
                }
            case .success(let msg):
                switch msg {
                case .data(let d):  self.handle(d)
                case .string(let s): self.handle(Data(s.utf8))
                @unknown default: break
                }
                if self.state != .closed { self.receiveLoop() }
            }
        }
    }

    private func handle(_ raw: Data) {
        if state == .connecting { state = .streaming }

        let msg: Sauc.ServerMessage
        do { msg = try Sauc.parse(raw) }
        catch {
            Log.warn("帧解析失败：\(error) — 原始前 32 字节：\(raw.prefix(32).hexDump())")
            return
        }

        // ── 错误帧 ──
        if msg.messageType == Sauc.MessageType.serverError.rawValue {
            let code = msg.errorCode ?? 0
            let body = String(data: msg.payload, encoding: .utf8) ?? ""
            // type4me 实测：已经发过音频之后收到 0x0F，往往是 session 正常结束的信号，
            // 只有一包音频都没发过时才是真正的鉴权/参数错误。
            // ⚠️ 原来用 `audioPacketCount == 0` 区分「真错误」和「会话正常结束」，
            //    但 begin() 一上来就发预缓冲音频，这个判据在真实时序下几乎永远为假，
            //    于是所有服务端错误（45000001 参数无效、45000151 格式错误…）
            //    都被降级成「没听清」，用户永远看不到真实错误码和 logid。
            //    改成按错误码本身判断。
            if code == 20000000 {
                Log.info("服务端正常结束会话")
                if !didFinish { finishUp(lastPartial) }
            } else {
                fail("服务端错误 \(code)：\(Sauc.describeError(code))" +
                     (body.isEmpty ? "" : "  \(body)"))
            }
            return
        }

        // ── 正常响应 ──
        guard !msg.payload.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: msg.payload) as? [String: Any]
        else {
            if msg.isFinal, !didFinish { finishUp(lastPartial) }
            return
        }

        var update = ASRUpdate()

        if let result = obj["result"] as? [String: Any] {
            if let full = result["text"] as? String { update.fullText = full }

            if let utts = result["utterances"] as? [[String: Any]] {
                let definites = utts.filter { ($0["definite"] as? Bool) ?? false }
                if definites.count > committedUtteranceCount {
                    update.newDefinite = definites[committedUtteranceCount...]
                        .compactMap { $0["text"] as? String }
                        .joined()
                    committedUtteranceCount = definites.count
                }
                update.partial = utts
                    .filter { !(($0["definite"] as? Bool) ?? false) }
                    .compactMap { $0["text"] as? String }
                    .joined()
            } else if let full = result["text"] as? String {
                update.partial = full            // 没开 show_utterances 时的降级
            }
        }

        lastPartial = update.partial
        if !update.newDefinite.isEmpty || !update.partial.isEmpty || !update.fullText.isEmpty {
            onUpdate?(update)
        }

        // ⚠️ 流是否结束只认帧头 flags。绝不能用 payload 里的 definite 判断 ——
        //    openless 实测：收到第一个 definite=true 就关连接，会丢掉用户后续说的全部内容。
        if msg.isFinal, !didFinish {
            finishUp(update.partial)
        }
    }

    // MARK: -

    private func finishUp(_ trailing: String) {
        guard !didFinish else { return }
        didFinish = true
        finalTimer?.invalidate(); finalTimer = nil
        state = .closed
        onFinished?(trailing)
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }

    private func fail(_ message: String) {
        guard state != .closed, !didFinish else { return }
        Log.error(message + (logId.isEmpty ? "" : "  [logid=\(logId)]"))
        // ⚠️ 同样必须置 didFinish：否则 6 秒后的兜底定时器还会再触发一次
        //    onFinished，导致「先报错、再把同一段文字上屏一遍」。
        didFinish = true
        state = .closed
        finalTimer?.invalidate(); finalTimer = nil
        onError?(message)
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

// MARK: - URLSessionWebSocketDelegate

extension DoubaoStreamingASR: URLSessionWebSocketDelegate {

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol proto: String?) {
        // X-Tt-Logid 是排障唯一线索，必须留下来
        if let http = webSocketTask.response as? HTTPURLResponse {
            logId = (http.value(forHTTPHeaderField: "X-Tt-Logid")
                  ?? http.value(forHTTPHeaderField: "x-tt-logid") ?? "")
            Log.info("WebSocket 已连接  logid=\(logId)")
        }
        if state == .connecting { state = .streaming }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Log.info("WebSocket 关闭 code=\(closeCode.rawValue) \(why)")
        if !didFinish, didSendLastPacket { finishUp(lastPartial) }
    }
}

extension Data {
    func hexDump() -> String {
        map { String(format: "%02x", $0) }.joined(separator: " ")
    }
}
