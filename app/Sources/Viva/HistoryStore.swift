import Foundation

/// 一条识别记录
struct VoiceRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var text: String
    var startedAt: Date
    /// 说话时长（秒）= 实际推流的音频时长，也是计费口径
    var durationSec: Double
    /// 首字返回延迟（毫秒）
    var firstCharMs: Int?
    /// 上屏目标 App
    var appBundleId: String?
    var appName: String?
    /// 是否成功写进了目标 App（false = 只复制到了剪贴板）
    var injected: Bool = true
    /// LLM 润色后的文本。Optional 字段，旧的 history.json 缺这个键也能正常解码。
    var polishedText: String? = nil

    /// 最终生效的文本（有润色就用润色后的）
    var finalText: String { polishedText ?? text }
    /// 中文按字符数算；英文按空格分词更合理，这里做混合估算
    var charCount: Int { finalText.count }

    var wordCount: Int {
        let ascii = text.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let cjk = text.filter { $0.unicodeScalars.first.map { s in
            (0x4E00...0x9FFF).contains(Int(s.value)) } ?? false }
        // 英文按 5 字符 ≈ 1 词的通行折算，中文 1 字 ≈ 1 词
        return cjk.count + max(0, ascii.count / 5)
    }
}

/// 统计汇总
struct VoiceStats {
    var count = 0                 // 说话次数
    var totalSeconds: Double = 0  // 累计说话时长
    var totalChars = 0            // 累计字数
    var totalWords = 0

    /// 语速：字/分钟
    var charsPerMinute: Double {
        totalSeconds > 0 ? Double(totalChars) / (totalSeconds / 60) : 0
    }

    /// 节省的时间（分钟）。
    /// 中文键盘输入速度按 30 字/分钟保守估算（熟练拼音用户 40~60，这里取低值避免虚报）。
    static let typingCharsPerMinute: Double = 30
    var savedMinutes: Double {
        let typingMin = Double(totalChars) / Self.typingCharsPerMinute
        return max(0, typingMin - totalSeconds / 60)
    }

    var avgFirstCharMs: Int? {
        firstCharSamples.isEmpty ? nil
            : Int(firstCharSamples.reduce(0, +) / Double(firstCharSamples.count))
    }
    var firstCharSamples: [Double] = []

    /// 费用（豆包流式 2.0 后付费 1 元/小时）
    var cost: Double { totalSeconds / 3600 * 1.0 }
}

/// 历史记录持久化 + 统计。
///
/// 用 JSON 单文件存储：语音输入的记录量级（一天几十到几百条）用 JSON 完全够用，
/// 且方便用户自己查看和备份。文件权限 600 —— 识别内容属于隐私。
@MainActor
final class HistoryStore: ObservableObject {

    static let shared = HistoryStore()

    @Published private(set) var records: [VoiceRecord] = []

    private let url = Config.configDir.appendingPathComponent("history.json")
    private var saveTask: Task<Void, Never>?

    private init() { load() }

    // MARK: - 读写

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            records = try dec.decode([VoiceRecord].self, from: data)
            records.sort { $0.startedAt > $1.startedAt }
        } catch {
            // ⚠️ 原来是 `try? … ?? []`：任何解码失败都静默退化成空数组，
            //   而下一条记录会用「单元素数组」原子覆盖原文件 —— 全部历史与
            //   统计永久归零且没有任何提示。改成先把坏文件挪走再继续。
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("history.corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.moveItem(at: url, to: backup)
            records = []
            Log.error("历史记录解码失败：\(error.localizedDescription)。原文件已保留为 history.corrupt.json")
        }
    }

    /// 合并写盘，避免每条记录都触发一次 IO
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try FileManager.default.createDirectory(at: Config.configDir,
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted]
            try enc.encode(records).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: url.path)
        } catch {
            Log.error("历史记录写入失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 变更

    func add(_ r: VoiceRecord) {
        records.insert(r, at: 0)
        scheduleSave()
    }

    func delete(_ r: VoiceRecord) {
        records.removeAll { $0.id == r.id }
        scheduleSave()
    }

    func clearAll() {
        records.removeAll()
        saveNow()
    }

    var fileURL: URL { url }

    // MARK: - 统计

    func stats(since: Date? = nil) -> VoiceStats {
        var s = VoiceStats()
        for r in records {
            if let since, r.startedAt < since { continue }
            s.count += 1
            s.totalSeconds += r.durationSec
            s.totalChars += r.charCount
            s.totalWords += r.wordCount
            if let f = r.firstCharMs { s.firstCharSamples.append(Double(f)) }
        }
        return s
    }

    var today: VoiceStats { stats(since: Calendar.current.startOfDay(for: Date())) }

    var thisWeek: VoiceStats {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear],
                                                      from: Date())) ?? Date()
        return stats(since: start)
    }

    var allTime: VoiceStats { stats() }

    /// 连续使用天数（今天没用则从昨天算起，避免早上打开就显示断签）
    var streak: Int {
        let cal = Calendar.current
        let days = Set(records.map { cal.startOfDay(for: $0.startedAt) })
        guard !days.isEmpty else { return 0 }

        var cursor = cal.startOfDay(for: Date())
        if !days.contains(cursor) {
            guard let y = cal.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(y) else { return 0 }
            cursor = y
        }
        var n = 0
        while days.contains(cursor) {
            n += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return n
    }

    /// 按 App 分布（次数 + 字数），降序
    func appBreakdown(limit: Int = 6) -> [(name: String, count: Int, chars: Int)] {
        var m: [String: (Int, Int)] = [:]
        for r in records {
            let key = r.appName ?? r.appBundleId ?? "未知"
            let cur = m[key] ?? (0, 0)
            m[key] = (cur.0 + 1, cur.1 + r.charCount)
        }
        return m.map { (name: $0.key, count: $0.value.0, chars: $0.value.1) }
            .sorted { $0.count > $1.count }
            .prefix(limit).map { $0 }
    }

    /// 最近 N 天每天的字数，用于热力图/趋势
    func dailyChars(days: Int = 84) -> [(date: Date, chars: Int, count: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var m: [Date: (Int, Int)] = [:]
        for r in records {
            let d = cal.startOfDay(for: r.startedAt)
            let cur = m[d] ?? (0, 0)
            m[d] = (cur.0 + r.charCount, cur.1 + 1)
        }
        return (0..<days).reversed().compactMap { i -> (Date, Int, Int)? in
            guard let d = cal.date(byAdding: .day, value: -i, to: today) else { return nil }
            let v = m[d] ?? (0, 0)
            return (d, v.0, v.1)
        }
    }

    /// 按日期分组，用于历史列表
    func grouped(matching query: String = "") -> [(day: Date, items: [VoiceRecord])] {
        let cal = Calendar.current
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? records
            : records.filter { $0.finalText.lowercased().contains(q)
                               || $0.text.lowercased().contains(q) }
        var m: [Date: [VoiceRecord]] = [:]
        for r in filtered { m[cal.startOfDay(for: r.startedAt), default: []].append(r) }
        return m.keys.sorted(by: >).map { (day: $0, items: m[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }

    // MARK: - 导出

    func exportMarkdown() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = "# 语音输入记录\n\n共 \(records.count) 条\n\n"
        for g in grouped() {
            let dayFmt = DateFormatter(); dayFmt.dateFormat = "yyyy-MM-dd"
            out += "## \(dayFmt.string(from: g.day))\n\n"
            for r in g.items {
                out += "- **\(df.string(from: r.startedAt))**"
                if let a = r.appName { out += " · \(a)" }
                out += String(format: " · %.1fs · %d 字\n", r.durationSec, r.charCount)
                out += "  \n  \(r.finalText)\n\n"
                if let p = r.polishedText, p != r.text {
                    out += "  <sub>原文：\(r.text)</sub>\n\n"
                }
            }
        }
        return out
    }

    func exportCSV() -> String {
        // ⚠️ 表头必须是 7 列 —— 下面每行确实写了 7 个字段（文本 + 原文）。
        //   原来表头只有 6 列，Excel/Numbers 打开会多出一列无表头数据，
        //   导入脚本按表头取列会整体错位。
        var out = "时间,App,时长秒,字数,首字毫秒,文本,原文\n"
        let df = ISO8601DateFormatter()
        for r in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            func csv(_ v: String) -> String {
                "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            let text = csv(r.finalText) + "," + csv(r.polishedText == nil ? "" : r.text)
            // App 名必须转义：localizedName 里带英文逗号的 App 会再切出一列，
            // 把后面所有列整体右移。
            out += "\(csv(df.string(from: r.startedAt))),\(csv(r.appName ?? "")),"
            out += String(format: "%.2f,%d,%@,", r.durationSec, r.charCount,
                          r.firstCharMs.map(String.init) ?? "")
            out += text + "\n"
        }
        return out
    }
}
