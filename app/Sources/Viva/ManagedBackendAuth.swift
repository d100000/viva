import Foundation
import Combine
import Security
import LocalAuthentication
import Darwin

struct ManagedBackendSession: Sendable {
    let accessToken: String
    let deviceID: String
    let expiresAt: Date
}

enum ManagedAuthPurpose: String, Codable, Sendable {
    case loginOrRegister = "login_or_register"
    case register
    case login
    case recentAuth = "recent_auth"
}

enum ManagedAuthRestorePhase: Equatable, Sendable {
    case idle
    case restoring
    case signedOut
    case signedIn
    case failed(String)
}

struct ManagedAccountUser: Codable, Equatable, Sendable {
    let id: String
    let username: String?
    let deviceId: String
    let keyThumbprint: String?
    let email: String?
    let accountType: String
    let status: String
    let clientName: String?
    let clientPlatform: String?
    let clientVersion: String?
    let clientOsVersion: String?
    let clientOsBuild: String?
    let clientArchitecture: String?
    let clientDeviceModel: String?
    let displayName: String?
    let maxConcurrency: Int?
    let locale: String?
    let timezone: String?
    let passwordUpdatedAt: String?
    let createdAt: String

    var hasPassword: Bool {
        guard let passwordUpdatedAt else { return false }
        return !passwordUpdatedAt.hasPrefix("0001-")
    }
}

struct ManagedWallet: Codable, Equatable, Sendable {
    let availablePoints: Int64
    let reservedPoints: Int64
    let totalCreditedPoints: Int64
    let totalDebitedPoints: Int64
}

struct ManagedPricing: Codable, Equatable, Sendable {
    let version: String
    let pointsPerCny: Int64
    let retailMultiplierBp: Int64
    let fixedRequestPoints: Int64
    let minimumRequestPoints: Int64
    let seedAsrNanoPerHour: Int64
}

struct ManagedCreditBalance: Codable, Equatable, Sendable {
    let wallet: ManagedWallet
    let pricing: ManagedPricing
}

struct ManagedOTPChallenge: Equatable, Sendable {
    let status: String
    let challengeID: String?
    let expiresAt: Date
    /// Legacy decode compatibility only. The current server never returns OTP plaintext.
    let developerCode: String?
}

struct ManagedOTPVerification: Equatable, Sendable {
    let created: Bool
    let user: ManagedAccountUser
    let wallet: ManagedWallet
}

struct ManagedAccountSnapshot: Equatable, Sendable {
    let user: ManagedAccountUser
    let balance: ManagedCreditBalance
}

struct ManagedASRTicket: Equatable, Sendable {
    let ticket: String
    let sessionID: String
    let expiresAt: Date
    let websocketURL: String
}

/// Observable account state for SwiftUI surfaces that need more detail than
/// `VivaAccountProfile`. All mutations are delivered on the main actor.
final class ManagedBackendAuthState: ObservableObject, @unchecked Sendable {
    @Published private(set) var phase: ManagedAuthRestorePhase = .idle
    @Published private(set) var user: ManagedAccountUser?
    @Published private(set) var wallet: ManagedWallet?
    @Published private(set) var pricing: ManagedPricing?
    @Published private(set) var deviceID: String?
    @Published private(set) var origin: String?

    @MainActor
    fileprivate func restoring(origin: String, deviceID: String?) {
        if self.origin != origin { clearAccountData() }
        self.origin = origin
        self.deviceID = deviceID
        phase = .restoring
    }

    @MainActor
    fileprivate func sessionRestored(origin: String, deviceID: String) {
        if self.origin != origin { clearAccountData() }
        self.origin = origin
        self.deviceID = deviceID
        phase = .signedIn
    }

    @MainActor
    fileprivate func authenticated(origin: String, user: ManagedAccountUser,
                                    wallet: ManagedWallet?, pricing: ManagedPricing?) {
        if self.origin != origin { clearAccountData() }
        self.origin = origin
        self.deviceID = user.deviceId
        self.user = user
        if let wallet { self.wallet = wallet }
        if let pricing { self.pricing = pricing }
        phase = .signedIn
    }

    @MainActor
    fileprivate func balanceUpdated(origin: String, balance: ManagedCreditBalance) {
        if self.origin != origin { clearAccountData() }
        self.origin = origin
        wallet = balance.wallet
        pricing = balance.pricing
        phase = .signedIn
    }

    @MainActor
    fileprivate func availablePointsUpdated(origin: String, availablePoints: Int64) {
        guard self.origin == origin, let current = wallet else { return }
        wallet = ManagedWallet(
            availablePoints: availablePoints,
            reservedPoints: current.reservedPoints,
            totalCreditedPoints: current.totalCreditedPoints,
            totalDebitedPoints: current.totalDebitedPoints)
    }

    @MainActor
    fileprivate func signedOut(origin: String) {
        self.origin = origin
        clearAccountData()
        phase = .signedOut
    }

    @MainActor
    fileprivate func failed(origin: String, message: String) {
        if self.origin != origin { clearAccountData() }
        self.origin = origin
        phase = .failed(message)
    }

    @MainActor
    private func clearAccountData() {
        user = nil
        wallet = nil
        pricing = nil
        deviceID = nil
    }
}

/// Owns the complete current server authentication lifecycle.
///
/// The current server contract uses email OTP and short-lived Bearer access tokens. The
/// access token, rotating refresh token, expiry, and device ID are persisted as
/// one atomic value so a refresh can never expose a half-written token pair.
actor ManagedBackendAuth: VivaAccountClient {
    static let shared = ManagedBackendAuth()

    nonisolated let state = ManagedBackendAuthState()

    enum AuthError: LocalizedError, Sendable {
        case invalidEndpoint
        case invalidInput(String)
        case keychain(OSStatus)
        case notLoggedIn
        case invalidResponse
        case server(statusCode: Int, code: String, message: String, requestID: String?)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "Viva 服务地址无效"
            case .invalidInput(let message):
                return message
            case .keychain(let status):
                return "无法访问系统钥匙串（\(status)）"
            case .notLoggedIn:
                return "请先登录 Viva 账户"
            case .invalidResponse:
                return "Viva 服务返回了无法识别的响应"
            case .server(_, let code, let message, let requestID):
                let suffix = requestID.map { " [\(code) request_id=\($0)]" } ?? " [\(code)]"
                return message + suffix
            }
        }
    }

    private struct StoredSession: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var deviceID: String
        /// Persisted before the request. A retry after timeout must reuse it.
        var pendingRefreshID: String?
        var publicValue: ManagedBackendSession {
            ManagedBackendSession(accessToken: accessToken,
                                  deviceID: deviceID,
                                  expiresAt: expiresAt)
        }
    }

    private struct LLMClientOutcomeResponse: Decodable, Sendable {
        let status: String
    }

    private struct OTPResponse: Decodable {
        let status: String
        let challengeId: String?
        let expiresAt: String
        let devCode: String?
    }

    private struct OTPVerifyResponse: Decodable {
        let created: Bool
        let user: ManagedAccountUser
        let credits: ManagedWallet
        let accessToken: String
        let refreshToken: String
        let expiresAt: String
    }

    private struct OTPRequestBody: Encodable {
        let email: String
        let purpose: String
        let deviceID: String
        let clientName: String
        let clientPlatform: String
        let clientVersion: String
        let osVersion: String
        let osBuild: String
        let clientArchitecture: String
        let deviceModel: String
        let locale: String
        let timezone: String
        let webSession: Bool
    }

    private struct OTPVerifyRequest: Encodable {
        let email: String
        let code: String
        let deviceID: String
        let challengeID: String?
        let webSession: Bool
        let rememberMe: Bool
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: String
    }

    private struct PasswordLoginRequest: Encodable {
        let account: String
        let password: String
        let deviceID: String
        let clientName: String
        let clientPlatform: String
        let clientVersion: String
        let osVersion: String
        let osBuild: String
        let clientArchitecture: String
        let deviceModel: String
        let locale: String
        let timezone: String
        let webSession: Bool
        let rememberMe: Bool
    }

    private struct PasswordSetupRequest: Encodable {
        let email: String
        let password: String
        let code: String
        let challengeID: String
        let deviceID: String
        let webSession: Bool
        let rememberMe: Bool
    }

    private struct ASRTicketResponse: Decodable {
        let ticket: String
        let sessionId: String
        let expiresAt: String
        let websocketUrl: String
    }

    private struct ErrorEnvelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
            let requestId: String?
        }
        let error: Body
    }

    private let keychainService = "cn.viva.managed-backend"
    private let installAccount = "install-id"
    private let credentialBackend: CredentialBackend
    private var cachedInstallID: String?
    private var memory: [String: StoredSession] = [:]
    private var refreshFlights: [String: Task<StoredSession, Error>] = [:]

    private let networkDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
    private let networkEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private enum CredentialBackend {
        case keychain
        case local(LocalAuthStore)
    }

    private init() {
        if let selfTestDirectory = Self.selfTestCredentialDirectory() {
            credentialBackend = .local(LocalAuthStore(directoryURL: selfTestDirectory))
            Log.info("登录状态存储：隔离的账户自检目录")
        } else if let teamID = Self.currentTeamIdentifier() {
            credentialBackend = .keychain
            Log.info("登录状态存储：系统钥匙串（Team ID \(teamID)）")
        } else {
            credentialBackend = .local(LocalAuthStore(directoryURL: Config.authDir))
            Log.info("登录状态存储：本机受限文件（当前构建没有 Apple Team ID）")
        }
    }

    // MARK: - AccountView boundary

    func restore() async throws -> VivaAccountProfile? {
        let baseURL = try configuredBaseURL()
        guard let snapshot = try await restore(baseURL: baseURL) else { return nil }
        return Self.accountProfile(user: snapshot.user, wallet: snapshot.balance.wallet)
    }

    func requestOTP(email: String, purpose: ManagedAuthPurpose) async throws -> VivaOTPDelivery {
        let challenge = try await requestOTP(email: email, purpose: purpose,
                                             baseURL: configuredBaseURL())
        return VivaOTPDelivery(resendAfterSeconds: 60,
                               challengeID: challenge.challengeID,
                               developerCode: challenge.developerCode)
    }

    func verifyOTP(email: String, code: String,
                   challengeID: String?) async throws -> VivaAccountProfile {
        let verification = try await verifyOTP(email: email, code: code,
                                               challengeID: challengeID,
                                               baseURL: configuredBaseURL())
        return Self.accountProfile(user: verification.user, wallet: verification.wallet)
    }

    func loginWithPassword(account: String, password: String) async throws -> VivaAccountProfile {
        let verification = try await loginWithPassword(
            account: account, password: password, baseURL: configuredBaseURL())
        return Self.accountProfile(user: verification.user, wallet: verification.wallet)
    }

    func setupPassword(email: String, password: String, code: String,
                       challengeID: String) async throws -> VivaAccountProfile {
        let verification = try await setupPassword(
            email: email, password: password, code: code,
            challengeID: challengeID, baseURL: configuredBaseURL())
        return Self.accountProfile(user: verification.user, wallet: verification.wallet)
    }

    func refreshProfile() async throws -> VivaAccountProfile {
        let snapshot = try await refreshProfile(baseURL: configuredBaseURL())
        return Self.accountProfile(user: snapshot.user, wallet: snapshot.balance.wallet)
    }

    func logout() async throws {
        try await logout(baseURL: configuredBaseURL())
    }

    // MARK: - Explicit service API

    @discardableResult
    func requestOTP(email: String, purpose: ManagedAuthPurpose,
                    baseURL: URL) async throws -> ManagedOTPChallenge {
        let normalizedEmail = try Self.normalizedEmail(email)
        let localDeviceID = try stableDeviceID()
        let metadata = Self.clientMetadata
        let body = try networkEncoder.encode(OTPRequestBody(
            email: normalizedEmail, purpose: purpose.rawValue, deviceID: localDeviceID,
            clientName: metadata.name, clientPlatform: metadata.platform,
            clientVersion: metadata.version, osVersion: metadata.osVersion,
            osBuild: metadata.osBuild ?? "", clientArchitecture: metadata.architecture,
            deviceModel: metadata.deviceModel ?? "", locale: metadata.locale,
            timezone: metadata.timezone, webSession: false))
        let response: OTPResponse = try await send(path: "/v1/auth/otp/request",
                                                   method: "POST", body: body,
                                                   deviceID: localDeviceID,
                                                   baseURL: baseURL)
        guard let expiresAt = Self.parseDate(response.expiresAt) else {
            throw AuthError.invalidResponse
        }
        return ManagedOTPChallenge(status: response.status,
                                   challengeID: response.challengeId,
                                   expiresAt: expiresAt,
                                   developerCode: response.devCode)
    }

    @discardableResult
    func verifyOTP(email: String, code: String, challengeID: String? = nil,
                   baseURL: URL) async throws -> ManagedOTPVerification {
        let normalizedEmail = try Self.normalizedEmail(email)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCode.count == 6, normalizedCode.allSatisfy(\.isNumber) else {
            throw AuthError.invalidInput("请输入 6 位数字验证码")
        }
        let localDeviceID = try stableDeviceID()
        let body = try networkEncoder.encode(OTPVerifyRequest(
            email: normalizedEmail, code: normalizedCode, deviceID: localDeviceID,
            challengeID: challengeID.flatMap { $0.isEmpty ? nil : $0 },
            webSession: false, rememberMe: false))
        let response: OTPVerifyResponse = try await send(path: "/v1/auth/otp/verify",
                                                         method: "POST", body: body,
                                                         deviceID: localDeviceID,
                                                         baseURL: baseURL)
        return try await persistAuthentication(response, localDeviceID: localDeviceID,
                                               baseURL: baseURL)
    }

    @discardableResult
    func loginWithPassword(account: String, password: String,
                           baseURL: URL) async throws -> ManagedOTPVerification {
        let normalizedAccount = try Self.normalizedAccount(account)
        guard !password.isEmpty, password.count <= 128 else {
            throw AuthError.invalidInput("请输入账号密码")
        }
        let localDeviceID = try stableDeviceID()
        let metadata = Self.clientMetadata
        let body = try networkEncoder.encode(PasswordLoginRequest(
            account: normalizedAccount, password: password, deviceID: localDeviceID,
            clientName: metadata.name, clientPlatform: metadata.platform,
            clientVersion: metadata.version,
            osVersion: metadata.osVersion, osBuild: metadata.osBuild ?? "",
            clientArchitecture: metadata.architecture,
            deviceModel: metadata.deviceModel ?? "", locale: metadata.locale,
            timezone: metadata.timezone, webSession: false, rememberMe: false))
        let response: OTPVerifyResponse = try await send(
            path: "/v1/auth/password/login", method: "POST", body: body,
            deviceID: localDeviceID, baseURL: baseURL)
        return try await persistAuthentication(response, localDeviceID: localDeviceID,
                                               baseURL: baseURL)
    }

    @discardableResult
    func setupPassword(email: String, password: String, code: String,
                       challengeID: String,
                       baseURL: URL) async throws -> ManagedOTPVerification {
        let normalizedEmail = try Self.normalizedEmail(email)
        try Self.validateNewPassword(password, email: normalizedEmail)
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCode.count == 6, normalizedCode.allSatisfy(\.isNumber),
              UUID(uuidString: challengeID) != nil else {
            throw AuthError.invalidInput("请输入 6 位数字验证码")
        }
        let localDeviceID = try stableDeviceID()
        let body = try networkEncoder.encode(PasswordSetupRequest(
            email: normalizedEmail, password: password, code: normalizedCode,
            challengeID: challengeID, deviceID: localDeviceID,
            webSession: false, rememberMe: false))
        let response: OTPVerifyResponse = try await send(
            path: "/v1/auth/password/setup", method: "POST", body: body,
            deviceID: localDeviceID, baseURL: baseURL)
        return try await persistAuthentication(response, localDeviceID: localDeviceID,
                                               baseURL: baseURL)
    }

    private func persistAuthentication(_ response: OTPVerifyResponse,
                                       localDeviceID: String,
                                       baseURL: URL) async throws -> ManagedOTPVerification {
        guard let expiresAt = Self.parseDate(response.expiresAt),
              !response.accessToken.isEmpty, !response.refreshToken.isEmpty else {
            throw AuthError.invalidResponse
        }
        let origin = try originString(baseURL)
        let deviceID = response.user.deviceId.isEmpty ? localDeviceID : response.user.deviceId
        let stored = StoredSession(
            accessToken: response.accessToken, refreshToken: response.refreshToken,
            expiresAt: expiresAt, deviceID: deviceID, pendingRefreshID: nil)
        try persist(stored, origin: origin)
        memory[origin] = stored
        await state.authenticated(origin: origin, user: response.user,
                                  wallet: response.credits, pricing: nil)
        return ManagedOTPVerification(created: response.created, user: response.user,
                                      wallet: response.credits)
    }

    /// Restores a saved session and verifies it against `/v1/me` and balance.
    @discardableResult
    func restore(baseURL: URL) async throws -> ManagedAccountSnapshot? {
        let origin = try originString(baseURL)
        let deviceID = try? stableDeviceID()
        await state.restoring(origin: origin, deviceID: deviceID)
        guard try storedSession(origin: origin) != nil else {
            await state.signedOut(origin: origin)
            return nil
        }
        do {
            let user = try await me(baseURL: baseURL)
            let balance = try await balance(baseURL: baseURL)
            let snapshot = ManagedAccountSnapshot(user: user, balance: balance)
            await state.authenticated(origin: origin, user: user,
                                      wallet: balance.wallet, pricing: balance.pricing)
            return snapshot
        } catch AuthError.notLoggedIn {
            await state.signedOut(origin: origin)
            return nil
        } catch {
            await state.failed(origin: origin, message: error.localizedDescription)
            throw error
        }
    }

    func refreshProfile(baseURL: URL) async throws -> ManagedAccountSnapshot {
        guard let snapshot = try await restore(baseURL: baseURL) else {
            throw AuthError.notLoggedIn
        }
        return snapshot
    }

    func me(baseURL: URL) async throws -> ManagedAccountUser {
        let user: ManagedAccountUser = try await authorized(path: "/v1/me", baseURL: baseURL)
        let origin = try originString(baseURL)
        await state.authenticated(origin: origin, user: user,
                                  wallet: nil, pricing: nil)
        return user
    }

    func balance(baseURL: URL) async throws -> ManagedCreditBalance {
        let balance: ManagedCreditBalance = try await authorized(
            path: "/v1/credits/balance", baseURL: baseURL)
        let origin = try originString(baseURL)
        await state.balanceUpdated(origin: origin, balance: balance)
        return balance
    }

    func createASRTicket(baseURL: URL) async throws -> ManagedASRTicket {
        let body = Data("{}".utf8)
        let response: ASRTicketResponse = try await authorized(
            path: "/v1/asr/tickets", method: "POST", body: body, baseURL: baseURL)
        guard !response.ticket.isEmpty, !response.sessionId.isEmpty,
              !response.websocketUrl.isEmpty,
              let expiresAt = Self.parseDate(response.expiresAt) else {
            throw AuthError.invalidResponse
        }
        return ManagedASRTicket(ticket: response.ticket,
                                sessionID: response.sessionId,
                                expiresAt: expiresAt,
                                websocketURL: response.websocketUrl)
    }

    /// User initiated logout always removes local credentials, even if the
    /// server is offline. The remote error is still surfaced to the caller.
    func logout(baseURL: URL) async throws {
        let origin = try originString(baseURL)
        var remoteError: Error?
        if try storedSession(origin: origin) != nil {
            do {
                try await authorizedWithoutResponse(
                    path: "/v1/auth/logout", method: "POST",
                    body: Data("{}".utf8), baseURL: baseURL)
            } catch {
                remoteError = error
            }
        }
        try clearSession(origin: origin)
        await state.signedOut(origin: origin)
        if let remoteError { throw remoteError }
    }

    func stableDeviceID() throws -> String {
        if let cachedInstallID { return cachedInstallID }
        if let data = try read(account: installAccount),
           let value = String(data: data, encoding: .utf8),
           let identifier = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let normalized = identifier.uuidString.lowercased()
            cachedInstallID = normalized
            return normalized
        }
        let value = UUID().uuidString.lowercased()
        try write(Data(value.utf8), account: installAccount)
        cachedInstallID = value
        return value
    }

    // MARK: - Bearer session

    func session(for baseURL: URL) async throws -> ManagedBackendSession {
        let origin = try originString(baseURL)
        return try await activeSession(baseURL: baseURL, origin: origin).publicValue
    }

    private func activeSession(baseURL: URL, origin: String) async throws -> StoredSession {
        guard let current = try storedSession(origin: origin) else {
            await state.signedOut(origin: origin)
            throw AuthError.notLoggedIn
        }
        if current.expiresAt.timeIntervalSinceNow > 90 {
            await state.sessionRestored(origin: origin, deviceID: current.deviceID)
            return current
        }
        return try await refreshSingleFlight(baseURL: baseURL, origin: origin)
    }

    /// Applies the authoritative post-billing balance returned by LLM SSE/JSON.
    func recordAvailablePoints(_ value: Int64, baseURL: URL) async throws {
        let origin = try originString(baseURL)
        await state.availablePointsUpdated(origin: origin, availablePoints: value)
    }

    /// Reports what happened after the server wrote an LLM response. Provider
    /// success and actual user-visible application are different outcomes, so
    /// this callback is intentionally best-effort and never affects dictation.
    func reportLLMOutcome(requestID: String, outcome: String, detail: String,
                          clientElapsedMS: Int, timeoutBudgetMS: Int,
                          baseURL: URL) async throws {
        let normalizedID = requestID.lowercased()
        guard normalizedID.count == 36, UUID(uuidString: normalizedID) != nil else {
            throw AuthError.invalidInput("大模型请求标识无效")
        }
        let allowedOutcomes = ["received", "applied", "fallback", "timeout", "cancelled", "rejected"]
        guard allowedOutcomes.contains(outcome) else {
            throw AuthError.invalidInput("大模型客户端结果无效")
        }
        let payload: [String: Any] = [
            "outcome": outcome,
            "detail": String(detail.prefix(160)),
            "client_elapsed_ms": max(0, min(clientElapsedMS, 10 * 60 * 1000)),
            "timeout_budget_ms": max(0, min(timeoutBudgetMS, 120_000)),
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let _: LLMClientOutcomeResponse = try await authorized(
            path: "/v1/llm-requests/\(normalizedID)/client-outcome",
            method: "POST", body: body, baseURL: baseURL)
    }

    @discardableResult
    func refreshNow(baseURL: URL) async throws -> ManagedBackendSession {
        let origin = try originString(baseURL)
        return try await refreshSingleFlight(baseURL: baseURL, origin: origin).publicValue
    }

    private func refreshSingleFlight(baseURL: URL, origin: String) async throws -> StoredSession {
        if let existing = refreshFlights[origin] {
            return try await existing.value
        }
        guard var current = try storedSession(origin: origin),
              !current.refreshToken.isEmpty else {
            await state.signedOut(origin: origin)
            throw AuthError.notLoggedIn
        }
        if current.pendingRefreshID == nil {
            current.pendingRefreshID = UUID().uuidString.lowercased()
            try persist(current, origin: origin)
            memory[origin] = current
        }

        let task = Task {
            try await self.refreshAndPersist(current, baseURL: baseURL, origin: origin)
        }
        refreshFlights[origin] = task
        do {
            let refreshed = try await task.value
            refreshFlights.removeValue(forKey: origin)
            return refreshed
        } catch {
            refreshFlights.removeValue(forKey: origin)
            throw error
        }
    }

    private func refreshAndPersist(_ current: StoredSession, baseURL: URL,
                                   origin: String) async throws -> StoredSession {
        guard let idempotencyKey = current.pendingRefreshID else {
            throw AuthError.invalidResponse
        }
        let body = try networkEncoder.encode(["refresh_token": current.refreshToken])
        do {
            let response: TokenResponse = try await send(
                path: "/v1/auth/refresh", method: "POST", body: body,
                deviceID: current.deviceID,
                headers: ["Idempotency-Key": idempotencyKey], baseURL: baseURL)
            guard let expiresAt = Self.parseDate(response.expiresAt),
                  !response.accessToken.isEmpty, !response.refreshToken.isEmpty else {
                throw AuthError.invalidResponse
            }
            let refreshed = StoredSession(
                accessToken: response.accessToken, refreshToken: response.refreshToken,
                expiresAt: expiresAt, deviceID: current.deviceID,
                pendingRefreshID: nil)
            try persist(refreshed, origin: origin)
            memory[origin] = refreshed
            await state.sessionRestored(origin: origin, deviceID: refreshed.deviceID)
            return refreshed
        } catch let error as AuthError {
            if case .server(_, let code, _, _) = error,
               code == "INVALID_REFRESH_TOKEN" {
                try? clearSession(origin: origin)
                await state.signedOut(origin: origin)
                throw AuthError.notLoggedIn
            }
            // Network/5xx failures keep the old token and fixed idempotency key.
            throw error
        }
    }

    // MARK: - Authorized HTTP

    private func authorized<Response: Decodable>(path: String, method: String = "GET",
                                                  body: Data? = nil,
                                                  baseURL: URL) async throws -> Response {
        guard let url = append(path, to: baseURL) else { throw AuthError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, _) = try await authorizedData(for: request, baseURL: baseURL)
        guard let decoded = try? networkDecoder.decode(Response.self, from: data) else {
            throw AuthError.invalidResponse
        }
        return decoded
    }

    private func authorizedWithoutResponse(path: String, method: String,
                                           body: Data?, baseURL: URL) async throws {
        guard let url = append(path, to: baseURL) else { throw AuthError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        _ = try await authorizedData(for: request, baseURL: baseURL)
    }

    func authorizedData(for original: URLRequest,
                        baseURL: URL) async throws -> (Data, HTTPURLResponse) {
        guard let url = original.url else { throw AuthError.invalidEndpoint }
        try validateTarget(url, belongsTo: baseURL)
        let origin = try originString(baseURL)
        let current = try await activeSession(baseURL: baseURL, origin: origin)

        let firstRequest = try prepareAuthorizedRequest(original, session: current)
        let (firstData, firstResponse) = try await URLSession.shared.data(for: firstRequest)
        guard let firstHTTP = firstResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        if (200...299).contains(firstHTTP.statusCode) { return (firstData, firstHTTP) }

        let firstError = serverError(
            response: firstHTTP, data: firstData, path: url.path)
        let retrySession = try await recoverySession(
            after: firstError, baseURL: baseURL, origin: origin)
        let retryRequest = try prepareAuthorizedRequest(original, session: retrySession)
        let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        if (200...299).contains(retryHTTP.statusCode) { return (retryData, retryHTTP) }

        let retryError = serverError(
            response: retryHTTP, data: retryData, path: url.path)
        try await handleTerminalAuthorizationFailure(retryError, origin: origin)
        throw retryError
    }

    func authorizedBytes(for original: URLRequest,
                         baseURL: URL) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        guard let url = original.url else { throw AuthError.invalidEndpoint }
        try validateTarget(url, belongsTo: baseURL)
        let origin = try originString(baseURL)
        let current = try await activeSession(baseURL: baseURL, origin: origin)

        let firstRequest = try prepareAuthorizedRequest(original, session: current)
        let (firstBytes, firstResponse) = try await URLSession.shared.bytes(for: firstRequest)
        guard let firstHTTP = firstResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        if (200...299).contains(firstHTTP.statusCode) { return (firstBytes, firstHTTP) }

        let firstData = try await collectErrorBody(firstBytes)
        let firstError = serverError(
            response: firstHTTP, data: firstData, path: url.path)
        let retrySession = try await recoverySession(
            after: firstError, baseURL: baseURL, origin: origin)
        let retryRequest = try prepareAuthorizedRequest(original, session: retrySession)
        let (retryBytes, retryResponse) = try await URLSession.shared.bytes(for: retryRequest)
        guard let retryHTTP = retryResponse as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        if (200...299).contains(retryHTTP.statusCode) { return (retryBytes, retryHTTP) }

        let retryData = try await collectErrorBody(retryBytes)
        let retryError = serverError(
            response: retryHTTP, data: retryData, path: url.path)
        try await handleTerminalAuthorizationFailure(retryError, origin: origin)
        throw retryError
    }

    private func collectErrorBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        data.reserveCapacity(1024)
        for try await byte in bytes where data.count < 64 * 1024 {
            data.append(byte)
        }
        return data
    }

    private func prepareAuthorizedRequest(_ original: URLRequest,
                                          session: StoredSession) throws -> URLRequest {
        guard original.url != nil else { throw AuthError.invalidEndpoint }
        var request = original
        request.setValue(nil, forHTTPHeaderField: "DPoP")
        for (name, value) in Self.clientMetadataHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(session.deviceID, forHTTPHeaderField: "X-Viva-Device-ID")
        request.setValue("1", forHTTPHeaderField: "X-Viva-Protocol-Version")
        return request
    }

    private func recoverySession(after error: AuthError, baseURL: URL,
                                 origin: String) async throws -> StoredSession {
        guard case .server(let statusCode, let code, _, _) = error else { throw error }
        if statusCode == 403, code == "ACCOUNT_UNAVAILABLE" {
            try? clearSession(origin: origin)
            await state.signedOut(origin: origin)
            throw error
        }
        guard statusCode == 401 else { throw error }

        switch code {
        case "UNAUTHORIZED":
            return try await refreshSingleFlight(baseURL: baseURL, origin: origin)
        default:
            throw error
        }
    }

    private func handleTerminalAuthorizationFailure(_ error: AuthError,
                                                    origin: String) async throws {
        guard case .server(let statusCode, let code, _, _) = error else { return }
        if statusCode == 403, code == "ACCOUNT_UNAVAILABLE" {
            try? clearSession(origin: origin)
            await state.signedOut(origin: origin)
            return
        }
        guard statusCode == 401 else { return }
        switch code {
        case "UNAUTHORIZED":
            try? clearSession(origin: origin)
            await state.signedOut(origin: origin)
            throw AuthError.notLoggedIn
        default:
            break
        }
    }

    private func send<Response: Decodable>(path: String, method: String,
                                           body: Data? = nil,
                                           deviceID: String? = nil,
                                           headers: [String: String] = [:],
                                           baseURL: URL) async throws -> Response {
        guard let url = append(path, to: baseURL) else { throw AuthError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in Self.clientMetadataHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let deviceID = deviceID ?? (try? stableDeviceID()) {
            request.setValue(deviceID, forHTTPHeaderField: "X-Viva-Device-ID")
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw serverError(response: http, data: data, path: path)
        }
        do {
            return try networkDecoder.decode(Response.self, from: data)
        } catch {
            throw AuthError.invalidResponse
        }
    }

    private func serverError(response: HTTPURLResponse, data: Data,
                             path: String) -> AuthError {
        let envelope = try? networkDecoder.decode(ErrorEnvelope.self, from: data)
        let code = envelope?.error.code ?? "HTTP_\(response.statusCode)"
        let message = envelope?.error.message ?? "Viva 服务请求失败"
        let requestID = envelope?.error.requestId
            ?? response.value(forHTTPHeaderField: "X-Request-ID")
        Log.warn("Viva API \(path) HTTP \(response.statusCode) code=\(code)"
                 + (requestID.map { " request_id=\($0)" } ?? ""))
        return AuthError.server(statusCode: response.statusCode, code: code,
                                message: message, requestID: requestID)
    }

    // MARK: - Credential storage

    private func storedSession(origin: String) throws -> StoredSession? {
        if let current = memory[origin] { return current }
        guard let data = try read(account: sessionAccount(origin)) else { return nil }
        guard let value = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            // Removes obsolete pre-email-auth records that cannot satisfy this contract.
            try? delete(account: sessionAccount(origin))
            return nil
        }
        memory[origin] = value
        return value
    }

    private func persist(_ value: StoredSession, origin: String) throws {
        let data = try JSONEncoder().encode(value)
        try write(data, account: sessionAccount(origin))
    }

    private func clearSession(origin: String) throws {
        memory.removeValue(forKey: origin)
        try delete(account: sessionAccount(origin))
    }

    private func sessionAccount(_ origin: String) -> String { "session:\(origin)" }

    private func read(account: String) throws -> Data? {
        switch credentialBackend {
        case .keychain:
            return try readKeychain(account: account)
        case .local(let store):
            return try store.read(account: account)
        }
    }

    private func write(_ data: Data, account: String) throws {
        switch credentialBackend {
        case .keychain:
            try writeKeychain(data, account: account)
        case .local(let store):
            try store.write(data, account: account)
        }
    }

    private func delete(account: String) throws {
        switch credentialBackend {
        case .keychain:
            try deleteKeychain(account: account)
        case .local(let store):
            try store.delete(account: account)
        }
    }

    private func readKeychain(account: String) throws -> Data? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        if Self.isNonInteractiveKeychainFailure(status) {
            Log.warn("旧钥匙串登录状态不可静默读取，等待用户重新登录")
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AuthError.keychain(status)
        }
        return data
    }

    private func writeKeychain(_ data: Data, account: String) throws {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        query[kSecUseAuthenticationContext as String] = context
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecItemNotFound {
            try addKeychain(data, account: account)
        } else if Self.isNonInteractiveKeychainFailure(updated) {
            deleteLegacyKeychainItem(account: account)
            try addKeychain(data, account: account)
        } else if updated != errSecSuccess {
            throw AuthError.keychain(updated)
        }
    }

    private func addKeychain(_ data: Data, account: String) throws {
        let inserted: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(inserted as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthError.keychain(status) }
    }

    private func deleteKeychain(account: String) throws {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychain(status)
        }
    }

    private func deleteLegacyKeychainItem(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            Log.warn("清理旧钥匙串登录状态失败（\(status)）")
        }
    }

    private static func isNonInteractiveKeychainFailure(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed
            || status == errSecAuthFailed
            || status == errSecUserCanceled
    }

    private static func currentTeamIdentifier() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            executableURL as CFURL,
            SecCSFlags(rawValue: 0),
            &code) == errSecSuccess,
              let code else {
            return nil
        }
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &information)
        guard status == errSecSuccess,
              let values = information as? [String: Any],
              let teamID = values[kSecCodeInfoTeamIdentifier as String] as? String,
              !teamID.isEmpty else {
            return nil
        }
        return teamID
    }

    /// Account self-tests must never read, replace, or log out the real user's
    /// saved session. The override is accepted only for the two explicit
    /// account-test commands and only inside /tmp.
    private static func selfTestCredentialDirectory() -> URL? {
        let args = CommandLine.arguments
        guard args.contains("--account-selftest")
                || args.contains("--account-restore-selftest"),
              let raw = ProcessInfo.processInfo.environment["VIVA_SELFTEST_AUTH_DIR"],
              !raw.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
        guard url.path == "/tmp" || url.path.hasPrefix("/tmp/") else { return nil }
        return url
    }

    // MARK: - Helpers

    private func configuredBaseURL() throws -> URL {
        guard let baseURL = Config.load().backendBaseURL else {
            throw AuthError.invalidEndpoint
        }
        return baseURL
    }

    private func append(_ path: String, to baseURL: URL) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/" + path.split(separator: "/").joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func originString(_ url: URL) throws -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            throw AuthError.invalidEndpoint
        }
        let renderedHost = host.contains(":") ? "[\(host)]" : host
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(renderedHost)\(port)"
    }

    private func validateTarget(_ target: URL, belongsTo baseURL: URL) throws {
        guard let targetComponents = URLComponents(url: target, resolvingAgainstBaseURL: false),
              let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              targetComponents.host?.lowercased() == baseComponents.host?.lowercased(),
              targetComponents.port == baseComponents.port else {
            throw AuthError.invalidEndpoint
        }
        let targetScheme = targetComponents.scheme?.lowercased()
        let baseScheme = baseComponents.scheme?.lowercased()
        let validScheme = targetScheme == baseScheme
            || (baseScheme == "http" && targetScheme == "ws")
            || (baseScheme == "https" && targetScheme == "wss")
        guard validScheme else { throw AuthError.invalidEndpoint }
    }

    private static func normalizedEmail(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.contains("@"), value.utf8.count <= 320 else {
            throw AuthError.invalidInput("请输入有效的邮箱地址")
        }
        return value
    }

    private static func normalizedAccount(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.utf8.count <= 320,
              !value.contains(where: \Character.isWhitespace) else {
            throw AuthError.invalidInput("请输入账号或邮箱")
        }
        return value
    }

    private static func validateNewPassword(_ password: String, email: String) throws {
        guard password.count >= 8, password.count <= 128,
              !password.contains("\n"), !password.contains("\r"),
              !password.contains("\0") else {
            throw AuthError.invalidInput("密码需为 8–128 个字符")
        }
        let localPart = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        if localPart.count >= 3,
           password.localizedCaseInsensitiveContains(localPart) {
            throw AuthError.invalidInput("密码不能包含邮箱 @ 前的账号部分")
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = fractional.date(from: raw) { return value }
        return ISO8601DateFormatter().date(from: raw)
    }

    private static func accountProfile(user: ManagedAccountUser,
                                       wallet: ManagedWallet) -> VivaAccountProfile {
        VivaAccountProfile(email: user.email ?? "", credits: wallet.availablePoints,
                           hasPassword: user.hasPassword)
    }

    private static var clientVersion: String {
        let release = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let normalizedRelease = release?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBuild = build?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedRelease, !normalizedRelease.isEmpty,
           let normalizedBuild, !normalizedBuild.isEmpty,
           normalizedBuild != normalizedRelease {
            return "\(normalizedRelease)+\(normalizedBuild)"
        }
        if let normalizedRelease, !normalizedRelease.isEmpty {
            return normalizedRelease
        }
        return "0.0.0"
    }

    /// Non-sensitive compatibility metadata only. Never add serial numbers,
    /// MAC addresses, computer names, local usernames, or a client-reported IP.
    private struct ClientMetadata {
        let name = "Viva"
        let platform = "macos"
        let version: String
        let osVersion: String
        let osBuild: String?
        let architecture: String
        let deviceModel: String?
        let locale: String
        let timezone: String
    }

    private static var clientMetadata: ClientMetadata {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ClientMetadata(
            version: clientVersion,
            osVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            osBuild: systemValue("kern.osversion"),
            architecture: clientArchitecture,
            deviceModel: systemValue("hw.model"),
            locale: Locale.preferredLanguages.first
                ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            timezone: TimeZone.current.identifier)
    }

    private static var clientMetadataHeaders: [String: String] {
        let metadata = clientMetadata
        var headers = [
            "X-Viva-Client-Name": metadata.name,
            "X-Viva-Client-Platform": metadata.platform,
            "X-Viva-Client-Version": metadata.version,
            "X-Viva-OS-Version": metadata.osVersion,
            "X-Viva-Client-Architecture": metadata.architecture,
            "X-Viva-Locale": metadata.locale,
            "X-Viva-Timezone": metadata.timezone,
            "User-Agent": userAgent,
        ]
        if let osBuild = metadata.osBuild {
            headers["X-Viva-OS-Build"] = osBuild
        }
        if let deviceModel = metadata.deviceModel {
            headers["X-Viva-Device-Model"] = deviceModel
        }
        return headers
    }

    private static var clientArchitecture: String {
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }

    private static func systemValue(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0,
              size > 1, size <= 256 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static var userAgent: String {
        "Viva/\(clientVersion) (macOS)"
    }
}
