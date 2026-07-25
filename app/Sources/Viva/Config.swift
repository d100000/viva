import Foundation

/// 运行期配置。
///
/// 读取优先级：环境变量 > `~/.config/viva/config.json` > 默认值。
/// **API Key 不写进源码。**
struct Config: Codable {

    // ── 鉴权 ──
    /// 新版控制台：单个 `x-api-key` 即可
    var apiKey: String = ""
    /// 旧版控制台：App ID + Access Token（填了 apiKey 就不用管这两个）
    var appKey: String = ""
    var accessKey: String = ""

    /// 豆包流式语音识别 2.0 小时版。
    /// 1.0 是 `volc.bigasr.sauc.duration`（贵 4.5 倍，没理由用）。
    var resourceId: String = "volc.seedasr.sauc.duration"

    /// 双向流式优化版。只有这个端点支持 enable_nonstream 二遍识别。
    var endpoint: String = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

    // ── 识别参数 ──
    /// 强制判停时间(ms)。越小上屏越碎越快，越大成句越完整。
    /// 快嘴模式 300~500 / 默认 800 / 思考模式 1500~3000
    var endWindowSize: Int = 600
    /// 音频超过该时长才开始尝试判停，避免刚开口就被切断
    var forceToSpeechTime: Int = 1000
    /// 二遍识别：判停后用非流式模型重识别该分句。
    ///
    /// ⚠️ **实测（3/3 复现）：开启后热词会失效。**
    ///   开启：句子更完整、尾字不易丢，但 corpus.context 的热词不生效
    ///        （"流式"→"流是"、"Claude"→"Cloth"、"上屏"→"尚平"）
    ///   关闭：热词正常生效，但偶尔会丢句尾（实测丢过"接口"两字）
    /// 默认关闭 —— 热词是本项目的差异化支点，不能牺牲。
    var enableNonstream: Bool = false
    var enablePunc: Bool = true
    var enableItn: Bool = true
    /// 语义顺滑，去「嗯」「那个」等口水词
    var enableDdc: Bool = true
    /// 热词直传，双向流式限 100 tokens
    var hotwords: [String] = []

    // ── 交互 ──
    /// 按住说话的键码。54 = 右 Command。
    /// ⚠️ 不要用 Fn(63)：微信输入法和豆包输入法都抢占了它。
    /// 其它可选：61 = 右 Option，58 = 左 Option
    var hotkeyKeyCode: Int64 = 54

    /// true = 单修饰键按住（右⌘ / 右⌥ / Fn…）
    /// false = 组合键按住（如 ⌃⌥空格），此时 hotkeyKeyCode 是主键，hotkeyModifiers 是修饰键
    var hotkeyIsModifierOnly: Bool = true

    /// 组合键模式下需要同时按住的修饰键（CGEventFlags.rawValue 的子集）
    var hotkeyModifiers: UInt64 = 0
    /// 判定为「按住」的最短时长(ms)，低于这个值算短按，放行给系统
    var holdThresholdMs: Int = 150
    /// 环形预缓冲时长(ms)：热键按下时把之前这么久的音频一并送出，解决首字丢失
    var preRollMs: Int = 400

    // ── 上屏 ──
    /// true = 剪贴板 + ⌘V（兼容性最好）；false = CGEvent 逐字键入
    var useClipboardPaste: Bool = true
    /// 粘贴后恢复原剪贴板的延迟(ms)。iTerm2 / Warp 这类 bracketed paste 慢消费者需要 1500。
    var clipboardRestoreDelayMs: Int = 200
    /// 只把最终整段结果上屏（不逐句）。默认 false = 边说边逐句上屏。
    var commitOnlyAtEnd: Bool = false

    // ── LLM 润色 ──

    var enablePolish: Bool = false

    /// 厂商预设 id，见 LLMProvider.all
    var polishProvider: String = "ark"
    /// 仅 provider == "custom" 时生效：关闭深度思考的参数写法
    var polishThinkingOff: String = "none"

    /// OpenAI 兼容的端点前缀（不含具体路径）
    var polishBaseURL: String = "https://ark.cn-beijing.volces.com/api/v3"

    /// 接口协议格式。各家的请求体、响应结构、鉴权头都不一样，猜错就是 400/404，
    /// 所以做成显式选项而不是自动嗅探。见 APIFormat。
    var polishAPIFormat: String = "openai-chat"

    /// 是否关闭深度思考。默认关 —— 润色一两句话不需要推理，
    /// 开着会让延迟从 1 秒涨到几秒，思维链还按输出 token 计费。
    var polishDisableThinking: Bool = true

    /// 端点路径。绝大多数 OpenAI 兼容服务是 /chat/completions；
    /// 火山方舟另有 /responses（Responses API），部分自建网关会用别的路径。
    var polishPath: String = "/chat/completions"

    /// 是否用流式（SSE）。开启后润色结果会在悬浮条里逐字出现，
    /// 而不是等整段返回 —— 长句子体感差别明显。
    var polishStream: Bool = true
    var polishApiKey: String = ""
    /// 方舟填「推理接入点 ID」（ep-xxxx）或模型名；其它服务填模型名
    var polishModel: String = ""
    /// 留空则用 LLMPolisher.defaultPrompt
    var polishPrompt: String = ""
    var polishTimeoutMs: Int = 5000

    /// 是否已经走过欢迎/配置引导。首次启动展示欢迎页，之后直接进主界面。
    var hasSeenWelcome: Bool = false

    // MARK: - 容错解码
    //
    // ⚠️ 这段不能删。用合成的 Codable 时，只要新版本加了一个字段，
    // 旧的 config.json 就会整份解码失败 → 悄悄退回默认值 → 用户的 API Key「凭空消失」。
    // 逐字段 decodeIfPresent 之后，缺字段用默认值、多余字段直接忽略，升级降级都不会丢配置。

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ d: String) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) .flatMap { $0 } ?? d }
        func i(_ k: CodingKeys, _ d: Int) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)).flatMap { $0 } ?? d }
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)).flatMap { $0 } ?? d }

        let def = Config()
        apiKey = s(.apiKey, def.apiKey)
        appKey = s(.appKey, def.appKey)
        accessKey = s(.accessKey, def.accessKey)
        resourceId = s(.resourceId, def.resourceId)
        endpoint = s(.endpoint, def.endpoint)
        endWindowSize = i(.endWindowSize, def.endWindowSize)
        forceToSpeechTime = i(.forceToSpeechTime, def.forceToSpeechTime)
        enableNonstream = b(.enableNonstream, def.enableNonstream)
        enablePunc = b(.enablePunc, def.enablePunc)
        enableItn = b(.enableItn, def.enableItn)
        enableDdc = b(.enableDdc, def.enableDdc)
        hotwords = (try? c.decodeIfPresent([String].self, forKey: .hotwords)).flatMap { $0 } ?? def.hotwords
        hotkeyKeyCode = (try? c.decodeIfPresent(Int64.self, forKey: .hotkeyKeyCode)).flatMap { $0 } ?? def.hotkeyKeyCode
        hotkeyIsModifierOnly = b(.hotkeyIsModifierOnly, def.hotkeyIsModifierOnly)
        hotkeyModifiers = (try? c.decodeIfPresent(UInt64.self, forKey: .hotkeyModifiers)).flatMap { $0 } ?? def.hotkeyModifiers
        holdThresholdMs = i(.holdThresholdMs, def.holdThresholdMs)
        preRollMs = i(.preRollMs, def.preRollMs)
        useClipboardPaste = b(.useClipboardPaste, def.useClipboardPaste)
        clipboardRestoreDelayMs = i(.clipboardRestoreDelayMs, def.clipboardRestoreDelayMs)
        commitOnlyAtEnd = b(.commitOnlyAtEnd, def.commitOnlyAtEnd)
        enablePolish = b(.enablePolish, def.enablePolish)
        polishProvider = s(.polishProvider, def.polishProvider)
        polishThinkingOff = s(.polishThinkingOff, def.polishThinkingOff)
        polishBaseURL = s(.polishBaseURL, def.polishBaseURL)
        polishAPIFormat = s(.polishAPIFormat, def.polishAPIFormat)
        polishDisableThinking = b(.polishDisableThinking, def.polishDisableThinking)
        polishPath = s(.polishPath, def.polishPath)
        polishStream = b(.polishStream, def.polishStream)
        polishApiKey = s(.polishApiKey, def.polishApiKey)
        polishModel = s(.polishModel, def.polishModel)
        polishPrompt = s(.polishPrompt, def.polishPrompt)
        polishTimeoutMs = i(.polishTimeoutMs, def.polishTimeoutMs)
        hasSeenWelcome = b(.hasSeenWelcome, def.hasSeenWelcome)
    }

    var apiFormat: APIFormat { APIFormat(rawValue: polishAPIFormat) ?? .openAIChat }

    var polishReady: Bool {
        enablePolish && !polishModel.isEmpty
            && (!polishApiKey.isEmpty || apiFormat == .ollamaNative)
    }

    // MARK: - 加载

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/viva", isDirectory: true)
    static let configURL = configDir.appendingPathComponent("config.json")

    /// 历代旧目录，按从新到旧的顺序找。
    /// 改目录必须配迁移 —— 否则用户的 API Key 和全部识别记录会「凭空消失」，
    /// 而且 load() 里是 try? 吞错误，连报错都看不到。
    private static let legacyDirs = ["justsay", "typespeed", "shengbi", "doubao-voice"].map {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\($0)", isDirectory: true)
    }

    static func migrateLegacyIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configURL.path) else { return }
        // ⚠️ 两个文件要**各自独立**地找来源。原来只按 config.json 挑一个目录，
        //    如果用户在某一代只写过配置没攒下记录（或反过来），
        //    另一代目录里的 history.json 就被永久丢弃了 —— 全部统计静默归零。
        var migrated: [String] = []
        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        for name in ["config.json", "history.json"] {
            let dst = configDir.appendingPathComponent(name)
            guard !fm.fileExists(atPath: dst.path) else { continue }
            guard let src = legacyDirs
                .map({ $0.appendingPathComponent(name) })
                .first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            if (try? fm.copyItem(at: src, to: dst)) != nil {
                migrated.append("\(src.deletingLastPathComponent().lastPathComponent)/\(name)")
            }
        }
        guard !migrated.isEmpty else { return }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        Log.info("已迁移：\(migrated.joined(separator: ", "))")

        // ⚠️ 迁移完必须清掉旧目录。本项目连续改过 4 次名，如果每次都「复制不删除」，
        //   用户的 API Key 就会留下 4 份散落的副本 —— 凭证副本越多风险越大。
        //   只在确认新目录已经写好之后才删，避免迁移失败反而丢数据。
        guard fm.fileExists(atPath: configURL.path) else { return }
        for dir in legacyDirs where fm.fileExists(atPath: dir.path) {
            do {
                try fm.removeItem(at: dir)
                Log.info("已清理旧配置目录 \(dir.lastPathComponent)（其中含 API Key 副本）")
            } catch {
                Log.warn("清理旧目录 \(dir.lastPathComponent) 失败：\(error.localizedDescription)")
            }
        }
    }

    static func load() -> Config {
        migrateLegacyIfNeeded()
        var cfg = Config()

        if let data = try? Data(contentsOf: configURL),
           let loaded = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = loaded
        }

        // 环境变量覆盖，方便临时测试
        let env = ProcessInfo.processInfo.environment
        if let v = env["DOUBAO_API_KEY"], !v.isEmpty { cfg.apiKey = v }
        if let v = env["DOUBAO_APP_KEY"], !v.isEmpty { cfg.appKey = v }
        if let v = env["DOUBAO_ACCESS_KEY"], !v.isEmpty { cfg.accessKey = v }
        if let v = env["DOUBAO_RESOURCE_ID"], !v.isEmpty { cfg.resourceId = v }
        if let v = env["DOUBAO_ENDPOINT"], !v.isEmpty { cfg.endpoint = v }

        return cfg
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.configDir,
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ⚠️ 必须 .atomic。非原子写在写入过程中被打断（强退 / 磁盘满 / 被系统杀）
        //   会留下截断的 config.json，下次启动解码失败 → API Key 和热词静默清零。
        try enc.encode(self).write(to: Self.configURL, options: .atomic)
        // 配置里有密钥，收紧权限
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.configURL.path)
    }

    var hasCredentials: Bool {
        !apiKey.isEmpty || (!appKey.isEmpty && !accessKey.isEmpty)
    }

    /// 组装 WebSocket 握手需要的鉴权头
    func authHeaders(requestId: String, connectId: String) -> [String: String] {
        var h: [String: String] = [
            "X-Api-Resource-Id": resourceId,
            "X-Api-Request-Id": requestId,
            "X-Api-Connect-Id": connectId,
            "X-Api-Sequence": "-1",
        ]
        if !apiKey.isEmpty {
            h["x-api-key"] = apiKey                 // 新版控制台
        } else {
            h["X-Api-App-Key"] = appKey             // 旧版控制台
            h["X-Api-Access-Key"] = accessKey
        }
        return h
    }
}
