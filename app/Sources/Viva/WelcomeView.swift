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
    @State private var keyDraft = ""
    var onFinish: () -> Void

    private var stepsDone: Int {
        [state.config.hasCredentials, state.micGranted, state.axGranted]
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
                    Text("别打了，说吧。")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text("Type at the speed of speech.")
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

                    StepCard(index: 1, done: state.config.hasCredentials,
                             title: "填入火山引擎 API Key",
                             detail: "需要先在控制台开通「豆包流式语音识别模型 2.0」。约 1 元/小时，按你实际说话时长计费。") {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                SecureField("控制台的 x-api-key", text: $keyDraft)
                                    .textFieldStyle(.roundedBorder)
                                Button("保存") {
                                    state.config.apiKey = keyDraft
                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                    state.saveConfig()
                                    state.onReloadConfig?()
                                }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                            Button("打开火山引擎控制台") {
                                NSWorkspace.shared.open(
                                    URL(string: "https://console.volcengine.com/speech/service")!)
                            }
                            .buttonStyle(.link)
                        }
                    }

                    StepCard(index: 2, done: state.micGranted,
                             title: "允许使用麦克风",
                             detail: "音频只发往你自己配置的火山账号，不经过任何第三方服务器。") {
                        Button("打开系统设置") {
                            openPrivacy("Privacy_Microphone")
                        }
                    }

                    StepCard(index: 3, done: state.axGranted,
                             title: "允许辅助功能",
                             detail: "用于监听全局热键，以及把识别出的文字写进当前光标处。⚠️ 授权后需要重启本应用才会生效。") {
                        Button("打开系统设置") {
                            openPrivacy("Privacy_Accessibility")
                        }
                    }

                    // ── 试一句 ──
                    if state.config.hasCredentials, state.micGranted {
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
                                Text(pressing ? "松开结束" : "按住说话")
                                    .font(.system(size: 13.5, weight: .medium))
                                    .foregroundStyle(pressing ? .white : .primary)
                                    .frame(width: 132, height: 34)
                                    .background(pressing ? Color.accentColor
                                                         : Color(nsColor: .controlColor),
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in
                                                guard !pressing else { return }
                                                pressing = true
                                                state.onTestStart?()
                                            }
                                            .onEnded { _ in
                                                guard pressing else { return }
                                                pressing = false
                                                state.onTestStop?()
                                            })
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
                Button(stepsDone == 3 ? "开始使用" : "先跳过，稍后配置") { onFinish() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { keyDraft = state.config.apiKey }
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
                if !done { trailing }
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
final class WelcomeWindowController {
    private var window: NSWindow?
    var onFinish: (() -> Void)?

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
