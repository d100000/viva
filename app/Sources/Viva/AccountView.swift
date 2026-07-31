import SwiftUI

struct VivaAccountProfile: Equatable, Sendable {
    let email: String
    let credits: Int64
    let hasPassword: Bool

    init(email: String, credits: Int64, hasPassword: Bool = false) {
        self.email = email
        self.credits = credits
        self.hasPassword = hasPassword
    }
}

struct VivaOTPDelivery: Equatable, Sendable {
    let resendAfterSeconds: Int
    let challengeID: String?
    let developerCode: String?

    init(resendAfterSeconds: Int = 60, challengeID: String? = nil,
         developerCode: String? = nil) {
        self.resendAfterSeconds = resendAfterSeconds
        self.challengeID = challengeID
        self.developerCode = developerCode
    }
}

/// Small account boundary for SwiftUI. ManagedBackendAuth can conform once the
/// server account endpoints are available without coupling this view to HTTP.
protocol VivaAccountClient: Sendable {
    func restore() async throws -> VivaAccountProfile?
    func requestOTP(email: String, purpose: ManagedAuthPurpose) async throws -> VivaOTPDelivery
    func verifyOTP(email: String, code: String,
                   challengeID: String?) async throws -> VivaAccountProfile
    func loginWithPassword(email: String, password: String) async throws -> VivaAccountProfile
    func setupPassword(email: String, password: String, code: String,
                       challengeID: String) async throws -> VivaAccountProfile
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
                    Text("支持邮箱验证码或账号密码登录。")
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
    @State private var revealsPassword = false

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
        if model.stage == .verification {
            verificationEntry
        } else if model.isSettingUpPassword {
            passwordSetupEntry
        } else {
            loginEntry
        }
    }

    private var loginEntry: some View {
        VStack(alignment: .leading, spacing: AccountViewMetrics.sectionSpacing) {
            Picker("登录方式", selection: $model.signInMethod) {
                ForEach(VivaAccountViewModel.SignInMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.isBusy)
            .onChange(of: model.signInMethod) { _, _ in
                revealsPassword = false
                model.signInMethodDidChange()
            }

            switch model.signInMethod {
            case .otp:
                emailEntry
            case .password:
                passwordLoginEntry
            }
        }
    }

    private var emailEntry: some View {
        VStack(alignment: .leading, spacing: AccountViewMetrics.rowSpacing) {
            AccountLabeledRow("邮箱") {
                TextField("name@example.com", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .disabled(model.isBusy)
                    .onChange(of: model.email) { _, _ in
                        model.emailDidChange()
                    }
                    .onSubmit {
                        guard model.canRequestOTP else { return }
                        Task { await model.requestOTP(purpose: .loginOrRegister) }
                    }
            }

            Text("新邮箱会自动注册，已有账户会直接登录。Viva 不会索取 Mac 系统密码；验证一次后会在本机保持登录。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    Task { await model.requestOTP(purpose: .loginOrRegister) }
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

    private var passwordLoginEntry: some View {
        VStack(alignment: .leading, spacing: AccountViewMetrics.rowSpacing) {
            AccountLabeledRow("邮箱") {
                TextField("name@example.com", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .disabled(model.isBusy)
                    .onChange(of: model.email) { _, _ in model.emailDidChange() }
            }

            passwordRow(label: "密码", text: $model.password)
                .onSubmit {
                    guard model.canLoginWithPassword else { return }
                    Task { await model.loginWithPassword() }
                }

            HStack(spacing: AccountViewMetrics.inlineSpacing) {
                Button {
                    Task { await model.loginWithPassword() }
                } label: {
                    operationLabel(isRunning: model.isPasswordLogin,
                                   title: "登录",
                                   systemImage: "arrow.right.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canLoginWithPassword)

                Button("忘记密码") {
                    revealsPassword = false
                    model.beginPasswordSetup(.recovery)
                }
                .disabled(model.isBusy)

                Spacer()
            }

            HStack(spacing: AccountViewMetrics.inlineSpacing) {
                Text("还没有账号？")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    revealsPassword = false
                    model.beginPasswordSetup(.registration)
                } label: {
                    Label("注册账号", systemImage: "person.badge.plus")
                }
                .buttonStyle(.link)
                .disabled(model.isBusy)
                Spacer()
            }
        }
    }

    private var passwordSetupEntry: some View {
        VStack(alignment: .leading, spacing: AccountViewMetrics.rowSpacing) {
            HStack {
                Label(model.passwordSetupTitle,
                      systemImage: model.isRecoveringPassword ? "key" : "person.badge.plus")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("返回登录") {
                    revealsPassword = false
                    model.cancelPasswordSetup()
                }
                    .controlSize(.small)
                    .disabled(model.isBusy)
            }

            AccountLabeledRow("邮箱") {
                TextField("name@example.com", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .disabled(model.isBusy)
                    .onChange(of: model.email) { _, _ in model.emailDidChange() }
            }

            passwordRow(label: "密码", text: $model.password, isNewPassword: true)
            passwordRow(label: "确认密码", text: $model.passwordConfirmation,
                        isNewPassword: true)

            Text("密码需为 15–128 个字符，可使用密码管理器生成，不能包含邮箱 @ 前的账号部分。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    Task { await model.requestPasswordSetupOTP() }
                } label: {
                    operationLabel(isRunning: model.isRequestingOTP,
                                   title: "发送验证码",
                                   systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canRequestPasswordSetupOTP)
                Spacer()
            }
        }
    }

    private func passwordRow(label: String, text: Binding<String>,
                             isNewPassword: Bool = false) -> some View {
        AccountLabeledRow(label) {
            HStack(spacing: AccountViewMetrics.inlineSpacing) {
                Group {
                    if revealsPassword {
                        TextField("密码", text: text)
                    } else {
                        SecureField("密码", text: text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .textContentType(isNewPassword ? .newPassword : .password)
                .disabled(model.isBusy)
                .onChange(of: text.wrappedValue) { _, _ in model.passwordDidChange() }

                Button {
                    revealsPassword.toggle()
                } label: {
                    Image(systemName: revealsPassword ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(revealsPassword ? "隐藏密码" : "显示密码")
                .disabled(model.isBusy)
                .accessibilityLabel(revealsPassword ? "隐藏密码" : "显示密码")
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
                    .textContentType(.oneTimeCode)
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
                                   title: model.verificationActionTitle,
                                   systemImage: "person.badge.key")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canVerify)

                Button(model.resendSeconds > 0
                       ? "\(model.resendSeconds) 秒后可重发"
                       : "重新发送") {
                    Task { await model.resendOTP() }
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

            AccountLabeledRow("登录方式") {
                Text(profile.hasPassword ? "邮箱验证码或密码" : "邮箱验证码")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    enum Stage: Equatable {
        case email
        case verification
    }

    enum SignInMethod: String, CaseIterable, Identifiable {
        case otp
        case password

        var id: String { rawValue }
        var title: String {
            switch self {
            case .otp: return "验证码登录"
            case .password: return "密码登录"
            }
        }
    }

    enum PasswordSetupKind: Equatable {
        case registration
        case recovery

        var purpose: ManagedAuthPurpose {
            switch self {
            case .registration: return .register
            case .recovery: return .recentAuth
            }
        }
    }

    private enum Operation {
        case restore
        case requestOTP
        case passwordLogin
        case verify
        case refresh
        case logout
    }

    @Published var email = ""
    @Published var code = ""
    @Published var password = ""
    @Published var passwordConfirmation = ""
    @Published var signInMethod: SignInMethod = .otp
    @Published private(set) var pendingEmail = ""
    @Published private(set) var profile: VivaAccountProfile?
    @Published private(set) var stage: Stage = .email
    @Published private(set) var errorMessage: String?
    @Published private(set) var resendSeconds = 0
    @Published private(set) var developerCode: String?
    @Published private(set) var passwordSetupKind: PasswordSetupKind?

    private let client: any VivaAccountClient
    private let showsDeveloperCode: Bool
    private let onProfileChange: (VivaAccountProfile?) -> Void
    private var operation: Operation?
    private var didAttemptRestore = false
    private var countdownTask: Task<Void, Never>?
    private var challengeID: String?
    private var pendingPurpose: ManagedAuthPurpose = .loginOrRegister

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
    var isPasswordLogin: Bool { operation == .passwordLogin }
    var isVerifying: Bool { operation == .verify }
    var isRefreshing: Bool { operation == .refresh }
    var isLoggingOut: Bool { operation == .logout }
    var isSettingUpPassword: Bool { passwordSetupKind != nil }
    var isRecoveringPassword: Bool { passwordSetupKind == .recovery }

    var passwordSetupTitle: String {
        isRecoveringPassword ? "重设密码" : "注册账号"
    }

    var verificationActionTitle: String {
        switch passwordSetupKind {
        case .registration: return "完成注册"
        case .recovery: return "重设密码"
        case nil: return "登录或注册"
        }
    }

    var canRequestOTP: Bool {
        !isBusy && Self.isPlausibleEmail(normalizedEmail)
    }

    var canLoginWithPassword: Bool {
        !isBusy && Self.isPlausibleEmail(normalizedEmail)
            && !password.isEmpty && password.count <= 128
    }

    var canRequestPasswordSetupOTP: Bool {
        !isBusy && passwordSetupKind != nil
            && Self.isPlausibleEmail(normalizedEmail)
            && !password.isEmpty && !passwordConfirmation.isEmpty
    }

    var canVerify: Bool {
        !isBusy && pendingEmail.count > 0 && code.count == 6
            && code.allSatisfy(\.isNumber)
            && (!isSettingUpPassword || challengeID != nil)
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

    func requestOTP(purpose: ManagedAuthPurpose) async {
        guard !isBusy else { return }
        let target = normalizedEmail
        guard Self.isPlausibleEmail(target) else {
            errorMessage = "请输入有效的邮箱地址"
            return
        }
        if purpose == .register || purpose == .recentAuth,
           let passwordError = passwordValidationError(email: target) {
            errorMessage = passwordError
            return
        }

        operation = .requestOTP
        errorMessage = nil
        defer { operation = nil }

        do {
            let delivery = try await client.requestOTP(email: target, purpose: purpose)
            if purpose == .register || purpose == .recentAuth,
               delivery.challengeID == nil {
                errorMessage = "当前 Viva 服务不支持密码注册，请更新服务后重试"
                return
            }
            email = target
            pendingEmail = target
            pendingPurpose = purpose
            challengeID = delivery.challengeID
            code = ""
            stage = .verification
            developerCode = showsDeveloperCode ? delivery.developerCode : nil
            startCountdown(seconds: delivery.resendAfterSeconds)
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    func requestPasswordSetupOTP() async {
        guard let passwordSetupKind else { return }
        await requestOTP(purpose: passwordSetupKind.purpose)
    }

    func resendOTP() async {
        await requestOTP(purpose: pendingPurpose)
    }

    func loginWithPassword() async {
        guard !isBusy else { return }
        let target = normalizedEmail
        guard Self.isPlausibleEmail(target), !password.isEmpty else {
            errorMessage = "请输入邮箱和密码"
            return
        }

        operation = .passwordLogin
        errorMessage = nil
        defer { operation = nil }

        do {
            let verified = try await client.loginWithPassword(
                email: target, password: password)
            completeAuthentication(verified)
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
            let verified: VivaAccountProfile
            if passwordSetupKind != nil {
                guard let challengeID else {
                    errorMessage = "验证码挑战已失效，请重新发送"
                    return
                }
                verified = try await client.setupPassword(
                    email: pendingEmail, password: password, code: code,
                    challengeID: challengeID)
            } else {
                verified = try await client.verifyOTP(
                    email: pendingEmail, code: code, challengeID: challengeID)
            }
            completeAuthentication(verified)
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
        resetAuthenticationForm(resetMethod: true)
        onProfileChange(nil)
    }

    func beginPasswordSetup(_ kind: PasswordSetupKind) {
        guard !isBusy else { return }
        resetPendingChallenge()
        password = ""
        passwordConfirmation = ""
        passwordSetupKind = kind
        signInMethod = .password
        stage = .email
        errorMessage = nil
    }

    func cancelPasswordSetup() {
        guard !isBusy else { return }
        resetPendingChallenge()
        password = ""
        passwordConfirmation = ""
        passwordSetupKind = nil
        signInMethod = .password
        stage = .email
        errorMessage = nil
    }

    func signInMethodDidChange() {
        guard !isBusy else { return }
        resetPendingChallenge()
        passwordSetupKind = nil
        password = ""
        passwordConfirmation = ""
        stage = .email
        errorMessage = nil
    }

    func changeEmail() {
        guard !isBusy else { return }
        resetPendingChallenge()
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

    func passwordDidChange() {
        if stage == .email, !isBusy { errorMessage = nil }
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func completeAuthentication(_ verified: VivaAccountProfile) {
        profile = verified
        email = verified.email
        password = ""
        passwordConfirmation = ""
        passwordSetupKind = nil
        resetPendingChallenge()
        onProfileChange(verified)
    }

    private func resetAuthenticationForm(resetMethod: Bool) {
        resetPendingChallenge()
        password = ""
        passwordConfirmation = ""
        passwordSetupKind = nil
        stage = .email
        if resetMethod { signInMethod = .otp }
    }

    private func resetPendingChallenge() {
        countdownTask?.cancel()
        resendSeconds = 0
        code = ""
        pendingEmail = ""
        developerCode = nil
        challengeID = nil
        pendingPurpose = .loginOrRegister
    }

    private func passwordValidationError(email: String) -> String? {
        guard password.count >= 15, password.count <= 128,
              !password.contains("\n"), !password.contains("\r"),
              !password.contains("\0") else {
            return "密码需为 15–128 个字符"
        }
        guard password == passwordConfirmation else {
            return "两次输入的密码不一致"
        }
        let localPart = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        if localPart.count >= 3,
           password.localizedCaseInsensitiveContains(localPart) {
            return "密码不能包含邮箱 @ 前的账号部分"
        }
        return nil
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
