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
    /// 确定性替换（改词记忆 + 预设词库规则），会话开始时快照一次。
    /// partial 和 definite 都过同一套规则 —— PartialCommitter 的前缀去重
    /// 要求两边文本一致，只替换一边会算错余额。
    private var replacer = TextReplacer(rules: [])
    /// 本次会话的有效配置 = 全局配置 + 目标 App 的 Profile 覆盖。
    /// 会话内一切行为（润色/上屏方式/逐段提交/去句号）都读它,不读全局 config ——
    /// 否则用户说话说到一半在设置页改配置会把会话行为撕裂。
    private var sessionConfig = Config()
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
    /// begin() 时刻的 config.llmPassReady 快照。
    /// ⚠️ handleFinished 判断「要不要润色」必须用它，不能读实时 config ——
    ///   否则会话进行中用户点一下说话页的「AI 润色」胶囊，就会出现
    ///   「已经逐句上屏 + 松手后又把全文润色一遍整段粘一次」的重复注入，
    ///   而按硬性不变量「只追加绝不退格」，多出来的那一整段永远删不掉。
    private var polishSnapshot = false
    /// begin() 时刻的整份配置快照，专供润色使用。
    /// ⚠️ 必须和 polishSnapshot 同源。只快照「要不要润色」而让 LLMPolisher 拿实时 config，
    ///   会出现：会话中途关掉润色 → handleFinished 仍按快照进入 .polishing，
    ///   但 LLMPolisher.isConfigured 读实时值判为 false，抛出服务配置错误。
    private var polishConfigSnapshot: Config?
    /// 本次会话是否有任何一次上屏走了降级路径（Secure Input / 缺权限 / 前台切走）。
    /// 历史记录里的「仅复制」角标要靠它才准。
    private var didFallbackToClipboard = false

    /// 连续听写：稳定前缀逐段上屏（09 号方案路线 B）。
    /// nil = 本会话不启用（配置关闭，或 deferCommit 模式 —— 润色要拿全文重写，互斥）。
    /// ⚠️ begin() 时按快照决定，会话中途改配置不影响本轮（同 deferCommitSnapshot 的理由）。
    private var partialCommitter: PartialCommitter?

    // ── 会话轮转（09 号方案路线 C）——
    // 单一 WebSocket 会话有服务端最大时长，说得久会被强制收流。
    // 把「被动被掐报错」变成「主动轮转无感续接」：
    //   T1 服务端自己收流（asyncFinal 但用户还按着）→ handleFinished 里自动续
    //   T2 会话年龄 > rotateAfterSeconds 且刚来一个 definite → 借干净边界轮转
    //   T3 年龄 > hardRotateSeconds 一直没 definite → 等音量谷值强切（+3s 兜底）
    /// 当前 ASR 会话的建立时刻（轮转判据）
    private var asrStartedAt: Date?
    /// 已发起轮转、老会话正在收尾。此间音频进 rotationBuffer 而不是老会话
    private var rotationDraining = false
    /// 老会话收尾期间的续接音频缓冲。上限 64 包（≈12.8s，老会话收尾有 6s 兜底，
    /// 实际到不了一半）；真溢出时丢最旧的 —— 丢最新的会吃掉用户正在说的话
    private var rotationBuffer: [Data] = []
    /// 本轮按住期间已轮转次数（日志/排障用）
    private var rotationCount = 0
    /// T3 已到时限，等一个音量谷值作为刀口
    private var wantRotateDip = false
    private var rotateTimer: Timer?

    init(config: Config, capture: AudioCapture, hud: HUDController) {
        self.config = config
        self.sessionConfig = config
        self.capture = capture
        self.hud = hud

        capture.onChunk = { [weak self] chunk in
            Task { @MainActor in
                guard let self, self.state == .listening else { return }
                if self.rotationDraining {
                    // 轮转窗口期：老会话已发末包不再收音频，新会话还没建 ——
                    // 先囤着，continueRotation 时一次性 flush，一个字都不丢
                    if self.rotationBuffer.count >= 64 {
                        Log.warn("轮转续接缓冲已满，丢弃最早的音频包")
                        self.rotationBuffer.removeFirst()
                    }
                    self.rotationBuffer.append(chunk)
                } else {
                    self.asr?.send(audio: chunk)
                }
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
                // T3：到了强切时限，挑一个音量谷值下刀，尽量别劈在字中间
                if self.wantRotateDip, level < 0.08 {
                    self.initiateRotation(reason: "T3 音量谷值")
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
        // ⚠️ 下面这些 flash 一律用**参数** testMode 把关，不能用 self.testMode ——
        //   self.testMode 要等过了第一道 guard 才赋值（不能提前，否则会覆盖掉
        //   正在跑的上一轮会话的 testMode），在此之前它还是上一轮的残值。
        //   试听模式全程不碰悬浮条：它面向的正是还没完成权限引导的新用户，
        //   引导页下方已经有 WarnBanner 显示同一条错误，再浮一条黑胶囊是重复且突兀的。
        guard state == .idle else {
            if !testMode {
                hud.flash(message: state == .polishing ? "正在处理上一段，稍候" : "正在收尾上一段，稍候",
                          duration: 1.2)
            }
            return
        }
        self.testMode = testMode

        guard config.hasValidBackendConfiguration else {
            app.lastError = config.backendConfigurationError ?? "Viva 服务地址无效"
            if !testMode { hud.flash(message: app.lastError, isError: true) }
            return
        }
        // ⚠️ 判据是 canStart 而不是 isRunning。蓝牙设备或用户选择按需模式时，
        //   空闲期的 isRunning 为 false 是预期状态 —— 用它当就绪判据
        //   会让按需模式完全无法录音（详见 AudioCapture.canStart 的注释）。
        guard capture.canStart else {
            app.lastError = "麦克风未就绪，检查系统设置里的麦克风权限"
            if !testMode { hud.flash(message: app.lastError, isError: true) }
            return
        }

        // 目标 App 必须先定 —— 本次会话的有效配置要按它的 Profile 覆盖。
        // sessionConfig 是快照语义：只影响这一次会话，松手即失效。
        targetBundleId = TextInjector.frontmostBundleId
        targetAppName = NSWorkspace.shared.frontmostApplication?.localizedName
        sessionConfig = config.applyingProfile(for: testMode ? nil : targetBundleId)
        if sessionConfig.enablePolish != config.enablePolish
            || sessionConfig.enableCourseCorrection != config.enableCourseCorrection
            || sessionConfig.useClipboardPaste != config.useClipboardPaste
            || sessionConfig.progressiveCommit != config.progressiveCommit {
            Log.info("按 App Profile 生效：\(targetAppName ?? targetBundleId ?? "?")")
        }

        // 润色或改口纠正任一开启 → 推迟上屏走 Viva 服务端大模型
        polishSnapshot = sessionConfig.llmPassReady
        polishConfigSnapshot = sessionConfig
        replacer = TextReplacer(rules: WordlistStore.shared.mergedRules(
            user: sessionConfig.replaceRules, enabledLists: sessionConfig.enabledWordlists))
        deferCommitSnapshot = testMode || sessionConfig.commitOnlyAtEnd || polishSnapshot
        partialCommitter = (sessionConfig.progressiveCommit && !deferCommitSnapshot)
            ? PartialCommitter(config: sessionConfig) : nil
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

        rotationDraining = false
        rotationBuffer = []
        rotationCount = 0
        wantRotateDip = false

        startASRClient()
        guard let client = asr else { return }   // startASRClient 必然赋值，防御

        // T3 看门狗：一直没 definite 也不能让会话老死在服务端手里
        rotateTimer?.invalidate()
        rotateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.rotateTick() }
        }

        state = .listening
        onStateChange?(state)
        if !testMode {
            hud.setPhase(.listening)
            hud.update(committed: "", partial: "")
        }

        // 把热键按下之前那段音频一并送出 —— 这就是「不吃掉你的前三个字」
        // （蓝牙或按需模式没有热键之前的 preRoll：引擎在这里才启动）
        let preRoll = capture.startCapturing()

        // 按需路径下引擎是在上面这一行才真正起来的，失败必须在这里兜住。
        // 否则会留下一个永远收不到音频的会话，用户说完一整段才发现什么都没出来。
        guard capture.isRunning else {
            Log.error("即时启动采集失败 —— 设备可能被占用或已断开")
            _ = capture.stopCapturing()
            client.cancel()
            asr = nil
            app.isListening = false
            finishState()
            app.lastError = "麦克风启动失败 —— 蓝牙耳机可能已断开，或正被其它 App 占用"
            if !testMode { hud.flash(message: app.lastError, isError: true, duration: 2.6) }
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
        if rotationDraining {
            // 罕见边角：恰好在轮转窗口期松手。老会话已发末包收不了新音频，
            // 新会话还没建 —— 缓冲里这一小段（≤6s）没有去处，只能丢弃并留痕。
            Log.warn("在轮转窗口期松手，续接缓冲 \(rotationBuffer.count) 包未能上送")
        }
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
        rotateTimer?.invalidate(); rotateTimer = nil
        rotationDraining = false
        rotationBuffer = []
        wantRotateDip = false
        onStateChange?(state)
    }

    // MARK: - 会话轮转

    /// 建一个新的 ASR 会话并接管 asr 引用。begin() 和 continueRotation 共用 ——
    /// 每次都走同一条 ticket + SAUC 建连路径，轮转不会漏掉账户鉴权。
    private func startASRClient() {
        let client = DoubaoStreamingASR(config: sessionConfig)
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
        asrStartedAt = Date()
    }

    private var asrAgeSeconds: Double {
        asrStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    private func rotateTick() {
        guard state == .listening, !rotationDraining, !testMode else { return }
        let age = asrAgeSeconds
        if age > Double(config.hardRotateSeconds + 3) {
            // 等谷值等了 3 秒都没等到（一直大声说）—— 只能硬切，好过被服务端掐
            initiateRotation(reason: "T3 超时兜底（\(Int(age))s）")
        } else if age > Double(config.hardRotateSeconds) {
            wantRotateDip = true   // 谷值刀口由 onLevel 回调触发
        }
    }

    /// 发起主动轮转：给老会话发末包。它的最终 definite/trailing 会照常从
    /// handle()/handleFinished 流回来，后者发现「用户还按着」就接 continueRotation。
    private func initiateRotation(reason: String) {
        guard state == .listening, !rotationDraining, !testMode else { return }
        // 幼年会话不轮转：也是熔断的一半 —— 见 handleFinished 里的 8 秒判据
        guard asrAgeSeconds >= 8 else { return }
        Log.info("发起会话轮转（\(reason)，会话年龄 \(Int(asrAgeSeconds))s）")
        rotationDraining = true
        wantRotateDip = false
        asr?.finish()
    }

    /// 老会话已收尾、用户还按着 —— 注入尾巴、起新会话、flush 续接缓冲。
    private func continueRotation(trailing: String) {
        rotationCount += 1
        rotationDraining = false
        wantRotateDip = false

        let tail = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            committedText += tail
            if deferCommit {
                pendingCommit += tail
            } else if partialCommitter != nil {
                let remainder = partialCommitter!.consumeDefinite(trailing)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                injectSentence(remainder)
            } else {
                injectSentence(tail)
            }
        }
        // 无条件复位：新会话的 partial 是全新上下文，旧余额必须清零
        //（正常路径 consumeDefinite 已清，这里兜的是 trailing 为空/异常的边角）
        partialCommitter?.reset()

        app.committed = committedText
        app.partial = ""
        if !testMode { hud.update(committed: committedText, partial: "") }

        startASRClient()
        // 轮转窗口期囤下的音频按序补发。计费在 onChunk 里已经记过，不重复记
        for chunk in rotationBuffer { asr?.send(audio: chunk) }
        Log.info("会话轮转 #\(rotationCount) 完成，续接缓冲补发 \(rotationBuffer.count) 包")
        rotationBuffer.removeAll()
    }

    // MARK: - 流式结果

    // MARK: - 上屏（去末尾句号）

    /// 逐句上屏路径。走「扣下-补回」，因为写下这一句时还不知道它是不是最后一句，
    /// 而事后回头删是绝对禁止的（见 TextPolish.PeriodHold）。
    private func injectSentence(_ chunk: String) {
        guard sessionConfig.stripTrailingPeriod else { inject(chunk); return }
        let out = periodHold.feed(chunk)
        if !out.isEmpty { inject(out) }
    }

    /// 一次性整段上屏路径（松手才上屏 / 润色完成 / 润色失败退回原文）。
    /// 这时全文已经在手上，直接去掉末尾那个句号即可，不需要扣下任何东西。
    private func injectWhole(_ text: String) {
        let out = sessionConfig.stripTrailingPeriod ? TextPolish.stripTrailingPeriod(text) : text
        guard !out.isEmpty else { return }
        inject(out)
    }

    /// 用户在底部看到的、以及点「复制」拿到的，必须和真正写进输入框的一致
    private func displayed(_ text: String) -> String {
        sessionConfig.stripTrailingPeriod ? TextPolish.stripTrailingPeriod(text) : text
    }

    private func handle(_ raw: ASRUpdate) {
        // 确定性替换（改词记忆）在文本入口统一做：definite 和 partial 用同一套
        // 规则，下游（PartialCommitter/HUD/历史）看到的是一致的替换后文本。
        var u = raw
        if !replacer.isEmpty {
            u.newDefinite = replacer.apply(u.newDefinite)
            u.partial = replacer.apply(u.partial)
        }
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
            } else if partialCommitter != nil {
                // 连续听写：这个 definite 的前缀可能已经被逐段提交过了，只补尾巴
                injectSentence(partialCommitter!.consumeDefinite(u.newDefinite))
            } else {
                injectSentence(u.newDefinite)  // 逐句上屏 —— 边说边打字
            }
        }

        // 连续听写：从 partial 里挑「稳定 + 标点收尾 + 距尾部有余量」的前缀提前上屏。
        // 必须在 consumeDefinite 之后喂 —— definite 到达意味着 partial 尾巴换了上下文，
        // consumeDefinite 已把稳定性历史清掉，这里从新尾巴重新积累。
        if partialCommitter != nil, !u.partial.isEmpty {
            let increment = partialCommitter!.feed(partialTail: u.partial)
            if !increment.isEmpty {
                Log.debug("逐段提交 \(increment.count) 字")
                injectSentence(increment)
            }
        }

        app.committed = committedText
        app.partial = u.partial
        if !testMode { hud.update(committed: committedText, partial: u.partial) }

        // T2：会话上了年纪，又刚好来了一个 definite —— 这是最干净的轮转边界
        //（definite 意味着服务端刚判停，此刻的 partial 尾巴最短、损失最小）
        if !u.newDefinite.isEmpty, !rotationDraining,
           asrAgeSeconds > Double(config.rotateAfterSeconds) {
            initiateRotation(reason: "T2 definite 边界")
        }
    }

    // MARK: - 收尾

    private func handleFinished(_ rawTrailing: String) {
        let trailing = replacer.isEmpty ? rawTrailing : replacer.apply(rawTrailing)
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

        // ── T1/T2/T3 汇聚点 ──
        // 会话结束了但用户还按着 → 无缝轮转续接，而不是报错让用户重说。
        // 不论是我们主动发起（T2/T3 的 initiateRotation）还是服务端强制收流（T1），
        // 都从这里走。⚠️ 必须在停采集之前 —— 轮转期间麦克风一刻都不能停。
        // ≥8s 熔断：会话建立不到 8 秒就被结束，说明服务端在赶我们
        //（配额耗尽/鉴权失效），再轮转就是死循环，落回终止路径亮出真实状态。
        if interrupted, !testMode, asrAgeSeconds >= 8 {
            continueRotation(trailing: trailing)
            return
        }

        if capture.isCapturing { _ = capture.stopCapturing() }

        // 还没定稿但已经识别出来的尾巴也要算上，否则用户会丢字
        let tail = trailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            committedText += tail
            if deferCommit {
                pendingCommit += tail
            } else if partialCommitter != nil {
                // ⚠️ 对账必须用未 trim 的原文 —— 逐段提交时 feed 计的字素数
                //   是按原始 partial 算的，trim 过再对账会错位。注入前再 trim 尾巴。
                let remainder = partialCommitter!.consumeDefinite(trailing)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                injectSentence(remainder)
            } else {
                injectSentence(tail)
            }
        } else if partialCommitter != nil {
            // 尾巴为空也要清余额：轮转后的新会话不能背着旧账
            _ = partialCommitter!.consumeDefinite(trailing)
        }

        if let s = startedAt {
            let ms = Int(Date().timeIntervalSince(s) * 1000)
            app.lastSentenceMs = ms
            Log.info("整段耗时 \(ms) ms，\(committedText.count) 字，音频 \(String(format: "%.1f", billedSeconds))s")
        }

        asr = nil
        refreshManagedBalance()
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

        let cfg = polishConfigSnapshot ?? config
        state = .polishing
        onStateChange?(state)
        app.isPolishing = true
        app.polishNote = "\(cfg.aiProcessingMode.processingLabel)…"
        if !testMode {
            hud.setPhase(.polishing)
            hud.update(committed: raw, partial: "")
        }

        let pending = pendingCommit

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
                let r = try await polisher.polish(raw)
                // 用户可能在这 1~2 秒里按了 Esc。此时绝不能上屏，
                // 更不能走 finishState —— 那会把新一轮录音打回 .idle。
                guard !Task.isCancelled, self.state == .polishing else {
                    self.reportLLMClientOutcome(requestID: r.requestID,
                                                outcome: "cancelled",
                                                detail: "cancelled_before_apply",
                                                elapsedMs: r.elapsedMs)
                    return
                }
                Log.info("AI 处理完成 \(r.elapsedMs)ms：\(raw.count) 字 → \(r.text.count) 字")
                self.applyPolish(raw: raw, polished: r.text, elapsedMs: r.elapsedMs,
                                 requestID: r.requestID)
            } catch {
                // ⚠️ 这道 guard 不是冗余：Task.cancel() 会让 URLSession 抛错落到这里，
                //    不判取消的话会走「退回原文上屏」，bug 一模一样地复现。
                guard !Task.isCancelled, self.state == .polishing else { return }
                Log.warn("AI 处理失败：\(error.localizedDescription)")
                self.app.polishNote = "AI 处理失败，已使用原文"
                // 失败绝不能丢内容 —— 退回原文照常上屏
                if !self.testMode, !pending.isEmpty { self.injectWhole(pending) }
                self.pendingCommit = ""
                self.finalize(raw: raw, polished: nil, aiOutcome: .fallback)
                if !self.testMode {
                    self.hud.flash(message: "AI 处理失败（\(error.localizedDescription)），已按原文上屏",
                                   isError: true, duration: 3)
                }
            }
        }
    }

    /// 润色成功 → 一次性上屏
    private func applyPolish(raw: String, polished rawPolished: String, elapsedMs: Int,
                             requestID: String?) {
        guard state == .polishing else { return }      // 兜底：已取消就不做任何事
        // 润色是 LLM 重写的新文本，没走过 handle() 的替换入口，这里补一遍 ——
        // 「Cloth Code→Claude Code」这类规则在润色后同样该生效
        let polished = replacer.isEmpty ? rawPolished : replacer.apply(rawPolished)
        pendingCommit = ""
        let mode = polishConfigSnapshot?.aiProcessingMode ?? .polish
        let changed = raw != polished
        app.polishNote = changed
            ? "已\(mode.resultNoun)（\(elapsedMs)ms）"
            : "已检查，未改动（\(elapsedMs)ms）"
        app.committed = displayed(polished)

        if testMode {
            finalize(raw: raw, polished: polished,
                     aiOutcome: changed ? .changed : .unchanged,
                     aiElapsedMs: elapsedMs)
            return
        }
        // 走到这里文字还没进目标 App，直接写润色后的版本 —— 不需要任何退格
        injectWhole(polished)
        reportLLMClientOutcome(requestID: requestID, outcome: "applied",
                               detail: didFallbackToClipboard
                                   ? "applied_via_clipboard_fallback"
                                   : "applied_to_target_app",
                               elapsedMs: elapsedMs)
        hud.update(committed: displayed(polished), partial: "")
        hud.hide(after: 0.6)
        finalize(raw: raw, polished: polished,
                 aiOutcome: changed ? .changed : .unchanged,
                 aiElapsedMs: elapsedMs)
    }

    private func reportLLMClientOutcome(requestID: String?, outcome: String,
                                        detail: String, elapsedMs: Int) {
        guard let requestID, !requestID.isEmpty,
              let baseURL = (polishConfigSnapshot ?? config).backendBaseURL else { return }
        Task.detached(priority: .utility) {
            try? await ManagedBackendAuth.shared.reportLLMOutcome(
                requestID: requestID, outcome: outcome, detail: detail,
                clientElapsedMS: elapsedMs, timeoutBudgetMS: 0,
                baseURL: baseURL)
        }
    }

    /// 落历史 + 复位状态
    private func finalize(raw: String,
                          polished: String?,
                          aiOutcome: AIProcessingOutcome? = nil,
                          aiElapsedMs: Int? = nil) {
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
                polishedText: polished,
                aiMode: aiOutcome == nil ? nil : polishConfigSnapshot?.aiProcessingMode,
                aiOutcome: aiOutcome,
                aiElapsedMs: aiElapsedMs))
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

    /// ASR 的实际计费由服务端在会话结束时结算，不用本地音频秒数推测余额。
    private func refreshManagedBalance() {
        guard let baseURL = sessionConfig.backendBaseURL else { return }
        Task {
            do {
                _ = try await ManagedBackendAuth.shared.balance(baseURL: baseURL)
            } catch {
                Log.warn("ASR 完成后刷新积分失败：\(error.localizedDescription)")
            }
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

        switch TextInjector.commit(text, config: sessionConfig) {
        case .injected:
            injectedCharCount += text.count
        case .copiedOnly(let reason):
            didFallbackToClipboard = true
            hud.flash(message: "\(reason)，已复制到剪贴板，请按 ⌘V", isError: true, duration: 3.5)
        }
    }
}
