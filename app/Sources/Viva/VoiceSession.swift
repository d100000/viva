import Foundation
import AppKit

/// 会话状态机：热键 → 采集 → 推流 → （润色）→ 上屏 → 记录。
@MainActor
final class VoiceSession {

    enum State { case idle, listening, finalizing, polishing }

    private(set) var state: State = .idle
    private var config: Config
    private let capture: AudioCapture
    private let hud: HUDController
    private let app = AppState.shared

    private var asr: DoubaoStreamingASR?
    private var committedText = ""
    private var pendingCommit = ""
    /// 已经写进目标 App 的字符数（按字素簇计），润色替换时要靠它算退格次数
    private var injectedCharCount = 0
    private var targetBundleId: String?
    private var targetAppName: String?
    private var startedAt: Date?
    /// 检测到人声的时刻。首字延迟要从这里算 ——
    /// 从「热键按下」算会把用户按下键之后、真正开口之前的反应时间也算进去，
    /// 实测会虚高 800ms 以上，那不是系统的延迟。
    private var firstVoiceAt: Date?
    private var firstCharAt: Date?
    /// 试听模式：结果只显示在主界面，不写进任何 App（因此不需要辅助功能权限）
    private var testMode = false

    private(set) var billedSeconds: Double = 0

    var onStateChange: ((State) -> Void)?

    /// 是否推迟上屏到最后。
    ///
    /// **开了 AI 润色就必须推迟** —— 润色要拿完整文本才能做，
    /// 而逐句上屏意味着文字已经写进去了，之后再改就得退格删用户屏幕上的东西。
    /// 所以：润色开 = 说话时只在悬浮窗显示，润色完一次性粘贴；
    ///       润色关 = 逐句上屏，真正的边说边写。
    private var deferCommit: Bool {
        testMode || config.commitOnlyAtEnd || config.polishReady
    }

    init(config: Config, capture: AudioCapture, hud: HUDController) {
        self.config = config
        self.capture = capture
        self.hud = hud

        capture.onChunk = { [weak self] chunk in
            Task { @MainActor in
                guard let self, self.state == .listening else { return }
                self.asr?.send(audio: chunk)
                self.addBilled(chunk.count)
            }
        }
        capture.onLevel = { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                // @Published 不做相等判断，无条件赋值会让主窗口以约 23Hz 持续重绘，
                // 而统计是每次渲染现算的 O(N) 全表扫描 —— 记录一多就卡。
                // 空闲时只在需要归零时写一次，录音时变化小于阈值也跳过。
                let target: Float = self.state == .idle ? 0 : level
                if abs(self.app.level - target) > 0.02 || (target == 0 && self.app.level != 0) {
                    self.app.level = target
                }
                if self.state != .idle { self.hud.update(level: level) }
                if self.state == .listening, self.firstVoiceAt == nil, level > 0.06 {
                    self.firstVoiceAt = Date()
                }
            }
        }
    }

    func update(config: Config) { self.config = config }

    private func addBilled(_ bytes: Int) {
        let s = Double(bytes) / (16000.0 * 2.0)
        billedSeconds += s
        app.billedSeconds += s
    }

    // MARK: - 开始

    func begin(testMode: Bool = false) {
        guard state == .idle else { return }
        self.testMode = testMode

        guard config.hasCredentials else {
            app.lastError = "还没配置 API Key —— 去「设置」页填入"
            hud.flash(message: app.lastError, isError: true)
            return
        }
        guard capture.isRunning else {
            app.lastError = "麦克风未就绪，检查系统设置里的麦克风权限"
            hud.flash(message: app.lastError, isError: true)
            return
        }

        targetBundleId = TextInjector.frontmostBundleId
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        startedAt = Date()
        firstVoiceAt = nil
        firstCharAt = nil
        committedText = ""
        pendingCommit = ""
        injectedCharCount = 0
        billedSeconds = 0

        app.lastError = ""
        app.polishNote = ""
        app.isPolishing = false
        app.committed = ""
        app.partial = ""
        app.firstCharMs = nil
        app.lastSentenceMs = nil
        app.isListening = true

        let client = DoubaoStreamingASR(config: config)
        client.onUpdate = { [weak self] u in
            Task { @MainActor in self?.handle(u) }
        }
        client.onError = { [weak self] msg in
            Task { @MainActor in self?.handleError(msg) }
        }
        client.onFinished = { [weak self] trailing in
            Task { @MainActor in self?.handleFinished(trailing) }
        }
        asr = client
        client.start()

        state = .listening
        onStateChange?(state)
        if !testMode {
            hud.setPhase(.listening)
            hud.update(committed: "", partial: "")
        }

        // 把热键按下之前那段音频一并送出 —— 这就是「不吃掉你的前三个字」
        let preRoll = capture.startCapturing()
        if !preRoll.isEmpty {
            client.send(audio: preRoll)
            addBilled(preRoll.count)
            Log.debug("预缓冲补发 \(preRoll.count) 字节（约 \(preRoll.count / 32)ms）")
        }
    }

    // MARK: - 结束

    func end() {
        guard state == .listening else { return }
        let tail = capture.stopCapturing()
        if !tail.isEmpty {
            asr?.send(audio: tail)
            addBilled(tail.count)
        }
        state = .finalizing
        onStateChange?(state)
        if !testMode {
            hud.setPhase(.finalizing)
            hud.update(committed: committedText, partial: "")
        }
        asr?.finish()
    }

    func abort() {
        guard state != .idle else { return }
        _ = capture.stopCapturing()
        asr?.cancel()
        asr = nil
        // 必须清空：否则「松手才上屏 / 润色」模式下 pendingCommit 还留着，
        // 后续任何路径调到 inject(pendingCommit) 都会把用户已取消的内容粘出去
        pendingCommit = ""
        committedText = ""
        hud.hideNow()
        app.isPolishing = false
        finishState()
        hud.flash(message: "已取消", duration: 0.85)
    }

    private func finishState() {
        state = .idle
        app.isListening = false
        app.level = 0
        onStateChange?(state)
    }

    // MARK: - 流式结果

    private func handle(_ u: ASRUpdate) {
        if firstCharAt == nil, !u.newDefinite.isEmpty || !u.partial.isEmpty {
            firstCharAt = Date()
            let base = firstVoiceAt ?? startedAt
            if let base {
                let ms = Int(firstCharAt!.timeIntervalSince(base) * 1000)
                app.firstCharMs = max(0, ms)
                let fromPress = startedAt.map { Int(firstCharAt!.timeIntervalSince($0) * 1000) } ?? ms
                Log.info("首字延迟 \(max(0, ms)) ms（从开口算）／\(fromPress) ms（从按键算）")
            }
        }
        if let id = asr?.logId, !id.isEmpty { app.lastLogId = id }

        if !u.newDefinite.isEmpty {
            committedText += u.newDefinite
            if deferCommit {
                pendingCommit += u.newDefinite
            } else {
                inject(u.newDefinite)          // 逐句上屏 —— 边说边打字
            }
        }

        app.committed = committedText
        app.partial = u.partial
        if !testMode { hud.update(committed: committedText, partial: u.partial) }
    }

    // MARK: - 收尾

    private func handleFinished(_ trailing: String) {
        // 还没定稿但已经识别出来的尾巴也要算上，否则用户会丢字
        let tail = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            committedText += tail
            if deferCommit { pendingCommit += tail } else { inject(tail) }
        }

        if let s = startedAt {
            let ms = Int(Date().timeIntervalSince(s) * 1000)
            app.lastSentenceMs = ms
            Log.info("整段耗时 \(ms) ms，\(committedText.count) 字，音频 \(String(format: "%.1f", billedSeconds))s")
        }

        asr = nil
        app.committed = committedText
        app.partial = ""

        let raw = committedText
        guard !raw.isEmpty else {
            finalize(raw: raw, polished: nil)
            hud.flash(message: "没听清，再说一次？", duration: 1.4)
            return
        }

        // ── 要不要润色 ──
        guard config.polishReady else {
            if deferCommit, !testMode, !pendingCommit.isEmpty { inject(pendingCommit) }
            pendingCommit = ""
            finalize(raw: raw, polished: nil)
            return
        }

        state = .polishing
        onStateChange?(state)
        app.isPolishing = true
        app.polishNote = "正在润色…"
        if !testMode {
            hud.setPhase(.polishing)
            hud.update(committed: raw, partial: "")
        }

        let pending = pendingCommit
        let cfg = config
        let ctxApp = targetAppName

        Task { @MainActor in
            do {
                let polisher = LLMPolisher(config: cfg)
                // 流式增量只喂悬浮条做视觉反馈。
                // ⚠️ 上屏必须等全文完成 —— 把润色到一半的文本粘进输入框比不润色更糟。
                polisher.onDelta = { [weak self] partial in
                    guard let self, !partial.isEmpty else { return }
                    self.app.committed = partial
                    if !self.testMode { self.hud.update(committed: partial, partial: "") }
                }
                let r = try await polisher.polish(raw, contextApp: ctxApp)
                Log.info("润色完成 \(r.elapsedMs)ms：\(raw.count) 字 → \(r.text.count) 字")
                self.applyPolish(raw: raw, polished: r.text, elapsedMs: r.elapsedMs)
            } catch {
                Log.warn("润色失败：\(error.localizedDescription)")
                self.app.polishNote = "润色失败，已使用原文"
                // 失败绝不能丢内容 —— 退回原文照常上屏
                if !self.testMode, !pending.isEmpty { self.inject(pending) }
                self.pendingCommit = ""
                self.finalize(raw: raw, polished: nil)
                if !self.testMode {
                    self.hud.flash(message: "润色失败（\(error.localizedDescription)），已按原文上屏",
                                   isError: true, duration: 3)
                }
            }
        }
    }

    /// 润色成功 → 一次性上屏
    private func applyPolish(raw: String, polished: String, elapsedMs: Int) {
        pendingCommit = ""
        app.polishNote = raw == polished ? "润色无改动（\(elapsedMs)ms）" : "已润色（\(elapsedMs)ms）"
        app.committed = polished

        if testMode {
            finalize(raw: raw, polished: polished)
            return
        }
        // 走到这里文字还没进目标 App，直接写润色后的版本 —— 不需要任何退格
        inject(polished)
        hud.update(committed: polished, partial: "")
        hud.hide(after: 0.6)
        finalize(raw: raw, polished: polished)
    }

    /// 落历史 + 复位状态
    private func finalize(raw: String, polished: String?) {
        app.isPolishing = false
        if !raw.isEmpty {
            HistoryStore.shared.add(VoiceRecord(
                text: raw,
                startedAt: startedAt ?? Date(),
                durationSec: billedSeconds,
                firstCharMs: app.firstCharMs,
                appBundleId: testMode ? nil : targetBundleId,
                appName: testMode ? "（试听）" : targetAppName,
                injected: !testMode,
                polishedText: polished))
        }
        finishState()

        if polished == nil, !testMode, !raw.isEmpty, !config.polishReady {
            hud.update(committed: raw, partial: "")
            hud.hide(after: 0.5)
        }
    }

    private func handleError(_ msg: String) {
        _ = capture.stopCapturing()
        asr = nil
        app.lastError = msg
        app.partial = ""
        app.isPolishing = false
        finishState()

        if testMode { return }
        if !committedText.isEmpty {
            TextInjector.copyToClipboard(committedText, transient: false)
            hud.flash(message: "\(msg)（已识别内容已复制，⌘V 可粘贴）", isError: true, duration: 4)
        } else {
            hud.flash(message: msg, isError: true, duration: 4)
        }
    }

    // MARK: - 上屏

    private func inject(_ text: String) {
        guard !text.isEmpty else { return }

        if let target = targetBundleId,
           let now = TextInjector.frontmostBundleId,
           target != now {
            Log.warn("前台 App 已从 \(target) 切到 \(now)，改为复制到剪贴板")
            TextInjector.copyToClipboard(text, transient: false)
            hud.flash(message: "前台应用已切换，文本已复制到剪贴板", isError: true, duration: 3)
            return
        }

        switch TextInjector.commit(text, config: config) {
        case .injected:
            injectedCharCount += text.count
        case .copiedOnly(let reason):
            hud.flash(message: "\(reason)，已复制到剪贴板，请按 ⌘V", isError: true, duration: 3.5)
        }
    }
}
