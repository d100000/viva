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
    /// 当前 capture / hotkey 是按哪份配置搭起来的，用来判断要不要真的重建。
    /// ⚠️ 没有它的话，词库页每加一个热词都会整体重启 AVAudioEngine + 重建 CGEventTap，
    ///   而 macOS 上「停掉引擎立刻新建再 start」是出了名的易失败时序
    ///   （inputNode 采样率会短暂返回 0），一失败就把 App 打成「未就绪」并弹红条。
    private var appliedConfig: Config?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)      // 菜单栏 App，不进 Dock
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon(.idle)
        buildMenu()

        capture = AudioCapture(preRollMs: state.config.preRollMs)
        session = VoiceSession(config: state.config, capture: capture, hud: hud)
        session.onStateChange = { [weak self] st in
            self?.updateStatusIcon(st)
            self?.buildMenu()
        }

        hotkey = makeHotkey()
        appliedConfig = state.config
        state.appliedConfig = state.config

        // UI 上的「按住这里说话」与「保存并应用」回调
        state.onTestStart = { [weak self] in self?.session.begin(testMode: true) }
        state.onTestStop = { [weak self] in self?.session.end() }
        state.onReloadConfig = { [weak self] in self?.reloadConfig() }

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
                self.mainWindow.show()
            }
            welcome.show()
        } else {
            mainWindow.show()
        }

        startUp()
    }

    func applicationWillTerminate(_ n: Notification) {
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
                self.setupHotkey()
            }
        }
    }

    private func makeHotkey() -> HotkeyManager {
        let hk = HotkeyManager(config: state.config)
        hk.onPress = { [weak self] in
            Task { @MainActor in self?.session.begin() }
        }
        hk.onRelease = { [weak self] in
            Task { @MainActor in self?.session.end() }
        }
        hk.onHealthChanged = { [weak self] healthy in
            Task { @MainActor in
                self?.state.hotkeyHealthy = healthy
                self?.buildMenu()
            }
        }
        return hk
    }

    private func setupHotkey() {
        state.refreshPermissions()
        guard HotkeyManager.hasAccessibilityPermission else {
            _ = HotkeyManager.promptForAccessibility()
            state.hotkeyHealthy = false
            buildMenu()
            // 用户可能稍后才在系统设置里授权。轮询到授权后自动把热键补注册上，
            // 否则 UI 会显示「就绪」但 CGEventTap 根本不存在（静默失败）。
            scheduleHotkeyRetry()
            return
        }
        state.hotkeyHealthy = hotkey.start()
        // ⚠️ 就绪提示**不要**走悬浮条。悬浮条只在识别过程中出现，
        //    平时屏幕上不该有任何浮层。就绪状态在菜单栏和主界面里已经有了。
        if !state.hotkeyHealthy {
            state.lastError = "热键注册失败，检查辅助功能权限"
        }
        buildMenu()
    }

    private var hotkeyRetry: Timer?

    private func scheduleHotkeyRetry() {
        hotkeyRetry?.invalidate()
        hotkeyRetry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                guard HotkeyManager.hasAccessibilityPermission else { return }
                t.invalidate()
                self.hotkeyRetry = nil
                self.state.hotkeyHealthy = self.hotkey.start()
                Log.info("检测到辅助功能已授权，热键补注册\(self.state.hotkeyHealthy ? "成功" : "失败")")
                self.buildMenu()
            }
        }
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

        // ── 音频链路：改预缓冲时长只需换环形缓冲上限，不动设备 ──
        capture.setPreRoll(ms: new.preRollMs)

        // ── 热键：只有三要素（或长按阈值）变了才重建 CGEventTap ──
        let hotkeyChanged = old == nil
            || old!.hotkeyKeyCode != new.hotkeyKeyCode
            || old!.hotkeyIsModifierOnly != new.hotkeyIsModifierOnly
            || old!.hotkeyModifiers != new.hotkeyModifiers
            || old!.holdThresholdMs != new.holdThresholdMs

        if hotkeyChanged {
            // 先把可能还在跑的会话收干净，否则 hotkey.stop() 补发的 onRelease
            // 会打到即将被替换掉的 session 上，旧会话的 WebSocket 变成孤儿继续计费
            if session.state != .idle { session.abort() }
            hotkey.stop()
            hotkey = makeHotkey()
            if HotkeyManager.hasAccessibilityPermission {
                state.hotkeyHealthy = hotkey.start()
            }
        }

        // ── 其余配置（热词、识别参数、润色、上屏方式）直接推给现有会话 ──
        session.update(config: new)

        buildMenu()
        Log.info("配置已重新加载（热键重建：\(hotkeyChanged ? "是" : "否")）")
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
