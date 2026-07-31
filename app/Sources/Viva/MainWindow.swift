import SwiftUI
import AppKit

// MARK: - 导航

enum Page: String, CaseIterable, Identifiable {
    case speak      = "说话"
    case history    = "历史记录"
    case stats      = "数据统计"
    case dictionary = "改词记忆"
    case settings   = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .speak:      return "mic.fill"
        case .history:    return "clock.arrow.circlepath"
        case .stats:      return "chart.bar.xaxis"
        case .dictionary: return "character.book.closed"
        case .settings:   return "gearshape.fill"
        }
    }

    /// 侧边栏的彩色圆角图标底色。macOS 系统设置就是这个语言：
    /// 每一项一个饱和度适中的纯色方块 + 白色 SF Symbol。
    var tint: Color {
        switch self {
        case .speak:      return Color(red: 0.35, green: 0.42, blue: 0.96)
        case .history:    return Color(red: 0.55, green: 0.55, blue: 0.60)
        case .stats:      return Color(red: 0.20, green: 0.70, blue: 0.55)
        case .dictionary: return Color(red: 0.95, green: 0.62, blue: 0.20)
        case .settings:   return Color(red: 0.45, green: 0.48, blue: 0.54)
        }
    }
}

/// 侧边栏那种「彩色圆角方形 + 白色符号」的图标。
/// 尺寸规格照 macOS 系统设置：20pt 方块、5pt 连续圆角、11pt 符号。
struct SidebarIcon: View {
    let page: Page
    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(LinearGradient(colors: [page.tint.opacity(0.95), page.tint],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: page.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

private enum MainWindowLayoutMetrics {
    static let sidebarMinimumWidth: CGFloat = 180
    static let sidebarIdealWidth: CGFloat = 196
    static let sidebarMaximumWidth: CGFloat = 240
}

// MARK: - 主界面外壳

struct MainView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var store = HistoryStore.shared
    @State private var page: Page = .speak
    /// ⭐ 默认只显示主区域。极简主页的前提是「一屏只做一件事」，
    ///   侧边栏是需要时才拉出来的东西，不该一上来就占掉三分之一屏。
    @State private var columns: NavigationSplitViewVisibility = .detailOnly

    // ── 启动进场动画 ──
    // 时序：窗口淡入(0.45s,MainWindowController) → 品牌 splash(V 标弹出+涟漪+字标)
    //      → splash 放大淡出,首页从轻微缩小+模糊中弹入 → done
    private enum LaunchPhase { case splash, revealing, done }
    /// 每个进程生命周期只播一次 —— 关窗再开不重复表演
    @MainActor static var didPlayLaunchAnimation = false
    @State private var launch: LaunchPhase = MainView.didPlayLaunchAnimation ? .done : .splash

    var body: some View {
        ZStack {
            mainContent
                .opacity(launch == .splash ? 0 : 1)
                .scaleEffect(launch == .splash ? 0.97 : 1)
                .blur(radius: launch == .splash ? 10 : 0)

            if launch != .done {
                LaunchSplash(exiting: launch == .revealing)
                    .allowsHitTesting(launch == .splash)   // 退场半途别挡住首页点击
            }
        }
        .onAppear {
            guard launch == .splash else { return }
            // splash 停留 1.15s(足够弹出+一圈涟漪),然后 0.45s 交叉揭幕
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
                    launch = .revealing
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) {
                launch = .done
                MainView.didPlayLaunchAnimation = true
            }
        }
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(Page.allCases, selection: $page) { p in
                Label {
                    Text(p.rawValue)
                } icon: {
                    SidebarIcon(page: p)
                }
                .tag(p)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(
                min: MainWindowLayoutMetrics.sidebarMinimumWidth,
                ideal: MainWindowLayoutMetrics.sidebarIdealWidth,
                max: MainWindowLayoutMetrics.sidebarMaximumWidth)
            .safeAreaInset(edge: .bottom) { SidebarFooter(state: state) }
        } detail: {
            Group {
                switch page {
                case .speak:      SpeakView(state: state, store: store)
                case .history:    HistoryView(store: store)
                case .stats:      StatsView(store: store)
                case .dictionary: DictionaryView(state: state)
                case .settings:   SettingsView(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // ⭐ 左下角常驻入口。侧边栏默认收起之后，「设置」就彻底藏起来了；
            //   服务或权限未就绪时它会变成高亮的行动号召。
            .overlay(alignment: .bottomLeading) {
                if page != .settings, columns == .detailOnly {
                    QuickSettingsButton(state: state) {
                        withAnimation(.easeInOut(duration: 0.2)) { page = .settings }
                    }
                    .padding(20)
                }
            }
            // 标题栏只由 SwiftUI 管理。NavigationSplitView 负责系统侧栏按钮，
            // 本层只声明业务按钮，避免再引入第二套 AppKit toolbar。
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NotificationCenter.default.post(name: .vivaCollapseToMenuBar,
                                                        object: nil)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "menubar.arrow.up.rectangle")
                                .font(.system(size: 11, weight: .semibold))
                            Text("收起")
                        }
                    }
                    .help("收起到菜单栏 —— 窗口和 Dock 图标都会藏起来，热键照常可用，点顶部状态栏图标随时唤回")
                }

                if page != .speak {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { page = .speak }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "chevron.backward")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("返回")
                            }
                        }
                        .help("返回主界面（⌘[）")
                    }
                }
            }
        }
        .navigationTitle(page == .speak ? "" : page.rawValue)
        .frame(minWidth: 860, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: .vivaOpenSettings)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { page = .settings }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vivaGoHome)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { page = .speak }
        }
    }
}

// MARK: - 启动进场 splash

/// 品牌进场动画：V 标从小弹出（带轻微旋转回正）、光环涟漪向外扩散、
/// 字标延迟浮现；退场时整体放大 + 淡出，把舞台交给首页。
/// 涟漪用 TimelineView 统一相位驱动 —— 和 VoiceOrb 同一套做法，各圈永不漂移。
private struct LaunchSplash: View {
    /// 父视图把它切到退场态（带着 withAnimation 一起来）
    let exiting: Bool
    @State private var markIn = false
    @State private var textIn = false

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.accentColor.opacity(0.10), .clear],
                           center: .center, startRadius: 30, endRadius: 420)

            VStack(spacing: 20) {
                ZStack {
                    // 涟漪圈,以 V 标为圆心
                    if markIn && !exiting {
                        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                            let t = ctx.date.timeIntervalSinceReferenceDate
                            ZStack {
                                ForEach(0..<3, id: \.self) { i in
                                    let p = ((t / 1.4) + Double(i) / 3.0)
                                        .truncatingRemainder(dividingBy: 1)
                                    let eased = 1 - pow(1 - p, 3)      // easeOutCubic
                                    Circle()
                                        .strokeBorder(
                                            Color.accentColor.opacity(0.30 * (1 - eased)),
                                            lineWidth: 2 - 1.4 * eased)
                                        .frame(width: 136, height: 136)
                                        .scaleEffect(1 + 1.05 * eased)
                                }
                            }
                        }
                    }
                    VivaMark(size: 108)
                        .scaleEffect(markIn ? 1 : 0.5)
                        .rotationEffect(.degrees(markIn ? 0 : -8))
                        .opacity(markIn ? 1 : 0)
                }
                .frame(height: 150)

                VStack(spacing: 6) {
                    Text("Viva")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("话音未落，字已上屏。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .opacity(textIn ? 1 : 0)
                .offset(y: textIn ? 0 : 12)
            }
        }
        // 退场：放大 + 淡出（动画曲线由父视图的 withAnimation 决定）
        .scaleEffect(exiting ? 1.12 : 1)
        .opacity(exiting ? 0 : 1)
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) { markIn = true }
            withAnimation(.easeOut(duration: 0.45).delay(0.3)) { textIn = true }
        }
    }
}

/// 左下角的设置入口。两种形态：
/// - 未配置好 → 高亮胶囊「去配置」+ 橙色圆点，是个明确的行动号召
/// - 已就绪   → 克制的灰色齿轮，不抢主界面的注意力
private struct QuickSettingsButton: View {
    @ObservedObject var state: AppState
    let action: () -> Void
    @State private var hovering = false

    private var needsSetup: Bool { !state.canSpeak }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if needsSetup {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text("去配置").font(.system(size: 12.5, weight: .medium))
                } else {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .medium))
                    Text("设置").font(.system(size: 12.5))
                }
            }
            .foregroundStyle(needsSetup ? Color.orange : Color.secondary)
            .padding(.horizontal, needsSetup ? 12 : 11)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(.regularMaterial)
                Capsule().fill(needsSetup ? Color.orange.opacity(0.12) : Color.clear)
            }
            .overlay {
                Capsule().strokeBorder(
                    needsSetup ? Color.orange.opacity(0.35)
                               : Color.primary.opacity(hovering ? 0.16 : 0.08))
            }
            .shadow(color: .black.opacity(hovering ? 0.10 : 0.05),
                    radius: hovering ? 6 : 3, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(needsSetup ? "服务或权限尚未就绪，点这里检查" : "打开设置")
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .animation(.easeInOut(duration: 0.25), value: needsSetup)
    }
}

private struct SidebarFooter: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(spacing: 8) {
                Circle()
                    .fill(state.isReady ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.isReady ? "就绪" : "未就绪")
                        .font(.system(size: 12, weight: .medium))
                    Text(state.isReady
                         ? "按住 \(HotkeyManager.describe(state.config))"
                         : "点「设置」检查")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - 总览

struct DashboardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var store: HistoryStore
    @State private var pressing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                // ── 四个核心指标：正是「次数 / 时长 / 字数」三件事 ──
                let all = store.allTime
                let today = store.today
                HStack(spacing: 12) {
                    StatTile(icon: "text.bubble", tint: .blue,
                             title: "说话次数",
                             value: "\(all.count)",
                             sub: "今天 \(today.count) 次")
                    StatTile(icon: "clock", tint: .purple,
                             title: "说话时长",
                             value: formatDuration(all.totalSeconds),
                             sub: "今天 \(formatDuration(today.totalSeconds))")
                    StatTile(icon: "character.cursor.ibeam", tint: .teal,
                             title: "累计字数",
                             value: compactNumber(all.totalChars),
                             sub: "今天 \(compactNumber(today.totalChars)) 字")
                    StatTile(icon: "bolt.fill", tint: .orange,
                             title: "节省时间",
                             value: formatMinutes(all.savedMinutes),
                             sub: "按打字 30 字/分估算")
                }

                if !state.isReady { ReadinessCard(state: state) }

                if state.secureInputOn {
                    WarnBanner(text: "当前处于「安全键盘输入」状态（密码框 / iTerm2 的 Secure Keyboard Entry），无法自动上屏，识别结果会复制到剪贴板。",
                               tint: .orange)
                }
                if !state.lastError.isEmpty {
                    WarnBanner(text: state.lastError, tint: .red)
                }

                // ── 试一试 ──
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("试一试").font(.headline)
                            Text(state.config.polishReady
                                 ? "已开启 AI 润色：说话时先在这里显示识别原文，松手后润色再上屏"
                                 : "结果只显示在这里，不会写进其它 App —— 不需要辅助功能权限")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }

                        LevelMeter(level: state.level).frame(height: 36)

                        ScrollView {
                            (Text(state.committed).foregroundStyle(.primary)
                             + Text(state.partial).foregroundStyle(.tertiary).italic())
                                .font(.system(size: 15))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(height: 108)
                        .background(Color(nsColor: .textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Color.secondary.opacity(0.22)))

                        HStack(spacing: 14) {
                            Text(pressing ? "松开结束" : "按住这里说话")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(pressing ? .white : .primary)
                                .frame(width: 160, height: 38)
                                .background(pressing ? Color.accentColor
                                                     : Color(nsColor: .controlColor),
                                            in: RoundedRectangle(cornerRadius: 9))
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in
                                            guard !pressing,
                                                  state.micGranted,
                                                  state.appliedConfig.hasValidBackendConfiguration else { return }
                                            pressing = true
                                            state.onTestStart?()
                                        }
                                        .onEnded { _ in
                                            guard pressing else { return }
                                            pressing = false
                                            state.onTestStop?()
                                        }
                                )
                                .opacity(state.micGranted
                                         && state.appliedConfig.hasValidBackendConfiguration ? 1 : 0.45)

                            if state.isPolishing {
                                HStack(spacing: 5) {
                                    ProgressView().controlSize(.small)
                                    Text("润色中…").font(.caption).foregroundStyle(.secondary)
                                }
                            } else if !state.polishNote.isEmpty {
                                Label(state.polishNote, systemImage: "sparkles")
                                    .font(.caption).foregroundStyle(.purple)
                            }
                            if let ms = state.firstCharMs { Metric(label: "首字", value: "\(ms) ms") }
                            if let ms = state.lastSentenceMs { Metric(label: "整段", value: "\(ms) ms") }
                            Metric(label: "本次运行",
                                   value: String(format: "%.1f 分", state.billedSeconds / 60))
                            Spacer()
                            Button("清空") {
                                state.committed = ""; state.partial = ""
                                state.firstCharMs = nil; state.lastSentenceMs = nil
                            }
                        }

                        if !state.lastLogId.isEmpty {
                            Text("logid: \(state.lastLogId)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                    }
                    .padding(6)
                }

                // ── 最近记录 ──
                if !store.records.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text("最近记录").font(.headline)
                                Spacer()
                                Text("共 \(store.records.count) 条")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 8)

                            ForEach(store.records.prefix(5)) { r in
                                RecordRow(record: r, compact: true)
                                if r.id != store.records.prefix(5).last?.id { Divider() }
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - 就绪检查卡片

private struct ReadinessCard: View {
    @ObservedObject var state: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Text("还差几步就能用了").font(.headline).padding(.bottom, 6)

                CheckRow(ok: state.appliedConfig.hasValidBackendConfiguration,
                         title: "Viva 服务地址",
                         detail: state.appliedConfig.hasValidBackendConfiguration
                            ? (state.appliedConfig.testModeEnabled
                               ? "测试模式 · \(state.appliedConfig.selectedBackendBaseURLString)"
                               : "托管地址已锁定 · 首次请求自动鉴权")
                            : (state.appliedConfig.backendConfigurationError ?? "服务地址无效"),
                         action: nil)
                Divider()
                CheckRow(ok: state.micGranted, title: "麦克风权限",
                         detail: state.micGranted ? "已授权" : "用于采集你说的话",
                         action: state.micGranted ? nil
                            : ("打开系统设置", { openPrivacy("Privacy_Microphone") }))
                Divider()
                CheckRow(ok: state.axGranted, title: "辅助功能权限",
                         detail: state.axGranted ? "已授权"
                            : "用于全局热键和把文字写进其它 App。⚠️ 授权后需重启本应用",
                         action: state.axGranted ? nil
                            : ("打开系统设置", { openPrivacy("Privacy_Accessibility") }))
                Divider()
                CheckRow(ok: state.audioEngineReady, title: "麦克风引擎",
                         detail: state.audioEngineReady
                            ? "已预热常驻（消除首字丢失）" : "未启动",
                         action: nil)
                Divider()
                CheckRow(ok: state.hotkeyHealthy, title: "全局热键",
                         detail: state.hotkeyHealthy
                            ? "\(HotkeyManager.describe(state.config)) 已注册并在监控中"
                            : "未注册。刚授权过就重启本应用；如果是升级/重新编译后失效，需要到「系统设置 → 隐私与安全性 → 辅助功能」里把 Viva 先移除再重新添加（授权绑定代码签名，仅重新勾选无效）",
                         action: nil)
            }
            .padding(6)
        }
    }

    private func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: - 共用小组件

struct StatTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let sub: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
                Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.secondary.opacity(0.16)))
    }
}

struct CheckRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let action: (String, () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let (label, run) = action { Button(label, action: run) }
        }
        .padding(.vertical, 7)
    }
}

struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .rounded))
        }
    }
}

struct WarnBanner: View {
    let text: String
    let tint: Color
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout).foregroundStyle(tint)
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LevelMeter: View {
    let level: Float
    @State private var bars = [Float](repeating: 0, count: 56)

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 静音时给一条淡淡的基线，避免一排 2px 的方块看起来像虚线
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                    .frame(height: 2)

                HStack(alignment: .center, spacing: 2) {
                    ForEach(bars.indices, id: \.self) { i in
                        let v = CGFloat(bars[i])
                        Capsule()
                            .fill(Color.accentColor
                                .opacity(v < 0.02 ? 0
                                                  : 0.35 + 0.65 * Double(i) / Double(bars.count)))
                            .frame(width: max(2, geo.size.width / CGFloat(bars.count) - 2),
                                   height: max(2, v * geo.size.height))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.linear(duration: 0.06), value: bars)
        }
        .onChange(of: level) { _, newValue in
            bars.removeFirst(); bars.append(newValue)
        }
    }
}

// MARK: - 格式化

func formatDuration(_ seconds: Double) -> String {
    if seconds < 60 { return String(format: "%.0f 秒", seconds) }
    if seconds < 3600 { return String(format: "%.1f 分", seconds / 60) }
    return String(format: "%.1f 小时", seconds / 3600)
}

func formatMinutes(_ minutes: Double) -> String {
    if minutes < 60 { return String(format: "%.0f 分钟", minutes) }
    return String(format: "%.1f 小时", minutes / 60)
}

func compactNumber(_ n: Int) -> String {
    if n < 10000 { return "\(n)" }
    if n < 1_000_000 { return String(format: "%.1f 万", Double(n) / 10000) }
    return String(format: "%.2f 百万", Double(n) / 1_000_000)
}

// MARK: - 窗口容器

@MainActor
final class MainWindowController {
    private var window: NSWindow?

    /// 收起到菜单栏时藏起窗口（不销毁，唤回秒开）
    func hide() { window?.orderOut(nil) }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable,
                        .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "Viva"
        w.titlebarAppearsTransparent = false
        w.center()
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MainView())
        window = w

        // 进场：窗口从全透明淡入（配合 MainView 里的品牌 splash 完成整套进场动画）。
        // 只在首次创建时播 —— 关窗再开走上面的快速路径，不重复表演。
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
        }
    }
}
