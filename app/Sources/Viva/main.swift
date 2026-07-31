import Foundation
import AppKit
import AVFoundation

// MARK: - 自检模式：把一个音频文件当作麦克风推给 Viva Gateway
//
// 用途：不碰麦克风、不碰辅助功能权限，纯验证「自动鉴权 + Gateway + SAUC」是否正确。
// 这是 M0 阶段该做的第一件事 —— 把协议调试和 App 工程两个风险源分开。
//
//   ./Viva --selftest /path/to/audio.wav

func runSelfTest(path: String) -> Never {
    let config = Config.load()
    guard config.hasValidBackendConfiguration else {
        print("✖ \(config.backendConfigurationError ?? "Viva 服务地址无效")")
        exit(2)
    }

    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("✖ 文件不存在：\(url.path)"); exit(2)
    }

    // 读音频并统一转成 16k / 16bit / 单声道
    let pcm: Data
    do { pcm = try loadAsPCM16k(url: url) }
    catch { print("✖ 读取音频失败：\(error.localizedDescription)"); exit(2) }

    let seconds = Double(pcm.count) / (16000 * 2)
    print("""
    ── Viva 托管语音识别 自检 ──
    音频      \(url.lastPathComponent)  \(String(format: "%.1f", seconds))s  \(pcm.count) 字节
    环境      \(config.testModeEnabled ? "本地测试" : "生产托管")
    服务      \(config.backendBaseURL?.absoluteString ?? "无效")
    鉴权      邮箱账户 Bearer + 一次性 ASR ticket
    参数      16kHz / 16bit / mono PCM，服务端托管识别参数
    ─────────────────────────
    """)

    let asr = DoubaoStreamingASR(config: config)

    var done = false
    var committed = ""
    let t0 = Date()
    var firstAt: Date?

    asr.onUpdate = { u in
        if firstAt == nil, !u.newDefinite.isEmpty || !u.partial.isEmpty {
            firstAt = Date()
            print(String(format: "⏱ 首字返回 %.0f ms", firstAt!.timeIntervalSince(t0) * 1000))
        }
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if !u.newDefinite.isEmpty {
            // definite 到达的时刻 = 真正能上屏的时刻。这条时间线直接决定
            // 「边说边打字」到底成不成立 —— 如果只有末尾一条，那就是「说完才上屏」。
            committed += u.newDefinite
            print(String(format: "✅ [%6dms] definite  %@", ms, u.newDefinite))
        }
        if !u.partial.isEmpty, Log.verbose {
            print(String(format: "   [%6dms] partial   %@", ms, u.partial))
        }
    }
    asr.onError = { msg in
        print("✖ \(msg)")
        done = true
    }
    asr.onFinished = { trailing in
        if !trailing.isEmpty { committed += trailing }
        print("""
        ─────────────────────────
        最终结果：\(committed.isEmpty ? "（空）" : committed)
        总耗时：\(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms
        logid：\(asr.logId.isEmpty ? "（未取到）" : asr.logId)
        """)
        done = true
    }

    asr.start()

    // 按 200ms 一包、间隔 200ms 推流，模拟真实说话节奏
    let chunkBytes = 6400
    var offset = 0
    // ⚠️ send / finish 必须回主线程调用。
    //   DoubaoStreamingASR 的前提是「所有可变状态收敛到主线程」（见其 delegateQueue 注释），
    //   而 URLSession 的回调本来就在主线程跑 receiveLoop→handle，写着同一批 state/String。
    //   在后台队列直接调是实打实的数据竞争，String 的写时复制缓冲区还会产生
    //   retain/release 竞争，可能过度释放而崩溃。
    //   另外 finish() 里那个 6 秒兜底 Timer 是挂到 RunLoop.current 上的 ——
    //   在这个从不运行 run loop 的后台线程上它永远不会触发，
    //   代理拦截 WebSocket 握手时就拿不到那条精确提示。
    let queue = DispatchQueue(label: "selftest.feed")
    queue.async {
        while offset < pcm.count {
            let end = min(offset + chunkBytes, pcm.count)
            let packet = pcm.subdata(in: offset..<end)
            DispatchQueue.main.async { asr.send(audio: packet) }
            offset = end
            Thread.sleep(forTimeInterval: 0.2)      // 节流仍在后台，不阻塞主线程
        }
        DispatchQueue.main.async { asr.finish() }
    }

    let deadline = Date().addingTimeInterval(seconds + 30)
    while !done, Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    if !done { print("✖ 超时，没有收到最终结果") }
    exit(done && !committed.isEmpty ? 0 : 1)
}

/// 本地服务端账户链路自检。只在 local/test 返回 dev_code 时可用，且从不打印
/// OTP、Access Token、Refresh Token 或 ASR ticket。
func runAccountSelfTest(email: String) -> Never {
    let config = Config.load()
    guard let baseURL = config.backendBaseURL else {
        print("✖ \(config.backendConfigurationError ?? "Viva 服务地址无效")")
        exit(2)
    }

    Task.detached {
        do {
            let auth = ManagedBackendAuth.shared
            print("自检 1/7：请求邮箱验证码")
            let challenge = try await auth.requestOTP(email: email, purpose: .login,
                                                       baseURL: baseURL)
            guard let code = challenge.developerCode else {
                throw ManagedBackendAuth.AuthError.invalidInput(
                    "当前服务未返回本地开发验证码；该自检不能用于正式环境")
            }
            print("自检 2/7：验证并登录账户")
            _ = try await auth.stableDeviceID()
            print("自检 2/7：设备标识已就绪")
            let verification = try await auth.verifyOTP(email: email, code: code,
                                                         baseURL: baseURL)
            print("自检 3/7：强制轮换 Token")
            _ = try await auth.refreshNow(baseURL: baseURL)
            print("自检 4/7：读取账户与积分")
            let user = try await auth.me(baseURL: baseURL)
            let before = try await auth.balance(baseURL: baseURL)

            var polishConfig = config
            polishConfig.enablePolish = true
            polishConfig.polishStream = true
            print("自检 5/7：请求 LLM SSE 润色")
            let polished = try await LLMPolisher(config: polishConfig)
                .polish("嗯，这个这个方案可以上线")
            print("自检 6/7：确认润色后积分")
            let after = try await auth.balance(baseURL: baseURL)

            print("""
            ── Viva 账户链路自检 ──
            环境      \(baseURL.absoluteString)
            账户      \(user.email ?? "（无邮箱）")
            结果      \(verification.created ? "注册并登录" : "登录已有账户")
            刷新      成功（Token 未输出）
            润色      \(polished.text)
            积分      \(before.wallet.availablePoints) → \(after.wallet.availablePoints)
            ──────────────────────
            """)
            if ProcessInfo.processInfo.environment["VIVA_SELFTEST_KEEP_SESSION"] != "1" {
                print("自检 7/7：退出并清理测试会话")
                try await auth.logout(baseURL: baseURL)
            }
            exit(0)
        } catch {
            print("✖ 账户链路自检失败：\(error.localizedDescription)")
            try? await ManagedBackendAuth.shared.logout(baseURL: baseURL)
            exit(1)
        }
    }

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) {
        print("✖ 账户链路自检超时")
        exit(1)
    }
    // URLSession on macOS still relies on CFRunLoop sources in this command-line
    // mode. `dispatchMain()` services GCD but can leave the async data task
    // suspended after the server has already returned its response.
    while true {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

/// Restores the session created by `--account-selftest` in a fresh process.
/// This proves persistence without printing any token or touching the user's
/// real session when `VIVA_SELFTEST_AUTH_DIR` points to an isolated /tmp path.
func runAccountRestoreSelfTest() -> Never {
    let config = Config.load()
    guard let baseURL = config.backendBaseURL else {
        print("✖ \(config.backendConfigurationError ?? "Viva 服务地址无效")")
        exit(2)
    }

    Task.detached {
        do {
            let auth = ManagedBackendAuth.shared
            print("恢复自检 1/2：从本机会话恢复账户")
            guard let snapshot = try await auth.restore(baseURL: baseURL) else {
                throw ManagedBackendAuth.AuthError.notLoggedIn
            }
            print("""
            ── Viva 登录恢复自检 ──
            账户      \(snapshot.user.email ?? "（无邮箱）")
            积分      \(snapshot.balance.wallet.availablePoints)
            结果      新进程静默恢复成功（Token 未输出）
            ──────────────────────
            """)
            print("恢复自检 2/2：退出并清理测试会话")
            try await auth.logout(baseURL: baseURL)
            exit(0)
        } catch {
            print("✖ 登录恢复自检失败：\(error.localizedDescription)")
            exit(1)
        }
    }

    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
        print("✖ 登录恢复自检超时")
        exit(1)
    }
    while true {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

/// 用 AVAudioFile 读任意音频（wav/m4a/mp3…），统一转成 16kHz 单声道 Int16 PCM
func loadAsPCM16k(url: URL) throws -> Data {
    let file = try AVAudioFile(forReading: url)
    let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                  sampleRate: 16000, channels: 1, interleaved: true)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: outFormat) else {
        throw NSError(domain: "selftest", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "无法创建重采样器"])
    }

    var out = Data()
    let frames: AVAudioFrameCount = 8192
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: frames) else {
        throw NSError(domain: "selftest", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "分配缓冲失败"])
    }

    while true {
        try file.read(into: inBuf, frameCount: frames)
        if inBuf.frameLength == 0 { break }

        let ratio = 16000.0 / file.processingFormat.sampleRate
        let cap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { break }

        var consumed = false
        var err: NSError?
        converter.convert(to: outBuf, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return inBuf
        }
        if let err { throw err }
        if let ch = outBuf.int16ChannelData, outBuf.frameLength > 0 {
            out.append(Data(bytes: ch[0], count: Int(outBuf.frameLength) * 2))
        }
        if inBuf.frameLength < frames { break }
    }
    return out
}

// MARK: - 入口

let args = CommandLine.arguments

// 越早装越好：初始化阶段的崩溃也要能留下记录
CrashReporter.install()

if args.contains("--help") || args.contains("-h") {
    print("""
    Viva 托管语音输入

      Viva                     以菜单栏 App 启动
      Viva --account-selftest <邮箱>  本地验证注册、登录、刷新、余额与润色
      Viva --account-restore-selftest  用隔离目录验证新进程自动恢复登录
      Viva --selftest <音频>    不用麦克风，直接把音频文件推给 Viva Gateway
      Viva --help

    配置文件：\(Config.configURL.path)
    环境变量：VIVA_TEST_MODE=1 / VIVA_TEST_BACKEND_URL=http://127.0.0.1:8080 / VIVA_SELFTEST_AUTH_DIR=/tmp/... / VIVA_VERBOSE=1
    """)
    exit(0)
}

if let i = args.firstIndex(of: "--selftest") {
    guard i + 1 < args.count else {
        print("✖ --selftest 需要一个音频文件路径"); exit(2)
    }
    runSelfTest(path: args[i + 1])
}

if let i = args.firstIndex(of: "--account-selftest") {
    guard i + 1 < args.count else {
        print("✖ --account-selftest 需要一个测试邮箱"); exit(2)
    }
    runAccountSelfTest(email: args[i + 1])
}

if args.contains("--account-restore-selftest") {
    runAccountRestoreSelfTest()
}

// main.swift 的顶层代码实际就跑在主线程上，但编译器不知道，
// 所以要显式告诉它这里已经在 MainActor 上。
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
