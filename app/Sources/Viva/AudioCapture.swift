import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// 麦克风采集：设备原生格式 → 16kHz / 16bit / 单声道 PCM，按 200ms 分包。
///
/// 两个关键设计：
/// 1. **引擎常驻空转**（`prewarm`）—— 热键按下才启动引擎会有 100~300ms 冷启动，
///    开头几个字必丢。豆包官方 Mac 输入法实测就有这个毛病。
/// 2. **环形预缓冲**（`preRollMs`）—— 即使不在录音状态也持续保留最近 400ms 音频，
///    热键按下瞬间把这段一并送出。这是「不吃掉你的前三个字」的实现。
final class AudioCapture {

    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16000,
                                          channels: 1,
                                          interleaved: true)!

    /// 每包字节数：16000 samples/s × 2 bytes × 0.2s = 6400
    /// 官方建议 100~200ms，双向流式下 200ms 性能最优。
    private let chunkBytes = 6400

    private let lock = NSLock()
    private var preRoll = Data()        // 未录音时滚动保留的最近音频
    private var pending = Data()        // 录音中待发送的缓冲
    private var preRollMaxBytes: Int

    private(set) var isCapturing = false
    private(set) var isTesting = false
    private(set) var isRunning = false
    private var selectedInputUID: String
    private var runningDeviceIsBluetooth = false
    /// ⚠️ 必须持有并在 stopEngine 里移除。原来直接丢弃返回的 token，
    ///   而 rebuild() 内部又会调 prewarm() 再注册一个 —— 观察者数量会
    ///   随每次设备变化 2^N 翻倍，插拔几次耳机就能把主线程卡死。
    private var configObserver: NSObjectProtocol?

    /// 每满 200ms 回调一次
    var onChunk: ((Data) -> Void)?
    /// 实时音量 0...1，用于 HUD 波形
    var onLevel: ((Float) -> Void)?
    /// 本地麦克风测试的音量，不参与识别和计费
    var onTestLevel: ((Float) -> Void)?

    init(preRollMs: Int, inputDeviceUID: String = "") {
        preRollMaxBytes = 16000 * 2 * max(0, preRollMs) / 1000
        selectedInputUID = inputDeviceUID
    }

    // MARK: - 权限

    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default:
            done(false)
        }
    }

    static var hasPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    // MARK: - 引擎

    /// 当前选择的输入设备是不是蓝牙。
    ///
    /// ⚠️ 这个判断决定了要不要常驻预热，而它关系到一个**比竞品更严重**的问题：
    /// 打开输入设备会把 AirPods 从 A2DP（高音质单向）拉到 HFP/SCO（双向通话），
    /// 于是音乐变成打电话音质、双击切歌变成挂断提示音、音量曲线突变。
    /// 竞品是「触发过一次录音才降级」，而我们如果无脑常驻预热，
    /// 就是「App 一启动就降级、直到退出」—— 更糟。
    ///
    /// 所以：蓝牙设备下放弃常驻预热，改成按下热键才启动。
    /// 首字的损失由 preRoll 之外的即时启动补偿（蓝牙本来就有 SCO 建链延迟，
    /// 常驻预热在这类设备上收益也有限）。
    /// 现在**能不能开始录音**。注意这和 `isRunning` 不是一回事。
    ///
    /// ⚠️ 蓝牙路径下引擎是**故意不常驻**的（常驻会把耳机永久拉进 HFP 通话模式，
    ///   音乐变成打电话音质），要等按下热键才由 `startCapturing()` 即时启动。
    ///   所以这种情况下 `isRunning == false` 是**预期状态，不是故障** ——
    ///   调用方绝不能拿 `isRunning` 当「就绪」判据去拦录音，否则蓝牙耳机用户
    ///   每次按热键都会被拦下。这里按“所选设备仍在线”判断，非蓝牙引擎若因
    ///   热插拔停掉，下一次 startCapturing() 也能即时重启并自恢复。
    var canStart: Bool {
        (try? AudioInputDevices.resolve(uid: selectedInputUID)) != nil
    }

    /// App 启动时调用一次。引擎从此常驻，`isCapturing` 只控制数据往不往外送。
    ///
    /// - Parameter force: 忽略蓝牙判断强行预热（热键按下时用）
    func prewarm(force: Bool = false) throws {
        let device = try AudioInputDevices.resolve(uid: selectedInputUID)
        if !force, device.isBluetooth {
            Log.info("输入设备「\(device.name)」是蓝牙设备，跳过常驻预热 —— 避免把耳机永久拉进 HFP 通话模式")
            return
        }
        guard !isRunning else { return }

        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw NSError(domain: "AudioCapture", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "无法访问 Core Audio 输入单元"])
        }
        var deviceID = device.deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard setStatus == noErr else {
            throw NSError(domain: "AudioCapture", code: Int(setStatus), userInfo: [
                NSLocalizedDescriptionKey: "无法切换到「\(device.name)」（Core Audio \(setStatus)）"])
        }

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else {
            throw NSError(domain: "AudioCapture", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "拿不到输入设备格式（麦克风被占用或无可用输入设备）"])
        }
        Log.info("输入设备：\(device.name)（\(device.connectionLabel)）· \(Int(inFormat.sampleRate))Hz \(inFormat.channelCount)ch")

        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "AudioCapture", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "无法创建重采样器 \(inFormat) → \(outFormat)"])
        }
        converter = conv

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buf, _ in
            self?.process(buf)
        }

        // 设备热插拔 / 采样率突变时重建。注册前先摘掉旧的，避免叠加。
        if let ob = configObserver {
            NotificationCenter.default.removeObserver(ob)
            configObserver = nil
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Log.warn("音频设备配置变化，重建采集链路")
            self?.rebuild()
        }

        engine.prepare()
        try engine.start()
        isRunning = true
        runningDeviceIsBluetooth = device.isBluetooth
    }

    private var rebuildRetries = 0

    private func rebuild() {
        stopEngine(keepObserver: true)
        do {
            // 设备刚切换时 CoreAudio 常常还没稳定（采样率会短暂返回 0），
            // 立刻重建大概率失败 —— 失败要能重试，否则一次抖动就永久失效，
            // 而且报给用户的原因还是错的（竞品那条「其他应用正在录音」就是这么来的）。
            try prewarm(force: isCapturing || isTesting)
            rebuildRetries = 0
            // ⚠️ 必须把 audioEngineReady 置回 true。它在下面重试耗尽时被置 false，
            //   而全项目只有 AppDelegate 的启动流程会置 true（只跑一次）——
            //   少了这一句它就是个单向闩锁：设备恢复后引擎其实已经好了，
            //   但 canSpeak/isReady 恒为 false，录音球置灰、菜单栏一直显示未就绪，
            //   用户只能重启 App。
            Task { @MainActor in
                AppState.shared.audioEngineReady = true
                AppState.shared.lastError = ""
            }
        } catch {
            // 重建失败不能静默 —— 用户会遇到「麦克风突然不工作了」而毫无线索
            Log.error("重建采集失败：\(error.localizedDescription)")
            if rebuildRetries < 3 {
                rebuildRetries += 1
                let delay = Double(rebuildRetries) * 0.6
                Log.info("\(delay)s 后重试第 \(rebuildRetries) 次")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.rebuild()
                }
            } else {
                // 复位计数：不复位的话第二轮设备变化连一次重试都不会做
                rebuildRetries = 0
                Task { @MainActor in
                    AppState.shared.audioEngineReady = false
                    AppState.shared.lastError = "音频设备变化后重建失败（已重试 3 次）：\(error.localizedDescription)"
                }
            }
        }
    }

    /// - Parameter keepObserver: 重建流程要保留观察者。
    ///   ⚠️ 否则 prewarm() 在拿不到设备格式时提前抛错（此时还没走到重新注册那步），
    ///   观察者就永久没了 —— 设备再变化也不会重建，麦克风永久失效只能重启 App。
    func stopEngine(keepObserver: Bool = false) {
        if !keepObserver, let ob = configObserver {
            NotificationCenter.default.removeObserver(ob)
            configObserver = nil
        }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        runningDeviceIsBluetooth = false
    }

    deinit {
        if let ob = configObserver { NotificationCenter.default.removeObserver(ob) }
    }

    /// 改预缓冲时长**不需要**重建整条采集链路 —— 只是换个环形缓冲上限。
    /// 这样「保存并应用」永远不会去动音频设备，也就不可能报「麦克风重建失败」。
    func setPreRoll(ms: Int) {
        lock.lock(); defer { lock.unlock() }
        preRollMaxBytes = 16000 * 2 * max(0, ms) / 1000
        if preRoll.count > preRollMaxBytes {
            preRoll.removeFirst(preRoll.count - preRollMaxBytes)
        }
    }

    /// 切换输入硬件。设备 UID 为空时恢复为“跟随系统默认”。
    /// 蓝牙设备只校验可用性，不常驻启动；实际录音或测试时再按需启动。
    func setInputDevice(uid: String, shouldPrewarm: Bool = true) throws {
        guard !isCapturing else {
            throw NSError(domain: "AudioCapture", code: -4, userInfo: [
                NSLocalizedDescriptionKey: "正在录音，无法切换输入设备"])
        }
        if isTesting { stopTesting() }
        stopEngine()
        engine = AVAudioEngine()
        converter = nil
        selectedInputUID = uid

        // 即使没有麦克风权限，也先校验这个 UID 仍对应一台在线输入设备。
        _ = try AudioInputDevices.resolve(uid: uid)
        if shouldPrewarm { try prewarm() }
    }

    // MARK: - 录音开关

    /// 开始录音。返回预缓冲里攒下的音频（热键按下之前的那 400ms），应当作为第一批发出去。
    func startCapturing() -> Data {
        if isTesting { stopTesting() }
        // 蓝牙路径下引擎是不常驻的，按下热键才启动。
        // 代价是没有 preRoll，但换来的是耳机不会被长期拉进通话模式。
        if !isRunning {
            do { try prewarm(force: true) }
            catch { Log.error("即时启动采集失败：\(error.localizedDescription)") }
        }
        lock.lock(); defer { lock.unlock() }
        isCapturing = true
        let head = preRoll
        preRoll.removeAll(keepingCapacity: true)
        pending = head
        // 立刻把整包的部分吐出去，剩下不足一包的留在 pending
        var out = Data()
        while pending.count >= chunkBytes {
            out.append(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
        }
        return out
    }

    /// 停止录音，返回残留的不足一包的尾巴
    func stopCapturing() -> Data {
        lock.lock()
        isCapturing = false
        let tail = pending
        pending.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        lock.unlock()
        if runningDeviceIsBluetooth { stopEngine() }
        return tail
    }

    // MARK: - 本地输入测试

    func startTesting() throws {
        guard !isCapturing else {
            throw NSError(domain: "AudioCapture", code: -5, userInfo: [
                NSLocalizedDescriptionKey: "正在进行语音输入，暂时不能测试麦克风"])
        }
        guard !isTesting else { return }
        if !isRunning { try prewarm(force: true) }
        guard isRunning else {
            throw NSError(domain: "AudioCapture", code: -6, userInfo: [
                NSLocalizedDescriptionKey: "输入设备启动失败"])
        }

        lock.lock()
        pending.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        isTesting = true
        lock.unlock()
    }

    func stopTesting() {
        lock.lock()
        isTesting = false
        pending.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        lock.unlock()
        if runningDeviceIsBluetooth { stopEngine() }
    }

    // MARK: - 处理

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let conv = converter, buf.frameLength > 0 else { return }

        let ratio = outFormat.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }

        var consumed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buf
        }
        if let err {
            Log.debug("重采样失败：\(err.localizedDescription)")
            return
        }
        guard out.frameLength > 0, let ch = out.int16ChannelData else { return }

        let n = Int(out.frameLength)
        let data = Data(bytes: ch[0], count: n * MemoryLayout<Int16>.size)

        // 音量（RMS → 0...1），给 HUD 画波形
        var sum: Double = 0
        for i in 0..<n { let s = Double(ch[0][i]) / 32768.0; sum += s * s }
        let rms = Float((sum / Double(max(n, 1))).squareRoot())
        let level = min(1, max(0, rms * 6))
        var ready: [Data] = []
        lock.lock()
        let testing = isTesting
        if isCapturing {
            pending.append(data)
            while pending.count >= chunkBytes {
                ready.append(pending.prefix(chunkBytes))
                pending.removeFirst(chunkBytes)
            }
        } else {
            preRoll.append(data)
            if preRoll.count > preRollMaxBytes {
                preRoll.removeFirst(preRoll.count - preRollMaxBytes)
            }
        }
        lock.unlock()

        DispatchQueue.main.async {
            self.onLevel?(level)
            if testing { self.onTestLevel?(level) }
        }

        for chunk in ready { onChunk?(chunk) }
    }
}
