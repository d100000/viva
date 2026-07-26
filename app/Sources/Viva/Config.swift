import Foundation

/// 按 App 的配置覆盖（Profile）。竞品标配：在终端里关润色 + 逐字键入,
/// 在微信里开润色 + 剪贴板上屏。nil = 该项跟随全局配置。
struct AppProfile: Codable, Equatable, Hashable, Identifiable {
    var bundleId: String
    /// 仅展示用；bundleId 才是匹配键
    var appName: String = ""
    var enablePolish: Bool? = nil
    var useClipboardPaste: Bool? = nil
    var progressiveCommit: Bool? = nil
    var id: String { bundleId }
}

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

    /// 去掉整段末尾的句号。
    ///
    /// 开了「自动标点」之后，识别结果一定以「。」收尾。但语音输入十有八九是往
    /// 聊天框、搜索框、命令行里塞一句话 —— 那个句号既多余又得手动删。
    /// 只去**句号**：问号和感叹号带语气，去掉会改变语义。
    /// 实现见 TextPolish.stripTrailingPeriod（逐句上屏时用「扣下-补回」策略，
    /// 绝不退格回改）。
    var stripTrailingPeriod: Bool = true
    /// 热词直传，双向流式限 100 tokens
    var hotwords: [String] = []
    /// 启用的预设词库 id（见 WordlistStore.knownIds）。默认启用 AI + 编程库 ——
    /// 本产品的目标人群就是开发者，且词库页一眼可关；「互联网职场」库默认关。
    /// 用户词永远排在预设词前面。选词与容量权衡见 10-预设词库方案.md。
    var enabledWordlists: [String] = ["ai", "it"]
    /// 确定性替换规则（改词记忆）。definite/partial 都过一遍，热词纠不动的靠它。
    var replaceRules: [ReplaceRule] = []

    /// 中文输出变体：""=简体（默认）/ traditional=繁体 / tw=台湾正体 / hk=香港繁体
    var zhVariant: String = ""
    /// 极速模式：enable_accelerate_text，首字更快但首字准确率下降。
    /// UI 上必须讲清代价，默认关。
    var accelerateFirstChar: Bool = false

    /// 全局快捷键 ⌃⌥⌘V：把上一段识别结果粘贴到当前光标处。
    /// Secure Input / 注入失败 / 手滑清空时的唯一兜底。
    var pasteLastHotkeyEnabled: Bool = true

    /// 对话上下文：把最近几条识别结果随首包传给豆包（corpus.context 的
    /// dialog_ctx 用法，限 800 tokens/20 轮），显著提升上下文连贯的识别准确率。
    /// 隐私：只发**最近的识别文本** —— 这些文本本来就是这家服务识别出来的，
    /// 不产生新的数据暴露面；App 名等额外信息一概不发。
    var enableDialogContext: Bool = true

    /// 按 App 自动切换的配置覆盖。会话开始时按目标 App 的 bundleId 查表，
    /// 命中的字段覆盖全局配置（快照语义，只影响本次会话）。
    var appProfiles: [AppProfile] = []

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
    /// Core Audio 设备 UID。留空表示始终跟随 macOS 的系统默认输入设备。
    var inputDeviceUID: String = ""

    // ── 上屏 ──
    /// true = 剪贴板 + ⌘V（兼容性最好）；false = CGEvent 逐字键入
    var useClipboardPaste: Bool = true
    /// 粘贴后恢复原剪贴板的延迟(ms)。iTerm2 / Warp 这类 bracketed paste 慢消费者需要 1500。
    /// ⚠️ 不要低于 600。恢复太早目标 App 还没读走剪贴板，会粘出旧内容 ——
    ///    这是不可逆的错误，而恢复晚一点用户几乎无感。
    ///    Electron 宿主和终端会自动提到 1500。
    var clipboardRestoreDelayMs: Int = 600
    /// 只把最终整段结果上屏（不逐句）。默认 false = 边说边逐句上屏。
    var commitOnlyAtEnd: Bool = false

    // ── 连续听写（方案见 09-连续听写技术方案.md） ──
    /// 稳定前缀逐段上屏：连续说话不留停顿时，服务端永远不判停（判停唯一依据是
    /// 静音 ≥ endWindowSize），文字会全部憋到松手。开启后把 partial 里
    /// 「以标点收尾、连续多帧未变、距尾部有安全边距」的前缀提前写进光标处。
    /// ⚠️ 润色开启时自动失效 —— 润色要拿全文重写，与逐段上屏互斥。
    var progressiveCommit: Bool = true
    /// partial 达到多少字才启用逐段提交（短句走原有 definite 流程）
    var progressiveMinLength: Int = 20
    /// 候选前缀需要连续多少帧保持不变
    var progressiveStableFrames: Int = 3
    /// 提交点距 partial 尾部的最小字素数 —— 服务端的修订几乎都发生在尾部
    var progressiveTailGuard: Int = 8
    /// 会话年龄超过该秒数后，借下一个 definite 的干净边界轮转新会话（T2）
    var rotateAfterSeconds: Int = 50
    /// 一直没有 definite 时强制轮转的上限秒数（T3），应大于 rotateAfterSeconds
    var hardRotateSeconds: Int = 75

    // ── LLM 润色 ──

    var enablePolish: Bool = false

    /// 改口自动纠正（对标 Typeless）：「明天九点,啊不对,下午三点」→ 只上屏
    /// 「明天下午三点」。与润色**共用**同一套大模型凭证/模型配置,可独立开关;
    /// 开启后与润色一样推迟到松手整段上屏（改口必须拿到全文才能改）。
    var enableCourseCorrection: Bool = false

    /// 厂商预设 id，见 LLMProvider.all
    ///
    /// 默认指向自家中转站：它是唯一「填一个 Key 就能用」的选项，其余每一家都要求
    /// 注册 → 实名 → 充值 → 开通模型 → 再抄一个大小写敏感的模型名。
    /// ⚠️ 因为默认值指向的是本项目作者运营的收费服务，「数据与隐私」那一节必须
    ///    把润色文本会经过中转站这件事写在明面上（见 SettingsView 数据与隐私）。
    ///    默认值可以有倾向，但不能是暗桩。
    /// 注意这只影响**全新安装**：老用户配置里已存了 polishProvider，不会被改写。
    var polishProvider: String = LLMProvider.relayID
    /// 仅 provider == "custom" 时生效：关闭深度思考的参数写法
    var polishThinkingOff: String = "none"

    /// OpenAI 兼容的端点前缀（不含具体路径）。必须与 polishProvider 的默认值配套 ——
    /// 两者对不上会让新用户一上来就撞 404。
    var polishBaseURL: String = "https://bobdong.cn/v1"

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

    /// 润色时是否把「当前前台 App 的名字」一并发给服务商，让它按场景调整风格
    /// （在终端里和在微信里，同一句话该润成不同样子）。
    ///
    /// ⚠️ 默认关。开了等于每说一句就告诉服务商「此人此刻在用哪个 App」——
    ///   1Password、Signal、某个内部工具都会被记上一笔。这是识别文本之外的
    ///   额外数据，隐私说明里没承诺过，必须由用户显式打开。
    var sendAppContext: Bool = false
    var polishTimeoutMs: Int = 5000

    /// 是否已经走过欢迎/配置引导。首次启动展示欢迎页，之后直接进主界面。
    var hasSeenWelcome: Bool = false

    /// 启动时自动检查并安装新版本（GitHub Releases）。
    /// 关掉后仍会检查并在菜单栏/设置页提示，只是不自动装。
    var autoUpdate: Bool = true

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
        stripTrailingPeriod = b(.stripTrailingPeriod, def.stripTrailingPeriod)
        hotwords = (try? c.decodeIfPresent([String].self, forKey: .hotwords)).flatMap { $0 } ?? def.hotwords
        enabledWordlists = (try? c.decodeIfPresent([String].self, forKey: .enabledWordlists)).flatMap { $0 } ?? def.enabledWordlists
        replaceRules = (try? c.decodeIfPresent([ReplaceRule].self, forKey: .replaceRules)).flatMap { $0 } ?? def.replaceRules
        zhVariant = s(.zhVariant, def.zhVariant)
        accelerateFirstChar = b(.accelerateFirstChar, def.accelerateFirstChar)
        pasteLastHotkeyEnabled = b(.pasteLastHotkeyEnabled, def.pasteLastHotkeyEnabled)
        enableDialogContext = b(.enableDialogContext, def.enableDialogContext)
        appProfiles = (try? c.decodeIfPresent([AppProfile].self, forKey: .appProfiles)).flatMap { $0 } ?? def.appProfiles
        hotkeyKeyCode = (try? c.decodeIfPresent(Int64.self, forKey: .hotkeyKeyCode)).flatMap { $0 } ?? def.hotkeyKeyCode
        hotkeyIsModifierOnly = b(.hotkeyIsModifierOnly, def.hotkeyIsModifierOnly)
        hotkeyModifiers = (try? c.decodeIfPresent(UInt64.self, forKey: .hotkeyModifiers)).flatMap { $0 } ?? def.hotkeyModifiers
        holdThresholdMs = i(.holdThresholdMs, def.holdThresholdMs)
        preRollMs = i(.preRollMs, def.preRollMs)
        inputDeviceUID = s(.inputDeviceUID, def.inputDeviceUID)
        useClipboardPaste = b(.useClipboardPaste, def.useClipboardPaste)
        clipboardRestoreDelayMs = i(.clipboardRestoreDelayMs, def.clipboardRestoreDelayMs)
        commitOnlyAtEnd = b(.commitOnlyAtEnd, def.commitOnlyAtEnd)
        progressiveCommit = b(.progressiveCommit, def.progressiveCommit)
        progressiveMinLength = i(.progressiveMinLength, def.progressiveMinLength)
        progressiveStableFrames = i(.progressiveStableFrames, def.progressiveStableFrames)
        progressiveTailGuard = i(.progressiveTailGuard, def.progressiveTailGuard)
        rotateAfterSeconds = i(.rotateAfterSeconds, def.rotateAfterSeconds)
        hardRotateSeconds = i(.hardRotateSeconds, def.hardRotateSeconds)
        enablePolish = b(.enablePolish, def.enablePolish)
        enableCourseCorrection = b(.enableCourseCorrection, def.enableCourseCorrection)
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
        sendAppContext = b(.sendAppContext, def.sendAppContext)
        polishTimeoutMs = i(.polishTimeoutMs, def.polishTimeoutMs)
        hasSeenWelcome = b(.hasSeenWelcome, def.hasSeenWelcome)
        autoUpdate = b(.autoUpdate, def.autoUpdate)
    }

    var apiFormat: APIFormat { APIFormat(rawValue: polishAPIFormat) ?? .openAIChat }

    /// 按目标 App 的 Profile 生成本次会话的有效配置。
    /// 没配 Profile 或字段为 nil（跟随全局）时原样返回。
    func applyingProfile(for bundleId: String?) -> Config {
        guard let bid = bundleId,
              let p = appProfiles.first(where: { $0.bundleId == bid }) else { return self }
        var c = self
        if let v = p.enablePolish { c.enablePolish = v }
        if let v = p.useClipboardPaste { c.useClipboardPaste = v }
        if let v = p.progressiveCommit { c.progressiveCommit = v }
        return c
    }

    var polishReady: Bool {
        enablePolish && !polishModel.isEmpty
            && (!polishApiKey.isEmpty || apiFormat == .ollamaNative)
    }

    /// 大模型凭证是否已配好（与开了哪个功能无关）
    var llmCredentialsReady: Bool {
        !polishModel.isEmpty && (!polishApiKey.isEmpty || apiFormat == .ollamaNative)
    }

    /// 松手后是否要走一遍大模型（润色或改口纠正,共用凭证）。
    /// ⚠️ VoiceSession 的推迟上屏判据和 LLMPolisher.isConfigured 都必须用它,
    ///   两边不一致会出现「白等一次再报错」（见 LLMPolisher.isConfigured 注释）。
    var llmPassReady: Bool {
        (enablePolish || enableCourseCorrection) && llmCredentialsReady
    }

    // MARK: - 加载

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/viva", isDirectory: true)
    static let configURL = configDir.appendingPathComponent("config.json")

    /// 按类别分开存放，别再全平铺在一个目录里 —— 否则「清空配置」会误伤历史/日志/证书。
    ///   config.json  配置（顶层，唯一；重置/备份的最小单位就是它）
    ///   data/        数据：history.json（识别历史）
    ///   logs/        日志：viva.log（+ viva.previous.log）
    ///   crashes/     崩溃报告（CrashReporter 管）
    ///   signing/     代码签名证书备份（make-signing-cert.sh 管，勿删/勿入库）
    static let dataDir = configDir.appendingPathComponent("data", isDirectory: true)
    static let logsDir = configDir.appendingPathComponent("logs", isDirectory: true)

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
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        // 旧目录里是平铺的文件名，各自搬到新布局里的目标位置：
        //   config.json 留顶层（配置），history.json 进 data/（数据）。
        let dests: [(name: String, dst: URL)] = [
            ("config.json",  configURL),
            ("history.json", dataDir.appendingPathComponent("history.json")),
        ]
        for (name, dst) in dests {
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

    /// 老版本（同名 viva 目录）把所有文件平铺在 ~/.config/viva/ 下。
    /// 新版本按类别分子目录 —— 这里把遗留的平铺文件就地搬进新位置（幂等）。
    ///
    /// ⚠️ 必须与调用顺序无关。App 启动早期（本函数之前）可能已经写过日志，
    ///   `logs/viva.log` 会被提前建出；若「目标已存在就跳过」，顶层那份旧日志就永远搬不进去、
    ///   内容也并不进来。所以目标已存在时不跳过、也不覆盖，而是把旧文件改名保存
    ///   （.premigration），既不丢内容又能清空顶层。
    static func migrateLayoutIfNeeded() {
        let fm = FileManager.default
        let moves: [(from: URL, to: URL)] = [
            (configDir.appendingPathComponent("history.json"),         dataDir.appendingPathComponent("history.json")),
            (configDir.appendingPathComponent("history.corrupt.json"), dataDir.appendingPathComponent("history.corrupt.json")),
            (configDir.appendingPathComponent("viva.log"),             logsDir.appendingPathComponent("viva.log")),
            (configDir.appendingPathComponent("viva.previous.log"),    logsDir.appendingPathComponent("viva.previous.log")),
        ]
        guard moves.contains(where: { fm.fileExists(atPath: $0.from.path) }) else { return }
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        var done: [String] = []
        for m in moves where fm.fileExists(atPath: m.from.path) {
            var dest = m.to
            if fm.fileExists(atPath: dest.path) {
                // 目标被早期写入抢先建出：改名保存旧文件，绝不覆盖、绝不丢内容。
                let base = m.to.deletingPathExtension().lastPathComponent
                let ext = m.to.pathExtension
                let name = ext.isEmpty ? "\(base).premigration" : "\(base).premigration.\(ext)"
                dest = m.to.deletingLastPathComponent().appendingPathComponent(name)
                try? fm.removeItem(at: dest)
            }
            if (try? fm.moveItem(at: m.from, to: dest)) != nil { done.append(m.from.lastPathComponent) }
        }
        if !done.isEmpty { Log.info("已整理目录布局：\(done.joined(separator: "、")) 归入 data//logs/") }
    }

    static func load() -> Config {
        migrateLegacyIfNeeded()
        migrateLayoutIfNeeded()
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
