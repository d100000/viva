import Foundation

// MARK: - 替换规则

/// 一条确定性替换：识别结果里的 `from` 一律改写为 `to`。
///
/// 与热词的分工：热词只能**提高**某个词被识别出来的概率，纠不了顽固错误；
/// 替换是确定性的 —— 「Cloth Code」永远变「Claude Code」，一次配置终身生效。
/// 这是竞品里「个人改词记忆」的底层机制（豆包输入法有，我们对标）。
struct ReplaceRule: Codable, Equatable, Hashable, Identifiable {
    var from: String
    var to: String
    var id: String { from }
}

// MARK: - 替换引擎

/// 把一组规则应用到识别文本上。会话开始时构建一次（用户规则 + 启用的预设词库规则），
/// 之后每帧 partial/definite 都过一遍 —— 规则量级是几十条、文本是几十字，开销可忽略。
///
/// ⚠️ 应用位置在 VoiceSession 的**文本入口**（handle/handleFinished/applyPolish），
///   partial 和 definite 用同一套规则替换，保证 PartialCommitter 的
///   前缀去重逻辑两边看到的文本一致。绝不在已上屏之后回头改（硬性不变量）。
struct TextReplacer {
    private let rules: [ReplaceRule]

    init(rules: [ReplaceRule]) {
        // 长的 from 优先匹配：规则「Cloud→Claude」和「Cloud Code→Claude Code」并存时,
        // 先替换长的，避免短规则把长规则的匹配现场破坏掉
        self.rules = rules
            .filter { !$0.from.isEmpty && $0.from != $0.to }
            .sorted { $0.from.count > $1.from.count }
    }

    var isEmpty: Bool { rules.isEmpty }

    func apply(_ text: String) -> String {
        guard !text.isEmpty, !rules.isEmpty else { return text }
        var out = text
        for r in rules {
            out = out.replacingOccurrences(of: r.from, with: r.to)
        }
        return out
    }

    // MARK: - 改词记忆：从用户的一次手动修改中学出规则

    /// 对比识别原文和用户改后的文本，若差异是**一处简单替换**就提取成规则。
    /// 掐头去尾取公共前后缀，中间剩下的就是 from→to。
    /// 刻意保守：差异过长（>14 字）或为空都不建议 —— 学错一条规则会污染以后每一句。
    static func suggest(original: String, edited: String) -> ReplaceRule? {
        guard original != edited, !original.isEmpty, !edited.isEmpty else { return nil }
        let o = Array(original), e = Array(edited)
        var p = 0
        while p < min(o.count, e.count), o[p] == e[p] { p += 1 }
        var s = 0
        while s < min(o.count, e.count) - p, o[o.count - 1 - s] == e[e.count - 1 - s] { s += 1 }
        let from = String(o[p..<(o.count - s)])
        let to = String(e[p..<(e.count - s)])
        guard !from.isEmpty, !to.isEmpty, from != to,
              from.count <= 14, to.count <= 14 else { return nil }
        // 单字→单字的替换误伤率太高（「的→地」会把满屏的「的」全改掉），不学
        guard from.count >= 2 || to.count >= 2 else { return nil }
        // 纯标点/空白的差异是语气调整，不是改错字
        let meaningful = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: Unicode.Scalar(0x4E00)!...Unicode.Scalar(0x9FFF)!))
        guard from.unicodeScalars.contains(where: { meaningful.contains($0) }) else { return nil }
        return ReplaceRule(from: from, to: to)
    }
}
