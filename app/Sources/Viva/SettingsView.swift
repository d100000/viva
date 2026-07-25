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
        state.config.hotkeyKeyCode = code
        state.config.hotkeyIsModifierOnly = modOnly
        state.config.hotkeyModifiers = mods
        state.saveConfig()
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
        state.saveConfig()
        state.onReloadConfig?()
        justSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { justSaved = false }
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

    var body: some View {
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
                        Text("豆包流式语音识别 2.0 = volc.seedasr.sauc.duration（1 元/小时）。1.0 是 volc.bigasr.sauc.duration，贵 4.5 倍，没有理由用。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

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
                    }
                    .padding(6)
                }

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
                            Text("**实测结论**：判停时长必须小于你说话时的自然停顿，否则「边说边打字」会退化成「说完才一次性上屏」。测试中设成 1500ms 后，句间停顿 900ms 的三句话全部憋到末尾才吐出来。真人换气通常 0.4~1.0 秒，**300~600ms 是安全区**。")
                        } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                        Toggle("松手才上屏（不逐句上屏）", isOn: $state.config.commitOnlyAtEnd)
                    }
                    .padding(6)
                }

                GroupBox("识别选项") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("自动标点", isOn: $state.config.enablePunc)
                        Toggle("数字规范化（「二零二六年」→「2026年」）",
                               isOn: $state.config.enableItn)
                        Toggle("语义顺滑（去掉「嗯」「那个」等口水词）",
                               isOn: $state.config.enableDdc)
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

                        if state.config.enablePolish {
                            Text("代价：上屏比不润色时晚约 0.5~2 秒（取决于模型速度）。超时或调用失败会自动退回原文上屏，不会丢内容。")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)

                            Divider()

                            let prov = LLMProvider.find(state.config.polishProvider)

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
                                    // 换服务商时自动填地址和推荐模型，省得用户去查文档
                                    let p = LLMProvider.find(new)
                                    if p.id != "custom" {
                                        state.config.polishBaseURL = p.baseURL
                                        state.config.polishModel = p.models.first?.id ?? ""
                                    }
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
                            }
                            HStack {
                                Text("模型").frame(width: 74, alignment: .leading)
                                TextField("模型 id", text: $state.config.polishModel)
                                    .textFieldStyle(.roundedBorder)
                                if !prov.models.isEmpty {
                                    Menu("建议") {
                                        ForEach(prov.models, id: \.id) { m in
                                            Button("\(m.id) — \(m.note)") {
                                                state.config.polishModel = m.id
                                            }
                                        }
                                    }
                                    .fixedSize()
                                }
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
                                    .disabled(state.polishTestRunning
                                              || state.config.polishApiKey.isEmpty
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

                GroupBox("数据与隐私") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("音频只发往你自己配置的火山引擎账号，不经过任何第三方服务器。识别记录、配置、热词全部保存在本机：")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(Config.configDir.path)
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
                        Text("Viva 0.2.0").font(.caption).foregroundStyle(.tertiary)
                        Text("Just say Viva")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
