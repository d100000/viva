import SwiftUI
import AppKit

// MARK: - 品牌标记（矢量绘制，和 .icns 里的 V 同一套几何）

struct VivaMark: View {
    var size: CGFloat = 72
    /// 大尺寸下在 V 右侧带一小段声波尾。小尺寸一律省掉 —— 会糊成一坨。
    var showWave: Bool { size >= 96 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(red: 0.388, green: 0.400, blue: 0.945),
                             Color(red: 0.659, green: 0.333, blue: 0.969)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .fill(LinearGradient(
                            colors: [.white.opacity(0.20), .clear],
                            startPoint: .top, endPoint: .center))
                }

            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                let inset = s * 0.255
                let g = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
                let lw = g.width * 0.215

                Path { p in
                    p.move(to: CGPoint(x: g.minX + lw / 2, y: g.minY))
                    p.addLine(to: CGPoint(x: g.midX, y: g.maxY - lw / 2))
                    p.addLine(to: CGPoint(x: g.maxX - lw / 2, y: g.minY))
                }
                .stroke(Color.white,
                        style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.95).opacity(0.35),
                radius: size * 0.12, y: size * 0.05)
    }
}

// MARK: - 欢迎 / 首次配置

struct WelcomeView: View {
    @ObservedObject var state = AppState.shared
    @State private var pressing = false
    var onFinish: () -> Void

    private var stepsDone: Int {
        [state.accountProfile != nil, state.micGranted, state.axGranted]
            .filter { $0 }.count
    }

    var body: some View {
        VStack(spacing: 0) {

            // ── 品牌区 ──
            VStack(spacing: 14) {
                VivaMark(size: 84)
                    .padding(.top, 40)

                VStack(spacing: 5) {
                    Text("Viva")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    Text("话音未落，字已上屏。")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text("Faster than your keyboard.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .tracking(0.6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 26)

            Divider()

            // ── 三步配置 ──
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("三步就能用").font(.headline)
                        Spacer()
                        Text("\(stepsDone)/3")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(stepsDone == 3 ? Color.green : .secondary)
                    }

                    AccountView(
                        client: ManagedBackendAuth.shared,
                        showsDeveloperCode: state.config.testModeEnabled,
                        onProfileChange: { state.accountProfile = $0 }
                    )

                    StepCard(index: 2, done: state.micGranted,
                             title: "允许使用麦克风",
                             detail: "用于采集语音。音频会加密传输到 Viva 服务，再由服务端转发到已配置的语音识别供应商。") {
                        Button("打开系统设置") {
                            openPrivacy("Privacy_Microphone")
                        }
                    }

                    StepCard(index: 3, done: state.axGranted,
                             title: "允许辅助功能",
                             detail: "用于监听全局热键，以及把识别出的文字写进当前光标处。授权后 Viva 会自动检测；若仍未生效，可在设置中重新检查或重启应用。") {
                        Button("打开系统设置") {
                            openPrivacy("Privacy_Accessibility")
                        }
                    }

                    // ── 试一句 ──
                    if state.accountProfile != nil,
                       state.config.hasValidBackendConfiguration,
                       state.micGranted {
                        Divider().padding(.vertical, 2)
                        VStack(alignment: .leading, spacing: 9) {
                            Text("试一句").font(.headline)
                            Text("按住下面的按钮说一句话。结果只显示在这里，不会写进任何应用。")
                                .font(.caption).foregroundStyle(.secondary)

                            ScrollView {
                                (Text(state.committed)
                                 + Text(state.partial).foregroundColor(.secondary))
                                    .font(.system(size: 14))
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .padding(9)
                            }
                            .frame(height: 62)
                            .background(Color(nsColor: .textBackgroundColor),
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.22)))

                            HStack(spacing: 12) {
                                HoldToSpeakButton(pressing: pressing,
                                                  level: state.level)
                                    .contentShape(Capsule())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in beginTestPress() }
                                            .onEnded { _ in endTestPress() })
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("按住试说")
                                    .accessibilityValue(pressing ? "正在试听" : "未开始")
                                    .accessibilityHint("VoiceOver 激活一次开始试听，再激活一次结束")
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction {
                                        if pressing {
                                            endTestPress()
                                        } else {
                                            beginTestPress()
                                        }
                                    }
                                if let ms = state.firstCharMs {
                                    Text("首字 \(ms) ms")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Spacer()
                            }
                        }
                    }

                    if !state.lastError.isEmpty {
                        WarnBanner(text: state.lastError, tint: .red)
                    }
                }
                .padding(22)
            }

            Divider()

            // ── 页脚 ──
            HStack {
                Text("Just say Viva.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer()
                // ⚠️ 这里**不要**加 .keyboardShortcut(.defaultAction)。
                //    它会把按钮设成窗口默认按钮，任何游荡的 Return 都会把引导页
                //    直接跳过并写死 hasSeenWelcome —— 实测启动 3 秒内就被误触发了。
                Button(state.accountProfile == nil
                       ? "请先登录"
                       : (stepsDone == 3 ? "开始使用" : "先跳过权限，稍后完成")) {
                    onFinish()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.accountProfile == nil)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func beginTestPress() {
        guard !pressing else { return }
        pressing = true
        state.onTestStart?()
    }

    private func endTestPress() {
        guard pressing else { return }
        pressing = false
        state.onTestStop?()
    }

    private func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(u)
        }
    }
}

// MARK: -

private struct StepCard<Trailing: View>: View {
    let index: Int
    let done: Bool
    let title: String
    let detail: String
    /// 完成之后是否仍允许修改。
    var editable: Bool = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.secondary.opacity(0.18))
                    .frame(width: 22, height: 22)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .strikethrough(done, color: .secondary)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !done {
                    trailing
                } else if editable {
                    DisclosureGroup("修改") { trailing.padding(.top, 4) }
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.secondary.opacity(done ? 0.10 : 0.18)))
    }
}

// MARK: - 窗口容器

@MainActor
final class WelcomeWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    var onFinish: (() -> Void)?

    /// ⚠️ 点红色关闭按钮也必须走 onFinish。否则 hasSeenWelcome 永远不会被置位，
    ///   引导页每次启动都重复弹，「跳过」形同虚设；而且主界面也不会打开，
    ///   屏幕上一个窗口都不剩 —— 正是「装了但没打开」那个坑。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onFinish?()
        return true
    }

    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "欢迎使用 Viva"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
            self?.close()
            self?.onFinish?()
        })
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.orderOut(nil) }
}


// MARK: - 引导页的「按住说话」

/// 引导页里那个测试按钮。
///
/// 原来是一个 132×34 的灰色小胶囊，和旁边的普通按钮长得一模一样 ——
/// 用户根本看不出它是**要按住不放**的，而这是整个引导流程里唯一需要
/// 亲手操作的一步。所以它必须一眼就跟其它控件区分开：
/// 更大、有主色、带麦克风图标、空闲时轻微呼吸吸引注意。
private struct HoldToSpeakButton: View {
    let pressing: Bool
    let level: Float
    @State private var breathe = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: pressing ? "waveform" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: pressing)

            Text(pressing ? "松开结束" : "按住说话")
                .font(.system(size: 14, weight: .semibold))

            if pressing {
                // 按住时右侧跟一小段电平条，明确「正在听」
                MiniLevel(level: level)
                    .frame(width: 26, height: 14)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background {
            Capsule().fill(
                LinearGradient(
                    colors: pressing
                        ? [Color.accentColor, Color.accentColor.opacity(0.82)]
                        : [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.78)],
                    startPoint: .top, endPoint: .bottom))
        }
        .overlay {
            // 空闲时一圈缓慢扩散的光环，把视线拉过来
            if !pressing {
                Capsule()
                    .stroke(Color.accentColor.opacity(breathe ? 0 : 0.45), lineWidth: 2)
                    .scaleEffect(breathe ? 1.14 : 1.0)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false),
                               value: breathe)
            }
        }
        .scaleEffect(pressing ? 0.96 : (hovering ? 1.03 : 1.0))
        .shadow(color: Color.accentColor.opacity(pressing ? 0.45 : 0.28),
                radius: pressing ? 14 : 8, y: 4)
        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: pressing)
        .animation(.easeInOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .onAppear { breathe = true }
    }
}

private struct MiniLevel: View {
    let level: Float
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let w = sin(t * 7 + Double(i) * 1.1) * 0.5 + 0.5
                    let h = 3 + CGFloat(min(1, level * 3.4)) * 11 * (0.5 + w * 0.5)
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: 2.5, height: max(3, h))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
