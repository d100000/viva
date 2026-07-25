import Foundation
import AppKit
import AVFoundation

// MARK: - 自检模式：把一个音频文件当作麦克风推给豆包
//
// 用途：不碰麦克风、不碰辅助功能权限，纯验证「凭证 + 协议 + 参数」是否正确。
// 这是 M0 阶段该做的第一件事 —— 把协议调试和 App 工程两个风险源分开。
//
//   ./Viva --selftest /path/to/audio.wav

func runSelfTest(path: String) -> Never {
    let config = Config.load()
    guard config.hasCredentials else {
        print("""
        ✖ 没有找到 API Key。

          方式一（推荐）：export DOUBAO_API_KEY=你的key
          方式二：写进 \(Config.configURL.path)
        """)
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
    ── 豆包流式语音识别 自检 ──
    音频      \(url.lastPathComponent)  \(String(format: "%.1f", seconds))s  \(pcm.count) 字节
    端点      \(config.endpoint)
    资源      \(config.resourceId)
    鉴权      \(config.apiKey.isEmpty ? "旧版控制台 AppKey/AccessKey" : "新版控制台 x-api-key ****\(String(config.apiKey.suffix(4)))")
    参数      end_window_size=\(config.endWindowSize)  nonstream=\(config.enableNonstream)  ddc=\(config.enableDdc)
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

if args.contains("--help") || args.contains("-h") {
    print("""
    豆包流式语音输入

      Viva                     以菜单栏 App 启动
      Viva --selftest <音频>    不用麦克风，直接把音频文件推给豆包验证协议
      Viva --help

    配置文件：\(Config.configURL.path)
    环境变量：DOUBAO_API_KEY / DOUBAO_RESOURCE_ID / DOUBAO_ENDPOINT / DOUBAO_VERBOSE
    """)
    exit(0)
}

if let i = args.firstIndex(of: "--selftest") {
    guard i + 1 < args.count else {
        print("✖ --selftest 需要一个音频文件路径"); exit(2)
    }
    runSelfTest(path: args[i + 1])
}

// main.swift 的顶层代码实际就跑在主线程上，但编译器不知道，
// 所以要显式告诉它这里已经在 MainActor 上。
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
