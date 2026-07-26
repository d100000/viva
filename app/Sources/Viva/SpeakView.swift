import SwiftUI
import AppKit

// MARK: - 极简主页：只有「说话」这一件事

/// 配置完成后的核心页面。
///
/// 设计原则：**一屏只做一件事**。中央一个录音球，按住说话时向外扩散涟漪、
/// 球体内部有波形律动，底部实时显示识别文本。其余一切（统计、历史、设置）
/// 都退到收起的侧边栏里。
struct SpeakView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: HistoryStore
    @State private var pressing = false
    @State private var hovering = false
    /// 用户二次编辑后的文本。识别结束时用识别结果填充，之后归用户所有。
    @State private var edited = ""

    private var listening: Bool { state.isListening }
    private var polishing: Bool { state.isPolishing }

    var body: some View {
        ZStack {
            // 背景：极浅的径向光晕，录音时随音量微微增强
            RadialGradient(
                colors: [Color.accentColor.opacity(listening ? 0.10 + Double(state.level) * 0.08 : 0.045),
                         Color.clear],
                center: .center, startRadius: 40, endRadius: 460)
                .animation(.easeOut(duration: 0.35), value: listening)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Spacer(minLength: 12)

                // ── 中央录音球 ──
                VoiceOrb(level: state.level,
                         listening: listening,
                         polishing: polishing,
                         pressing: pressing,
                         hovering: hovering)
                    .frame(width: 208, height: 208)
                    .contentShape(Circle())
                    .onHover { hovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in
                                guard !pressing, state.canSpeak else { return }
                                pressing = true
                                edited = ""          // 新一轮，清掉上次的编辑内容
                                state.onTestStart?()
                            }
                            .onEnded { _ in
                                guard pressing else { return }
                                pressing = false
                                state.onTestStop?()
                            })
                    .opacity(state.canSpeak ? 1 : 0.4)

                // ── 提示语 ──
                Text(hint)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
                    .animation(.easeInOut(duration: 0.2), value: hint)

                Spacer(minLength: 14)

                // ── 底部实时文本 ──
                TranscriptPane(committed: state.committed,
                               partial: state.partial,
                               listening: listening,
                               polishing: polishing,
                               note: state.polishNote,
                               error: state.lastError,
                               edited: $edited,
                               editable: !listening && !polishing,
                               onClear: {
                                   // 三处都要清：编辑框、识别结果、润色提示，
                                   // 漏掉任何一个都会让文字「清了又回来」
                                   edited = ""
                                   state.committed = ""
                                   state.partial = ""
                                   state.polishNote = ""
                                   state.lastError = ""
                               },
                               onCopy: { text in
                                   TextInjector.copyToClipboard(text, transient: false)
                                   Log.info("已复制 \(text.count) 字到剪贴板")
                               })
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 32)

                // ── 修改快捷键入口 ──
                //   主页只做「说话」一件事，但「用哪个键说话」是用户最常想改的设置。
                //   放一个显示当前热键、点一下就跳到设置对应处的小胶囊，省去翻设置页。
                HotkeyChip(state: state) {
                    state.pendingSettingsAnchor = "hotkey"
                    NotificationCenter.default.post(name: .vivaOpenSettings, object: nil)
                }
                .padding(.top, 16)

                // ── 极轻的状态栏 ──
                FooterStats(store: store, state: state)
                    .padding(.top, 12)
                    .padding(.bottom, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // 识别（含润色）结束后把最终结果交给可编辑文本，之后归用户所有
        .onChange(of: state.isListening) { _, on in
            if !on, !state.isPolishing, !state.committed.isEmpty { edited = state.committed }
        }
        .onChange(of: state.isPolishing) { _, p in
            if !p, !state.committed.isEmpty { edited = state.committed }
        }
    }

    private var hint: String {
        if !state.canSpeak { return "还差一步 —— 在「设置」里填入 API Key" }
        if polishing { return "正在润色…" }
        if listening { return "松开结束" }
        return "按住说话，或按住 \(HotkeyManager.describe(state.config))"
    }
}

// MARK: - 录音球

/// 中央的录音球。三层结构：
/// 1. 外层扩散涟漪（只在录音时）
/// 2. 中层球体（材质 + 渐变描边，随音量呼吸）
/// 3. 内层波形（录音时）或图标（空闲时）
struct VoiceOrb: View {
    let level: Float
    let listening: Bool
    let polishing: Bool
    let pressing: Bool
    let hovering: Bool

    /// 平滑后的音量。原始 RMS 抖得厉害，直接映射到半径会「颤」，
    /// 用一阶低通滤掉高频抖动。系数越小越稳、越迟钝。
    @State private var smooth: Double = 0
    @State private var breathe = false

    private var accent: Color { Color.accentColor }

    var body: some View {
        ZStack {
            // ① 扩散涟漪（Shazam / AirDrop 式）
            //
            // ⚠️ 关键：用 TimelineView 驱动**统一相位**，而不是给每圈加 delay 再
            //    repeatForever。后者的各圈启动时刻不同，跑一会儿就会漂移、间距变乱。
            //    参数取自苹果同类效果的实测值：周期 1.2s、3 环、scale 1.0→2.4、
            //    opacity 0.35→0、lineWidth 2→0.5，缓动 easeOutCubic。
            //    线宽用 strokeBorder（向内画），否则放大时线也跟着变粗。
            if listening {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<3, id: \.self) { i in
                            let p = ((t / 1.2) + Double(i) / 3.0)
                                .truncatingRemainder(dividingBy: 1)
                            let eased = 1 - pow(1 - p, 3)          // easeOutCubic
                            // ⚠️ 调研给的 scale 1.0→2.4 是按 160pt 小按钮定的。
                            //    我们的球 208pt，2.4 倍就是 500pt，直接冲出可视区、
                            //    最外圈和球完全脱节。按实际尺寸压到 1.45。
                            Circle()
                                .strokeBorder(accent.opacity(0.30 * (1 - eased)),
                                              lineWidth: 1.8 - 1.3 * eased)
                                .scaleEffect(1.0 + 0.45 * eased)
                        }
                    }
                }
            }

            // ①.5 旋转光环。角向渐变 + 慢速旋转，是 Siri 那种「有生命」的来源。
            //     只在录音时存在，空闲时完全不渲染 —— 常驻工具不能白烧 GPU。
            if listening {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [accent.opacity(0.0), accent.opacity(0.85),
                                         Color.purple.opacity(0.6), accent.opacity(0.0)],
                                center: .center,
                                angle: .degrees(t * 42)),
                            lineWidth: 3)
                        .blur(radius: 2.5)
                        .scaleEffect(1.06 + smooth * 0.05)
                }
            }

            // ② 音量光晕
            Circle()
                .fill(accent.opacity(listening ? 0.10 + smooth * 0.16 : 0))
                .blur(radius: 26)
                .scaleEffect(0.78 + smooth * 0.30)

            // ③ 球体
            //    浅色模式下别用 .ultraThinMaterial —— 它在白底上会糊成一团灰，
            //    没有精神。用「近白渐变 + 彩色描边 + 柔和投影」才有实体感。
            Circle()
                .fill(
                    LinearGradient(
                        colors: listening
                            ? [accent.opacity(0.14), accent.opacity(0.04)]
                            : [Color(nsColor: .controlBackgroundColor),
                               Color(nsColor: .controlBackgroundColor).opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    // 顶部一道高光，制造球面感
                    Circle().fill(
                        LinearGradient(colors: [.white.opacity(listening ? 0.42 : 0.55), .clear],
                                       startPoint: .top, endPoint: .center))
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: listening
                                ? [accent.opacity(0.75), accent.opacity(0.28)]
                                : [Color.primary.opacity(0.14), Color.primary.opacity(0.06)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: listening ? 2 : 1.2)
                }
                .scaleEffect(orbScale)
                .shadow(color: listening ? accent.opacity(0.30) : .black.opacity(0.13),
                        radius: listening ? 28 : 16, y: 8)

            // ④ 内容
            Group {
                if polishing {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34, weight: .light))
                        // HIG 明确要求：第三方 AI 不得复用 Apple Intelligence 的彩虹
                        // shimmer。改用单一品牌色 + 慢呼吸（2.5~3.0s）。
                        .foregroundStyle(accent)
                        .symbolEffect(.pulse, options: .repeating)
                } else if listening {
                    OrbWaveform(level: smooth, tint: accent)
                        .frame(width: 152, height: 88)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(
                            LinearGradient(colors: [accent, accent.opacity(hovering ? 0.85 : 0.7)],
                                           startPoint: .top, endPoint: .bottom))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: listening)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.72), value: pressing)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: listening)
        .onChange(of: level) { _, v in
            // 一阶低通。0.28 太平滑，语音的瞬时峰值全被削掉，波形显得没劲。
            smooth += (Double(v) - smooth) * 0.45
        }
        .onChange(of: listening) { _, on in if !on { smooth = 0 } }
        .onAppear { breathe = true }
    }

    /// 空闲时轻微呼吸，录音时随音量涨落，按下时回弹一点
    private var orbScale: Double {
        var s = 1.0
        if pressing { s -= 0.035 }
        if listening { s += smooth * 0.06 }
        if hovering && !listening { s += 0.012 }
        return s
    }

}

// MARK: - 球内波形

/// 球体内部的波形 —— 密集细条的真实音频波形。
///
/// 关键是**相邻柱子高度差要大**。平滑的正弦起伏看起来像装饰条，
/// 真实音频波形是根根不同、参差不齐的，这才有「声音」的感觉。
private struct OrbWaveform: View {
    let level: Double
    let tint: Color

    private let count = 34
    private let barW: CGFloat = 2.6
    private let gap: CGFloat = 2.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let midY = size.height / 2
                let total = CGFloat(count) * barW + CGFloat(count - 1) * gap
                var x = (size.width - total) / 2

                for i in 0..<count {
                    let h = barHeight(i, t, maxH: size.height)
                    let rect = CGRect(x: x, y: midY - h / 2, width: barW, height: h)
                    g.fill(Path(roundedRect: rect, cornerRadius: barW / 2),
                           with: .color(tint))
                    x += barW + gap
                }
            }
        }
    }

    /// 伪随机噪声。用 hash 而不是 sin 叠加 —— 叠正弦永远是平滑的，
    /// 出不来相邻柱子高低悬殊的参差感。
    private func noise(_ i: Int, _ step: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + step * 78.233) * 43758.5453
        return v - floor(v)
    }

    private func barHeight(_ i: Int, _ t: Double, maxH: CGFloat) -> CGFloat {
        // 每秒换 14 组噪声，两组之间插值 —— 太快会闪，太慢像卡住
        let f = t * 14
        let s0 = floor(f)
        let k = f - s0
        let smoothK = k * k * (3 - 2 * k)              // smoothstep
        let n = noise(i, s0) * (1 - smoothK) + noise(i, s0 + 1) * smoothK

        // 整体包络：中间高两端收，边缘不完全归零（参考图两端仍有小柱）
        let center = Double(count - 1) / 2
        let d = abs(Double(i) - center) / center
        let env = 0.22 + pow(cos(d * .pi / 2), 1.6) * 0.78

        let amp = 0.14 + min(1.0, level * 3.6) * 0.86
        // n 的幂次拉开高低差：0.55 次方让高柱更高、低柱更低
        let h = maxH * env * amp * (0.12 + pow(n, 0.55) * 0.88)
        return max(barW, min(maxH, h))
    }
}

// MARK: - 底部实时文本（可编辑 + 逐段淡入 + 毛玻璃）

/// 识别结果面板。
///
/// 三件事必须同时成立，而它们互相冲突：
/// 1. 识别中要**实时刷新**并带出现动效
/// 2. 识别完用户要能**二次编辑**
/// 3. 不能吃 CPU
///
/// 做法：识别中用 Text 层（可做动效、无编辑开销），结束后**切换成 TextEditor**。
/// 这是「可编辑 + 动效」这对矛盾的通行解法 —— 两个控件分时复用同一块区域。
struct TranscriptPane: View {
    let committed: String
    let partial: String
    let listening: Bool
    let polishing: Bool
    let note: String
    let error: String
    @Binding var edited: String
    /// 是否进入编辑态（识别结束后自动进入）
    let editable: Bool
    /// ⚠️ 清空必须由外层做。只把 edited 置空是无效的 ——
    ///    finalText 会立刻回落到 committed，看起来像按钮没反应。
    let onClear: () -> Void
    let onCopy: (String) -> Void

    @State private var copied = false
    @FocusState private var focused: Bool

    private var isEmpty: Bool { committed.isEmpty && partial.isEmpty && edited.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if editable && !edited.isEmpty {
                    // ── 编辑态 ──
                    TextEditor(text: $edited)
                        .font(.system(size: 17))
                        .lineSpacing(5)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                } else {
                    // ── 识别态：只读，可做动效 ──
                    ScrollView {
                        Group {
                            if isEmpty {
                                Text(error.isEmpty ? "说的话会实时出现在这里" : error)
                                    .foregroundStyle(error.isEmpty
                                                     ? Color.secondary.opacity(0.5) : Color.orange)
                                    .frame(maxWidth: .infinity)
                            } else {
                                StreamingText(committed: committed, partial: partial)
                            }
                        }
                        .font(.system(size: 17))
                        .lineSpacing(5)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                    }
                }
            }
            .frame(height: 116)

            // ── 工具条 ──
            Divider().opacity(0.5)
            HStack(spacing: 10) {
                PolishToggle()

                // 改词记忆：用户刚改完一处错字 —— 这是学规则的最佳时机。
                // 从 committed→edited 的 diff 里提取「一处简单替换」，点一下永久生效。
                if let sug = suggestion {
                    RememberFixChip(rule: sug)
                }

                if polishing {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                        Text("润色中").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else if !note.isEmpty {
                    Label(note, systemImage: "sparkles")
                        .font(.system(size: 11)).foregroundStyle(.purple)
                        .lineLimit(1)
                }

                Spacer()

                if !finalText.isEmpty {
                    Text("\(finalText.count) 字")
                        .font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(.tertiary)

                    GlassButton(icon: copied ? "checkmark" : "doc.on.doc",
                                title: copied ? "已复制" : "复制",
                                tint: copied ? .green : .secondary) {
                        onCopy(finalText)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                            withAnimation { copied = false }
                        }
                    }
                    GlassButton(icon: "xmark", title: "清空", tint: .secondary) {
                        onClear()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        // ⭐ 毛玻璃：Material 之上再压一层极淡的白，避免它在浅色背景里发灰
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom))
                    .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)      // 装饰层不参与命中，别挡住工具条按钮
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 18, y: 8)
        .animation(.easeInOut(duration: 0.2), value: note)
        .animation(.easeInOut(duration: 0.25), value: editable)
    }

    private var finalText: String { edited.isEmpty ? committed : edited }

    /// 编辑态下且 diff 是一处简单替换时才提示。已在规则表里的不再重复提示。
    private var suggestion: ReplaceRule? {
        guard editable, !edited.isEmpty, !committed.isEmpty else { return nil }
        guard let s = TextReplacer.suggest(original: committed, edited: edited) else { return nil }
        guard !AppState.shared.config.replaceRules.contains(where: { $0.from == s.from }) else { return nil }
        return s
    }
}

/// 「记住 X→Y」小胶囊。点一下写进替换词表，以后每一句自动纠正。
private struct RememberFixChip: View {
    let rule: ReplaceRule
    @State private var saved = false

    var body: some View {
        Button {
            let state = AppState.shared
            var rules = state.config.replaceRules.filter { $0.from != rule.from }
            rules.append(rule)
            state.config.replaceRules = rules
            state.commitField { $0.replaceRules = rules }
            state.onReloadConfig?()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { saved = true }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: saved ? "checkmark" : "lightbulb")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(saved ? "已记住" : "记住 \(rule.from)→\(rule.to)")
                    .font(.system(size: 11)).lineLimit(1)
            }
            .foregroundStyle(saved ? Color.green : Color.orange)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill((saved ? Color.green : Color.orange).opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(saved)
        .help("以后识别出「\(rule.from)」都会自动替换成「\(rule.to)」，可在词库页管理")
    }
}

/// 流式文本：**只对新增的那一段做淡入**，已经稳定的部分完全不动。
/// 整体重做动画会让全文每帧重排，既闪又费 CPU。
private struct StreamingText: View {
    let committed: String
    let partial: String
    @State private var shownCommitted = ""

    var body: some View {
        (Text(shownCommitted).foregroundStyle(.primary)
         + Text(committed.dropFirst(shownCommitted.count))
            .foregroundStyle(.primary)
         + Text(partial).foregroundStyle(.tertiary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .contentTransition(.opacity)
            .animation(.easeOut(duration: 0.18), value: committed)
            .animation(.easeOut(duration: 0.12), value: partial)
            .onChange(of: committed) { _, v in shownCommitted = v }
    }
}

/// 极简页上的润色开关。直接读写 config 并立刻生效 ——
/// 这个开关的语义是「下一句要不要润色」，不该还要用户去点保存。
private struct PolishToggle: View {
    @ObservedObject var state = AppState.shared
    @State private var hovering = false

    @State private var showSetup = false

    /// ⚠️ on 和 ready 必须同源，都读 appliedConfig。
    ///   这个胶囊要回答的是「下一句真的会被润色吗」，而真正干活的 VoiceSession
    ///   拿的是 appliedConfig。只把 ready 改过来会渲染出自相矛盾的状态：
    ///   设置页勾了润色但没保存时，on=true 显示紫色「已开启」，ready=false 同时
    ///   挂出橙色感叹号说「未配置模型」—— 而模型明明配好了，缺的只是保存。
    ///   反向更糟：applied 开着、草稿取消勾选未保存时胶囊显示「关闭」，
    ///   下一句却仍会被送去第三方润色。
    private var on: Bool { state.appliedConfig.enablePolish }
    private var ready: Bool { state.appliedConfig.polishReady }

    var body: some View {
        Button {
            let turningOn = !on
            // 只提交这一个字段。用 saveConfig() 会把设置页里尚未保存的整份草稿
            // 一并落盘生效 —— 用户可能正把 API Key 清空准备重贴（见 commitField 注释）。
            state.commitField { $0.enablePolish = turningOn }
            state.onReloadConfig?()
            // 刚打开却还没配模型 —— 这是用户意图最强的一瞬间，
            // 与其等他说完一句才弹「未配置」的红字，不如当场把路指出来。
            if turningOn && !ready { showSetup = true }
            else if !turningOn { showSetup = false }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10.5, weight: .semibold))
                Text("AI 润色").font(.system(size: 11, weight: .medium))
                if on && !ready {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            .foregroundStyle(on ? Color.white : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background {
                Capsule().fill(on
                    ? AnyShapeStyle(LinearGradient(colors: [.purple, .pink],
                                                   startPoint: .leading, endPoint: .trailing))
                    : AnyShapeStyle(Color.primary.opacity(hovering ? 0.09 : 0.05)))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(on
              ? (ready ? "已开启：松手后先润色再显示" : "已开启但未配置模型，点一下看怎么配")
              : "关闭状态：直接显示原始识别结果")
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: on)
        .popover(isPresented: $showSetup, arrowEdge: .top) {
            PolishSetupPopover { showSetup = false }
        }
    }
}

/// 开了润色但没配模型时弹的引导。
///
/// 这里是整个产品转化意图最强的一个点：用户刚刚亲手表达了「我想要 AI 润色」，
/// 而挡在他和这个功能之间的是「去某家云厂商注册 → 实名 → 充值 → 开通模型 →
/// 建 Key → 抄模型名」这一长串。把最短的那条路直接摆出来。
private struct PolishSetupPopover: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text("还差一个润色模型").font(.system(size: 13, weight: .semibold))
            }
            Text("润色要调一个大模型。挨家云厂商注册的话，实名、充值、开通模型、抄模型名，一套下来十几分钟；用 **Viva 中转站**的话，国内外的模型共用一个 Key，填进去点「拉取模型」就自动配好了。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)

            HStack(spacing: 8) {
                Button("去拿一个 Key") {
                    if let u = URL(string: LLMProvider.relaySite) {
                        NSWorkspace.shared.open(u)
                    }
                    NotificationCenter.default.post(name: .vivaOpenSettings, object: nil)
                    onDone()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)

                Button("已经有 Key 了") {
                    NotificationCenter.default.post(name: .vivaOpenSettings, object: nil)
                    onDone()
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .padding(13)
    }
}

extension Notification.Name {
    /// 从任意页面请求跳到「设置」。用通知而不是把 page 的 Binding 一路传下来 ——
    /// 只为一个跳转就改三层视图的签名不划算。
    static let vivaOpenSettings = Notification.Name("viva.openSettings")
    /// 返回主界面（说话页）。工具栏的「返回」按钮和主菜单的 ⌘[ 都走这里。
    static let vivaGoHome = Notification.Name("viva.goHome")
}

/// 工具条上的小玻璃按钮
private struct GlassButton: View {
    let icon: String
    let title: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.09 : 0.045)))
            .contentShape(Capsule())      // 保证整个胶囊都可点，而不只是文字
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.13), value: hovering)
    }
}

// MARK: - 修改快捷键胶囊

/// 主页底部的「快捷键」入口。
/// 左侧把当前热键渲染成一枚 keycap（比纯文字更像「一个可按的键」），
/// 右侧一句「修改」点明它可点。点一下跳到设置页并滚到热键那一节。
private struct HotkeyChip: View {
    @ObservedObject var state: AppState
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                // 当前热键做成一枚 keycap
                Text(HotkeyManager.describe(state.config))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.primary.opacity(0.06)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12)))
                Text("修改")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.07 : 0.0)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("修改「按住说话」的快捷键")
        .animation(.easeInOut(duration: 0.13), value: hovering)
    }
}

// MARK: - 底部极轻状态

private struct FooterStats: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var state: AppState

    var body: some View {
        let today = store.today
        HStack(spacing: 18) {
            stat("今天", "\(today.count) 次")
            dot
            stat("字数", "\(today.totalChars)")
            dot
            stat("时长", formatDuration(today.totalSeconds))
            if let ms = state.firstCharMs {
                dot
                stat("首字", "\(ms) ms")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }

    private var dot: some View {
        Circle().fill(Color.secondary.opacity(0.25)).frame(width: 3, height: 3)
    }

    private func stat(_ k: String, _ v: String) -> some View {
        HStack(spacing: 5) {
            Text(k)
            Text(v).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}
