import Foundation

// MARK: - 预设词库

/// 官方维护的预设词库（热词 + 替换规则），数据源是仓库根目录的 `wordlists/*.json`。
///
/// 三级加载，优先级从高到低：
///   1. 本地缓存 `~/.config/viva/data/wordlists/`（上次从 GitHub 拉到的最新版）
///   2. App 内置副本（build.sh 把仓库的 wordlists/ 打进 Resources，离线也有兜底）
///   3. 都没有 → 该词库不可用
///
/// 远程同步：启动后从 GitHub raw 拉一次（24h 内拉过则跳过），version 更大才落缓存。
/// 这样**维护者改一下仓库里的 JSON，全体用户一天内自动拿到新词**，不用发版。
struct Wordlist: Codable, Identifiable {
    var schema: Int = 1
    var id: String
    var name: String
    var description: String = ""
    var version: Int = 0
    var updatedAt: String = ""
    var hotwords: [String] = []
    var replaceRules: [ReplaceRule] = []
}

@MainActor
final class WordlistStore: ObservableObject {
    static let shared = WordlistStore()

    /// 词库注册表。**数组顺序 = 合并优先级**（热词窗口约 60 词，先到先得）：
    /// AI 词 churn 最快、混淆度最高排最前。加库 = 这里登记 + 仓库 wordlists/ 放 JSON。
    static let knownIds = ["ai", "it", "work"]
    /// raw.githubusercontent.com 的 main 分支 —— 改仓库文件即全网生效
    static let remoteBase = "https://raw.githubusercontent.com/d100000/viva/main/wordlists"

    @Published private(set) var lists: [Wordlist] = []
    @Published private(set) var syncStatus = ""
    @Published private(set) var syncing = false

    private static var cacheDir: URL {
        Config.dataDir.appendingPathComponent("wordlists", isDirectory: true)
    }

    private init() { reload() }

    // MARK: - 加载

    func reload() {
        lists = Self.knownIds.compactMap { Self.loadOne($0) }
    }

    private static func loadOne(_ id: String) -> Wordlist? {
        let dec = JSONDecoder()
        // 缓存版和内置版都解析出来，取 version 更大的 —— 降级安装（装回旧 App）时
        // 缓存里的新版词库依然生效
        let cached = (try? Data(contentsOf: cacheDir.appendingPathComponent("\(id).json")))
            .flatMap { try? dec.decode(Wordlist.self, from: $0) }
        let bundled = Bundle.main.url(forResource: id, withExtension: "json",
                                      subdirectory: "wordlists")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? dec.decode(Wordlist.self, from: $0) }
        switch (cached, bundled) {
        case let (c?, b?): return c.version >= b.version ? c : b
        case let (c?, nil): return c
        case let (nil, b?): return b
        default: return nil
        }
    }

    // MARK: - 远程同步

    /// 启动时调用：24 小时内同步过就跳过。手动刷新用 refresh(force: true)。
    func refreshIfStale() {
        let stampURL = Self.cacheDir.appendingPathComponent(".last-sync")
        if let mtime = try? FileManager.default
            .attributesOfItem(atPath: stampURL.path)[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < 24 * 3600 {
            return
        }
        refresh(force: false)
    }

    func refresh(force: Bool) {
        guard !syncing else { return }
        syncing = true
        syncStatus = "同步中…"
        Task { @MainActor in
            defer { syncing = false }
            var updated: [String] = []
            var failed = false
            for id in Self.knownIds {
                do {
                    if let new = try await Self.fetchRemote(id) { updated.append(new) }
                } catch {
                    failed = true
                    Log.warn("词库 \(id) 同步失败：\(error.localizedDescription)")
                }
            }
            // 成功才盖时间戳 —— 失败的下次启动继续重试，不被 24h 节流挡住
            if !failed {
                let fm = FileManager.default
                try? fm.createDirectory(at: Self.cacheDir, withIntermediateDirectories: true)
                let stamp = Self.cacheDir.appendingPathComponent(".last-sync")
                try? Data().write(to: stamp)
            }
            if !updated.isEmpty {
                reload()
                syncStatus = "已更新：\(updated.joined(separator: "、"))"
                Log.info("预设词库已更新：\(updated.joined(separator: "、"))")
            } else {
                syncStatus = failed ? "同步失败（离线？用本地版本继续）" : "已是最新"
            }
        }
    }

    /// 返回「名称 vN」表示拉到了新版；nil 表示远端不比本地新
    private static func fetchRemote(_ id: String) async throws -> String? {
        guard let url = URL(string: "\(remoteBase)/\(id).json") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "wordlist", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"])
        }
        // 先完整解码再落盘 —— 仓库里改坏的 JSON 不能污染本地缓存
        let new = try JSONDecoder().decode(Wordlist.self, from: data)
        let current = loadOne(id)
        guard new.version > (current?.version ?? -1) else { return nil }
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try data.write(to: cacheDir.appendingPathComponent("\(id).json"), options: .atomic)
        return "\(new.name) v\(new.version)"
    }

    // MARK: - 合并（用户配置优先）

    /// 用户自己的热词排最前（直传 context 约 100 tokens，先到先得），
    /// 预设词补在后面，去重，总量交给 ASR 客户端的 prefix(60) 截断。
    func mergedHotwords(user: [String], enabledLists: [String]) -> [String] {
        var out = user
        for list in lists where enabledLists.contains(list.id) {
            for w in list.hotwords where !out.contains(w) { out.append(w) }
        }
        return out
    }

    /// 用户规则优先：同一个 from，用户的 to 覆盖预设的
    func mergedRules(user: [ReplaceRule], enabledLists: [String]) -> [ReplaceRule] {
        var out = user
        let taken = Set(user.map(\.from))
        for list in lists where enabledLists.contains(list.id) {
            for r in list.replaceRules where !taken.contains(r.from) { out.append(r) }
        }
        return out
    }
}
