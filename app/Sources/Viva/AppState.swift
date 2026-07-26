import Foundation
import SwiftUI
import AVFoundation

/// 全局可观察状态。UI 只读这里，业务逻辑只写这里。
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    // ── 配置 ──
    @Published var config: Config = Config.load()

    /// 跳进设置页后要滚到的锚点（如 "hotkey"）。设置页消费后自行清空。
    /// 用它而不是纯通知：发起跳转时设置页往往还没挂载，通知会漏；
    /// 存成状态后设置页 onAppear 也能补读到。
    @Published var pendingSettingsAnchor: String?

    // ── 权限 ──
    @Published var micGranted = false
    @Published var axGranted = false
    @Published var secureInputOn = false
    @Published var hotkeyHealthy = false
    @Published var audioEngineReady = false
    @Published var hotkeyStatus = "尚未检查"
    @Published var permissionLastCheckedAt: Date?

    // ── 热键实测 ──
    @Published var hotkeyTestRunning = false
    @Published var hotkeyTestResult: Bool?
    @Published var hotkeyTestMessage = "尚未测试实际按键"

    // ── 软件更新 ──
    /// 有可用新版时为其版本号，否则 nil
    @Published var updateAvailable: String?
    @Published var updateStatus = ""
    @Published var updateBusy = false

    // ── 音频输入设备 ──
    @Published var audioInputDevices: [AudioInputDevice] = []
    @Published var audioInputDevicesLoading = false
    @Published var audioInputTestRunning = false
    @Published var audioInputTestLevel: Float = 0
    @Published var audioInputError = ""

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
    var onRefreshInputDevices: (() -> Void)?
    var onInputTestStart: (() -> Void)?
    var onInputTestStop: (() -> Void)?
    var onRefreshPermissions: (() -> Void)?
    var onHotkeyTestStart: (() -> Void)?
    var onHotkeyTestCancel: (() -> Void)?
    var onCheckUpdate: (() -> Void)?
    var onInstallUpdate: (() -> Void)?

    private var permTimer: Timer?

    private init() {
        refreshPermissions()
        // 权限会在系统设置里被改，也可能因重新签名而失效，必须轮询
        permTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let refresh = self.onRefreshPermissions {
                    refresh()
                } else {
                    self.refreshPermissions()
                }
            }
        }
    }

    func refreshPermissions() {
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        axGranted = AXIsProcessTrusted()
        secureInputOn = TextInjector.isSecureInputEnabled
        permissionLastCheckedAt = Date()
    }

    /// ⚠️ 必须含 hotkeyHealthy。原来不含它，导致「启动后才授予辅助功能」时
    ///   UI 显示「就绪 · 按住右⌘说话」，但 CGEventTap 根本没建，按键毫无反应。
    ///
    /// ⚠️ 用的是 appliedConfig 而不是 config：设置页的控件直接双向绑定 config，
    ///   用户敲完 Key 但没点「保存并应用」时 config 已变、而真正干活的
    ///   VoiceSession 还拿着旧配置。若这里读 config，界面会立刻显示「就绪」，
    ///   用户按热键却报「还没配置 API Key」—— 状态与行为对不上。
    var isReady: Bool {
        micGranted && axGranted && appliedConfig.hasCredentials
            && audioEngineReady && hotkeyHealthy
    }

    /// 能不能开始说话。比 isReady 宽松 —— 极简主页里对着 App 自己说话
    /// 只需要麦克风和 Key，不需要辅助功能（那是写进别的 App 才要的）。
    var canSpeak: Bool { micGranted && appliedConfig.hasCredentials && audioEngineReady }

    /// 真正生效中的配置（由 AppDelegate 在 reloadConfig 后同步）。
    /// 与 `config`（UI 编辑中的草稿）区分开。
    @Published var appliedConfig: Config = Config.load()

    /// UI 上是否有未保存的改动
    var hasUnsavedChanges: Bool {
        (try? JSONEncoder().encode(config)) != (try? JSONEncoder().encode(appliedConfig))
    }

    /// 本次运行的粗略费用（豆包流式 2.0 后付费 1 元/小时）
    var estimatedCost: Double { billedSeconds / 3600.0 * 1.0 }

    /// 「保存并应用」用的：把整份草稿落盘并正式生效。
    /// ⚠️ 必须同步 appliedConfig —— reloadConfig 现在以它为准（不再读草稿），
    ///   不同步的话点了保存也不会生效。
    func saveConfig() {
        do {
            try config.save()
            appliedConfig = config
            lastError = ""
        } catch {
            lastError = "保存配置失败：\(error.localizedDescription)"
        }
    }

    /// 「立刻生效」类入口专用：只提交**这一个字段**，不碰设置页里其它未保存的草稿。
    ///
    /// ⚠️ 不要直接用 `saveConfig()` 做这件事。`config` 是设置页的草稿，控件全都双向
    ///   绑定在它上面；用户可能正把 API Key 清空准备重贴、或者改了服务地址还没决定要不要留。
    ///   这时候他在说话页随手点一下「AI 润色」胶囊、或者加一个热词、换一个热键，
    ///   `saveConfig()` 会把**整份草稿**落盘并生效 —— 用户以为已经丢弃的改动全部生效，
    ///   磁盘上的 config.json 也被覆盖（Key 被清空的话界面立刻掉成「未就绪」，原 Key 没了）。
    ///
    /// 正确做法是以 `appliedConfig`（真正生效中的那份）为基线打补丁，
    /// 再把结果同步回草稿，这样草稿里其它未保存的改动原封不动留着。
    func commitField(_ mutate: (inout Config) -> Void) {
        var patched = appliedConfig
        mutate(&patched)
        do {
            try patched.save()
            lastError = ""
        } catch {
            lastError = "保存配置失败：\(error.localizedDescription)"
            return
        }
        appliedConfig = patched
        // 草稿里对应字段也要跟上，否则设置页再点保存会把刚生效的值又改回去
        mutate(&config)
    }

    func pushHistory(text: String) {
        guard !text.isEmpty else { return }
        history.insert(Transcript(text: text, at: Date(),
                                  firstCharMs: firstCharMs, seconds: billedSeconds),
                       at: 0)
        if history.count > 50 { history.removeLast() }
    }
}
