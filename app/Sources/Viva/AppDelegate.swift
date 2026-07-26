import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let state = AppState.shared
    private var statusItem: NSStatusItem!
    private var capture: AudioCapture!
    private var hotkey: HotkeyManager!
    private var session: VoiceSession!
    private let hud = HUDController()
    private let mainWindow = MainWindowController()
    private let welcome = WelcomeWindowController()
    private var escMonitor: Any?
    private var hotkeyTestTimeout: Timer?
    private var hotkeyTestPressDetected = false
    /// 点按开关模式：双击热键锁定连续听写，无需一直按住。
    /// 锁定期间 onPress/onRelease 都被旁路，单击（onShortTap）= 结束。
    private var dictationLocked = false
    private var lastShortTapAt: Date?
    /// 当前 capture / hotkey 是按哪份配置搭起来的，用来判断要不要真的重建。
    /// ⚠️ 没有它的话，词库页每加一个热词都会整体重启 AVAudioEngine + 重建 CGEventTap，
    ///   而 macOS 上「停掉引擎立刻新建再 start」是出了名的易失败时序
    ///   （inputNode 采样率会短暂返回 0），一失败就把 App 打成「未就绪」并弹红条。
    private var appliedConfig: Config?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)      // 菜单栏 App，不进 Dock
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        Log.info("===== Viva 启动 version=\(version) pid=\(ProcessInfo.processInfo.processIdentifier) =====")
        Log.info("运行路径：\(Bundle.main.bundlePath)；日志：\(Log.fileURL.path)")
        installMainMenu()

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
        refreshInputDevices()
        checkPermissionsAndHotkey(forceRetry: true)

        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { Task { @MainActor in self?.session.abort() } }
        }

        // 首次启动（或还没配好 Key）走欢迎引导；否则直接进主界面。
        // 无论走哪条，都必须开一个窗口 —— 菜单栏 App 什么都不弹的话，
        // 用户会以为「装了但没打开」。
        if !state.config.hasSeenWelcome || !state.config.hasCredentials {
            welcome.onFinish = { [weak self] in
                guard let self else { return }
                Log.info("欢迎引导完成")
                self.state.config.hasSeenWelcome = true
                self.state.saveConfig()
                // ⚠️ saveConfig() 现在会把整份草稿标记为「已生效」（appliedConfig = config），
                //   所以必须紧跟一次 reloadConfig 把它真正推给 capture / hotkey / session。
                //   少了这一句就会出现「isReady 显示就绪、按热键却报还没配 Key」——
                //   引导期间用户完全可以从菜单栏打开主界面去设置页改东西而不保存。
                self.state.onReloadConfig?()
                self.mainWindow.show()
            }
            welcome.show()
        } else {
            mainWindow.show()
        }

        startUp()
    }

    func applicationWillTerminate(_ n: Notification) {
        cancelHotkeyTest(resetMessage: false)
        stopInputTest()
        hotkey?.stop()
        capture?.stopEngine()
        HistoryStore.shared.saveNow()
        if let m = escMonitor { NSEvent.removeMonitor(m) }
    }

    /// 点 Dock / 重新打开时把主界面唤回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    /// ⚠️ 必须有主菜单，否则自家窗口里的 ⌘V / ⌘C / ⌘A / ⌘Z **全部失效**。
    ///
    /// macOS 上文本编辑的剪切/拷贝/粘贴/全选是靠主菜单的 key equivalent 分发的，
    /// 不在 NSResponder 的默认链路里。LSUIElement + .accessory 的 App 不会自动获得
    /// 主菜单，于是用户在欢迎页粘贴 40 多位的 API Key 时会发现 ⌘V 没反应 ——
    /// 这是整条 onboarding 上最容易让人直接放弃的一步，且现象诡异到不会怀疑是 App 的问题。
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
                guard let self else { return }
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
                guard let self else { return }
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
                guard let self else { return }
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
                    // begin 可能因缺 Key/权限直接失败回 idle —— 只有真开起来才锁
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

    // MARK: - 热键实测

    private func startHotkeyTest() {
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
        //   任何一个「立刻生效」的入口（说话页的 AI 润色胶囊、加热词、换热键）
        //   都会顺带把用户尚未保存、甚至打算丢弃的改动一起推进运行时 ——
        //   包括那个被清空准备重贴的 API Key。
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
            checkPermissionsAndHotkey(forceRetry: true)
        }

        // ── 其余配置（热词、识别参数、润色、上屏方式）直接推给现有会话 ──
        session.update(config: new)

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

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func openMain() { mainWindow.show() }

}
