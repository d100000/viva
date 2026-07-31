import Foundation
import CryptoKit

/// 一次识别会话的结果回调
struct ASRUpdate {
    /// 本次新确定（definite）的文本，可直接上屏
    var newDefinite: String = ""
    /// 当前尚未定稿的文本，只用于 HUD 预览，**不要写进输入框**
    var partial: String = ""
    /// 到目前为止的完整文本（已定稿 + 未定稿）
    var fullText: String = ""
}

/// Viva 托管语音识别 WebSocket 客户端。
/// 客户端继续使用现有 SAUC 二进制帧，但只连接 Viva Gateway；火山地址和长期凭证
/// 由服务端 allowlist 与密钥系统管理，永远不会从这里透传。
final class DoubaoStreamingASR: NSObject {

    enum State { case idle, connecting, streaming, finalizing, closed }

    private let config: Config
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var authTask: Task<Void, Never>?
    private struct OutboundFrame {
        let data: Data
        let context: String
        let startsFinalTimer: Bool
    }
    /// 申请一次性 ASR ticket 尚未结束时先缓存音频，避免热键路径丢掉开头。
    private var pendingFrames: [OutboundFrame] = []
    /// URLSessionWebSocketTask 的 send 不能并发调用；所有二进制帧严格串行。
    private var outboundFrames: [OutboundFrame] = []
    private var sendInFlight = false
    /// Full request 可以立即发送；音频必须等 Gateway 确认上游就绪后再按序刷出，
    /// 避免客户端长时间鉴权缓存与 Gateway 256KiB 缓冲叠加后溢出。
    private var upstreamReady = false
    /// 发给语音供应商的不可逆伪标识；真实 Viva device ID 只保留在鉴权 Header。
    private var managedProviderUID = "viva_anonymous_device"

    private(set) var state: State = .idle
    private(set) var logId: String = ""
    /// WebSocket 是否真的握手成功过。
    /// ⚠️ 本地代理（Clash / AdGuard）会拦掉 WSS 的 Upgrade 握手，此时 state 停在
    ///    .connecting，用户松手后照样发末包、6 秒后兜底定时器拿着空 partial 收尾，
    ///    最终提示「没听清，再说一次」—— 用户永远查不出是代理的问题。
    private var didConnect = false

    /// 已提交的 definite 分句数，用作游标（result_type = full 时避免重复上屏）
    private var committedUtteranceCount = 0
    private var lastPartial = ""
    private var audioPacketCount = 0
    private var didSendLastPacket = false
    private var didSendFullRequest = false

    var onUpdate: ((ASRUpdate) -> Void)?
    var onError: ((String) -> Void)?
    /// 流真正结束（收到帧头 flags 标记的 final 帧，或服务端正常关闭）
    var onFinished: ((String) -> Void)?

    private var finalTimer: Timer?
    private var readinessTimer: Timer?
    private var didFinish = false

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - 生命周期

    func start() {
        guard state == .idle else { return }
        state = .connecting

        guard let baseURL = config.backendBaseURL else {
            fail(config.backendConfigurationError ?? "Viva 服务地址无效"); return
        }

        Log.debug("开始申请 Viva ASR 一次性 ticket")
        authTask = Task { [weak self] in
            do {
                async let deviceID = ManagedBackendAuth.shared.stableDeviceID()
                async let ticket = ManagedBackendAuth.shared.createASRTicket(baseURL: baseURL)
                let (stableDeviceID, issuedTicket) = try await (deviceID, ticket)
                guard let url = Self.webSocketURL(ticket: issuedTicket, baseURL: baseURL) else {
                    throw ManagedBackendAuth.AuthError.invalidResponse
                }
                guard let owner = self else { return }
                await MainActor.run { [owner] in
                    guard owner.state == .connecting || owner.state == .finalizing else { return }
                    owner.managedProviderUID = Self.providerUID(for: stableDeviceID)
                    owner.openSocket(url: url)
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard let owner = self else { return }
                await MainActor.run { [owner] in
                    owner.fail("连接 Viva 服务失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func openSocket(url: URL) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("viva.sauc.v1", forHTTPHeaderField: "Sec-WebSocket-Protocol")

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

        receiveLoop()
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            guard let self, !self.didFinish, !self.upstreamReady else { return }
            self.fail("Viva 语音服务上游连接超时，请重试")
        }
    }

    /// 送一包音频（16k / 16bit / 单声道 PCM）
    func send(audio: Data) {
        guard state == .streaming || state == .connecting else { return }
        audioPacketCount += 1
        let frame = Sauc.audioRequest(pcm: audio, isLast: false)
        sendOrQueue(frame, context: "发送音频失败")
    }

    /// 说完了：发末包，然后等最终结果（带超时兜底）
    func finish() {
        guard !didSendLastPacket, state == .streaming || state == .connecting else { return }
        didSendLastPacket = true
        state = .finalizing

        // 末包允许为空，但如果一包音频都没发过，服务端会回 45000002 空音频
        let frame = Sauc.audioRequest(pcm: Data(), isLast: true)
        sendOrQueue(frame, context: "发送末包失败", startsFinalTimer: true)
    }

    private func scheduleFinalTimerIfNeeded() {
        guard task != nil, upstreamReady, finalTimer == nil else { return }
        // 从“末包实际刷出”开始计时。Gateway 契约允许上游 final 最长约 8 秒，
        // 留 1 秒调度余量，避免正常慢尾包被客户端过早截断。
        finalTimer = Timer.scheduledTimer(withTimeInterval: 9.0, repeats: false) { [weak self] _ in
            guard let self, !self.didFinish else { return }
            // 从没连上过 → 不是「没听清」，是网络/代理问题，必须如实报
            guard self.didConnect else {
                self.fail("Viva 语音连接始终没有建立。请检查网络、代理，或确认测试模式下的本地服务已启动")
                return
            }
            Log.warn("等最终结果超时，丢弃未确认 partial")
            self.fail("等待最终识别结果超时，请重试")
        }
    }

    func cancel() {
        // ⚠️ 必须置 didFinish：否则用户按 Esc 取消后，随后到达的最终帧
        //    仍会走 finishUp → onFinished → 文本照样被粘贴进光标处。
        didFinish = true
        finalTimer?.invalidate(); finalTimer = nil
        readinessTimer?.invalidate(); readinessTimer = nil
        state = .closed
        authTask?.cancel(); authTask = nil
        pendingFrames.removeAll()
        outboundFrames.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: - 发首包

    private func sendFullClientRequest() {
        guard !didSendFullRequest else { return }
        didSendFullRequest = true

        let request: [String: Any] = [
            "model_name": "bigmodel",
            "show_utterances": true,          // 必开，否则拿不到 definite
            "result_type": "full",            // 全量返回 + 游标计数，比 single 更好对齐
        ]

        let payload: [String: Any] = [
            "user": ["uid": managedProviderUID],
            "audio": ["format": "pcm", "codec": "raw",
                      "rate": 16000, "bits": 16, "channel": 1],
            "request": request,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: payload) else {
            fail("首包 JSON 序列化失败"); return
        }
        enqueueOutbound(OutboundFrame(data: Sauc.fullClientRequest(json: json),
                                      context: "发送首包失败",
                                      startsFinalTimer: false))
    }

    // MARK: - 收包

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                guard !self.didFinish, self.state != .closed else { return }
                // 从没握手成功 + badServerResponse = 服务端拒绝了握手（非 101）。
                if !self.didConnect, (err as? URLError)?.code == .badServerResponse {
                    self.failOrDiagnose(err, context: "连接被拒")
                    return
                }
                // 即使已经发过末包，也必须等到 SAUC final；网络断开不能把 partial
                // 冒充最终文本上屏。
                let hint: String
                if let u = err as? URLError {
                    switch u.code {
                    case .cannotFindHost, .dnsLookupFailed:
                        hint = "（DNS 解析失败，可能被本地代理或 DNS 工具改写）"
                    case .secureConnectionFailed, .serverCertificateUntrusted:
                        hint = "（TLS 握手失败，可能有中间人代理）"
                    case .notConnectedToInternet, .networkConnectionLost:
                        hint = "（网络已断开）"
                    case .timedOut:
                        hint = "（超时，检查代理设置）"
                    default: hint = ""
                    }
                } else { hint = "" }
                self.fail("连接中断，未收到最终识别结果：\(err.localizedDescription)\(hint)")
            case .success(let msg):
                switch msg {
                case .data(let d):  self.handle(d)
                case .string(let s): self.handleGatewayControl(s)
                @unknown default: break
                }
                if self.state != .closed { self.receiveLoop() }
            }
        }
    }

    private func handle(_ raw: Data) {
        if state == .connecting { state = .streaming }
        didConnect = true

        let msg: Sauc.ServerMessage
        do { msg = try Sauc.parse(raw) }
        catch {
            Log.warn("语音响应帧解析失败：\(error)（\(raw.count) bytes）")
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
                Log.warn("上游语音错误 code=\(code) payloadBytes=\(body.utf8.count)")
                fail("Viva 语音服务暂时不可用（错误码 \(code)）")
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
        // ⚠️ 这道 didFinish 守卫不是冗余（下面的 finishUp、fail 各自都有一道）。
        //   cancel() 只置 didFinish + task.cancel()，**已经排进 delegateQueue(.main)
        //   的完成块拦不住**。少了它，用户按 Esc 之后、或 6 秒兜底 finishUp 之后，
        //   在途的那一帧仍会触发 onUpdate → VoiceSession 在逐句上屏模式下把一句话
        //   真的粘进用户输入框，而按「只追加绝不退格」这句永远撤不回。
        if !didFinish,
           !update.newDefinite.isEmpty || !update.partial.isEmpty || !update.fullText.isEmpty {
            onUpdate?(update)
        }

        // ⚠️ 流是否结束只认帧头 flags。绝不能用 payload 里的 definite 判断 ——
        //    openless 实测：收到第一个 definite=true 就关连接，会丢掉用户后续说的全部内容。
        if msg.isFinal, !didFinish {
            finishUp(update.partial)
        }
    }

    /// Gateway 控制事件与火山 SAUC binary 可以交错到达，绝不能把 JSON text 当二进制帧解析。
    private func handleGatewayControl(_ raw: String) {
        guard !didFinish, state != .closed else { return }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            Log.warn("收到无法识别的 Gateway 文本消息（\(raw.utf8.count) bytes）")
            return
        }
        switch type {
        case "gateway.session.accepted":
            Log.debug("Viva Gateway 已接受语音会话")
            // v1 契约要求 accepted 后首个二进制消息必须是严格最小 SAUC full request。
            sendFullClientRequest()
        case "gateway.upstream.ready":
            if let value = object["upstream_log_id"] as? String, !value.isEmpty {
                logId = value
            }
            Log.info("Viva Gateway 上游已就绪" + (logId.isEmpty ? "" : "  logid=\(logId)"))
            upstreamReady = true
            readinessTimer?.invalidate(); readinessTimer = nil
            flushPendingFrames()
        case "gateway.session.draining":
            Log.warn("Viva Gateway 正在排空，本次会话完成后将迁移连接")
        case "gateway.error":
            let code = object["code"] as? String ?? "GATEWAY_ERROR"
            let retryable = object["retryable"] as? Bool ?? false
            Log.warn("Viva Gateway 返回错误 code=\(code) retryable=\(retryable)")
            fail(retryable
                 ? "Viva 语音服务暂时不可用（\(code)），请重试"
                 : "Viva 语音服务无法完成本次请求（\(code)）")
        default:
            Log.debug("Gateway 控制事件：\(type)")
        }
    }

    // MARK: -

    private func finishUp(_ trailing: String) {
        guard !didFinish else { return }
        didFinish = true
        authTask?.cancel(); authTask = nil
        pendingFrames.removeAll()
        outboundFrames.removeAll()
        finalTimer?.invalidate(); finalTimer = nil
        readinessTimer?.invalidate(); readinessTimer = nil
        state = .closed
        onFinished?(trailing)
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
    }

    /// ticket 握手失败时不探测供应商上游，也不撤销邮箱会话；下一次语音会话
    /// 会重新申请一次性 ticket。
    private func failOrDiagnose(_ err: Error, context: String) {
        guard state != .closed, !didFinish else { return }
        if !didConnect, (err as? URLError)?.code == .badServerResponse {
            fail("Viva 服务拒绝了语音连接。请重试；测试模式下请确认本地 URL、反向代理和服务进程均已启动")
        } else {
            fail("\(context)：\(err.localizedDescription)")
        }
    }

    private func sendOrQueue(_ frame: Data, context: String,
                             startsFinalTimer: Bool = false) {
        let item = OutboundFrame(data: frame, context: context,
                                 startsFinalTimer: startsFinalTimer)
        guard task != nil, upstreamReady else {
            if pendingFrames.count >= 64 {
                pendingFrames.removeFirst()
                Log.warn("等待 Viva ASR ticket 时音频缓存已满，丢弃最早一包")
            }
            pendingFrames.append(item)
            return
        }
        enqueueOutbound(item)
    }

    private func flushPendingFrames() {
        guard task != nil, upstreamReady, !didFinish else { return }
        let queued = pendingFrames
        pendingFrames.removeAll(keepingCapacity: true)
        for item in queued { enqueueOutbound(item) }
    }

    private func enqueueOutbound(_ item: OutboundFrame) {
        guard !didFinish else { return }
        outboundFrames.append(item)
        pumpOutboundQueue()
    }

    private func pumpOutboundQueue() {
        guard !sendInFlight, let task, !outboundFrames.isEmpty, !didFinish else { return }
        sendInFlight = true
        let item = outboundFrames.removeFirst()
        task.send(.data(item.data)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.sendInFlight = false
                guard !self.didFinish else { return }
                if let error {
                    self.failOrDiagnose(error, context: item.context)
                    return
                }
                if item.startsFinalTimer { self.scheduleFinalTimerIfNeeded() }
                self.pumpOutboundQueue()
            }
        }
    }

    private func fail(_ message: String) {
        guard state != .closed, !didFinish else { return }
        Log.error(message + (logId.isEmpty ? "" : "  [logid=\(logId)]"))
        // ⚠️ 同样必须置 didFinish：否则 6 秒后的兜底定时器还会再触发一次
        //    onFinished，导致「先报错、再把同一段文字上屏一遍」。
        didFinish = true
        state = .closed
        authTask?.cancel(); authTask = nil
        pendingFrames.removeAll()
        outboundFrames.removeAll()
        finalTimer?.invalidate(); finalTimer = nil
        readinessTimer?.invalidate(); readinessTimer = nil
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
        guard proto == "viva.sauc.v1" else {
            fail("Viva 语音服务协议协商失败")
            return
        }
        // X-Tt-Logid 是排障唯一线索，必须留下来
        if let http = webSocketTask.response as? HTTPURLResponse {
            didConnect = true
            logId = (http.value(forHTTPHeaderField: "X-Tt-Logid")
                  ?? http.value(forHTTPHeaderField: "x-tt-logid") ?? "")
            Log.info("WebSocket 已连接  logid=\(logId)")
        }
        if state == .connecting { state = .streaming }
        didConnect = true
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Log.info("WebSocket 关闭 code=\(closeCode.rawValue) reasonBytes=\(why.utf8.count)")
        guard !didFinish, state != .closed else { return }
        if closeCode == .normalClosure, !lastPartial.isEmpty {
            finishUp(lastPartial)
        } else {
            fail(closeCode == .normalClosure
                 ? "语音连接正常结束，但没有返回可用文字"
                 : "Viva 语音连接异常关闭（\(closeCode.rawValue)），请重试")
        }
    }
}

private extension DoubaoStreamingASR {
    /// 服务端返回的 websocket_url 当前是相对路径；也兼容未来返回同源绝对 URL。
    /// 无论响应写 http(s) 还是 ws(s)，最终协议都跟随受信任的 Base URL。
    static func webSocketURL(ticket: ManagedASRTicket, baseURL: URL) -> URL? {
        guard let resolved = URL(string: ticket.websocketURL, relativeTo: baseURL)?.absoluteURL,
              var target = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              let base = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              target.host?.lowercased() == base.host?.lowercased(),
              target.port == base.port,
              target.user == nil, target.password == nil,
              target.fragment == nil
        else { return nil }

        switch base.scheme?.lowercased() {
        case "http": target.scheme = "ws"
        case "https": target.scheme = "wss"
        default: return nil
        }
        return target.url
    }

    /// 服务端规范：viva_ + base32(SHA256(device_id))[0:26]。
    static func providerUID(for deviceID: String) -> String {
        let digest = Array(SHA256.hash(data: Data(deviceID.utf8)))
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(26)

        for bitOffset in stride(from: 0, to: digest.count * 8, by: 5) {
            var value = 0
            for bit in 0..<5 {
                value <<= 1
                let absolute = bitOffset + bit
                if absolute < digest.count * 8 {
                    let byte = digest[absolute / 8]
                    value |= Int((byte >> UInt8(7 - absolute % 8)) & 1)
                }
            }
            encoded.append(alphabet[value])
            if encoded.count == 26 { break }
        }
        return "viva_" + String(decoding: encoded, as: UTF8.self)
    }
}
