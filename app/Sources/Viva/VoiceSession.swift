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
    /// 逐句上屏时扣下的句末句号，见 TextPolish.PeriodHold
    private var periodHold = TextPolish.PeriodHold()
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
    /// 润色请求。**必须被持有** —— abort() 要能取消它。
    /// 否则用户按 Esc 取消后，1~2 秒后润色返回仍会把文字粘进光标处；
    /// 更糟的是它返回时的 finishState() 会把「下一次录音」的 state 打回 .idle，
    /// 导致新会话的音频不再上送（capture.onChunk 有 state == .listening 的守卫），
    /// 表现为「说了半天一个字都没出来」。
    private var polishTask: Task<Void, Never>?

    private(set) var billedSeconds: Double = 0

    var onStateChange: ((State) -> Void)?

    /// 是否推迟上屏到最后。
    ///
    /// **开了 AI 润色就必须推迟** —— 润色要拿完整文本才能做，
    /// 而逐句上屏意味着文字已经写进去了，之后再改就得退格删用户屏幕上的东西。
    /// 所以：润色开 = 说话时只在悬浮窗显示，润色完一次性粘贴；
    ///       润色关 = 逐句上屏，真正的边说边写。
    private var deferCommit: Bool { deferCommitSnapshot }

    /// ⚠️ 必须在 begin() 时快照。它原本是计算属性，而 reloadConfig 可以在
    /// .listening/.finalizing 期间把新配置推进来 —— 中途变值会导致：
    /// 录音时润色关（已逐句上屏）→ 收尾时润色开 → 再 inject 一遍全文（重复）；
    /// 或录音时润色开（内容全囤着）→ 收尾时润色关 → 谁都不 inject（整段丢失）。
    private var deferCommitSnapshot = false
    /// begin() 时刻的 config.polishReady 快照。
    /// ⚠️ handleFinished 判断「要不要润色」必须用它，不能读实时 config ——
    ///   否则会话进行中用户点一下说话页的「AI 润色」胶囊，就会出现
    ///   「已经逐句上屏 + 松手后又把全文润色一遍整段粘一次」的重复注入，
    ///   而按硬性不变量「只追加绝不退格」，多出来的那一整段永远删不掉。
    private var polishSnapshot = false
    /// 本次会话是否有任何一次上屏走了降级路径（Secure Input / 缺权限 / 前台切走）。
    /// 历史记录里的「仅复制」角标要靠它才准。
    private var didFallbackToClipboard = false

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
        // 静默返回是最糟的处理：用户按住热键说了一整段，屏幕上什么都没发生，
        // 说完的话直接蒸发。.finalizing 最长 6 秒、.polishing 最长 5 秒，
        // 这段窗口真实存在，必须告诉用户「在忙，稍候」。
        guard state == .idle else {
            hud.flash(message: state == .polishing ? "正在润色上一段，稍候" : "正在收尾上一段，稍候",
                      duration: 1.2)
            return
        }
        self.testMode = testMode

        guard config.hasCredentials else {
            app.lastError = "还没配置 API Key —— 去「设置」页填入"
            hud.flash(message: app.lastError, isError: true)
            return
        }
        // ⚠️ 判据是 canStart 而不是 isRunning。蓝牙输入设备下引擎故意不常驻，
        //   isRunning 恒为 false 是预期状态 —— 用 isRunning 拦会让所有蓝牙耳机
        //   用户完全无法录音（详见 AudioCapture.canStart 的注释）。
        guard capture.canStart else {
            app.lastError = "麦克风未就绪，检查系统设置里的麦克风权限"
            hud.flash(message: app.lastError, isError: true)
            return
        }

        polishSnapshot = config.polishReady
        deferCommitSnapshot = testMode || config.commitOnlyAtEnd || polishSnapshot
        targetBundleId = TextInjector.frontmostBundleId
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        startedAt = Date()
        firstVoiceAt = nil
        firstCharAt = nil
        committedText = ""
        pendingCommit = ""
        periodHold.reset()          // 上一轮扣下的句号绝不能漏到这一轮句首
        injectedCharCount = 0
        didFallbackToClipboard = false
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
        // （蓝牙路径没有 preRoll：引擎就是在这一行才启动的）
        let preRoll = capture.startCapturing()

        // 蓝牙路径下引擎是在上面这一行才真正起来的，失败必须在这里兜住。
        // 否则会留下一个永远收不到音频的会话，用户说完一整段才发现什么都没出来。
        guard capture.isRunning else {
            Log.error("即时启动采集失败 —— 设备可能被占用或已断开")
            _ = capture.stopCapturing()
            client.cancel()
            asr = nil
            app.isListening = false
            finishState()
            app.lastError = "麦克风启动失败 —— 蓝牙耳机可能已断开，或正被其它 App 占用"
            hud.flash(message: app.lastError, isError: true, duration: 2.6)
            return
        }

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
        polishTask?.cancel()
        polishTask = nil
        // 必须清空：否则「松手才上屏 / 润色」模式下 pendingCommit 还留着，
        // 后续任何路径调到 inject(pendingCommit) 都会把用户已取消的内容粘出去
        pendingCommit = ""
        committedText = ""
        periodHold.reset()
        hud.hideNow()
        app.isPolishing = false
        finishState()
        // 逐句上屏模式下，已经写进目标 App 的文字是**不会**被撤回的
        //（TextInjector 明确只做追加，退格回改是破坏性操作）。
        // 所以提示必须说实话，否则用户以为撤销了，实际文档里还留着半句。
        // 试听模式全程不碰悬浮条（begin 里也跳过了）—— 它面向的正是还没授予
        // 辅助功能权限的新用户，这时候凭空浮出一条黑胶囊是明确的行为偏差。
        if !testMode {
            hud.flash(message: injectedCharCount > 0
                      ? "已停止 —— 已输入的 \(injectedCharCount) 字保留在原处"
                      : "已取消",
                      duration: injectedCharCount > 0 ? 2.0 : 0.85)
        }
    }

    private func finishState() {
        state = .idle
        app.isListening = false
        app.level = 0
        onStateChange?(state)
    }

    // MARK: - 流式结果

    // MARK: - 上屏（去末尾句号）

    /// 逐句上屏路径。走「扣下-补回」，因为写下这一句时还不知道它是不是最后一句，
    /// 而事后回头删是绝对禁止的（见 TextPolish.PeriodHold）。
    private func injectSentence(_ chunk: String) {
        guard config.stripTrailingPeriod else { inject(chunk); return }
        let out = periodHold.feed(chunk)
        if !out.isEmpty { inject(out) }
    }

    /// 一次性整段上屏路径（松手才上屏 / 润色完成 / 润色失败退回原文）。
    /// 这时全文已经在手上，直接去掉末尾那个句号即可，不需要扣下任何东西。
    private func injectWhole(_ text: String) {
        let out = config.stripTrailingPeriod ? TextPolish.stripTrailingPeriod(text) : text
        guard !out.isEmpty else { return }
        inject(out)
    }

    /// 用户在底部看到的、以及点「复制」拿到的，必须和真正写进输入框的一致
    private func displayed(_ text: String) -> String {
        config.stripTrailingPeriod ? TextPolish.stripTrailingPeriod(text) : text
    }

    private func handle(_ u: ASRUpdate) {
        // ⚠️ 必须挡住「会话已结束但回调还在途」的那一跳。
        //   ASR 回调是 Task { @MainActor in handle(u) }，Esc 的 abort 也是一次同样的
        //   异步跳转；abort 先执行完之后，那一帧仍会走到这里，在逐句上屏模式下把
        //   一句话真的粘进用户输入框 —— 用户刚看到「已取消」，光标处却又多出一句，
        //   而按硬性不变量这句永远撤不回。6 秒兜底 finishUp 之后同理。
        guard state == .listening || state == .finalizing else { return }
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
                injectSentence(u.newDefinite)  // 逐句上屏 —— 边说边打字
            }
        }

        app.committed = committedText
        app.partial = u.partial
        if !testMode { hud.update(committed: committedText, partial: u.partial) }
    }

    // MARK: - 收尾

    private func handleFinished(_ trailing: String) {
        // ⚠️ 同 handle(_:)：会话已经被 abort 打回 .idle 时，在途的最终帧不能再往下走。
        //   否则 tail 会被追加上屏，state 还会被从 .idle 改回 .polishing 起一个新的润色请求，
        //   最后给这次已取消的会话写一条历史记录。
        guard state == .listening || state == .finalizing else { return }
        // ⚠️ 必须停采集。服务端可能在 state 还是 .listening 时就结束流
        //    （VAD 强制收流 / 最大时长 / asyncFinal），此时若不停，
        //    isCapturing 会永久为 true，preRoll 再也不会被填充 ——
        //    「不吃掉你的前三个字」这个核心卖点会在本次进程剩余生命周期里失效。
        // 服务端可能在用户还在说话时就结束流（VAD 强制收流 / 最大时长 / asyncFinal）。
        // 这时后半段会静默蒸发 —— 竞品「系统自动吞掉我一部分话」就是这个。
        let interrupted = state == .listening
        if capture.isCapturing { _ = capture.stopCapturing() }

        // 还没定稿但已经识别出来的尾巴也要算上，否则用户会丢字
        let tail = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            committedText += tail
            if deferCommit { pendingCommit += tail } else { injectSentence(tail) }
        }

        if let s = startedAt {
            let ms = Int(Date().timeIntervalSince(s) * 1000)
            app.lastSentenceMs = ms
            Log.info("整段耗时 \(ms) ms，\(committedText.count) 字，音频 \(String(format: "%.1f", billedSeconds))s")
        }

        asr = nil
        app.committed = committedText
        app.partial = ""

        if interrupted, !testMode {
            Log.warn("服务端在录音中途结束了本次识别")
            hud.flash(message: "本次识别被服务端结束了，请松开热键重新说", isError: true, duration: 2.6)
        }

        let raw = committedText
        guard !raw.isEmpty else {
            finalize(raw: raw, polished: nil)
            if !testMode { hud.flash(message: "没听清，再说一次？", duration: 1.4) }
            return
        }

        // ── 要不要润色 ──
        guard polishSnapshot else {
            if deferCommit, !testMode, !pendingCommit.isEmpty { injectWhole(pendingCommit) }
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

        polishTask = Task { @MainActor in
            do {
                let polisher = LLMPolisher(config: cfg)
                // 流式增量只喂悬浮条做视觉反馈。
                // ⚠️ 上屏必须等全文完成 —— 把润色到一半的文本粘进输入框比不润色更糟。
                polisher.onDelta = { [weak self] partial in
                    guard let self, !partial.isEmpty,
                          self.state == .polishing, !Task.isCancelled else { return }
                    self.app.committed = partial
                    if !self.testMode { self.hud.update(committed: partial, partial: "") }
                }
                let r = try await polisher.polish(raw, contextApp: ctxApp)
                // 用户可能在这 1~2 秒里按了 Esc。此时绝不能上屏，
                // 更不能走 finishState —— 那会把新一轮录音打回 .idle。
                guard !Task.isCancelled, self.state == .polishing else { return }
                Log.info("润色完成 \(r.elapsedMs)ms：\(raw.count) 字 → \(r.text.count) 字")
                self.applyPolish(raw: raw, polished: r.text, elapsedMs: r.elapsedMs)
            } catch {
                // ⚠️ 这道 guard 不是冗余：Task.cancel() 会让 URLSession 抛错落到这里，
                //    不判取消的话会走「退回原文上屏」，bug 一模一样地复现。
                guard !Task.isCancelled, self.state == .polishing else { return }
                Log.warn("润色失败：\(error.localizedDescription)")
                self.app.polishNote = "润色失败，已使用原文"
                // 失败绝不能丢内容 —— 退回原文照常上屏
                if !self.testMode, !pending.isEmpty { self.injectWhole(pending) }
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
        guard state == .polishing else { return }      // 兜底：已取消就不做任何事
        pendingCommit = ""
        app.polishNote = raw == polished ? "润色无改动（\(elapsedMs)ms）" : "已润色（\(elapsedMs)ms）"
        app.committed = displayed(polished)

        if testMode {
            finalize(raw: raw, polished: polished)
            return
        }
        // 走到这里文字还没进目标 App，直接写润色后的版本 —— 不需要任何退格
        injectWhole(polished)
        hud.update(committed: displayed(polished), partial: "")
        hud.hide(after: 0.6)
        finalize(raw: raw, polished: polished)
    }

    /// 落历史 + 复位状态
    private func finalize(raw: String, polished: String?) {
        polishTask = nil
        app.isPolishing = false
        if !raw.isEmpty {
            HistoryStore.shared.add(VoiceRecord(
                text: raw,
                startedAt: startedAt ?? Date(),
                durationSec: billedSeconds,
                firstCharMs: app.firstCharMs,
                appBundleId: testMode ? nil : targetBundleId,
                appName: testMode ? "（试听）" : targetAppName,
                injected: !testMode && !didFallbackToClipboard,
                polishedText: polished))
        }
        finishState()

        // 底部那段文字是用户要复制/二次编辑的东西，必须和实际写进输入框的一致 ——
        // 显示「你好。」而输入框里是「你好」会让人以为漏字了
        if polished == nil { app.committed = displayed(raw) }

        if polished == nil, !testMode, !raw.isEmpty, !polishSnapshot {
            hud.update(committed: displayed(raw), partial: "")
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

        // ⚠️ 必须落历史。原来只往剪贴板放一份 —— 用户随手复制点别的，
        //    这段话就永久没了。竞品「网络不好说完一整段什么都没上屏」正是这个坑。
        if !committedText.isEmpty {
            HistoryStore.shared.add(VoiceRecord(
                text: committedText,
                startedAt: startedAt ?? Date(),
                durationSec: billedSeconds,
                firstCharMs: app.firstCharMs,
                appBundleId: testMode ? nil : targetBundleId,
                appName: testMode ? "（试听）" : targetAppName,
                injected: false))
        }

        if testMode { return }
        if !committedText.isEmpty {
            TextInjector.copyToClipboard(committedText, transient: false)
            hud.flash(message: "\(msg)（已识别的内容已存进历史并复制到剪贴板）",
                      isError: true, duration: 4)
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
            didFallbackToClipboard = true
            hud.flash(message: "前台应用已切换，文本已复制到剪贴板", isError: true, duration: 3)
            return
        }

        switch TextInjector.commit(text, config: config) {
        case .injected:
            injectedCharCount += text.count
        case .copiedOnly(let reason):
            didFallbackToClipboard = true
            hud.flash(message: "\(reason)，已复制到剪贴板，请按 ⌘V", isError: true, duration: 3.5)
        }
    }
}
