import SwiftUI

struct VivaAccountProfile: Equatable, Sendable {
    let email: String
    let credits: Int64
}

struct VivaOTPDelivery: Equatable, Sendable {
    let resendAfterSeconds: Int
    let developerCode: String?

    init(resendAfterSeconds: Int = 60, developerCode: String? = nil) {
        self.resendAfterSeconds = resendAfterSeconds
        self.developerCode = developerCode
    }
}

/// Small account boundary for SwiftUI. ManagedBackendAuth can conform once the
/// server account endpoints are available without coupling this view to HTTP.
protocol VivaAccountClient: Sendable {
    func restore() async throws -> VivaAccountProfile?
    func requestOTP(email: String) async throws -> VivaOTPDelivery
    func verifyOTP(email: String, code: String) async throws -> VivaAccountProfile
    func refreshProfile() async throws -> VivaAccountProfile
    func logout() async throws
}

/// 独立账户窗口的内容。认证是产品使用前提，因此未登录时先完成登录，
/// 登录成功后再打开结构稳定的主窗口。
@MainActor
struct AccountAccessView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: AccountViewMetrics.accessSectionSpacing) {
                VivaMark(size: AccountViewMetrics.accessMarkSize)

                VStack(spacing: AccountViewMetrics.titleSpacing) {
                    Text("登录 Viva")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("使用邮箱验证码登录；新邮箱会自动创建账户。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                AccountView(
                    client: ManagedBackendAuth.shared,
                    showsDeveloperCode: state.appliedConfig.testModeEnabled,
                    onProfileChange: { state.accountProfile = $0 }
                )
                .id(state.appliedConfig.selectedBackendBaseURLString)

                if state.appliedConfig.testModeEnabled {
                    VivaServiceRoutingView(config: state.appliedConfig)
                }

                DeveloperBackendAccessView(state: state)
            }
            .frame(maxWidth: AccountViewMetrics.accessContentMaxWidth)
            .padding(.horizontal, AccountViewMetrics.accessHorizontalPadding)
            .padding(.vertical, AccountViewMetrics.accessVerticalPadding)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private enum AccountWindowMetrics {
    static let width: CGFloat = 600
    static let height: CGFloat = 650
}

/// 登录窗口与主窗口完全分离。每次从隐藏状态重新打开时重建 SwiftUI 根视图，
/// 让 AccountView 重新检查当前服务 origin 的本机登录会话；窗口已经显示时
/// 只置前，避免 restore → signedOut → 再 show 形成重复恢复循环。
@MainActor
final class AccountWindowController {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let accountContent = AccountAccessView(state: AppState.shared)
        let window: NSWindow
        if let existing = self.window {
            window = existing
            window.contentView = NSHostingView(rootView: accountContent)
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0,
                                    width: AccountWindowMetrics.width,
                                    height: AccountWindowMetrics.height),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            window.title = "登录 Viva"
            window.center()
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: accountContent)
            self.window = window
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.orderOut(nil) }
}

@MainActor
private struct DeveloperBackendAccessView: View {
    @ObservedObject var state: AppState
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: AccountViewMetrics.rowSpacing) {
                Toggle("连接本地 Viva 服务", isOn: $state.config.testModeEnabled)

                if state.config.testModeEnabled {
                    TextField(Config.defaultTestBackendBaseURL,
                              text: $state.config.testBackendBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Text("仅允许 localhost、127.0.0.0/8 或 ::1 的无路径 origin。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let error = state.config.backendConfigurationError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                HStack {
                    Button("保存并切换") {
                        state.saveConfig()
                        state.onReloadConfig?()
                    }
                    .disabled(state.config.backendBaseURL == nil)

                    if state.hasUnsavedChanges {
                        Text("有未保存更改")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(.top, AccountViewMetrics.rowSpacing)
        } label: {
            Label(state.appliedConfig.testModeEnabled
                  ? "开发者测试环境 · 已启用"
                  : "开发者测试环境",
                  systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.medium))
                .foregroundStyle(state.appliedConfig.testModeEnabled ? .orange : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 当前真正生效的 Viva 服务路由。测试模式只切换统一的服务 origin，账户、
/// 积分、ASR 和大模型仍走完整的服务端链路，不在客户端生成 Mock 结果。
struct VivaServiceRoutingView: View {
    let config: Config
    var alignment: HorizontalAlignment = .leading
    var compact = false

    var body: some View {
        VStack(alignment: alignment, spacing: compact ? 2 : 4) {
            Label(routeTitle,
                  systemImage: config.testModeEnabled ? "server.rack" : "checkmark.shield.fill")
                .font(compact ? .caption2.weight(.medium) : .callout.weight(.medium))
                .foregroundStyle(config.testModeEnabled ? Color.green : Color.primary)

            if !compact {
                Text(routeDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var routeTitle: String {
        guard config.testModeEnabled else { return "Viva 托管服务" }
        let address = config.backendBaseURL?.absoluteString
            ?? config.selectedBackendBaseURLString
        return "本地服务器 · \(address)"
    }

    private var routeDetail: String {
        config.testModeEnabled
            ? "账户、积分、语音识别和大模型请求均发送到此服务器。"
            : "账户、积分、语音识别和大模型请求统一由 Viva 托管服务处理。"
    }
}

@MainActor
struct AccountView: View {
    @StateObject private var model: VivaAccountViewModel
    @State private var confirmsLogout = false

    init(client: any VivaAccountClient,
         showsDeveloperCode: Bool = false,
         onProfileChange: @escaping (VivaAccountProfile?) -> Void = { _ in }) {
        _model = StateObject(wrappedValue: VivaAccountViewModel(
            client: client,
            showsDeveloperCode: showsDeveloperCode,
            onProfileChange: onProfileChange
        ))
    }

    var body: some View {
        GroupBox("Viva 账户") {
            VStack(alignment: .leading, spacing: AccountViewMetrics.sectionSpacing) {
                if model.isRestoring {
                    loadingRow("正在恢复登录状态…")
                } else if let profile = model.profile {
                    signedInContent(profile)
                } else {
                    signedOutContent
                }

                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("账户错误：\(error)")
                }
            }
            .padding(AccountViewMetrics.contentPadding)
        }
        .task { await model.restoreIfNeeded() }
        .alert("退出登录？", isPresented: $confirmsLogout) {
            Button("取消", role: .cancel) {}
            Button("退出登录", role: .destructive) {
                Task { await model.logout() }
            }
        } message: {
            Text("本机登录状态会被清除；再次使用需要重新验证邮箱。")
        }
    }

    @ViewBuilder
    private var signedOutContent: some View {
        switch model.stage {
        case .email:
            emailEntry
        case .verification:
            verificationEntry
        }
    }

    private var emailEntry: some View {
        VStack(alignment: .leading, spacing: AccountViewMetrics.rowSpacing) {
            AccountLabeledRow("邮箱") {
                TextField("name@example.com", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBusy)
                    .onChange(of: model.email) { _, _ in
                        model.emailDidChange()
                    }
                    .onSubmit {
                        guard model.canRequestOTP else { return }
                        Task { await model.requestOTP() }
                    }
            }

            Text("新邮箱会自动注册，已有账户会直接登录。Viva 不会索取 Mac 系统密码；验证一次后会在本机保持登录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    Task { await model.requestOTP() }
                } label: {
                    operationLabel(isRunning: model.isRequestingOTP,
                                   title: "发送验证码",
                                   systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRequestOTP)

                Spacer()
            }
        }
    }

    private var verificationEntry: some View {
        VStack(alignment: .leading, spacing: AccountViewMetrics.rowSpacing) {
            AccountLabeledRow("邮箱") {
                HStack(spacing: AccountViewMetrics.inlineSpacing) {
                    Text(model.pendingEmail)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: AccountViewMetrics.inlineSpacing)
                    Button("修改") { model.changeEmail() }
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
            }

            AccountLabeledRow("验证码") {
                TextField("6 位数字", text: $model.code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: AccountViewMetrics.codeFieldMaxWidth)
                    .disabled(model.isBusy)
                    .onChange(of: model.code) { _, value in
                        model.sanitizeCode(value)
                    }
                    .onSubmit {
                        guard model.canVerify else { return }
                        Task { await model.verifyOTP() }
                    }
                    .accessibilityLabel("六位邮箱验证码")
            }

            if let developerCode = model.developerCode {
                Label {
                    Text("本地测试验证码：\(developerCode)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "hammer")
                }
                .foregroundStyle(.orange)
                .accessibilityLabel("本地测试验证码 \(developerCode)")
            }

            HStack(spacing: AccountViewMetrics.inlineSpacing) {
                Button {
                    Task { await model.verifyOTP() }
                } label: {
                    operationLabel(isRunning: model.isVerifying,
                                   title: "登录或注册",
                                   systemImage: "person.badge.key")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canVerify)

                Button(model.resendSeconds > 0
                       ? "\(model.resendSeconds) 秒后可重发"
                       : "重新发送") {
                    Task { await model.requestOTP() }
                }
                .monospacedDigit()
                .frame(minWidth: AccountViewMetrics.secondaryActionMinWidth)
                .disabled(model.isBusy || model.resendSeconds > 0)

                Spacer()
            }
        }
    }

    private func signedInContent(_ profile: VivaAccountProfile) -> some View {
        VStack(alignment: .leading, spacing: AccountViewMetrics.rowSpacing) {
            HStack {
                Label("已登录", systemImage: "checkmark.shield.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.green)
                Spacer()
                if model.isRefreshing || model.isLoggingOut {
                    ProgressView().controlSize(.small)
                }
            }

            Divider()

            AccountLabeledRow("邮箱") {
                Text(profile.email)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            AccountLabeledRow("积分") {
                HStack(spacing: AccountViewMetrics.inlineSpacing) {
                    Image(systemName: "seal.fill")
                        .foregroundStyle(.orange)
                    Text("\(profile.credits)")
                        .monospacedDigit()
                        .font(.body.weight(.medium))
                    Spacer()
                }
            }

            HStack(spacing: AccountViewMetrics.inlineSpacing) {
                Button {
                    Task { await model.refreshProfile() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isBusy)

                Spacer()

                Button("退出登录", role: .destructive) {
                    confirmsLogout = true
                }
                .disabled(model.isBusy)
            }
        }
    }

    private func loadingRow(_ title: String) -> some View {
        HStack(spacing: AccountViewMetrics.inlineSpacing) {
            ProgressView().controlSize(.small)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func operationLabel(isRunning: Bool,
                                title: String,
                                systemImage: String) -> some View {
        HStack(spacing: AccountViewMetrics.buttonLabelSpacing) {
            if isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(isRunning ? "请稍候…" : title)
        }
        .frame(minWidth: AccountViewMetrics.primaryActionMinWidth)
    }
}

@MainActor
private final class VivaAccountViewModel: ObservableObject {
    enum Stage {
        case email
        case verification
    }

    private enum Operation {
        case restore
        case requestOTP
        case verify
        case refresh
        case logout
    }

    @Published var email = ""
    @Published var code = ""
    @Published private(set) var pendingEmail = ""
    @Published private(set) var profile: VivaAccountProfile?
    @Published private(set) var stage: Stage = .email
    @Published private(set) var errorMessage: String?
    @Published private(set) var resendSeconds = 0
    @Published private(set) var developerCode: String?

    private let client: any VivaAccountClient
    private let showsDeveloperCode: Bool
    private let onProfileChange: (VivaAccountProfile?) -> Void
    private var operation: Operation?
    private var didAttemptRestore = false
    private var countdownTask: Task<Void, Never>?

    init(client: any VivaAccountClient,
         showsDeveloperCode: Bool,
         onProfileChange: @escaping (VivaAccountProfile?) -> Void) {
        self.client = client
        self.showsDeveloperCode = showsDeveloperCode
        self.onProfileChange = onProfileChange
    }

    var isBusy: Bool { operation != nil }
    var isRestoring: Bool { operation == .restore }
    var isRequestingOTP: Bool { operation == .requestOTP }
    var isVerifying: Bool { operation == .verify }
    var isRefreshing: Bool { operation == .refresh }
    var isLoggingOut: Bool { operation == .logout }

    var canRequestOTP: Bool {
        !isBusy && Self.isPlausibleEmail(normalizedEmail)
    }

    var canVerify: Bool {
        !isBusy && pendingEmail.count > 0 && code.count == 6 && code.allSatisfy(\.isNumber)
    }

    func restoreIfNeeded() async {
        guard !didAttemptRestore, !isBusy else { return }
        didAttemptRestore = true
        operation = .restore
        errorMessage = nil
        defer { operation = nil }

        do {
            let restored = try await client.restore()
            profile = restored
            if let restored { email = restored.email }
            onProfileChange(restored)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func requestOTP() async {
        guard !isBusy else { return }
        let target = normalizedEmail
        guard Self.isPlausibleEmail(target) else {
            errorMessage = "请输入有效的邮箱地址"
            return
        }

        operation = .requestOTP
        errorMessage = nil
        defer { operation = nil }

        do {
            let delivery = try await client.requestOTP(email: target)
            email = target
            pendingEmail = target
            code = ""
            stage = .verification
            developerCode = showsDeveloperCode ? delivery.developerCode : nil
            startCountdown(seconds: delivery.resendAfterSeconds)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func verifyOTP() async {
        guard !isBusy else { return }
        guard canVerify else {
            errorMessage = "请输入 6 位数字验证码"
            return
        }

        operation = .verify
        errorMessage = nil
        defer { operation = nil }

        do {
            let verified = try await client.verifyOTP(email: pendingEmail, code: code)
            profile = verified
            email = verified.email
            code = ""
            developerCode = nil
            countdownTask?.cancel()
            resendSeconds = 0
            onProfileChange(verified)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func refreshProfile() async {
        guard !isBusy, profile != nil else { return }
        operation = .refresh
        errorMessage = nil
        defer { operation = nil }

        do {
            let refreshed = try await client.refreshProfile()
            profile = refreshed
            email = refreshed.email
            onProfileChange(refreshed)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func logout() async {
        guard !isBusy else { return }
        operation = .logout
        errorMessage = nil
        defer { operation = nil }

        do {
            try await client.logout()
        } catch {
            // 服务端失败或超时也必须按用户意图退出；client.logout() 负责先清
            // 本机登录状态，这里同步清 UI，并保留“远端会话可能仍有效”的提示。
            errorMessage = Self.message(for: error)
        }
        profile = nil
        pendingEmail = ""
        code = ""
        developerCode = nil
        stage = .email
        countdownTask?.cancel()
        resendSeconds = 0
        onProfileChange(nil)
    }

    func changeEmail() {
        guard !isBusy else { return }
        countdownTask?.cancel()
        resendSeconds = 0
        code = ""
        pendingEmail = ""
        developerCode = nil
        errorMessage = nil
        stage = .email
    }

    func sanitizeCode(_ value: String) {
        let sanitized = String(value.filter(\.isNumber).prefix(6))
        if code != sanitized { code = sanitized }
        if !isBusy { errorMessage = nil }
    }

    func emailDidChange() {
        if stage == .email, !isBusy { errorMessage = nil }
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func startCountdown(seconds: Int) {
        countdownTask?.cancel()
        resendSeconds = max(0, seconds)
        guard resendSeconds > 0 else { return }

        countdownTask = Task { [weak self] in
            while let self, self.resendSeconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.resendSeconds -= 1
            }
        }
    }

    private static func isPlausibleEmail(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains(where: \.isWhitespace),
              let at = value.lastIndex(of: "@"),
              at != value.startIndex,
              value.index(after: at) != value.endIndex,
              value[..<at].contains("@") == false
        else { return false }
        return value[value.index(after: at)...].contains(".")
    }

    private static func message(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let description = error.localizedDescription
        return description.isEmpty ? "请求失败，请稍后重试" : description
    }
}

private enum AccountViewMetrics {
    static let accessMarkSize: CGFloat = 58
    static let accessContentMaxWidth: CGFloat = 520
    static let accessHorizontalPadding: CGFloat = 24
    static let accessVerticalPadding: CGFloat = 42
    static let accessSectionSpacing: CGFloat = 18
    static let titleSpacing: CGFloat = 5
    static let contentPadding: CGFloat = 6
    static let sectionSpacing: CGFloat = 10
    static let rowSpacing: CGFloat = 9
    static let inlineSpacing: CGFloat = 8
    static let buttonLabelSpacing: CGFloat = 5
    static let labelWidth: CGFloat = 92
    static let codeFieldMaxWidth: CGFloat = 180
    static let primaryActionMinWidth: CGFloat = 110
    static let secondaryActionMinWidth: CGFloat = 112
}

private struct AccountLabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: AccountViewMetrics.inlineSpacing) {
            Text(label)
                .frame(width: AccountViewMetrics.labelWidth, alignment: .leading)
            content
        }
    }
}
