import Foundation
import SwiftUI
import AVFoundation

/// 全局可观察状态。UI 只读这里，业务逻辑只写这里。
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    // ── 配置 ──
    @Published var config: Config = Config.load()

    // ── 权限 ──
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var secureInputOn = false
    @Published var hotkeyHealthy = false
    @Published var audioEngineReady = false

    // ── 实时识别 ──
    @Published var isListening = false
    @Published var committed = ""
    @Published var partial = ""
    @Published var level: Float = 0

    // ── 润色 ──
    @Published var isPolishing = false
    /// 润色的结果提示（成功/失败/被护栏拦下）
    @Published var polishNote = ""

    // ── 润色连通性自测 ──
    @Published var polishTestRunning = false
    @Published var polishTestOutput: String?
    @Published var polishTestError: String?
    @Published var polishTestMs: Int?
    @Published var polishTestLeaked = false

    /// 用一段固定的「脏」文本试一次润色，把结果直接给用户看。
    /// 没有这个按钮，用户配错了要等到真正说话才知道 —— 体验太差。
    func runPolishTest() {
        guard !polishTestRunning else { return }
        polishTestRunning = true
        polishTestOutput = nil; polishTestError = nil
        polishTestMs = nil; polishTestLeaked = false

        let sample = "嗯那个我们今天下午三点开个会讨论一下豆包流是语音识别的接入方案就是说那个接口的部分"
        let cfg = config
        Task { @MainActor in
            do {
                let r = try await LLMPolisher(config: cfg).polish(sample, contextApp: nil)
                polishTestOutput = r.text
                polishTestMs = r.elapsedMs
                polishTestLeaked = r.thoughtLeaked
            } catch {
                polishTestError = error.localizedDescription
            }
            polishTestRunning = false
        }
    }

    // ── 观测 ──
    @Published var firstCharMs: Int?
    @Published var lastSentenceMs: Int?
    @Published var billedSeconds: Double = 0
    @Published var lastLogId = ""
    @Published var lastError = ""
    @Published var history: [Transcript] = []

    struct Transcript: Identifiable {
        let id = UUID()
        let text: String
        let at: Date
        let firstCharMs: Int?
        let seconds: Double
    }

    // ── UI → 业务逻辑的回调，由 AppDelegate 注入 ──
    var onTestStart: (() -> Void)?
    var onTestStop: (() -> Void)?
    var onReloadConfig: (() -> Void)?

    private var permTimer: Timer?

    private init() {
        refreshPermissions()
        // 权限会在系统设置里被改，也可能因重新签名而失效，必须轮询
        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        secureInputOn = TextInjector.isSecureInputEnabled
    }

    /// ⚠️ 必须含 hotkeyHealthy。原来不含它，导致「启动后才授予辅助功能」时
    ///   UI 显示「就绪 · 按住右⌘说话」，但 CGEventTap 根本没建，按键毫无反应。
    var isReady: Bool {
        micGranted && axGranted && config.hasCredentials && audioEngineReady && hotkeyHealthy
    }

    /// 本次运行的粗略费用（豆包流式 2.0 后付费 1 元/小时）
    var estimatedCost: Double { billedSeconds / 3600.0 * 1.0 }

    func saveConfig() {
        do {
            try config.save()
            lastError = ""
        } catch {
            lastError = "保存配置失败：\(error.localizedDescription)"
        }
    }

    func pushHistory(text: String) {
        guard !text.isEmpty else { return }
        history.insert(Transcript(text: text, at: Date(),
                                  firstCharMs: firstCharMs, seconds: billedSeconds),
                       at: 0)
        if history.count > 50 { history.removeLast() }
    }
}
