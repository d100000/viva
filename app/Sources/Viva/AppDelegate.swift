import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let state = AppState.shared
    private var statusItem: NSStatusItem!
    private var capture: AudioCapture!
    private var hotkey: HotkeyManager!
    private var session: VoiceSession!
    private let hud = HUDController()
    private let mainWindow = MainWindowController()
    private let accountWindow = AccountWindowController()
    private let welcome = WelcomeWindowController()
    private var escMonitor: Any?
    private var hotkeyTestTimeout: Timer?
    private var hotkeyTestPressDetected = false
    /// 点按开关模式：双击热键锁定连续听写，无需一直按住。
    /// 锁定期间 onPress/onRelease 都被旁路，单击（onShortTap）= 结束。
    private var dictationLocked = false
    private var lastShortTapAt: Date?
    private var accountCancellables = Set<AnyCancellable>()

    // ── 软件更新 ──
    private let updater = UpdateChecker()
    private var pendingRelease: UpdateChecker.Release?
    private var updateTimer: Timer?
    /// 当前 capture / hotkey 是按哪份配置搭起来的，用来判断要不要真的重建。
    /// ⚠️ 没有它的话，词库页每修改一项本地替换规则都会整体重启 AVAudioEngine + 重建 CGEventTap，
    ///   而 macOS 上「停掉引擎立刻新建再 start」是出了名的易失败时序
    ///   （inputNode 采样率会短暂返回 0），一失败就把 App 打成「未就绪」并弹红条。
    private var appliedConfig: Config?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)      // 菜单栏 App，不进 Dock
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        Log.info("===== Viva 启动 version=\(version) pid=\(ProcessInfo.processInfo.processIdentifier) =====")
        Log.info("运行路径：\(Bundle.main.bundlePath)；日志：\(Log.fileURL.path)")
        installMainMenu()
        bindManagedAccountState()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(.idle)
        buildMenu()

        capture = AudioCapture(preRollMs: state.config.preRollMs,
                               inputDeviceUID: state.config.inputDeviceUID)
        session = VoiceSession(config: state.config, capture: capture, hud: hud)
        capture.onTestLevel = { [weak self] level in
            guard let self, self.state.audioInputTestRunning else { return }
            if abs(self.state.audioInputTestLevel - level) > 0.01 {
                self.state.audioInputTestLevel = level
            }
        }
        session.onStateChange = { [weak self] st in
            guard let self else { return }
            // 会话无论因何结束（松手/Esc/出错），锁定标志都必须跟着落下 ——
            // 否则 Esc 取消后热键单击会被「锁定中，单击=结束」的分支吃掉
            if st == .idle { self.dictationLocked = false }
            self.updateStatusIcon(st)
            self.buildMenu()
        }

        hotkey = makeHotkey()
        appliedConfig = state.config
        state.appliedConfig = state.config

        // UI 上的「按住这里说话」与「保存并应用」回调
        state.onTestStart = { [weak self] in
            self?.stopInputTest()
            self?.session.begin(testMode: true)
        }
        state.onTestStop = { [weak self] in self?.session.end() }
        state.onReloadConfig = { [weak self] in self?.reloadConfig() }
        state.onRefreshInputDevices = { [weak self] in self?.refreshInputDevices() }
        state.onInputTestStart = { [weak self] in self?.startInputTest() }
        state.onInputTestStop = { [weak self] in self?.stopInputTest() }
        state.onRefreshPermissions = { [weak self] in self?.checkPermissionsAndHotkey() }
        state.onHotkeyTestStart = { [weak self] in self?.startHotkeyTest() }
        state.onHotkeyTestCancel = { [weak self] in self?.cancelHotkeyTest() }
        state.onCheckUpdate = { [weak self] in self?.checkForUpdate(manual: true) }
        state.onInstallUpdate = { [weak self] in self?.installPendingUpdate() }
        refreshInputDevices()
        syncHotkeyActivation(forceRetry: true)

        // 启动 5 秒后查一次更新（错开启动关键路径），此后每 24 小时一次 ——
        // 菜单栏 App 一挂几个星期，只查启动那一次会漏掉所有后续版本
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdate(manual: false)
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForUpdate(manual: false) }
        }

        // 预设词库：启动 3 秒后同步一次 GitHub 上的最新版（24h 内同步过则跳过）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            WordlistStore.shared.refreshIfStale()
        }

        // 全局快捷键 ⌃⌥⌘V：粘贴上一段。未登录时不向系统注册。
        PasteLastHotkey.shared.onTrigger = { [weak self] in
            guard let self,
                  self.state.accountProfile != nil,
                  self.state.config.pasteLastHotkeyEnabled else { return }
            self.pasteLastTranscript()
        }
        syncHotkeyActivation()

        state.onResetHUDPosition = { [weak self] in
            self?.hud.resetPosition()
            self?.hud.flash(message: "悬浮条已恢复默认位置（跟随光标）", duration: 1.6)
        }

        // 「收起到菜单栏」：窗口 + Dock 图标一起藏,只留状态栏图标,热键照常
        NotificationCenter.default.addObserver(
            forName: .vivaCollapseToMenuBar, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.collapseToMenuBar() }
        }

        // 首次启动走欢迎引导；第一步是邮箱验证码登录/注册，
        // 不要求用户填写任何供应商 Key。
        // 无论走哪条，都必须开一个窗口 —— 菜单栏 App 什么都不弹的话，
        // 用户会以为「装了但没打开」。
        if !state.config.hasSeenWelcome {
            welcome.onFinish = { [weak self] in
                guard let self else { return }
                guard self.state.accountProfile != nil else {
                    // 红色关闭按钮也会走 onFinish；未登录时不能因此绕过账户门。
                    self.accountWindow.show()
                    return
                }
                Log.info("欢迎引导完成")
                self.state.config.hasSeenWelcome = true
                self.state.saveConfig()
                // ⚠️ saveConfig() 现在会把整份草稿标记为「已生效」（appliedConfig = config），
                //   所以必须紧跟一次 reloadConfig 把它真正推给 capture / hotkey / session。
                //   少了这一句就会出现「isReady 显示就绪、会话仍使用旧服务环境」——
                //   引导期间用户完全可以从菜单栏打开主界面去设置页改东西而不保存。
                self.state.onReloadConfig?()
                self.showWindowForCurrentAccount()
            }
            welcome.show()
        } else {
            showWindowForCurrentAccount()
        }

        startUp()
    }

    /// Keep the product-wide login gate in sync with token refreshes performed
    /// outside AccountView (ASR and LLM both refresh independently).
    private func bindManagedAccountState() {
        let authState = ManagedBackendAuth.shared.state

        // accountProfile 是全产品统一的登录门。只观察 nil / non-nil 变化，
        // 避免余额刷新时反复拆建系统热键监听。
        state.$accountProfile
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.syncHotkeyActivation(forceRetry: true)
            }
            .store(in: &accountCancellables)

        authState.$phase
            .combineLatest(authState.$user, authState.$wallet)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase, user, wallet in
                guard let self else { return }
                switch phase {
                case .signedOut:
                    self.state.accountProfile = nil
                    if self.state.config.hasSeenWelcome {
                        self.mainWindow.hide()
                        self.accountWindow.show()
                    }
                case .signedIn:
                    guard let user, let wallet else { return }
                    // 余额刷新也会发布 .signedIn；只有首次拿到账号资料时才能切换窗口，
                    // 否则一次听写结束就会抢走当前输入应用的焦点。
                    let shouldPresentMainWindow = self.state.accountProfile == nil
                    self.state.accountProfile = VivaAccountProfile(
                        email: user.email ?? "",
                        credits: wallet.availablePoints,
                        hasPassword: user.hasPassword)
                    if shouldPresentMainWindow {
                        self.accountWindow.close()
                        if self.state.config.hasSeenWelcome {
                            self.mainWindow.show()
                        }
                    }
                case .failed:
                    if self.state.accountProfile == nil,
                       self.state.config.hasSeenWelcome {
                        self.mainWindow.hide()
                        self.accountWindow.show()
                    }
                case .idle, .restoring:
                    break
                }
            }
            .store(in: &accountCancellables)
    }

    func applicationWillTerminate(_ n: Notification) {
        cancelHotkeyTest(resetMessage: false)
        stopInputTest()
        hotkey?.stop()
        PasteLastHotkey.shared.unregister()
        capture?.stopEngine()
        HistoryStore.shared.saveNow()
        unregisterEscMonitor()
    }

    /// 点 Dock / 重新打开时把主界面唤回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindowForCurrentAccount()
        return true
    }

    /// ⚠️ 必须有主菜单，否则自家窗口里的 ⌘V / ⌘C / ⌘A / ⌘Z **全部失效**。
    ///
    /// macOS 上文本编辑的剪切/拷贝/粘贴/全选是靠主菜单的 key equivalent 分发的，
    /// 不在 NSResponder 的默认链路里。LSUIElement + .accessory 的 App 不会自动获得
    /// 主菜单，于是设置页里的 URL、替换规则等文本输入会发现 ⌘V 没反应。
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Viva", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Viva",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Viva",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // ⌘[ 也必须挂在主菜单上，理由和上面的 ⌘V 完全一样：
        // 光在 SwiftUI 的工具栏按钮上写 .keyboardShortcut("[") 是不够的 ——
        // LSUIElement/.accessory 的 App 里那条路不可靠（实测按下没反应），
        // 而主菜单的 key equivalent 是全局分发的，稳定得多，顺带还能在菜单栏里被看见。
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "视图")
        let home = NSMenuItem(title: "返回主界面", action: #selector(goHome), keyEquivalent: "[")
        home.target = self
        view.addItem(home)
        viewItem.submenu = view
        main.addItem(viewItem)

        NSApp.mainMenu = main
    }

    @objc private func goHome() {
        guard state.accountProfile != nil else {
            accountWindow.show()
            return
        }
        mainWindow.show()
        NotificationCenter.default.post(name: .vivaGoHome, object: nil)
    }

    // MARK: - 启动流程

    private func startUp() {
        AudioCapture.requestPermission { [weak self] ok in
            guard let self else { return }
            Task { @MainActor in
                self.state.refreshPermissions()
                guard ok else {
                    self.state.lastError = "没有麦克风权限，无法采集语音。请在系统设置里授权后重启本应用。"
                    self.buildMenu()
                    return
                }
                do {
                    try self.capture.prewarm()      // 引擎常驻，消除冷启动丢字
                    self.state.audioEngineReady = true
                    Log.info("麦克风就绪（引擎已预热）")
                } catch {
                    self.state.audioEngineReady = false
                    self.state.lastError = "麦克风初始化失败：\(error.localizedDescription)"
                    Log.error(self.state.lastError)
                }
            }
        }
    }

    private func makeHotkey() -> HotkeyManager {
        let hk = HotkeyManager(config: state.config)
        hk.onPress = { [weak self] in
            Task { @MainActor in
                guard let self, self.state.accountProfile != nil else { return }
                if self.state.hotkeyTestRunning {
                    self.hotkeyTestPressDetected = true
                    self.state.hotkeyTestMessage = "已检测到按下，请松开完成测试"
                    return
                }
                // 锁定模式下会话已经在跑，长按不该再开一轮（begin 的 guard 会
                // 弹「正在收尾稍候」，那是误导 —— 用户只是手放上去了）
                guard !self.dictationLocked else { return }
                self.stopInputTest()
                self.session.begin()
            }
        }
        hk.onRelease = { [weak self] in
            Task { @MainActor in
                guard let self, self.state.accountProfile != nil else { return }
                if self.state.hotkeyTestRunning {
                    guard self.hotkeyTestPressDetected else { return }
                    self.finishHotkeyTest(
                        success: true,
                        message: "已检测到 \(HotkeyManager.describe(self.state.appliedConfig))，热键可用")
                    return
                }
                guard !self.dictationLocked else { return }
                self.session.end()
            }
        }
        hk.onShortTap = { [weak self] in
            Task { @MainActor in
                guard let self, self.state.accountProfile != nil else { return }
                guard !self.state.hotkeyTestRunning else { return }

                // 锁定中：单击立即结束 —— 不需要等第二击，停止意图越快兑现越好
                if self.dictationLocked {
                    self.dictationLocked = false
                    self.session.end()
                    return
                }
                // 未锁定：400ms 内两次短按 = 锁定开始连续听写。
                // 单次短按维持原语义（忽略，放行给系统的 ⌘C 等组合键）。
                let now = Date()
                if let last = self.lastShortTapAt, now.timeIntervalSince(last) < 0.4 {
                    self.lastShortTapAt = nil
                    self.stopInputTest()
                    self.session.begin()
                    // begin 可能因服务/权限未就绪直接失败回 idle —— 只有真开起来才锁
                    if self.state.isListening {
                        self.dictationLocked = true
                        self.hud.flash(message: "连续听写已开启 —— 再按一下 \(HotkeyManager.describe(self.state.appliedConfig)) 结束",
                                       duration: 2.2)
                    }
                } else {
                    self.lastShortTapAt = now
                }
            }
        }
        hk.onHealthChanged = { [weak self] healthy in
            Task { @MainActor in
                guard let self else { return }
                guard self.state.accountProfile != nil else {
                    self.state.hotkeyHealthy = false
                    self.state.hotkeyStatus = "登录后启用全局热键"
                    return
                }
                self.state.hotkeyHealthy = healthy
                self.state.hotkeyStatus = healthy
                    ? "全局热键监听正常"
                    : "热键监听被系统停用，后台正在恢复"
                if !healthy, self.state.hotkeyTestRunning {
                    self.finishHotkeyTest(success: false,
                                          message: "测试中监听被系统停用，请重新检查权限")
                }
                self.buildMenu()
            }
        }
        return hk
    }

    /// 后台权限检查的统一入口。
    ///
    /// 权限恢复后自动补建 CGEventTap；授权被撤销时拆掉旧监听。
    /// 创建失败也不会永久卡死，AppState 的 2 秒轮询会继续重试。
    private func checkPermissionsAndHotkey(forceRetry: Bool = false) {
        guard state.accountProfile != nil else {
            deactivateGlobalHotkeys()
            return
        }

        let previousAX = state.axGranted
        let previousHealthy = state.hotkeyHealthy
        let previousStatus = state.hotkeyStatus

        state.refreshPermissions()

        if forceRetry || previousAX != state.axGranted {
            Log.info("辅助功能权限：\(state.axGranted ? "已授权" : "未授权")")
        }

        guard state.axGranted else {
            if state.hotkeyTestRunning {
                finishHotkeyTest(success: false, message: "辅助功能权限不可用")
            }
            if state.hotkeyHealthy { hotkey.stop() }
            state.hotkeyHealthy = false
            state.hotkeyStatus = "辅助功能未授权；若列表中已开启，请移除旧 Viva 后重新添加"
            if previousAX != state.axGranted || previousHealthy != state.hotkeyHealthy
                || previousStatus != state.hotkeyStatus {
                buildMenu()
            }
            return
        }

        if forceRetry, state.hotkeyHealthy {
            hotkey.stop()
            state.hotkeyHealthy = false
        }

        if !state.hotkeyHealthy {
            state.hotkeyHealthy = hotkey.start()
            state.hotkeyStatus = state.hotkeyHealthy
                ? "全局热键监听正常"
                : "系统拒绝创建热键监听，后台将在 2 秒后重试"
            Log.info("权限检查后热键注册\(state.hotkeyHealthy ? "成功" : "失败")")
        } else {
            state.hotkeyStatus = "全局热键监听正常"
        }

        if previousAX != state.axGranted || previousHealthy != state.hotkeyHealthy
            || previousStatus != state.hotkeyStatus {
            buildMenu()
        }
    }

    /// 语音热键和“粘贴上一段”都属于系统级快捷键，统一跟随登录状态。
    private func syncHotkeyActivation(forceRetry: Bool = false) {
        guard hotkey != nil else { return }
        checkPermissionsAndHotkey(forceRetry: forceRetry)
        guard state.accountProfile != nil else { return }

        registerEscMonitorIfNeeded()
        if state.config.pasteLastHotkeyEnabled {
            PasteLastHotkey.shared.register()
        } else {
            PasteLastHotkey.shared.unregister()
        }
    }

    private func deactivateGlobalHotkeys() {
        let inactiveStatus = "登录后启用全局热键"
        let stateChanged = state.hotkeyHealthy || state.hotkeyStatus != inactiveStatus

        cancelHotkeyTest(resetMessage: false)
        dictationLocked = false
        lastShortTapAt = nil
        if let activeSession = session, activeSession.state != .idle {
            activeSession.abort()
        }
        hotkey?.stop()
        PasteLastHotkey.shared.unregister()
        unregisterEscMonitor()
        state.hotkeyHealthy = false
        state.hotkeyStatus = inactiveStatus

        if stateChanged {
            Log.info("账户未登录，已停用全局热键")
            if statusItem != nil { buildMenu() }
        }
    }

    private func registerEscMonitorIfNeeded() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.session.abort() }
        }
    }

    private func unregisterEscMonitor() {
        guard let monitor = escMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escMonitor = nil
    }

    // MARK: - 热键实测

    private func startHotkeyTest() {
        guard state.accountProfile != nil else {
            state.hotkeyTestResult = false
            state.hotkeyTestMessage = "请先登录 Viva 后再测试热键"
            return
        }
        checkPermissionsAndHotkey()
        guard state.hotkeyHealthy else {
            state.hotkeyTestResult = false
            state.hotkeyTestMessage = "热键监听未就绪，请先处理上方权限"
            return
        }
        guard session.state == .idle else {
            state.hotkeyTestResult = false
            state.hotkeyTestMessage = "语音输入正在进行，请结束后再测试"
            return
        }

        stopInputTest()
        Log.info("开始热键测试：\(HotkeyManager.describe(state.appliedConfig))")
        hotkeyTestTimeout?.invalidate()
        hotkeyTestPressDetected = false
        state.hotkeyTestRunning = true
        state.hotkeyTestResult = nil
        state.hotkeyTestMessage = "请按住 \(HotkeyManager.describe(state.appliedConfig))，然后松开"

        hotkeyTestTimeout = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.hotkeyTestRunning else { return }
                self.finishHotkeyTest(success: false,
                                      message: "10 秒内没有检测到热键，请检查按键配置或权限")
            }
        }
    }

    private func cancelHotkeyTest(resetMessage: Bool = true) {
        hotkeyTestTimeout?.invalidate()
        hotkeyTestTimeout = nil
        hotkeyTestPressDetected = false
        state.hotkeyTestRunning = false
        if resetMessage {
            state.hotkeyTestResult = nil
            state.hotkeyTestMessage = "已取消热键测试"
        }
    }

    private func finishHotkeyTest(success: Bool, message: String) {
        hotkeyTestTimeout?.invalidate()
        hotkeyTestTimeout = nil
        hotkeyTestPressDetected = false
        state.hotkeyTestRunning = false
        state.hotkeyTestResult = success
        state.hotkeyTestMessage = message
    }

    private func reloadConfig() {
        // ⚠️ 读 appliedConfig，**不要**读 state.config。
        //   state.config 是设置页的草稿，控件全都双向绑定在它上面。若这里读草稿，
        //   任何一个「立刻生效」的入口（说话页的 AI 润色胶囊、加替换规则、换热键）
        //   都会顺带把用户尚未保存、甚至打算丢弃的改动一起推进运行时 ——
        //   包括正在编辑的测试模式和本地服务 URL。
        //   真正生效的那份由 saveConfig()（整份提交）或 commitField()（单字段提交）
        //   在调这里之前写好。
        let new = state.appliedConfig
        let old = appliedConfig
        appliedConfig = new

        // ── 音频链路 ──
        capture.setPreRoll(ms: new.preRollMs)
        let inputDeviceChanged = old == nil || old!.inputDeviceUID != new.inputDeviceUID

        if inputDeviceChanged {
            stopInputTest()
            if session.state != .idle { session.abort() }
            do {
                try capture.setInputDevice(uid: new.inputDeviceUID,
                                           shouldPrewarm: state.micGranted)
                state.audioEngineReady = state.micGranted && capture.canStart
                state.audioInputError = ""
                state.lastError = ""
            } catch {
                state.audioEngineReady = false
                state.audioInputError = error.localizedDescription
                state.lastError = "输入设备切换失败：\(error.localizedDescription)"
                Log.error(state.lastError)
            }
            refreshInputDevices()
        }

        // ── 热键：只有三要素（或长按阈值）变了才重建 CGEventTap ──
        let hotkeyChanged = old == nil
            || old!.hotkeyKeyCode != new.hotkeyKeyCode
            || old!.hotkeyIsModifierOnly != new.hotkeyIsModifierOnly
            || old!.hotkeyModifiers != new.hotkeyModifiers
            || old!.holdThresholdMs != new.holdThresholdMs

        if hotkeyChanged {
            cancelHotkeyTest(resetMessage: false)
            // 先把可能还在跑的会话收干净，否则 hotkey.stop() 补发的 onRelease
            // 会打到即将被替换掉的 session 上，旧会话的 WebSocket 变成孤儿继续计费
            if session.state != .idle { session.abort() }
            hotkey.stop()
            hotkey = makeHotkey()
            state.hotkeyHealthy = false
        }

        // ── 其余配置（本地替换、润色、上屏方式）直接推给现有会话 ──
        session.update(config: new)
        if old?.testModeEnabled != new.testModeEnabled
            || old?.testBackendBaseURL != new.testBackendBaseURL {
            // Token 按服务 origin 隔离。切换环境后使用独立账户窗口恢复该 origin
            // 的本机登录会话；主窗口的 NavigationSplitView 不参与登录状态切换。
            state.accountProfile = nil
            mainWindow.hide()
            accountWindow.show()
        }

        syncHotkeyActivation(forceRetry: hotkeyChanged)

        buildMenu()
        Log.info("配置已重新加载（输入设备切换：\(inputDeviceChanged ? "是" : "否")，热键重建：\(hotkeyChanged ? "是" : "否")）")
    }

    // MARK: - 输入设备与本地测试

    private func refreshInputDevices() {
        state.audioInputDevicesLoading = true
        defer { state.audioInputDevicesLoading = false }
        do {
            let devices = try AudioInputDevices.available()
            state.audioInputDevices = devices
            let selectedUID = state.config.inputDeviceUID
            if devices.isEmpty {
                state.audioInputError = "没有检测到可用的音频输入设备"
            } else if selectedUID.isEmpty, !devices.contains(where: \.isDefault) {
                state.audioInputError = "macOS 当前没有设置默认输入设备"
            } else if !selectedUID.isEmpty,
                      !devices.contains(where: { $0.uid == selectedUID }) {
                state.audioInputError = "所选输入设备已断开，请重新选择"
            } else if !state.audioInputTestRunning {
                state.audioInputError = ""
            }
        } catch {
            state.audioInputDevices = []
            state.audioInputError = error.localizedDescription
        }
    }

    private func startInputTest() {
        guard !state.audioInputTestRunning else { return }
        if state.hotkeyTestRunning {
            cancelHotkeyTest()
        }
        guard state.micGranted else {
            state.audioInputError = "需要先在系统设置中允许 Viva 使用麦克风"
            return
        }
        guard session.state == .idle else {
            state.audioInputError = "语音输入正在进行，请结束后再测试麦克风"
            return
        }

        do {
            try capture.startTesting()
            state.audioInputTestLevel = 0
            state.audioInputTestRunning = true
            state.audioInputError = ""
            state.audioEngineReady = true
        } catch {
            state.audioInputTestRunning = false
            state.audioInputTestLevel = 0
            state.audioInputError = error.localizedDescription
            state.audioEngineReady = false
        }
    }

    private func stopInputTest() {
        guard capture != nil else { return }
        state.audioInputTestRunning = false
        capture.stopTesting()
        state.audioInputTestLevel = 0
    }

    // MARK: - 菜单栏

    private func updateStatusIcon(_ st: VoiceSession.State) {
        guard let button = statusItem.button else { return }
        let name: String
        switch st {
        case .idle:       name = "mic"
        case .listening:  name = "mic.fill"
        case .finalizing: name = "waveform"
        case .polishing:  name = "sparkles"
        }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Viva")
        button.image?.isTemplate = (st != .listening)
        button.contentTintColor = (st == .listening) ? .systemRed : nil
    }

    private func buildMenu() {
        let menu = NSMenu()

        let head = NSMenuItem(
            title: state.isReady
                ? "就绪 · 按住\(HotkeyManager.describe(state.config))说话"
                : "未就绪 —— 点「打开主界面」查看",
            action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        let all = HistoryStore.shared.allTime
        let today = HistoryStore.shared.today
        let stat = NSMenuItem(
            title: "今天 \(today.count) 次 · \(today.totalChars) 字　｜　累计 \(all.count) 次 · \(compactNumber(all.totalChars)) 字",
            action: nil, keyEquivalent: "")
        stat.isEnabled = false
        menu.addItem(stat)

        if TextInjector.isSecureInputEnabled {
            menu.addItem(withTitle: "  ⚠️ 安全键盘输入中，无法自动上屏",
                         action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开主界面", action: #selector(openMain), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        // 粘贴上一段：Secure Input / 注入失败 / 手滑清空时的兜底入口
        let paste = NSMenuItem(title: "粘贴上一段结果（⌃⌥⌘V）",
                               action: #selector(pasteLastFromMenu), keyEquivalent: "")
        paste.target = self
        menu.addItem(paste)

        let pasteOriginal = NSMenuItem(title: "粘贴上一段识别原文",
                                       action: #selector(pasteLastOriginalFromMenu),
                                       keyEquivalent: "")
        pasteOriginal.target = self
        menu.addItem(pasteOriginal)

        if let v = state.updateAvailable {
            let up = NSMenuItem(title: "⬆️ 升级到 \(v)…",
                                action: #selector(installUpdateFromMenu), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openMain() {
        // 可能正处于「收起到菜单栏」的 accessory 形态,先把 Dock 图标请回来
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        showWindowForCurrentAccount()
    }

    private func showWindowForCurrentAccount() {
        if state.accountProfile != nil {
            accountWindow.close()
            mainWindow.show()
        } else {
            mainWindow.hide()
            accountWindow.show()
        }
    }

    /// 收起到菜单栏:窗口藏起、Dock 图标撤下,App 变成纯菜单栏形态。
    /// 热键/识别/自动更新全部照常 —— 这本来就是语音输入工具的常驻姿势。
    /// 弹 HUD 提醒用户去哪找回来 —— 不弹的话「App 消失了」跟「App 崩了」没区别。
    private func collapseToMenuBar() {
        mainWindow.hide()
        NSApp.setActivationPolicy(.accessory)
        hud.flash(message: "Viva 已收起到顶部菜单栏 —— 热键照常可用，点状态栏图标随时唤回",
                  duration: 3.2)
        Log.info("已收起到菜单栏（accessory 形态）")
    }

    // MARK: - 粘贴上一段

    private enum LastTranscriptVersion {
        case final
        case original
    }

    /// 菜单点击要等菜单收起、焦点回到目标 App 再粘，否则可能粘错地方
    @objc private func pasteLastFromMenu() {
        pasteLastTranscript(version: .final, afterDelay: 0.25)
    }

    @objc private func pasteLastOriginalFromMenu() {
        pasteLastTranscript(version: .original, afterDelay: 0.25)
    }

    private func pasteLastTranscript(version: LastTranscriptVersion = .final,
                                     afterDelay delay: Double = 0) {
        guard let r = HistoryStore.shared.records.first else {
            hud.flash(message: "还没有识别记录，先说一句吧", duration: 1.4)
            return
        }
        let source = version == .original ? r.text : r.finalText
        let text = state.appliedConfig.stripTrailingPeriod
            ? TextPolish.stripTrailingPeriod(source) : source
        guard !text.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            switch TextInjector.commit(text, config: self.state.appliedConfig) {
            case .injected:
                let noun = version == .original ? "识别原文" : "结果"
                self.hud.flash(message: "已粘贴上一段\(noun)（\(text.count) 字）", duration: 1.2)
            case .copiedOnly(let reason):
                self.hud.flash(message: "已复制到剪贴板 —— \(reason)", duration: 2.0)
            }
        }
    }

    // MARK: - 软件更新

    /// manual = 用户点了「检查更新」按钮（失败/已最新都要给反馈）；
    /// 自动检查时这两种情况保持安静，别拿弹窗烦人。
    private func checkForUpdate(manual: Bool) {
        guard !state.updateBusy else { return }
        state.updateBusy = true
        if manual { state.updateStatus = "检查中…" }

        Task { @MainActor in
            defer { state.updateBusy = false }
            do {
                guard let release = try await updater.checkLatest() else {
                    pendingRelease = nil
                    state.updateAvailable = nil
                    if manual { state.updateStatus = "已是最新版（\(UpdateChecker.currentVersion)）" }
                    return
                }
                pendingRelease = release
                state.updateAvailable = release.version
                state.updateStatus = "发现新版 \(release.version)"
                buildMenu()   // 菜单栏挂上「升级」入口

                // 自动模式：正在说话/润色时绝不动刀 —— 换包要重启，会打断会话。
                // 忙就留给 24h 定时器或下次启动，提示入口反正已经亮了。
                if state.config.autoUpdate, !manual, session.state == .idle {
                    // ⚠️ 必须先解锁再调用：本 Task 的 defer 此刻还没执行，
                    //   updateBusy 仍是 true，不解锁 install 的 guard 会直接吞掉这次安装
                    //  （实测踩过：日志只有「发现新版」，后面什么都不发生）
                    state.updateBusy = false
                    installPendingUpdate()
                }
            } catch {
                pendingRelease = nil
                state.updateAvailable = nil
                if manual { state.updateStatus = error.localizedDescription }
                Log.warn("检查更新失败：\(error.localizedDescription)")
            }
        }
    }

    private func installPendingUpdate() {
        guard let release = pendingRelease, !state.updateBusy else { return }
        guard session.state == .idle else {
            state.updateStatus = "正在录音/润色，稍后再更新"
            return
        }
        state.updateBusy = true
        hud.flash(message: "正在更新到 \(release.version)，完成后自动重启…", duration: 3)

        Task { @MainActor in
            do {
                // 成功路径不会返回 —— downloadAndInstall 末尾会重启进程
                try await updater.downloadAndInstall(release) { [weak self] step in
                    self?.state.updateStatus = step
                }
            } catch {
                state.updateBusy = false
                state.updateStatus = error.localizedDescription
                Log.error("更新失败：\(error.localizedDescription)")
                hud.flash(message: "更新失败：\(error.localizedDescription)", isError: true, duration: 3.5)
            }
        }
    }

    @objc private func installUpdateFromMenu() { installPendingUpdate() }

}
