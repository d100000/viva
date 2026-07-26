import Foundation

/// 连续听写的「稳定前缀提交」引擎（方案见 09-连续听写技术方案.md §2 路线 B）。
///
/// 背景：服务端判停的唯一依据是静音。用户连续说话不留停顿 → 永远没有 definite →
/// 文字全部憋在 partial 里直到松手。本类型把 partial 中**不会再被修订**的前缀
/// 提前挑出来交给调用方上屏。
///
/// 判定「不会再被修订」的四个条件（全部同时满足）：
///   1. partial 总长 ≥ minLength —— 短句让原有 definite 流程处理
///   2. 提交点必须是**标点**（服务端 enable_punc 已开；标点 = 语言模型认为小句已闭合）
///   3. 提交点之前的前缀连续 stableFrames 帧逐字未变
///   4. 提交点距 partial 尾部 ≥ tailGuard 字素 —— 修订几乎只发生在尾部
///
/// 硬性约束：本项目**绝不退格回改**。这里提交出去的每个字都收不回来，
/// 所以所有阈值宁可保守（漏提交没有代价——definite 到了照样上屏；错提交不可逆）。
///
/// 纯逻辑、无 UI、无注入 —— 可以拿合成的 partial 序列直接压测。
struct PartialCommitter {

    /// 允许作为提交点的标点。
    /// ⚠️ 故意不含 ASCII 的 `.` `:` `;` —— 「3.14」「10:30」「Mr.」这类会被劈开。
    ///   中文语流里 enable_punc 吐的是全角标点，覆盖面足够。
    private static let boundaryPunct: Set<Character> =
        ["，", "。", "？", "！", "；", "：", "、", ",", "?", "!"]

    private var minLength: Int
    private var stableFrames: Int
    private var tailGuard: Int

    /// 已提交（= 调用方已注入）的字素数，相对当前 partial 尾巴的起点
    private(set) var injectedGraphemes: Int = 0
    /// 最近若干帧的 partial（字素数组），用于稳定性判断
    private var history: [[Character]] = []

    init(minLength: Int = 20, stableFrames: Int = 3, tailGuard: Int = 8) {
        // 下限防呆：全 0 配置会退化成「见标点就提交」，把修订区也交出去
        self.minLength = max(4, minLength)
        self.stableFrames = max(2, stableFrames)
        self.tailGuard = max(2, tailGuard)
    }

    init(config: Config) {
        self.init(minLength: config.progressiveMinLength,
                  stableFrames: config.progressiveStableFrames,
                  tailGuard: config.progressiveTailGuard)
    }

    // MARK: - 喂 partial

    /// 每帧调用。返回这一帧可以安全上屏的增量（无则空串）。
    mutating func feed(partialTail: String) -> String {
        let chars = Array(partialTail)   // Character 即字素簇
        history.append(chars)
        if history.count > stableFrames { history.removeFirst(history.count - stableFrames) }

        guard chars.count >= minLength, history.count >= stableFrames else { return "" }

        // 从尾部往前找最后一个满足 tailGuard 的标点
        // 提交区间是 [0, cut]（含标点）；cut 之后到尾部是修订缓冲区
        var cut = -1
        let limit = chars.count - tailGuard   // 提交点必须 < limit
        var i = min(limit, chars.count) - 1
        while i > 0 {   // i > 0：单独一个标点开头没有提交价值
            if Self.boundaryPunct.contains(chars[i]) { cut = i; break }
            i -= 1
        }
        guard cut >= 0 else { return "" }

        let commitCount = cut + 1
        guard commitCount > injectedGraphemes else { return "" }   // 没有新内容

        // 稳定性：候选前缀必须在全部历史帧里逐字一致
        for frame in history {
            guard frame.count >= commitCount else { return "" }
            // 逐字比对而不是整段 hash —— N 帧 × 前缀长度在这个量级下微不足道
            for j in injectedGraphemes..<commitCount where frame[j] != chars[j] {
                return ""
            }
        }
        // 已提交区间若被修订（frame[0..<injected] 变了）也无能为力 —— 绝不退格，
        // 这里只保证不在动荡的区间上追加提交。

        let increment = String(chars[injectedGraphemes..<commitCount])
        injectedGraphemes = commitCount
        return increment
    }

    // MARK: - definite 对账

    /// definite（或会话收尾的 trailing）到达时调用。
    /// 返回其中**还没被逐段提交过**的尾巴 —— 调用方直接上屏。
    ///
    /// 用饱和减法统一处理所有边界：
    /// - definite 覆盖了已提交前缀 → 只吐出多出来的部分
    /// - definite 只覆盖了已提交前缀的一部分（跨 utterance 提交）→ 吐空串，余额留给下一批
    /// - 从没提交过 → 原样吐回
    ///
    /// ⚠️ 按字素**数**切，不做文本 diff：若服务端把已提交区间修订成了别的字，
    ///   我们既检测不了也补救不了（绝不退格），按数量切至少保证不重复、不丢尾巴。
    mutating func consumeDefinite(_ definite: String) -> String {
        defer {
            // definite 之后服务端会开启新的 utterance，partial 尾巴换人了
            history.removeAll(keepingCapacity: true)
        }
        let chars = Array(definite)
        if injectedGraphemes >= chars.count {
            injectedGraphemes -= chars.count
            return ""
        }
        let remainder = String(chars[injectedGraphemes...])
        injectedGraphemes = 0
        return remainder
    }

    /// 会话轮转 / 新会话开始：尾巴上下文作废（余额也清零 ——
    /// 轮转前必须先用 consumeDefinite 把旧会话的 trailing 对完账再调这里）
    mutating func reset() {
        injectedGraphemes = 0
        history.removeAll(keepingCapacity: true)
    }
}
