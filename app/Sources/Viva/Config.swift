import Foundation

enum AIProcessingMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case off
    case correction
    case polish
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .correction: return "口误纠正"
        case .polish: return "轻度润色"
        case .both: return "润色并纠错"
        }
    }

    var compactTitle: String {
        switch self {
        case .off: return "AI 关闭"
        case .correction: return "口误纠正"
        case .polish: return "轻度润色"
        case .both: return "润色 + 纠错"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "不经过大模型，识别结果直接写入。"
        case .correction:
            return "处理“不是……是……”等口头改口，尽量保留原本表达。"
        case .polish:
            return "整理语气词、标点和轻微语病，不主动改变原意。"
        case .both:
            return "先判断最终意思并纠正口误，再做轻度文字整理；两步由服务端一次完成。"
        }
    }

    var processingLabel: String {
        switch self {
        case .off: return "正在处理"
        case .correction: return "正在检查口误"
        case .polish: return "正在润色"
        case .both: return "正在润色并纠错"
        }
    }

    var resultNoun: String {
        switch self {
        case .off: return "AI 处理"
        case .correction: return "口误纠正"
        case .polish: return "润色"
        case .both: return "AI 处理"
        }
    }
}

/// 按 App 的配置覆盖（Profile）。竞品标配：在终端里关润色 + 逐字键入,
/// 在微信里开润色 + 剪贴板上屏。nil = 该项跟随全局配置。
struct AppProfile: Codable, Equatable, Hashable, Identifiable {
    var bundleId: String
    /// 仅展示用；bundleId 才是匹配键
    var appName: String = ""
    var enablePolish: Bool? = nil
    var enableCourseCorrection: Bool? = nil
    var useClipboardPaste: Bool? = nil
    var progressiveCommit: Bool? = nil
    var id: String { bundleId }
}

/// 运行期配置。
///
/// 读取优先级：环境变量 > `~/.config/viva/config.json` > 默认值。
/// 火山引擎和大模型供应商凭证只存在 Viva 服务端，客户端不保存也不接收。
struct Config: Codable, Equatable {

    // ── Viva 托管服务 ──
    /// 生产地址由客户端版本固定/远程配置控制，普通用户不可编辑。
    static let productionBackendBaseURL = "https://viva.bobdong.cn"
    static let defaultTestBackendBaseURL = "http://127.0.0.1:8080"
    static let supportedWordlistIDs = ["ai", "it"]

    /// 开发者测试模式：ASR WebSocket 与大模型润色同时切到本地项目。
    var testModeEnabled: Bool = false
    /// 这是客户端唯一允许编辑的服务地址，而且只在测试模式下生效。
    var testBackendBaseURL: String = Config.defaultTestBackendBaseURL

    /// 去掉整段末尾的句号。
    ///
    /// 开了「自动标点」之后，识别结果一定以「。」收尾。但语音输入十有八九是往
    /// 聊天框、搜索框、命令行里塞一句话 —— 那个句号既多余又得手动删。
    /// 只去**句号**：问号和感叹号带语气，去掉会改变语义。
    /// 实现见 TextPolish.stripTrailingPeriod（逐句上屏时用「扣下-补回」策略，
    /// 绝不退格回改）。
    var stripTrailingPeriod: Bool = true
    /// 启用的本地预设替换规则 id（见 WordlistStore.knownIds）。
    var enabledWordlists: [String] = Config.supportedWordlistIDs
    /// 确定性替换规则（改词记忆），在识别文本返回后仅在本机应用。
    var replaceRules: [ReplaceRule] = []

    /// 全局快捷键 ⌃⌥⌘V：把上一段识别结果粘贴到当前光标处。
    /// Secure Input / 注入失败 / 手滑清空时的唯一兜底。
    var pasteLastHotkeyEnabled: Bool = true

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
    /// true = 空闲时保持麦克风引擎预热，用预缓冲换取最低首字延迟。
    /// false = 只在语音输入或本地麦克风测试时启动，空闲时释放系统麦克风。
    var keepAudioEngineWarm: Bool = false
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
    /// 稳定前缀逐段上屏：连续说话不留停顿时，服务端可能一直不返回 definite，
    /// 文字会全部憋到松手。开启后把 partial 里
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

    // ── 服务端大模型处理 ──

    var enablePolish: Bool = false

    /// 改口自动纠正（对标 Typeless）：「明天九点,啊不对,下午三点」→ 只上屏
    /// 「明天下午三点」。与润色共用服务端模型，可独立开关；
    /// 开启后与润色一样推迟到松手整段上屏（改口必须拿到全文才能改）。
    var enableCourseCorrection: Bool = false

    /// 对外统一成一个四态模式；底层保留两个布尔字段，旧配置和按 App 覆盖无需迁移。
    var aiProcessingMode: AIProcessingMode {
        get {
            switch (enablePolish, enableCourseCorrection) {
            case (false, false): return .off
            case (false, true): return .correction
            case (true, false): return .polish
            case (true, true): return .both
            }
        }
        set {
            enablePolish = newValue == .polish || newValue == .both
            enableCourseCorrection = newValue == .correction || newValue == .both
        }
    }

    /// 是否用流式（SSE）。开启后润色结果会在悬浮条里逐字出现，
    /// 而不是等整段返回 —— 长句子体感差别明显。
    var polishStream: Bool = true

    var polishTimeoutMs: Int = 5000

    /// 是否已经走过欢迎/配置引导。首次启动展示欢迎页，之后直接进主界面。
    var hasSeenWelcome: Bool = false

    /// 启动时自动检查并安装新版本（GitHub Releases）。
    /// 关掉后仍会检查并在菜单栏/设置页提示，只是不自动装。
    var autoUpdate: Bool = true

    // MARK: - 容错解码
    //
    // ⚠️ 这段不能删。用合成的 Codable 时，只要新版本加了一个字段，
    // 旧的 config.json 就会整份解码失败 → 悄悄退回默认值 → 用户设置「凭空消失」。
    // 逐字段 decodeIfPresent 之后，缺字段用默认值、多余字段直接忽略，升级降级都不会丢配置。

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ d: String) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) .flatMap { $0 } ?? d }
        func i(_ k: CodingKeys, _ d: Int) -> Int { (try? c.decodeIfPresent(Int.self, forKey: k)).flatMap { $0 } ?? d }
        func b(_ k: CodingKeys, _ d: Bool) -> Bool { (try? c.decodeIfPresent(Bool.self, forKey: k)).flatMap { $0 } ?? d }

        let def = Config()
        testModeEnabled = b(.testModeEnabled, def.testModeEnabled)
        testBackendBaseURL = s(.testBackendBaseURL, def.testBackendBaseURL)
        stripTrailingPeriod = b(.stripTrailingPeriod, def.stripTrailingPeriod)
        enabledWordlists = (try? c.decodeIfPresent([String].self, forKey: .enabledWordlists)).flatMap { $0 } ?? def.enabledWordlists
        replaceRules = (try? c.decodeIfPresent([ReplaceRule].self, forKey: .replaceRules)).flatMap { $0 } ?? def.replaceRules
        pasteLastHotkeyEnabled = b(.pasteLastHotkeyEnabled, def.pasteLastHotkeyEnabled)
        appProfiles = (try? c.decodeIfPresent([AppProfile].self, forKey: .appProfiles)).flatMap { $0 } ?? def.appProfiles
        hotkeyKeyCode = (try? c.decodeIfPresent(Int64.self, forKey: .hotkeyKeyCode)).flatMap { $0 } ?? def.hotkeyKeyCode
        hotkeyIsModifierOnly = b(.hotkeyIsModifierOnly, def.hotkeyIsModifierOnly)
        hotkeyModifiers = (try? c.decodeIfPresent(UInt64.self, forKey: .hotkeyModifiers)).flatMap { $0 } ?? def.hotkeyModifiers
        holdThresholdMs = i(.holdThresholdMs, def.holdThresholdMs)
        preRollMs = i(.preRollMs, def.preRollMs)
        keepAudioEngineWarm = b(.keepAudioEngineWarm, def.keepAudioEngineWarm)
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
        polishStream = b(.polishStream, def.polishStream)
        polishTimeoutMs = i(.polishTimeoutMs, def.polishTimeoutMs)
        hasSeenWelcome = b(.hasSeenWelcome, def.hasSeenWelcome)
        autoUpdate = b(.autoUpdate, def.autoUpdate)
    }

    /// 按目标 App 的 Profile 生成本次会话的有效配置。
    /// 没配 Profile 或字段为 nil（跟随全局）时原样返回。
    func applyingProfile(for bundleId: String?) -> Config {
        guard let bid = bundleId,
              let p = appProfiles.first(where: { $0.bundleId == bid }) else { return self }
        var c = self
        if let v = p.enablePolish { c.enablePolish = v }
        if let v = p.enableCourseCorrection { c.enableCourseCorrection = v }
        if let v = p.useClipboardPaste { c.useClipboardPaste = v }
        if let v = p.progressiveCommit { c.progressiveCommit = v }
        return c
    }

    var selectedBackendBaseURLString: String {
        testModeEnabled ? testBackendBaseURL : Self.productionBackendBaseURL
    }

    /// 当前真正生效的服务根地址。只接受 http/https，拒绝 userinfo/query/fragment，
    /// 避免把令牌或路径意外发到一个看似合法、实际被拼接过的地址。
    var backendBaseURL: URL? {
        guard let url = Self.normalizedBackendBaseURL(selectedBackendBaseURLString) else {
            return nil
        }
        // 测试模式是本机开发逃生口，不是给普通用户重新开放任意上游代理。
        // 即使远端使用 HTTPS，也只允许 loopback；生产地址则始终来自编译期常量。
        if testModeEnabled,
           let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.host,
           !Self.isLoopbackHost(host) {
            return nil
        }
        return url
    }

    var hasValidBackendConfiguration: Bool { backendBaseURL != nil }

    var backendConfigurationError: String? {
        guard testModeEnabled, backendBaseURL == nil else { return nil }
        return "请输入不带路径的本机服务 origin，例如 http://127.0.0.1:8080；仅允许 localhost、127.0.0.0/8 或 ::1"
    }

    func polishEndpointURL(streaming: Bool) -> URL? {
        serviceURL(path: streaming ? "/v1/text/polish/stream" : "/v1/text/polish")
    }

    func serviceURL(path: String, webSocket: Bool = false) -> URL? {
        guard let base = backendBaseURL,
              var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        let prefix = comps.path.split(separator: "/").map(String.init)
        let suffix = path.split(separator: "/").map(String.init)
        comps.path = "/" + (prefix + suffix).joined(separator: "/")
        comps.query = nil
        comps.fragment = nil
        if webSocket {
            comps.scheme = comps.scheme?.lowercased() == "http" ? "ws" : "wss"
        }
        return comps.url
    }

    private static func normalizedBackendBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var comps = URLComponents(string: trimmed),
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = comps.host, !host.isEmpty,
              comps.user == nil, comps.password == nil,
              comps.query == nil, comps.fragment == nil,
              comps.path.isEmpty || comps.path == "/",
              scheme == "https" || isLoopbackHost(host)
        else { return nil }
        comps.scheme = scheme
        comps.path = ""
        return comps.url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value == "::1" { return true }
        let parts = value.split(separator: ".")
        guard parts.count == 4,
              parts.allSatisfy({ part in
                  guard !part.isEmpty, part.allSatisfy(\.isNumber), let octet = Int(part) else {
                      return false
                  }
                  return (0...255).contains(octet)
              }) else { return false }
        return parts[0] == "127"
    }

    var polishReady: Bool { enablePolish && hasValidBackendConfiguration }

    /// 服务端大模型是否可调用（与开了哪个功能无关）。供应商、模型和 Key 均由服务端管理。
    var managedLLMReady: Bool { hasValidBackendConfiguration }

    /// 松手后是否要走一遍大模型（润色或改口纠正,共用凭证）。
    /// ⚠️ VoiceSession 的推迟上屏判据和 LLMPolisher.isConfigured 都必须用它,
    ///   两边不一致会出现「白等一次再报错」（见 LLMPolisher.isConfigured 注释）。
    var llmPassReady: Bool {
        (enablePolish || enableCourseCorrection) && managedLLMReady
    }

    // MARK: - 加载

    static let configDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/viva", isDirectory: true)
    static let configURL = configDir.appendingPathComponent("config.json")

    /// 按类别分开存放，别再全平铺在一个目录里 —— 否则「清空配置」会误伤历史/日志/证书。
    ///   config.json  配置（顶层，唯一；重置/备份的最小单位就是它）
    ///   auth/        当前设备登录会话（仅当前 macOS 用户可读）
    ///   data/        数据：history.json（识别历史）
    ///   logs/        日志：viva.log（+ viva.previous.log）
    ///   crashes/     崩溃报告（CrashReporter 管）
    ///   signing/     代码签名证书备份（make-signing-cert.sh 管，勿删/勿入库）
    static let dataDir = configDir.appendingPathComponent("data", isDirectory: true)
    static let authDir = configDir.appendingPathComponent("auth", isDirectory: true)
    static let logsDir = configDir.appendingPathComponent("logs", isDirectory: true)

    /// 历代旧目录，按从新到旧的顺序找。
    /// 改目录必须配迁移 —— 否则用户设置和全部识别记录会「凭空消失」，
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
        //   历史版本里保存过的供应商凭证会留下多份散落副本。
        //   只在确认新目录已经写好之后才删，避免迁移失败反而丢数据。
        guard fm.fileExists(atPath: configURL.path) else { return }
        for dir in legacyDirs where fm.fileExists(atPath: dir.path) {
            do {
                try fm.removeItem(at: dir)
                Log.info("已清理旧配置目录 \(dir.lastPathComponent)（可能含旧供应商凭证）")
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
            let invalidWordlistIDs = cfg.enabledWordlists.filter {
                !Self.supportedWordlistIDs.contains($0)
            }
            if !invalidWordlistIDs.isEmpty {
                cfg.enabledWordlists.removeAll { !Self.supportedWordlistIDs.contains($0) }
            }

            // 旧版曾把供应商长期凭证和自定义上游写进 config.json。
            // 用当前 Codable 结构生成允许字段集，原子重写任何含未知
            // 字段的旧配置。这样既不会在新客户端中编译进旧密钥字段名，
            // 也能在升级时把旧敏感值从磁盘上清掉。
            let currentData = try? JSONEncoder().encode(cfg)
            let currentObject = currentData.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let currentObject,
               (!Set(object.keys).isSubset(of: Set(currentObject.keys))
                || !invalidWordlistIDs.isEmpty) {
                do {
                    try cfg.save()
                    Log.info("已从本地配置移除旧版字段或失效词库")
                } catch {
                    Log.warn("清理旧版配置失败：\(error.localizedDescription)")
                }
            }
        }

        // 环境变量只允许打开开发测试模式；生产托管地址不能被本地配置覆盖。
        let env = ProcessInfo.processInfo.environment
        if env["VIVA_TEST_MODE"] == "1" { cfg.testModeEnabled = true }
        if let v = env["VIVA_TEST_BACKEND_URL"], !v.isEmpty {
            cfg.testModeEnabled = true
            cfg.testBackendBaseURL = v
        }

        return cfg
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.configDir,
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // ⚠️ 必须 .atomic。非原子写在写入过程中被打断（强退 / 磁盘满 / 被系统杀）
        //   会留下截断的 config.json，下次启动解码失败 → 用户设置静默清零。
        try enc.encode(self).write(to: Self.configURL, options: .atomic)
        // 配置里包含隐私偏好和本地服务地址，仍保持仅当前用户可读。
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.configURL.path)
    }
}
