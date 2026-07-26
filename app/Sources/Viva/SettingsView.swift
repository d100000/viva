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
    @State private var newWord = ""
    @State private var bulkMode = false
    @State private var bulkText = ""
    @State private var justSaved = false
    @FocusState private var inputFocused: Bool

    private var words: [String] { state.config.hotwords }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── 说明卡 ──
                GroupBox {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles").foregroundStyle(.orange)
                            Text("热词是专有名词识别率的最大杠杆")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text("把最容易被识错的人名、产品名、技术术语加进来，直接传给豆包的 corpus.context。实测「Claude」不加热词会被识别成「Cloth」，「上屏」会变成「尚平」。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // ── 添加 ──
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            TextField(bulkMode ? "批量编辑中，请在下方文本框修改" : "输入一个热词，回车添加",
                                      text: $newWord)
                                .textFieldStyle(.roundedBorder)
                                .focused($inputFocused)
                                .onSubmit(addWord)
                                // 批量编辑用的是进入时的快照，退出时整体覆盖。
                                // 若此时还能从这里加词，退出批量编辑会把刚加的词吞掉。
                                .disabled(bulkMode)
                            Button("添加", action: addWord)
                                .disabled(bulkMode || newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button(bulkMode ? "退出批量编辑" : "批量编辑") {
                                if bulkMode {
                                    applyBulk()
                                } else {
                                    bulkText = words.joined(separator: "\n")
                                }
                                bulkMode.toggle()
                            }
                        }

                        if bulkMode {
                            VStack(alignment: .leading, spacing: 6) {
                                TextEditor(text: $bulkText)
                                    .font(.system(size: 13, design: .monospaced))
                                    .scrollContentBackground(.hidden)
                                    .padding(6)
                                    .frame(height: 180)
                                    .background(Color(nsColor: .textBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 7))
                                    .overlay(RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(Color.secondary.opacity(0.28)))
                                Text("一行一个词。点「退出批量编辑」保存。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        if !bulkMode {
                            if words.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "character.book.closed")
                                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                                    Text("还没有热词").foregroundStyle(.secondary).font(.callout)
                                    Button("填入一组示例") { loadSamples() }
                                        .buttonStyle(.link)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 26)
                            } else {
                                WordChips(words: words, onDelete: removeWord)
                            }
                        }
                    }
                    .padding(6)
                }

                // ── 预设词库 ──
                PresetWordlistSection(state: state)

                // ── 替换词表 ──
                ReplaceRuleSection(state: state)

                // ── 状态与警告 ──
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(words.count) 个热词")
                            .font(.caption).foregroundStyle(.secondary)
                        if justSaved {
                            Label("已生效", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                        Spacer()
                        if !words.isEmpty {
                            Button("清空") {
                                state.config.hotwords = []
                                persist()
                            }
                            .buttonStyle(.link)
                        }
                    }

                    if words.count > 60 {
                        WarnBanner(text: "超过 60 个词可能超出双向流式约 100 tokens 的上限，靠后的词可能不生效。建议只保留最容易识错的。",
                                   tint: .orange)
                    }

                    if state.config.enableNonstream {
                        WarnBanner(text: "「设置」里的二遍识别 enable_nonstream 是开着的 —— 实测这会让热词全部失效（「流式」→「流是」、「Claude」→「Cloth」）。依赖热词就把它关掉。",
                                   tint: .red)
                    }
                }
            }
            .padding(20)
        }
        // 关键：给整页一个背景色。之前是裸 VStack + TextEditor，
        // TextEditor 自带白底又铺满，整页看起来就是一张白纸。
        .background(Color(nsColor: .windowBackgroundColor))
        // 在批量编辑状态下直接切页会把整段编辑丢掉，离开时补一次保存
        .onDisappear { if bulkMode { applyBulk() } }
    }

    // MARK: -

    private func addWord() {
        let w = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        guard !state.config.hotwords.contains(w) else { newWord = ""; return }
        state.config.hotwords.append(w)
        newWord = ""
        inputFocused = true
        persist()
    }

    private func removeWord(_ w: String) {
        state.config.hotwords.removeAll { $0 == w }
        persist()
    }

    private func applyBulk() {
        state.config.hotwords = bulkText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { acc, w in if !acc.contains(w) { acc.append(w) } }
        persist()
    }

    private func loadSamples() {
        state.config.hotwords = ["Claude Code", "豆包", "火山引擎", "WebSocket",
                                 "流式语音识别", "上屏", "热词", "Swift", "Xcode"]
        persist()
    }

    private func persist() {
        // 同上：只提交词库，不连带提交设置页的草稿
        let words = state.config.hotwords
        state.commitField { $0.hotwords = words }
        state.onReloadConfig?()
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { justSaved = false }
    }
}

// MARK: - 预设词库

/// 官方维护的预设词库（数据在仓库 wordlists/，App 每天自动从 GitHub 同步）。
/// 用户自己的热词永远优先于预设词 —— 直传 context 只有约 100 tokens。
private struct PresetWordlistSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var store = WordlistStore.shared

    var body: some View {
        GroupBox("预设词库") {
            VStack(alignment: .leading, spacing: 10) {
                if store.lists.isEmpty {
                    Text("没有可用的预设词库（安装包不完整？）")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(store.lists) { list in
                    HStack(alignment: .top, spacing: 10) {
                        Toggle("", isOn: binding(for: list.id))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(list.name)
                                    .font(.system(size: 13, weight: .medium))
                                Text("\(list.hotwords.count) 词 · \(list.replaceRules.count) 条替换 · v\(list.version)")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            Text(list.description)
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
                Text("词库由官方仓库维护，每天自动同步 —— 仓库里加了新词，全体用户次日就能用上，不用等发版。热词直传有约 60 词的窗口：你自己的热词永远最优先，其后按上面的顺序取,开太多库时靠后的会被截断；替换规则不受此限制。")
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

/// 确定性纠正：热词只能提高概率，替换是板上钉钉。
/// 「Cloth Code→Claude Code」这类顽固错误、以及主界面「记住改法」学来的规则都在这里。
private struct ReplaceRuleSection: View {
    @ObservedObject var state: AppState
    @State private var newFrom = ""
    @State private var newTo = ""

    var body: some View {
        GroupBox("替换词表（改词记忆）") {
            VStack(alignment: .leading, spacing: 10) {
                Text("识别结果里出现左边的词，一律替换成右边的。热词纠不动的顽固错误靠它 —— 识别完在主界面改一次错字，也会自动提示「记住改法」加进这里。")
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

// MARK: - 热词标签流式布局

private struct WordChips: View {
    let words: [String]
    let onDelete: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(words, id: \.self) { w in
                HStack(spacing: 5) {
                    Text(w).font(.system(size: 12))
                    Button {
                        onDelete(w)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.12),
                            in: Capsule())
                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.25)))
            }
        }
    }
}

/// SwiftUI 没有内置流式布局，自己实现一个最小版
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - 设置页

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var saved = false

    // 在线拉取到的模型列表（见 ModelCatalog）
    @State private var catalog: [ModelCatalog.Entry] = []
    @State private var catalogLoading = false
    @State private var catalogError = ""
    /// 换服务商时清掉了上一家的 Key，要明确告诉用户，否则会以为配置丢了
    @State private var keyCleared = false
    /// 在飞的拉取请求。换服务商时要能取消，否则旧响应会覆盖新配置。
    @State private var catalogTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                GroupBox("凭证") {
                    VStack(alignment: .leading, spacing: 9) {
                        LabeledRow("API Key") {
                            SecureField("火山引擎控制台的 x-api-key", text: $state.config.apiKey)
                                .textFieldStyle(.roundedBorder)
                        }
                        LabeledRow("Resource ID") {
                            TextField("volc.seedasr.sauc.duration",
                                      text: $state.config.resourceId)
                                .textFieldStyle(.roundedBorder)
                        }

                        DisclosureGroup("用的是旧版控制台？") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("新版控制台只需上面那个 API Key。如果你的账号还是旧版（控制台给的是 App ID + Access Token 两个值），填下面这两项，上面的 API Key 留空。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                LabeledRow("App ID") {
                                    TextField("控制台的 APP ID", text: $state.config.appKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                                LabeledRow("Access Token") {
                                    SecureField("控制台的 Access Token",
                                                text: $state.config.accessKey)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.caption)
                        HStack(spacing: 10) {
                            Button("获取 API Key") {
                                NSWorkspace.shared.open(URL(string: "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default")!)
                            }
                            .buttonStyle(.link)
                            Text("需先开通「豆包流式语音识别模型 2.0」")
                                .font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        Text("豆包流式语音识别 2.0 = volc.seedasr.sauc.duration（1 元/小时）。1.0 是 volc.bigasr.sauc.duration，贵 4.5 倍，没有理由用。⚠️ 这个 Key 与「大模型润色」用的方舟 Key 不是同一套，两边账号体系独立。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

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
                            Text("\(state.config.preRollMs) ms").monospacedDigit()
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("按下热键时，把此前这段时间的音频一并送出，解决「开头几个字被吃掉」。豆包官方 Mac 输入法实测就有这个毛病。")
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
                        Picker("判停档位", selection: $state.config.endWindowSize) {
                            Text("快嘴 300ms — 上屏最碎最快").tag(300)
                            Text("推荐 600ms").tag(600)
                            Text("标准 800ms — 官方默认").tag(800)
                            Text("思考 1500ms — ⚠️ 会丧失逐句上屏").tag(1500)
                        }
                        .frame(width: 380)

                        Label {
                            Text("**实测结论**：判停时长必须小于你说话时的自然停顿，否则「边说边打字」会退化成「说完才一次性上屏」。测试中设成 1500ms 后，句间停顿 900ms 的三句话全部憋到末尾才吐出来。真人换气通常 0.4–1.0 秒，**300–600ms 是安全区**。")
                            // ⚠️ 这里必须用连接号「–」而不是「~」：SwiftUI 的 Text 会把字符串
                            //    当 Markdown 解析，一句话里出现两个 ~ 就成了删除线标记，
                            //    实测把「1.0 秒，**300」整段划掉了。
                        } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                        Toggle("松手才上屏（不逐句上屏）", isOn: $state.config.commitOnlyAtEnd)

                        Divider()

                        Toggle("连续听写：长句中途也逐段上屏", isOn: $state.config.progressiveCommit)
                            .disabled(state.config.commitOnlyAtEnd)
                        Label {
                            Text("服务端只在你**停顿**时才定稿一句。一口气说长句不换气时，文字会全部憋到说完 —— 开启后，已经稳定、以标点收尾的部分会提前写进光标处。**开了 AI 润色时此功能自动让位**（润色需要拿全文重写）。\n配合**双击 \(HotkeyManager.describe(state.config)) 锁定**使用：双击开始连续听写，不用一直按着，再按一下结束。长文口述、会议记录都是这么用。")
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

                GroupBox("识别选项") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("自动标点", isOn: $state.config.enablePunc)
                        Toggle("数字规范化（「二零二六年」→「2026年」）",
                               isOn: $state.config.enableItn)
                        Toggle("语义顺滑（去掉「嗯」「那个」等口水词）",
                               isOn: $state.config.enableDdc)

                        Toggle("去掉末尾句号（「今天开会。」→「今天开会」）",
                               isOn: $state.config.stripTrailingPeriod)
                            .disabled(!state.config.enablePunc)
                        Label {
                            Text("语音输入十有八九是往聊天框、搜索框、命令行里塞一句话，那个句号既多余又得手动删。**只去句号** —— 问号和感叹号带语气，去掉会改变意思；省略号「……」也会原样保留。\n逐句上屏时用的是「先扣下、下一句到了再补回去」，不是事后退格删 —— 本工具任何情况下都不会回头改已经写进你输入框的内容。")
                        } icon: { Image(systemName: "text.badge.minus") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        HStack {
                            Text("中文字形").frame(width: 92, alignment: .leading)
                            Picker("", selection: $state.config.zhVariant) {
                                Text("简体（默认）").tag("")
                                Text("繁体").tag("traditional")
                                Text("台湾正体").tag("tw")
                                Text("香港繁体").tag("hk")
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            Spacer()
                        }

                        Toggle("极速模式（首字更快，但首字准确率下降）",
                               isOn: $state.config.accelerateFirstChar)
                        Label {
                            Text("enable_accelerate_text：服务端更激进地吐首字，实测能快 100~200ms，代价是开头个别字更容易识错。追求「按下就出字」的手感再开。")
                        } icon: { Image(systemName: "hare") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Toggle("对话上下文（把最近几条识别结果带给服务端）",
                               isOn: $state.config.enableDialogContext)
                        Label {
                            Text("连着说几段话时，服务端能接住上文语境，人名、术语的识别明显更稳。只发送**最近三条识别文本** —— 它们本来就是这家服务识别出来的，不产生新的数据暴露；不发送 App 名等任何额外信息。")
                        } icon: { Image(systemName: "text.bubble") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Divider()
                        Toggle("二遍识别 enable_nonstream", isOn: $state.config.enableNonstream)
                        Label {
                            Text("⚠️ **实测 3/3 复现：开启后热词会失效**（「流式」→「流是」、「Claude」→「Cloth」、「上屏」→「尚平」）。它在句子完整性和尾字上确实更好，但如果你依赖热词，请保持关闭。这与官方「又快又准」的说法不符，以实测为准。")
                        } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

                GroupBox("大模型润色") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("识别完成后用大模型润色", isOn: $state.config.enablePolish)

                        Label {
                            Text("**这是一个开关，两种工作方式二选一：**\n· **关闭润色** → 逐句直接写进输入框，真正的边说边写\n· **开启润色** → 说话时文字只显示在底部悬浮窗，松手后交给大模型润色，润完再一次性粘贴到输入框\n\n为什么不能兼得：润色必须拿到完整文本才能做，而边说边写意味着文字已经写进去了，之后再改就得退格删你屏幕上的内容。Wispr Flow、superwhisper 这些带 AI 润色的产品全都是「松手后整段插入」，原因就在这里。")
                        } icon: { Image(systemName: "info.circle") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        Toggle("改口自动纠正（说错了直接重说，只保留最终意思）",
                               isOn: $state.config.enableCourseCorrection)
                        Label {
                            Text("「明天上午九点，**啊不对，下午三点**」→ 上屏只有「明天下午三点」。自动处理当场改口、口吃重复、犹豫填充词、说到一半放弃的半句；引用别人说的「不对」不会被误改，拿不准的一律保留原样。可以和润色同时开（一次调用完成），也可以只开这一个 —— 只改口，不动你的措辞风格。")
                        } icon: { Image(systemName: "arrow.uturn.backward.circle") }
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                        // 刚打开却还没配模型 —— 当场把最短的路摆出来（推荐 DeepSeek V4 Flash）
                        if state.config.enableCourseCorrection, !state.config.llmCredentialsReady {
                            CourseCorrectionSetupCard {
                                applyProvider(LLMProvider.find("deepseek"))
                                state.config.polishModel = "deepseek-v4-flash"
                            }
                        }

                        if state.config.enablePolish || state.config.enableCourseCorrection {
                            Text("代价：上屏比直接识别晚约 0.5~2 秒（取决于模型速度）。超时或调用失败会自动退回原文上屏，不会丢内容。")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            let prov = LLMProvider.find(state.config.polishProvider)

                            RelayBanner(isCurrent: prov.id == LLMProvider.relayID,
                                        onUse: switchToRelay)

                            HStack {
                                Text("服务商").frame(width: 74, alignment: .leading)
                                Picker("", selection: $state.config.polishProvider) {
                                    ForEach(LLMProvider.all) { p in
                                        Text(p.name).tag(p.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(width: 220)
                                .onChange(of: state.config.polishProvider) { _, new in
                                    // 地址、协议、端点、模型一次性对齐，并清空上一家的 Key
                                    applyProvider(LLMProvider.find(new))
                                }
                                if let u = prov.keyURL {
                                    Button("获取 Key") {
                                        NSWorkspace.shared.open(URL(string: u)!)
                                    }
                                    .buttonStyle(.link)
                                }
                                Spacer()
                            }

                            HStack {
                                Text("协议格式").frame(width: 74, alignment: .leading)
                                Picker("", selection: $state.config.polishAPIFormat) {
                                    ForEach(APIFormat.allCases) { f in
                                        Text(f.label).tag(f.rawValue)
                                    }
                                }
                                .labelsHidden().frame(width: 300)
                                .onChange(of: state.config.polishAPIFormat) { _, new in
                                    // 换协议就把端点路径换成该协议的默认值
                                    if let f = APIFormat(rawValue: new) {
                                        state.config.polishPath = f.defaultPath
                                    }
                                }
                                Spacer()
                            }
                            Text(state.config.apiFormat.hint)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            LabeledRow("服务地址") {
                                TextField("", text: $state.config.polishBaseURL)
                                    .textFieldStyle(.roundedBorder)
                            }
                            HStack {
                                Text("端点路径").frame(width: 74, alignment: .leading)
                                TextField("/chat/completions", text: $state.config.polishPath)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 200)
                                Text("绝大多数服务是 /chat/completions")
                                    .font(.caption).foregroundStyle(.tertiary)
                                Spacer()
                            }
                            LabeledRow("API Key") {
                                SecureField(prov.id == "ollama"
                                            ? "本地不校验，随便填个非空串如 ollama"
                                            : "该服务商的 API Key",
                                            text: $state.config.polishApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    // ⚠️ 只在**新值非空**时复位。applyProvider 自己会把
                                    //   polishApiKey 置空，那次赋值同样会触发这个 onChange ——
                                    //   无条件复位的话，keyCleared 在同一个 runloop turn 里
                                    //   被立刻打回 false，那条橙色提示一帧都留不住，
                                    //   用户只会看到 Key 凭空消失、测试连接和拉取模型双双置灰。
                                    .onChange(of: state.config.polishApiKey) { _, new in
                                        if !new.isEmpty { keyCleared = false }
                                    }
                            }
                            if keyCleared {
                                Label {
                                    Text("已清空上一家的 Key —— Key 是和服务商绑定的，换了服务商必须重填。（不清空的话，下次润色会把上一家的 Key 发到这个新地址去。）")
                                } icon: { Image(systemName: "key.slash") }
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 78)
                            }
                            HStack {
                                Text("模型").frame(width: 74, alignment: .leading)
                                TextField("模型 id", text: $state.config.polishModel)
                                    .textFieldStyle(.roundedBorder)

                                // 在线拉取到的列表优先 —— 它一定是最新的，
                                // 而写死的预设表迟早会过期（见 LLMProvider 注释）
                                if !catalog.isEmpty {
                                    Menu("可用 \(catalog.count)") {
                                        ForEach(catalog) { m in
                                            Button(m.note.isEmpty ? m.id : "\(m.id) — \(m.note)") {
                                                state.config.polishModel = m.id
                                            }
                                        }
                                    }
                                    .fixedSize()
                                } else if !prov.models.isEmpty {
                                    Menu("建议") {
                                        ForEach(prov.models, id: \.id) { m in
                                            Button("\(m.id) — \(m.note)") {
                                                state.config.polishModel = m.id
                                            }
                                        }
                                    }
                                    .fixedSize()
                                }

                                if prov.supportsModelList {
                                    Button(catalogLoading ? "拉取中…" : "拉取模型") { fetchModels() }
                                        .disabled(catalogLoading
                                                  || state.config.polishBaseURL.isEmpty
                                                  || (state.config.polishApiKey.isEmpty
                                                      && state.config.apiFormat != .ollamaNative))
                                        .fixedSize()
                                }
                            }

                            if catalogLoading || !catalogError.isEmpty || !catalog.isEmpty {
                                HStack(spacing: 6) {
                                    if catalogLoading { ProgressView().controlSize(.small) }
                                    Text(catalogLoading
                                         ? "正在向服务端要模型列表…"
                                         : (catalogError.isEmpty
                                            ? "已拉到 \(catalog.count) 个可用模型（已过滤掉向量/语音/画图这类不能用来润色的）。"
                                            : catalogError))
                                        .font(.caption)
                                        .foregroundStyle(catalogError.isEmpty ? .secondary : Color.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                }
                                .padding(.leading, 78)
                            }

                            if prov.id == "custom" {
                                HStack {
                                    Text("关闭思考").frame(width: 74, alignment: .leading)
                                    Picker("", selection: $state.config.polishThinkingOff) {
                                        ForEach([LLMProvider.ThinkingOff.none,
                                                 .thinkingDisabled,
                                                 .enableThinkingFalse,
                                                 .reasoningEffortNone], id: \.rawValue) { t in
                                            Text(t.label).tag(t.rawValue)
                                        }
                                    }
                                    .labelsHidden().frame(width: 260)
                                    Spacer()
                                }
                            }

                            Text(prov.hint)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            Toggle("把当前 App 名一并发给模型（按场景调整语气）",
                                   isOn: $state.config.sendAppContext)
                            Label {
                                Text("**默认关闭。** 打开后，润色请求里会多一句「当前用户正在「微信」中输入」，让模型知道该用什么语气 —— 在终端里和在聊天框里，同一句话该润成不同样子。\n⚠️ 代价是每说一句就等于告诉服务商**你此刻在用哪个 App**（1Password、Signal、公司内部工具都会被记上一笔）。这是识别文本之外的额外数据，所以做成默认关、由你自己决定。")
                            } icon: { Image(systemName: "hand.raised") }
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            Label {
                                Text("⚠️ **当代模型几乎全都默认开启「深度思考」，而每家关闭的写法都不一样。** 润色一两句话本来该 1 秒内返回，开着思考会先吐一大段思维链——延迟涨到几秒，思维链还按输出 token 计费。上面的预设已经帮你按服务商传了正确的关闭参数；如果「测试连接」提示带思维链，说明没生效。")
                            } icon: { Image(systemName: "bolt.slash") }
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)

                            Toggle("开启深度思考", isOn: Binding(
                                get: { !state.config.polishDisableThinking },
                                set: { state.config.polishDisableThinking = !$0 }))
                            Label {
                                Text("**默认关闭，建议保持关闭。** 当代模型大多默认开启思考，而润色一两句话根本不需要推理——开着会让延迟从 1 秒涨到几秒，思维链还按输出 token 计费，某些服务甚至会因此让正文返回空串。只有在润色质量确实不满意时才打开试试。")
                            } icon: { Image(systemName: "brain") }
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            Toggle("流式输出", isOn: $state.config.polishStream)
                            Label {
                                Text("**不会让总耗时变快** —— 模型要生成的 token 数一样，流式只是把「等全部生成完」改成「生成一个吐一个」，端到端时间基本相同。收益在感知：悬浮条里能看到文字被逐字修正，而不是盯着「润色中…」发呆。而且上屏时刻完全没变 —— 润色结果必须等全文完成才能粘贴，粘半截比不润色更糟。短句几乎无差别，长段口述差别明显。")
                            } icon: { Image(systemName: "info.circle") }
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            // ── 测试连接 ──
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
                                            Text("测试连接")
                                        }
                                    }
                                    // Ollama 本地服务不校验鉴权（Config.polishReady 也对它豁免），
                                    // 漏掉这条豁免会让这类用户永远点不了「测试连接」，
                                    // 没有任何办法在真正说话之前验证润色是否可用。
                                    // 判据与上面「拉取模型」保持一致。
                                    .disabled(state.polishTestRunning
                                              || (state.config.polishApiKey.isEmpty
                                                  && state.config.apiFormat != .ollamaNative)
                                              || state.config.polishModel.isEmpty)

                                    if let ms = state.polishTestMs {
                                        Text("\(ms) ms").font(.caption)
                                            .foregroundStyle(ms < 2000 ? .green : .orange)
                                            .monospacedDigit()
                                    }
                                    if state.polishTestLeaked {
                                        Label("返回带思维链，关闭思考未生效",
                                              systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption).foregroundStyle(.orange)
                                    }
                                    Spacer()
                                }

                                if let e = state.polishTestError {
                                    Text(e).font(.caption).foregroundStyle(.red)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else if let o = state.polishTestOutput {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("原文　嗯那个我们今天下午三点开个会讨论一下豆包流是语音识别的接入方案就是说那个接口的部分")
                                            .font(.caption).foregroundStyle(.tertiary)
                                        Text("润色后　\(o)")
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
                        // ⚠️ 这段必须分层说。原来只有一句「不经过任何第三方服务器」，
                        //    但「大模型润色」一旦配到中转站，润色文本就确实经过第三方了 ——
                        //    而且那个第三方是本项目作者运营的。代码是开源的，含糊其辞一定会被扒出来，
                        //    主动写清楚 + 给出本地替代方案，比事后解释划算得多。
                        Text("**语音识别**：音频只发往你自己配置的火山引擎账号，不经过任何第三方服务器。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("**大模型润色**：只有开启润色时才会发生，且只发送识别出的文本（不发音频），发往你在上面选的那家服务商。⚠️ 它是**默认服务商**：如果你没有换过，文本会经过 bobdong.cn 中转到目标模型 —— 该中转站由本项目作者运营，是本项目的收入来源。介意的话，换成任意其它服务商，或者选 Ollama 做完全本地的润色。\n另外：只有当你手动打开「把当前 App 名一并发给模型」时，请求里才会额外带上你所在 App 的名字；默认是关的。")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("全部保存在本机这个目录下，已按类别分开存放 —— 顶层 `config.json` 才是配置，其余各归子目录，重置配置不会误伤历史/证书：")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("""
                        \(Config.configDir.path)/
                          ├─ config.json   配置（API Key、热词、各项设置）
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

                HStack {
                    Button("保存并应用") {
                        state.saveConfig()
                        state.onReloadConfig?()
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { saved = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s")

                    if saved {
                        Label("已保存并生效", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    }
                    Spacer()
                    VivaMark(size: 18)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Viva \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                            .font(.caption).foregroundStyle(.tertiary)
                        Text("Just say Viva")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // 从主页「修改快捷键」进来：滚到热键那一节。
        // onAppear 兜底（跳转时本页往往刚挂载，onChange 赶不上）。
        .onAppear { consumePendingAnchor(proxy) }
        .onChange(of: state.pendingSettingsAnchor) { _, _ in consumePendingAnchor(proxy) }
        }
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
                Text("给特定 App 单独定行为：在这些 App 里说话时，下面勾选的项覆盖全局设置，其余照旧。典型用法：终端/IDE 关润色、用逐字键入（不污染剪贴板）；微信/飞书开润色。")
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
                tri("AI 润色", \.enablePolish)
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

// MARK: - 中转站 / 模型列表

    /// 换服务商时统一走这里。两个入口（服务商下拉、「用中转站配置」按钮）都必须调它。
    ///
    /// ⚠️⚠️ **必须清空 polishApiKey。**
    ///   地址换了、Key 没换，下一次润色就会把上一家的 API Key 原样发到新服务商的
    ///   域名去（`Authorization: Bearer <别人家的key>`）—— 这是实打实的凭证外泄，
    ///   而且用户完全无从察觉。中转站是本项目作者运营的，一键切过去还把用户的
    ///   DeepSeek/OpenAI Key 一起送过来，性质更严重。
    ///
    /// 顺带把协议和端点也一起重置：预设表里每一家都兼容 OpenAI Chat，
    /// 不重置的话「Anthropic 的 /messages + DeepSeek 的地址」这种组合直接 404。
    private func applyProvider(_ p: LLMProvider) {
        state.config.polishProvider = p.id
        if p.id != "custom" {
            state.config.polishBaseURL = p.baseURL
            state.config.polishAPIFormat = APIFormat.openAIChat.rawValue
            state.config.polishPath = APIFormat.openAIChat.defaultPath
            state.config.polishModel = p.models.first?.id ?? ""
        }
        if !state.config.polishApiKey.isEmpty {
            state.config.polishApiKey = ""
            keyCleared = true
        }
        // 上一家拉到的模型对这一家没有意义，留着会误导；在飞的请求也要掐掉
        catalogTask?.cancel(); catalogTask = nil
        catalog = []; catalogError = ""; catalogLoading = false
    }

    /// 一键切到中转站。地址、协议、端点一次性配好，只留 Key 要用户填 ——
    /// 少一步就多一分转化，而这几个字段填错任何一个都是直接 404。
    private func switchToRelay() {
        applyProvider(LLMProvider.find(LLMProvider.relayID))
    }

    private func fetchModels() {
        catalogTask?.cancel()
        catalogLoading = true
        catalogError = ""
        let base = state.config.polishBaseURL
        let key = state.config.polishApiKey
        let fmt = state.config.apiFormat
        // ⚠️ 连服务商一起快照，回写前必须比对。
        //   请求最长 15 秒，用户等不及切到别家是很自然的事；旧响应回来时
        //   若不校验归属，会把上一家的模型列表塞进新服务商的界面，
        //   autoPick 还会因为「新家的默认模型不在旧家列表里」而把 polishModel
        //   静默改成旧家的第一个模型 —— 配置变成「B 家地址 + A 家模型」，
        //   保存后每次润色都 404，而界面上没有任何异常提示。
        let snapProvider = state.config.polishProvider
        catalogTask = Task { @MainActor in
            defer { catalogLoading = false }
            do {
                let list = try await ModelCatalog.fetch(baseURL: base, apiKey: key, format: fmt)
                guard !Task.isCancelled,
                      state.config.polishProvider == snapProvider,
                      state.config.polishBaseURL == base else { return }
                catalog = list
                state.config.polishModel = ModelCatalog.autoPick(list,
                                                                 current: state.config.polishModel)
            } catch {
                guard !Task.isCancelled,
                      state.config.polishProvider == snapProvider,
                      state.config.polishBaseURL == base else { return }
                catalog = []
                catalogError = error.localizedDescription
            }
        }
    }
}

// MARK: - 中转站转化位

/// 「大模型润色」里的一张软广。
///
/// 放这里是有理由的：用户勾上润色开关的那一刻，正好撞上整个软件里最劝退的一段路 ——
/// 要去某家云厂商注册、实名、充值、开通模型、建 Key、再抄一个大小写敏感的模型名回来。
/// 转化位就该出现在痛点发生的地方，而不是首页横幅。
///
/// 分寸：只在**没在用中转站**时显示；不挡住任何原有选项；不做任何夸张承诺。
/// 「改口纠正」刚打开但大模型还没配 —— 用户意图最强的一瞬间，
/// 把最短的路当场摆出来：一键按 DeepSeek V4 Flash 配好一切，只留 Key 要填。
private struct CourseCorrectionSetupCard: View {
    /// 一键应用 DeepSeek 预设（服务商/地址/协议/模型 = deepseek-v4-flash）
    let onApplyDeepSeek: () -> Void
    @State private var applied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("还差一步：改口纠正要调一个大模型")
                    .font(.system(size: 13, weight: .semibold))
                Text("推荐 **DeepSeek V4 Flash** —— 快、便宜（一句话不到一厘钱），改口这种活它绰绰有余。点下面一键配好服务商、地址和模型，然后去 DeepSeek 拿个 API Key 填进下方「API Key」栏即可。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button(applied ? "已按 DeepSeek 配置 ✓" : "一键按 DeepSeek V4 Flash 配置") {
                        onApplyDeepSeek()
                        applied = true
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(applied)

                    Button("去拿 DeepSeek Key") {
                        if let u = URL(string: "https://platform.deepseek.com/api_keys") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                    .buttonStyle(.link).controlSize(.small)
                    Spacer()
                }
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.orange.opacity(0.30)))
    }
}

/// 中转站品牌 banner。常驻在润色配置区顶部（选没选中转站都显示）——
/// 这是 08 号营销方案里的「产品内转化位」，但要守住三条红线：
/// 不弹窗、不挡功能、身份透明（数据与隐私一节已声明它是作者运营的收费服务）。
private struct RelayBanner: View {
    /// 当前服务商是否已是中转站（是 → 只留「前往」，不再劝切换）
    let isCurrent: Bool
    let onUse: () -> Void
    @State private var hovering = false

    private var site: String {
        LLMProvider.relaySite.replacingOccurrences(of: "https://", with: "")
            .components(separatedBy: "/").first ?? "bobdong.cn"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Viva 中转站")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                    Text(site)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                    ForEach(["稳定", "高并发", "企业级"], id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.18)))
                    }
                }
                Text("国内外主流模型共用一个 Key · 按量计费 · 生产级稳定性与并发，个人和企业都能直接接")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if !isCurrent {
                Button(action: onUse) {
                    Text("一键使用")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.purple)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(.white))
                }
                .buttonStyle(.plain)
            }
            Button {
                if let u = URL(string: LLMProvider.relaySite) {
                    NSWorkspace.shared.open(u)
                }
            } label: {
                HStack(spacing: 3) {
                    Text(isCurrent ? "前往 \(site)" : "前往")
                        .font(.system(size: 11.5, weight: .semibold))
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().strokeBorder(.white.opacity(0.55), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.42, green: 0.30, blue: 0.95),
                             Color(red: 0.72, green: 0.29, blue: 0.86)],
                    startPoint: .leading, endPoint: .trailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(hovering ? 0.35 : 0.15))
        )
        .shadow(color: Color.purple.opacity(hovering ? 0.35 : 0.2),
                radius: hovering ? 10 : 6, y: 3)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: hovering)
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
