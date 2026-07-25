import Foundation

/// 上屏前的纯文本处理。故意做成无状态的静态函数 ——
/// 这些规则要能被 `--selftest` 直接验证，不该藏在 VoiceSession 的状态机里。
enum TextPolish {

    /// 句末**句号**。只认这三个：
    /// - `。` 中文句号（开了自动标点后 99% 是它）
    /// - `.` 英文句号
    /// - `．` 全角句点（少数 ITN 实现会吐这个）
    ///
    /// ⚠️ 故意**不含** `？！?!` —— 问号和感叹号带语气，去掉会改变语义
    ///   （「真的吗？」→「真的吗」读起来完全是两句话）。
    ///   也不含 `，、；` —— 逗号结尾说明话没说完，那是识别问题，不该在这里掩盖。
    private static let periods: Set<Character> = ["。", ".", "．"]

    /// 去掉结尾的一个句号（连同它后面的空白）。
    ///
    /// 只去**一个**：「等等...」这种省略号是用户的表达，连着吃掉三个点就成了篡改。
    /// 首尾都是句号的情况（比如整段就是一个「。」）会返回空串，调用方负责判空。
    static func stripTrailingPeriod(_ s: String) -> String {
        var out = Substring(s)
        // 先剥掉尾部空白，否则 "你好。 " 这种会漏掉
        while let last = out.last, last.isWhitespace { out = out.dropLast() }
        guard let last = out.last, periods.contains(last) else { return s }

        // 省略号保护：`...` / `。。。` 是表达，不是句末标点
        let body = out.dropLast()
        if let prev = body.last, periods.contains(prev) { return s }

        return String(body)
    }

    /// 逐句上屏时的「扣下-补回」游标。
    ///
    /// 为什么需要它：边说边写是**一句一句**写进用户输入框的，写的那一刻根本不知道
    /// 哪句是最后一句；而本项目有条硬规则 —— **绝不退格回改**（算错一次就会不可逆地
    /// 删掉用户自己敲的字，竞品这类事故都是这么来的）。
    ///
    /// 所以反过来做：每句先把末尾句号摘下来暂存，下一句到了再补回句首。
    /// 说完之后，最后被扣下的那个句号自然就不会被吐出去。全程只追加。
    ///
    /// ```
    /// "你好。"     → feed → "你好"        （held = "。"）
    /// "今天不错。" → feed → "。今天不错"  （held = "。"）
    /// 松手                                 held 丢弃
    /// 输入框里：你好。今天不错
    /// ```
    struct PeriodHold {
        private var held = ""

        mutating func reset() { held = "" }

        /// 传入这一句定稿文本，返回真正该上屏的内容（可能为空串）。
        mutating func feed(_ chunk: String) -> String {
            let merged = held + chunk
            let kept = TextPolish.stripTrailingPeriod(merged)
            // kept 一定是 merged 的前缀，差值就是这次扣下的部分
            held = String(merged.dropFirst(kept.count))
            return kept
        }
    }
}
