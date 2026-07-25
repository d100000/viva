import Foundation

/// 在线拉取服务商的模型列表（OpenAI 标准 `GET /models`）。
///
/// 为什么值得单独做一个模块：润色配置里最劝退的一步一直是「model 该填什么」。
/// 模型名 churn 极快（见 `LLMProvider` 顶部注释：deepseek-chat 已下线、
/// 豆包 1.6/1.8 全系标注即将下线），任何写死的预设表都会过期；而每家的
/// 模型广场都藏在控制台深处，用户得开浏览器、找文档、抄一个大小写敏感的字符串回来。
///
/// 中转/聚合类服务尤其明显 —— 一个 Key 后面挂着几百个模型，手抄根本不现实。
/// 所以这里直接问服务端要：`GET {baseURL}/models`。这是 OpenAI 规范的一部分，
/// one-api / new-api 这类中转层、DeepSeek、硅基流动、Ollama 的 /v1 兼容层
/// 都实现了它。
///
/// ⚠️ 设计原则：**这是锦上添花，不是必需路径**。拿不到就静默降级回手填，
///    绝不阻塞配置流程 —— 有些自建服务会把 /models 关掉。
enum ModelCatalog {

    /// 一个可选模型。`cheapTier` 越小越适合润色（便宜且快）。
    struct Entry: Identifiable, Hashable {
        let id: String
        let cheapTier: Int

        /// 给 UI 用的一句话说明
        var note: String {
            cheapTier == 0 ? "轻量档 · 润色首选" : ""
        }
    }

    enum CatalogError: LocalizedError {
        case unsupported(String)
        case http(Int, String)
        case badPayload
        case empty

        var errorDescription: String? {
            switch self {
            case .unsupported(let s): return s
            case .http(let code, let body):
                if code == 401 || code == 403 {
                    return "鉴权失败（HTTP \(code)）—— 检查 API Key 是否填对、是否已过期。"
                }
                if code == 404 {
                    return "该服务没有提供模型列表接口（HTTP 404）。手动填模型名即可。"
                }
                return "HTTP \(code)：\(body.prefix(200))"
            case .badPayload: return "返回内容不是预期的模型列表格式。"
            case .empty:      return "服务返回了空列表 —— 可能这个 Key 还没有开通任何模型。"
            }
        }
    }

    // MARK: - 拉取

    static func fetch(baseURL: String,
                      apiKey: String,
                      format: APIFormat) async throws -> [Entry] {

        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty else { throw CatalogError.unsupported("请先填写服务地址。") }

        // Gemini 的模型列表长在另一套路径和响应结构上，且我们没有实测过，
        // 与其猜错不如明说。
        guard format != .geminiGenerate else {
            throw CatalogError.unsupported("Gemini 暂不支持自动拉取，请手动填模型名。")
        }

        // Ollama 原生用 /api/tags；其余走 OpenAI 标准的 /models
        let isOllama = (format == .ollamaNative)
        let path = isOllama ? "/api/tags" : "/models"

        // Ollama 的 base 通常带 /v1（兼容层），但 /api/tags 挂在根上
        var root = base
        if isOllama, root.hasSuffix("/v1") { root = String(root.dropLast(3)) }

        guard let url = URL(string: root + path) else {
            throw CatalogError.unsupported("服务地址非法：\(root + path)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 15
        for (k, v) in format.headers(apiKey: apiKey) where k != "Content-Type" {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CatalogError.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.badPayload
        }

        var ids: [String] = []
        if isOllama {
            // {"models":[{"name":"qwen2.5:3b", ...}]}
            let arr = (obj["models"] as? [[String: Any]]) ?? []
            ids = arr.compactMap { $0["name"] as? String }
        } else {
            // {"data":[{"id":"gpt-4o-mini", ...}]}  —— OpenAI / Anthropic / 各家中转都是这个
            let arr = (obj["data"] as? [[String: Any]]) ?? []
            ids = arr.compactMap { $0["id"] as? String }
        }

        let entries = rank(ids)
        guard !entries.isEmpty else { throw CatalogError.empty }
        return entries
    }

    // MARK: - 过滤与排序

    /// 非对话模型的关键词。中转站后面常挂着几百个条目，
    /// 把 embedding / 重排 / 语音 / 画图 混在里面选会直接调用失败。
    private static let nonChat = [
        "embed", "rerank", "bge-", "gte-", "text-embedding",
        "whisper", "tts", "asr", "speech", "audio", "voice",
        "dall-e", "flux", "stable-diffusion", "sd3", "sdxl", "kolors",
        "cogview", "cogvideo", "wanx", "seedream", "seededit", "sora",
        "moderation", "guard", "ocr", "translation-",
    ]

    /// 轻量档关键词 —— 润色一两句话根本用不上大模型，
    /// 这一档延迟和价格通常差一个数量级。
    private static let cheap = [
        "mini", "flash", "lite", "nano", "turbo", "air", "haiku",
        "small", "fast", "instant", "speed", "tiny",
    ]

    static func rank(_ ids: [String]) -> [Entry] {
        var seen = Set<String>()
        var out: [Entry] = []
        for id in ids {
            let low = id.lowercased()
            if nonChat.contains(where: { low.contains($0) }) { continue }
            guard seen.insert(low).inserted else { continue }
            out.append(Entry(id: id, cheapTier: cheap.contains(where: { low.contains($0) }) ? 0 : 1))
        }
        // 轻量档排前面，同档按名字排，保证每次拉取顺序稳定
        return out.sorted { a, b in
            a.cheapTier != b.cheapTier ? a.cheapTier < b.cheapTier : a.id < b.id
        }
    }

    /// 拉完之后自动选一个。优先保留用户已经填过且仍然存在的那个 ——
    /// 拉取模型列表不该悄悄改掉用户的选择。
    static func autoPick(_ entries: [Entry], current: String) -> String {
        if !current.isEmpty, entries.contains(where: { $0.id == current }) { return current }
        return entries.first?.id ?? current
    }
}
