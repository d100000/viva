import SwiftUI
import AppKit

// MARK: - 热键录制

@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published var recording = false
    private var monitor: Any?

    /// (keyCode, 是否单修饰键, 修饰键掩码)
    var onCapture: ((Int64, Bool, UInt64) -> Void)?

    func toggle() { recording ? stop() : start() }

    func start() {
        guard !recording else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self, self.recording else { return ev }
            let code = Int64(ev.keyCode)
            // NSEvent.modifierFlags 拿不到左右区分位，必须回到 CGEvent 取完整 flags
            let raw = UInt64(ev.cgEvent?.flags.rawValue ?? 0)

            switch ev.type {
            case .keyDown:
                if code == 53 { self.stop(); return nil }          // Esc 取消录制
                let mods = raw & HotkeyManager.significantFlags
                if mods == 0 {
                    // 裸主键会和正常打字抢，必须带修饰键
                    NSSound.beep()
                    return nil
                }
                self.onCapture?(code, false, mods)
                self.stop()
                return nil

            case .flagsChanged:
                guard HotkeyManager.isModifierKeyCode(code),
                      let mask = HotkeyManager.deviceMasks[code] else { return nil }
                if raw & mask != 0 {                                // 只认按下那一刻
                    self.onCapture?(code, true, 0)
                    self.stop()
                }
                return nil

            default:
                return ev
            }
        }
    }

    func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
}

struct HotkeyRecorderField: View {
    @ObservedObject var state: AppState
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(recorder.recording
                          ? Color.accentColor.opacity(0.14)
                          : Color(nsColor: .textBackgroundColor))
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(recorder.recording ? Color.accentColor
                                                     : Color.secondary.opacity(0.3),
                                  lineWidth: recorder.recording ? 1.6 : 1)
                Text(recorder.recording ? "请按下按键…" : HotkeyManager.describe(state.config))
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(recorder.recording ? Color.accentColor : Color.primary)
            }
            .frame(width: 170, height: 34)
            .contentShape(Rectangle())
            .onTapGesture { recorder.toggle() }

            Button(recorder.recording ? "取消" : "录制") { recorder.toggle() }

            Menu("常用") {
                Button("右 ⌘（推荐）") { set(54, true, 0) }
                Button("右 ⌥") { set(61, true, 0) }
                Button("左 ⌥") { set(58, true, 0) }
                Button("右 ⌃") { set(62, true, 0) }
                Divider()
                Button("⌃⌥ Space") {
                    set(49, false,
                        CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue)
                }
                Button("⌥ Space") { set(49, false, CGEventFlags.maskAlternate.rawValue) }
                Divider()
                Button("Fn（不推荐）") { set(63, true, 0) }
            }
            .fixedSize()

            Spacer()
        }
        .onAppear {
            recorder.onCapture = { code, modOnly, mods in
                set(code, modOnly, mods)
            }
        }
        .onDisappear { recorder.stop() }
    }

    private func set(_ code: Int64, _ modOnly: Bool, _ mods: UInt64) {
        // 只提交热键这三个字段，不连带把同屏其它未保存的草稿一起生效
        state.commitField {
            $0.hotkeyKeyCode = code
            $0.hotkeyIsModifierOnly = modOnly
            $0.hotkeyModifiers = mods
        }
        state.onReloadConfig?()
    }
}

// MARK: - 词库页

struct DictionaryView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundStyle(.orange)
                            Text("识别后在本机自动纠错")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text("替换规则只在识别结果返回后由 Viva 客户端应用，不会改变服务端语音识别参数，也不会把自定义词表发送给供应商。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                ReplaceRuleSection(state: state)
                PresetReplacementSection(state: state)
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 预设替换规则

private struct PresetReplacementSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var store = WordlistStore.shared

    private var availableLists: [Wordlist] {
        store.lists.filter { !$0.replaceRules.isEmpty }
    }

    var body: some View {
        GroupBox("预设替换规则") {
            VStack(alignment: .leading, spacing: 10) {
                if availableLists.isEmpty {
                    Text("没有可用的预设替换规则")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(availableLists) { list in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: binding(for: list.id))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(list.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(list.replaceRules.count) 条本地替换 · v\(list.version)")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            Text("用于在本机纠正常见误识别，不会修改服务端识别配置。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                }

                Divider()
                HStack(spacing: 10) {
                    Button("立即同步") { store.refresh(force: true) }
                        .controlSize(.small)
                        .disabled(store.syncing)
                    if store.syncing { ProgressView().controlSize(.small) }
                    if !store.syncStatus.isEmpty {
                        Text(store.syncStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Text("预设规则由 Viva 仓库维护并定期同步，应用时仍只在本机处理识别文本。")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { state.config.enabledWordlists.contains(id) },
            set: { on in
                var lists = state.config.enabledWordlists
                if on { if !lists.contains(id) { lists.append(id) } }
                else { lists.removeAll { $0 == id } }
                state.config.enabledWordlists = lists
                state.commitField { $0.enabledWordlists = lists }
                state.onReloadConfig?()
            })
    }
}

// MARK: - 替换词表

private struct ReplaceRuleSection: View {
    @ObservedObject var state: AppState
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        GroupBox("替换词表（改词记忆）") {
            VStack(alignment: .leading, spacing: 10) {
                Text("识别结果里出现左边的内容时，在本机替换成右边的内容。主界面保存的「记住改法」也会出现在这里。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("识别成了…", text: $newFrom)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                    Image(systemName: "arrow.right").font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("应该是…", text: $newTo)
                        .textFieldStyle(.roundedBorder).frame(width: 150)
                    Button("添加", action: addRule)
                        .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newTo.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                }

                if !state.config.replaceRules.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(state.config.replaceRules) { rule in
                            HStack(spacing: 8) {
                                Text(rule.from)
                                    .font(.system(size: 12, design: .monospaced))
                                    .strikethrough(color: .secondary)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                                Text(rule.to)
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Button {
                                    removeRule(rule)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.primary.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private func addRule() {
        let from = newFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        let to = newTo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !from.isEmpty, !to.isEmpty, from != to else { return }
        var rules = state.config.replaceRules.filter { $0.from != from }   // 同 from 覆盖
        rules.append(ReplaceRule(from: from, to: to))
        persist(rules)
        newFrom = ""; newTo = ""
    }

    private func removeRule(_ rule: ReplaceRule) {
        persist(state.config.replaceRules.filter { $0 != rule })
    }

    private func persist(_ rules: [ReplaceRule]) {
        state.config.replaceRules = rules
        state.commitField { $0.replaceRules = rules }
        state.onReloadConfig?()
    }
}

// MARK: - 设置页

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var saved = false
    @State private var developerServiceExpanded = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                AccountView(
                    client: ManagedBackendAuth.shared,
                    showsDeveloperCode: state.appliedConfig.testModeEnabled,
                    onProfileChange: { state.accountProfile = $0 }
                )
                .id(state.appliedConfig.selectedBackendBaseURLString)

                GroupBox("Viva 服务") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Label(state.appliedConfig.testModeEnabled ? "开发者测试环境" : "Viva 托管环境",
                                  systemImage: state.appliedConfig.testModeEnabled
                                    ? "wrench.and.screwdriver" : "checkmark.shield.fill")
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(state.appliedConfig.hasValidBackendConfiguration ? "服务地址已就绪" : "服务地址无效")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(state.appliedConfig.hasValidBackendConfiguration
                                                 ? Color.green : Color.orange)
                        }

                        VivaServiceRoutingView(config: state.appliedConfig)

                        Divider()

                        DisclosureGroup(isExpanded: $developerServiceExpanded) {
                            VStack(alignment: .leading, spacing: 9) {
                                Toggle("连接本机测试服务",
                                       isOn: $state.config.testModeEnabled)

                                if state.config.testModeEnabled {
                                    LabeledRow("本地服务 URL") {
                                        TextField(Config.defaultTestBackendBaseURL,
                                                  text: $state.config.testBackendBaseURL)
                                            .textFieldStyle(.roundedBorder)
                                            .font(.system(.body, design: .monospaced))
                                    }
                                    Text("只接受单个 loopback origin：localhost、127.0.0.0/8 或 ::1；REST 与 WebSocket 必须由该 origin 统一代理。")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let error = state.config.backendConfigurationError {
                                        Label(error, systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption).foregroundStyle(.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    HStack {
                                        Button("恢复本地默认值") {
                                            state.config.testBackendBaseURL = Config.defaultTestBackendBaseURL
                                        }
                                        .controlSize(.small)
                                        Spacer()
                                    }
                                } else {
                                    Text("仅供开发和联调使用。普通用户保持关闭即可。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Label("开发者选项", systemImage: "wrench.and.screwdriver")
                                .font(.callout.weight(.medium))
                        }
                    }
                    .padding(6)
                }
                .id("service")

                PermissionsSettingsSection(state: state)

                MicrophoneSettingsSection(state: state)

                GroupBox("按住说话的快捷键") {
                    VStack(alignment: .leading, spacing: 10) {
                        HotkeyRecorderField(state: state)

                        Text("点方框或「录制」，然后按下你想用的键。可以是**单个修饰键**（按住右⌘说话），也可以是**组合键**（如 ⌃⌥Space）。组合键会被本应用吞掉，不会输入到当前程序里。按 Esc 取消录制。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Label {
                            Text("⚠️ 不建议用 Fn：微信输入法和豆包输入法都抢占了它，而且很多第三方键盘根本不上报 Fn 的按下事件。")
                        } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        HStack {
                            Text("环形预缓冲").frame(width: 92, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(state.config.preRollMs) },
                                set: { state.config.preRollMs = Int($0) }),
                                   in: 0...800, step: 100)
                                .frame(width: 220)
                                .disabled(!state.config.keepAudioEngineWarm)
                            Text("\(state.config.preRollMs) ms").monospacedDigit()
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(state.config.keepAudioEngineWarm
                             ? "按下热键时，把此前这段时间的音频一并送出，减少开头几个字被吃掉。"
                             : "开启“加速引擎”后生效，可减少句首内容遗漏。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Toggle("⌃⌥⌘V 全局粘贴上一段识别结果", isOn: $state.config.pasteLastHotkeyEnabled)
                        Text("目标 App 开着安全键盘输入、或注入失败只进了剪贴板时，用它把上一段找回来。菜单栏里也有同名入口。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }
                .id("hotkey")   // 主页「修改快捷键」跳转的锚点

                GroupBox("上屏节奏") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("松手才上屏（不逐句上屏）", isOn: $state.config.commitOnlyAtEnd)

                        Divider()

                        Toggle("连续听写：长句中途也逐段上屏", isOn: $state.config.progressiveCommit)
                            .disabled(state.config.commitOnlyAtEnd)
                        Label {
                            Text("开启后，客户端会把已经稳定、以标点收尾的部分提前写进光标处。**启用任意 AI 处理模式时此功能自动让位**（AI 需要拿全文处理）。\n配合**双击 \(HotkeyManager.describe(state.config)) 锁定**使用：双击开始连续听写，不用一直按着，再按一下结束。")
                        } icon: { Image(systemName: "infinity") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        HStack(spacing: 10) {
                            Button("恢复悬浮条默认位置") { state.onResetHUDPosition?() }
                                .controlSize(.small)
                            Text("悬浮条可以直接拖到任意位置固定；恢复后重新跟随光标。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                }

                AppProfileSection(state: state)

                GroupBox("文本整理") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("去掉末尾句号（「今天开会。」→「今天开会」）",
                               isOn: $state.config.stripTrailingPeriod)
                        Label {
                            Text("识别结果以句号收尾时，由客户端在写入前去掉它。**只去句号**；问号、感叹号和省略号会原样保留。")
                        } icon: { Image(systemName: "text.badge.minus") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

                GroupBox("大模型处理") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("AI 处理模式", selection: Binding(
                            get: { state.config.aiProcessingMode },
                            set: { state.config.aiProcessingMode = $0 })) {
                            ForEach(AIProcessingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Label {
                            Text(state.config.aiProcessingMode.detail)
                        } icon: { Image(systemName: "info.circle") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        if state.config.aiProcessingMode != .off {
                            Label("使用 Viva 托管模型 · 无需填写模型名或 API Key",
                                  systemImage: "checkmark.shield.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)

                            Toggle("流式显示 AI 处理过程", isOn: $state.config.polishStream)
                            Text("只影响悬浮条的实时反馈；最终仍会等待完整结果后再上屏，避免半截文本进入当前应用。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack {
                                Text("最长等待").frame(width: 74, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(state.config.polishTimeoutMs) },
                                    set: { state.config.polishTimeoutMs = Int($0) }),
                                       in: 1000...5000, step: 500)
                                    .frame(width: 220)
                                Text(String(format: "%.1f 秒",
                                            Double(state.config.polishTimeoutMs) / 1000))
                                    .monospacedDigit()
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("这是基础等待时间；为避免长文本被过早截断，实际总预算还会按每个字符增加约 30 ms。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            VStack(alignment: .leading, spacing: 7) {
                                HStack(spacing: 10) {
                                    Button {
                                        state.runPolishTest()
                                    } label: {
                                        if state.polishTestRunning {
                                            HStack(spacing: 5) {
                                                ProgressView().controlSize(.small)
                                                Text("测试中…")
                                            }
                                        } else {
                                            Text("测试托管模型")
                                        }
                                    }
                                    .disabled(state.polishTestRunning
                                              || !state.config.hasValidBackendConfiguration)

                                    if let ms = state.polishTestMs {
                                        Text("\(ms) ms").font(.caption)
                                            .foregroundStyle(ms < 2000 ? .green : .orange)
                                            .monospacedDigit()
                                    }
                                    Spacer()
                                }

                                if let error = state.polishTestError {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else if let output = state.polishTestOutput {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("原文　嗯那个我们今天下午三点开个会讨论一下豆包流是语音识别的接入方案就是说那个接口的部分")
                                            .font(.caption).foregroundStyle(.tertiary)
                                        Text("处理后　\(output)")
                                            .font(.system(size: 12.5))
                                            .textSelection(.enabled)
                                    }
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.green.opacity(0.09),
                                                in: RoundedRectangle(cornerRadius: 7))
                                }
                            }
                        }
                    }
                    .padding(6)
                }

                GroupBox("上屏方式") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("用剪贴板 + ⌘V（兼容性最好，推荐）",
                               isOn: $state.config.useClipboardPaste)
                        Text("关闭则改用 CGEvent 逐字键入：不污染剪贴板、不占用撤销栈，但在 Electron 应用（VS Code / Slack / 飞书）和终端里容易丢字。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if state.config.useClipboardPaste {
                            HStack {
                                Text("恢复延迟").frame(width: 72, alignment: .leading)
                                Slider(value: Binding(
                                    get: { Double(state.config.clipboardRestoreDelayMs) },
                                    set: { state.config.clipboardRestoreDelayMs = Int($0) }),
                                       in: 100...2000, step: 50)
                                    .frame(width: 220)
                                Text("\(state.config.clipboardRestoreDelayMs) ms")
                                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                            }
                            Text("粘贴后多久恢复你原本的剪贴板内容。恢复太早目标应用可能还没读走，会粘出旧内容。iTerm2 / Warp 这类慢终端会自动提到 1500ms。")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(6)
                }

                GroupBox("软件更新") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text("当前版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                                .font(.callout)
                            if state.updateBusy { ProgressView().controlSize(.small) }
                            if !state.updateStatus.isEmpty {
                                Text(state.updateStatus)
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        Toggle("启动时自动更新到新版本", isOn: $state.config.autoUpdate)
                        HStack {
                            Button("检查更新") { state.onCheckUpdate?() }
                                .disabled(state.updateBusy)
                            if state.updateAvailable != nil {
                                Button("立即更新") { state.onInstallUpdate?() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(state.updateBusy)
                            }
                        }
                        Label {
                            Text("更新来源是 [GitHub Releases](https://github.com/d100000/viva/releases)，下载后校验版本、原地替换并自动重启。所有版本用同一张固定证书签名，**更新后「辅助功能」授权保持有效**，无需重新添加。")
                        } icon: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

                GroupBox("数据与隐私") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("**语音识别**：音频加密发送到 Viva 服务，再由服务端转发至已配置的语音识别供应商。供应商长期密钥不会下发到客户端。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("**大模型处理**：只有开启润色或口误纠正时才发送识别文本到 Viva 服务，不重复发送音频。模型、Prompt 和上游路由由服务端统一管理。当前客户端不会发送目标 App 标识或历史正文。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("**登录状态**：正式发布版使用系统钥匙串；当前本地开发版保存在仅当前 Mac 用户可读的本机会话文件中，重新编译后不会索取系统密码。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("**本地测试模式**：语音和文本都改发到你填写的本地项目 URL。客户端要求同一 origin 同时代理 `/v1/asr/stream` 与 `/v1/text/*`，避免暴露多个可编辑上游入口。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("全部保存在本机这个目录下，已按类别分开存放 —— 顶层 `config.json` 才是配置，其余各归子目录，重置配置不会误伤历史/证书：")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("""
                        \(Config.configDir.path)/
                          ├─ config.json   配置（不含供应商 API Key）
                          ├─ auth/         当前设备登录会话
                          ├─ data/         识别历史
                          ├─ logs/         运行日志
                          ├─ crashes/      崩溃报告
                          └─ signing/      代码签名证书备份（勿删）
                        """)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("在访达中显示") {
                                NSWorkspace.shared.activateFileViewerSelecting([Config.configURL])
                            }
                            Button("打开配置文件") {
                                NSWorkspace.shared.open(Config.configURL)
                            }
                        }

                        Divider()

                        // 排障时让用户「把日志发来」，没有这两行地址就是一句空话。
                        Text("运行日志（自动轮转，最多保留约 4 MB）：")
                            .font(.callout)
                        Text(Log.fileURL.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        Text("崩溃报告文件夹（自动清理 30 天前的）：")
                            .font(.callout)
                        Text(CrashReporter.dirURL.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button("打开日志") {
                                NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                            }
                            Button("打开崩溃报告文件夹") {
                                // 文件夹可能是空的（从没崩过），直接打开而不是选中
                                NSWorkspace.shared.open(CrashReporter.dirURL)
                            }
                            if let last = CrashReporter.latestReport() {
                                Button("查看上次崩溃") {
                                    NSWorkspace.shared.activateFileViewerSelecting([last])
                                }
                            }
                        }
                    }
                    .padding(6)
                }

            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            settingsSaveBar
        }
        // 从主页「修改快捷键」进来：滚到热键那一节。
        // onAppear 兜底（跳转时本页往往刚挂载，onChange 赶不上）。
        .onAppear {
            if state.config.testModeEnabled { developerServiceExpanded = true }
            consumePendingAnchor(proxy)
        }
        .onChange(of: state.config.testModeEnabled) { _, enabled in
            if enabled { developerServiceExpanded = true }
        }
        .onChange(of: state.pendingSettingsAnchor) { _, _ in consumePendingAnchor(proxy) }
        }
    }

    private var settingsSaveBar: some View {
        HStack(spacing: 10) {
            Group {
                if state.hasUnsavedChanges {
                    Label("有未保存更改", systemImage: "circle.fill")
                        .foregroundStyle(.orange)
                } else if saved {
                    Label("已保存并生效", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("所有设置已生效", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            Spacer()

            if state.hasUnsavedChanges {
                Button {
                    state.config = state.appliedConfig
                    saved = false
                } label: {
                    Label("还原", systemImage: "arrow.uturn.backward")
                }
            }

            Button {
                state.saveConfig()
                state.onReloadConfig?()
                saved = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { saved = false }
            } label: {
                Label("保存并应用", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s")
            .disabled(!state.hasUnsavedChanges)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func consumePendingAnchor(_ proxy: ScrollViewProxy) {
        guard let anchor = state.pendingSettingsAnchor else { return }
        // 略等一帧让内容完成布局，否则 onAppear 时滚动目标还没算出位置
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(anchor, anchor: .top)
            }
            state.pendingSettingsAnchor = nil
        }
    }

// MARK: - 按 App 自动切换（Profile）

/// 竞品标配（VoiceInk / superwhisper / Wispr 的 Power Mode）：
/// 在终端里关润色 + 逐字键入，在微信里开润色 + 剪贴板上屏。
/// 会话开始时按目标 App 匹配，覆盖字段只影响那一次会话。
private struct AppProfileSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        GroupBox("按 App 自动切换") {
            VStack(alignment: .leading, spacing: 10) {
                Text("给特定 App 单独定行为：在这些 App 里说话时，下面选项覆盖全局设置，其余照旧。典型用法：终端/IDE 关闭 AI 处理并逐字键入；微信/飞书开启口误纠正或轻度润色。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(state.config.appProfiles) { profile in
                    ProfileRow(state: state, profile: profile)
                }

                AddProfileMenu(state: state)
            }
            .padding(6)
        }
    }
}

private struct ProfileRow: View {
    @ObservedObject var state: AppState
    let profile: AppProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(profile.appName.isEmpty ? profile.bundleId : profile.appName)
                    .font(.system(size: 13, weight: .medium))
                Text(profile.bundleId)
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    persist(state.config.appProfiles.filter { $0.bundleId != profile.bundleId })
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }
            HStack(spacing: 14) {
                tri("轻度润色", \.enablePolish)
                tri("口误纠正", \.enableCourseCorrection)
                tri("剪贴板上屏", \.useClipboardPaste)
                tri("连续听写", \.progressiveCommit)
                Spacer()
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 三态：跟随全局（nil）/ 开 / 关
    private func tri(_ title: String, _ key: WritableKeyPath<AppProfile, Bool?>) -> some View {
        Picker(title, selection: Binding<Int>(
            get: {
                switch profile[keyPath: key] {
                case nil: return 0
                case true?: return 1
                case false?: return 2
                }
            },
            set: { v in
                var profiles = state.config.appProfiles
                guard let i = profiles.firstIndex(where: { $0.bundleId == profile.bundleId }) else { return }
                profiles[i][keyPath: key] = (v == 0 ? nil : v == 1)
                persist(profiles)
            })) {
            Text("跟随全局").tag(0)
            Text("开").tag(1)
            Text("关").tag(2)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
    }

    private func persist(_ profiles: [AppProfile]) {
        state.config.appProfiles = profiles
        state.commitField { $0.appProfiles = profiles }
        state.onReloadConfig?()
    }
}

/// 从正在运行的 App 里挑一个添加 —— 手填 bundleId 是反人类的
private struct AddProfileMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Menu {
            ForEach(runningApps(), id: \.0) { bid, name in
                Button(name) { add(bundleId: bid, name: name) }
            }
        } label: {
            Label("从正在运行的 App 添加…", systemImage: "plus.circle")
                .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func runningApps() -> [(String, String)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let bid = app.bundleIdentifier,
                      bid != Bundle.main.bundleIdentifier,
                      !state.config.appProfiles.contains(where: { $0.bundleId == bid })
                else { return nil }
                return (bid, app.localizedName ?? bid)
            }
            .sorted { $0.1.localizedCompare($1.1) == .orderedAscending }
    }

    private func add(bundleId: String, name: String) {
        var profiles = state.config.appProfiles
        profiles.append(AppProfile(bundleId: bundleId, appName: name))
        state.config.appProfiles = profiles
        state.commitField { $0.appProfiles = profiles }
        state.onReloadConfig?()
    }
}

// MARK: - 权限与状态

private struct PermissionsSettingsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        GroupBox("权限与状态") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Label("后台自动检查", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let checkedAt = state.permissionLastCheckedAt {
                        Text(checkedAt.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button {
                        state.onRefreshPermissions?()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .help("立即重新检查权限")
                }
                .padding(.bottom, 7)

                Divider()

                PermissionStatusRow(
                    ok: state.micGranted,
                    icon: "mic.fill",
                    title: "麦克风",
                    detail: state.micGranted
                        ? "已允许读取语音输入"
                        : "未授权，无法录音和测试输入设备",
                    actionTitle: state.micGranted ? nil : "前往开启",
                    action: openMicrophonePrivacy)

                Divider()

                PermissionStatusRow(
                    ok: state.axGranted,
                    icon: "accessibility",
                    title: "辅助功能",
                    detail: state.axGranted
                        ? "已允许全局热键和文字上屏"
                        : "未授权；若列表中已开启，请移除旧 Viva 后重新添加当前版本",
                    actionTitle: state.axGranted ? nil : "前往开启",
                    action: HotkeyManager.openAccessibilitySettings)

                Divider()

                PermissionStatusRow(
                    ok: state.hotkeyHealthy,
                    icon: "command",
                    title: "全局热键",
                    detail: state.hotkeyStatus,
                    actionTitle: hotkeyActionTitle,
                    action: hotkeyAction)

                HStack(spacing: 7) {
                    if state.hotkeyTestRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: hotkeyTestIcon)
                            .foregroundStyle(hotkeyTestColor)
                    }
                    Text(state.hotkeyTestMessage)
                        .font(.caption)
                        .foregroundStyle(hotkeyTestColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(.leading, 38)
                .padding(.bottom, 7)
            }
            .padding(6)
        }
        .onAppear { state.onRefreshPermissions?() }
        .onDisappear {
            if state.hotkeyTestRunning { state.onHotkeyTestCancel?() }
        }
    }

    private var hotkeyActionTitle: String? {
        if state.hotkeyTestRunning { return "取消测试" }
        if state.hotkeyHealthy { return "测试热键" }
        if state.axGranted { return "重新注册" }
        return nil
    }

    private var hotkeyTestIcon: String {
        switch state.hotkeyTestResult {
        case true: return "checkmark.circle.fill"
        case false: return "xmark.circle.fill"
        case nil: return "circle.dashed"
        }
    }

    private var hotkeyTestColor: Color {
        if state.hotkeyTestRunning { return .accentColor }
        switch state.hotkeyTestResult {
        case true: return .green
        case false: return .orange
        case nil: return .secondary
        }
    }

    private func hotkeyAction() {
        if state.hotkeyTestRunning {
            state.onHotkeyTestCancel?()
        } else if state.hotkeyHealthy {
            state.onHotkeyTestStart?()
        } else {
            state.onRefreshPermissions?()
        }
    }

    private func openMicrophonePrivacy() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct PermissionStatusRow: View {
    let ok: Bool
    let icon: String
    let title: String
    let detail: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(ok ? Color.green.opacity(0.14) : Color.orange.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ok ? Color.green : Color.orange)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let actionTitle {
                Button(actionTitle, action: action)
                    .fixedSize()
            } else if ok {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .help("检查通过")
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("尚未通过检查")
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 麦克风输入

private struct MicrophoneSettingsSection: View {
    @ObservedObject var state: AppState

    private var defaultDevice: AudioInputDevice? {
        state.audioInputDevices.first(where: \.isDefault)
    }

    private var selectedDeviceAvailable: Bool {
        state.config.inputDeviceUID.isEmpty
            ? defaultDevice != nil
            : state.audioInputDevices.contains(where: { $0.uid == state.config.inputDeviceUID })
    }

    private var systemDefaultTitle: String {
        guard let device = defaultDevice else { return "系统默认" }
        return "系统默认 — \(device.name)"
    }

    private var levelText: String {
        guard state.audioInputTestRunning else { return "等待测试" }
        switch state.audioInputTestLevel {
        case ..<0.025: return "等待声音"
        case ..<0.12: return "声音偏小"
        case ..<0.72: return "声音正常"
        default: return "声音较强"
        }
    }

    var body: some View {
        GroupBox("麦克风输入") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("输入设备")
                        .frame(width: 92, alignment: .leading)

                    Picker("", selection: Binding(
                        get: { state.config.inputDeviceUID },
                        set: selectDevice)) {
                        Text(systemDefaultTitle).tag("")
                        Divider()
                        ForEach(state.audioInputDevices) { device in
                            Text(devicePickerLabel(device)).tag(device.uid)
                        }
                        if !state.config.inputDeviceUID.isEmpty,
                           !state.audioInputDevices.contains(where: {
                               $0.uid == state.config.inputDeviceUID
                           }) {
                            Text("设备不可用（已断开）").tag(state.config.inputDeviceUID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 410)
                    .disabled(state.isListening)

                    Button {
                        state.onRefreshInputDevices?()
                    } label: {
                        Group {
                            if state.audioInputDevicesLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(state.audioInputDevicesLoading || state.isListening)
                    .help("刷新输入设备")

                    Spacer()
                }

                Divider()

                Toggle("加速引擎",
                       isOn: $state.config.keepAudioEngineWarm)
                    .disabled(state.isListening || state.audioInputTestRunning)

                Label {
                    Text(state.config.keepAudioEngineWarm
                         ? "引擎会提前就绪，按下热键即可开始采集，减少句首内容遗漏，让整句话识别得更完整。开启后，macOS 会在空闲时显示麦克风正在使用；蓝牙设备仍会按需启动。"
                         : "默认关闭，由你选择开启。关闭时只在语音输入或麦克风测试时启动，空闲时不持续使用麦克风。")
                } icon: {
                    Image(systemName: state.config.keepAudioEngineWarm
                          ? "bolt.fill" : "bolt")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(spacing: 10) {
                    Image(systemName: state.audioInputTestRunning
                          ? "waveform" : "mic")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(state.audioInputTestRunning
                                         ? Color.accentColor : Color.secondary)
                        .frame(width: 20)

                    InputLevelMeter(level: state.audioInputTestLevel,
                                    active: state.audioInputTestRunning)
                        .frame(height: 14)

                    Text("\(Int(state.audioInputTestLevel * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)

                    Text(levelText)
                        .font(.caption)
                        .foregroundStyle(state.audioInputTestRunning
                                         ? levelColor(state.audioInputTestLevel)
                                         : Color.secondary)
                        .frame(width: 62, alignment: .leading)

                    Button {
                        if state.audioInputTestRunning {
                            state.onInputTestStop?()
                        } else {
                            state.onInputTestStart?()
                        }
                    } label: {
                        Label(state.audioInputTestRunning ? "停止" : "测试麦克风",
                              systemImage: state.audioInputTestRunning
                                ? "stop.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(state.audioInputTestRunning ? Color.red : Color.accentColor)
                    .disabled(!state.micGranted || !selectedDeviceAvailable || state.isListening)
                    .fixedSize()
                }

                if !state.micGranted {
                    HStack(spacing: 8) {
                        Label("Viva 没有麦克风权限", systemImage: "mic.slash.fill")
                            .font(.caption).foregroundStyle(.orange)
                        Button("打开系统设置") { openMicrophonePrivacy() }
                            .buttonStyle(.link)
                        Spacer()
                    }
                } else if !state.audioInputError.isEmpty {
                    Label(state.audioInputError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(state.audioInputTestRunning
                          ? "正在本地监听输入电平，音频不会发送到识别服务"
                          : "测试只读取本地音量，不连接识别服务",
                          systemImage: state.audioInputTestRunning
                            ? "waveform.circle.fill" : "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
        .onAppear { state.onRefreshInputDevices?() }
        .onDisappear { state.onInputTestStop?() }
        .onChange(of: state.micGranted) { _, granted in
            if !granted { state.onInputTestStop?() }
        }
    }

    private func selectDevice(_ uid: String) {
        guard uid != state.config.inputDeviceUID else { return }
        state.onInputTestStop?()
        state.commitField { $0.inputDeviceUID = uid }
        state.onReloadConfig?()
    }

    private func devicePickerLabel(_ device: AudioInputDevice) -> String {
        let defaultMark = device.isDefault ? " · 当前默认" : ""
        return "\(device.name) · \(device.connectionLabel)\(defaultMark)"
    }

    private func levelColor(_ level: Float) -> Color {
        if level >= 0.88 { return .red }
        if level >= 0.72 { return .orange }
        return level < 0.025 ? .secondary : .green
    }

    private func openMicrophonePrivacy() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct InputLevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(meterColor)
                    .frame(width: active
                           ? max(2, geometry.size.width * CGFloat(min(1, max(0, level))))
                           : 0)
                HStack(spacing: 0) {
                    Spacer()
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
                        .frame(width: 1)
                    Spacer()
                    Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.7))
                        .frame(width: 1)
                    Spacer()
                }
                .clipShape(Capsule())
            }
        }
        .animation(.linear(duration: 0.06), value: level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("麦克风输入音量")
        .accessibilityValue(active ? "\(Int(level * 100))%" : "未测试")
    }

    private var meterColor: Color {
        if level >= 0.88 { return .red }
        if level >= 0.72 { return .orange }
        return .green
    }
}

}

// MARK: -

private struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(label).frame(width: 92, alignment: .leading)
            content
        }
    }
}
