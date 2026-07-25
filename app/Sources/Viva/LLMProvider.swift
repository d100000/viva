import Foundation

/// 各家 OpenAI 兼容服务的预设。
///
/// ⚠️ 这个表是 2026-07-25 逐家核实官方文档得来的，不是凭印象写的。两条最关键的发现：
///
/// 1. **当代模型几乎全都默认开启「深度思考」，而每家关闭的写法都不一样。**
///    润色一两句话本来该 1 秒内返回，开着思考会先吐一大段思维链 ——
///    延迟涨到几秒，而且思维链按输出 token 计费。有的家还会因此让 content 返回空串。
///    所以 `thinkingOff` 必须按厂商注入正确的参数。
///
/// 2. **模型名 churn 极快。** `deepseek-chat` 已于 2026-07-24 15:59 UTC 彻底下线；
///    豆包 1.6/1.8 全系标注即将下线；OpenAI 的 gpt-5-nano 2026-10-23 停服。
///    所以模型名一律做成**可编辑的字符串 + 建议列表**，绝不写死。
struct LLMProvider: Identifiable, Hashable {

    /// 关闭深度思考的参数写法 —— 每家不一样，传错了等于没关
    enum ThinkingOff: String, Hashable {
        case none                    // 该模型本来就不思考
        case thinkingDisabled        // "thinking": {"type": "disabled"}
        case enableThinkingFalse     // "enable_thinking": false
        case reasoningEffortNone     // "reasoning_effort": "none"

        var label: String {
            switch self {
            case .none: return "不需要（模型默认不思考）"
            case .thinkingDisabled: return #"thinking: {"type": "disabled"}"#
            case .enableThinkingFalse: return "enable_thinking: false"
            case .reasoningEffortNone: return #"reasoning_effort: "none""#
            }
        }
    }

    struct Model: Hashable {
        let id: String
        let note: String
    }

    let id: String
    let name: String
    let baseURL: String
    let models: [Model]
    let thinkingOff: ThinkingOff
    /// OpenAI 的 gpt-5.x 只认 max_completion_tokens，传 max_tokens 会报参数错误
    let useMaxCompletionTokens: Bool
    /// gpt-5.x 把 temperature 锁死为 1，传了直接 400
    let sendTemperature: Bool
    /// 智谱的 temperature 是开区间 (0,1)，不能传 0
    let temperature: Double
    let keyURL: String?
    let hint: String

    // MARK: - 预设表

    static let all: [LLMProvider] = [
        LLMProvider(
            id: "ark",
            name: "火山方舟（豆包）",
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            models: [
                .init(id: "doubao-seed-2-0-mini-260428",
                      note: "首选 · 最便宜（0.2/2.0 元每百万 token）"),
                .init(id: "doubao-seed-2-0-lite-260428",
                      note: "mini 效果不够时再上（0.6/3.6 元）"),
            ],
            thinkingOff: .thinkingDisabled,
            useMaxCompletionTokens: false, sendTemperature: true, temperature: 0.2,
            keyURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey",
            hint: "和语音识别的 Key 不是同一个，要单独在方舟建。⚠️ 建完还必须去「开通管理」把模型开通，否则调用会失败。model 填模型名即可，不需要创建推理接入点（ep-xxx 是进阶用法）。"
        ),
        LLMProvider(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            models: [
                .init(id: "deepseek-v4-flash", note: "首选 · 便宜快"),
                .init(id: "deepseek-v4-pro", note: "约 3 倍价，润色用不上"),
            ],
            thinkingOff: .thinkingDisabled,
            useMaxCompletionTokens: false, sendTemperature: true, temperature: 0.2,
            keyURL: "https://platform.deepseek.com/api_keys",
            hint: "⚠️ deepseek-chat / deepseek-reasoner 已于 2026-07-24 彻底下线，只能用 v4。baseURL 用不带 /v1 的裸域名。预付费制，余额为 0 会返回 402。"
        ),
        LLMProvider(
            id: "dashscope",
            name: "阿里百炼（通义千问）",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            models: [
                .init(id: "qwen-flash", note: "首选 · 默认就不思考，最省心"),
                .init(id: "qwen3.6-flash", note: "更新一代，但默认开思考"),
                .init(id: "qwen-turbo", note: "最老最便宜，够用"),
            ],
            thinkingOff: .enableThinkingFalse,
            useMaxCompletionTokens: false, sendTemperature: true, temperature: 0.2,
            keyURL: "https://bailian.console.aliyun.com/",
            hint: "⚠️ 路径是 /compatible-mode/v1，不是 /v1，填错直接 404。需实名认证并开通百炼，新用户有 100 万 token 免费额度。Key 与地域绑定。"
        ),
        LLMProvider(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            models: [
                .init(id: "gpt-4o-mini", note: "首选 · 非推理模型，延迟最低"),
                .init(id: "gpt-5.4-nano", note: "更便宜，reasoning_effort 默认 none"),
            ],
            thinkingOff: .reasoningEffortNone,
            useMaxCompletionTokens: true, sendTemperature: false, temperature: 0.2,
            keyURL: "https://platform.openai.com/api-keys",
            hint: "⚠️ gpt-5.x 把 temperature 锁死为 1（传了会 400），且只认 max_completion_tokens。别用 gpt-5-nano —— 2026-10-23 停服。项目级 key 需在 project 里勾上模型白名单。"
        ),
        LLMProvider(
            id: "zhipu",
            name: "智谱 GLM",
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            models: [
                .init(id: "glm-4.7-flash", note: "首选 · 官方免费模型"),
                .init(id: "glm-4.7-flashx", note: "免费档限流时的付费兜底"),
            ],
            thinkingOff: .thinkingDisabled,
            useMaxCompletionTokens: false, sendTemperature: true, temperature: 0.1,
            keyURL: "https://open.bigmodel.cn/usercenter/apikeys",
            hint: "⚠️ 路径是 /api/paas/v4，不是 /v1。temperature 是开区间 (0,1)，不能传 0，这里用 0.1。GLM-4.5 代以后是混合推理模型，关思考的写法官方没文档化，建议用「测试连接」确认返回里没有思维链。"
        ),
        LLMProvider(
            id: "siliconflow",
            name: "硅基流动 SiliconFlow",
            baseURL: "https://api.siliconflow.cn/v1",
            models: [
                .init(id: "inclusionAI/Ling-mini-2.0",
                      note: "首选 · 最便宜（0.5/2.0 元每百万），生成极快"),
                .init(id: "Qwen/Qwen3.5-4B", note: "小而稳，需关思考"),
            ],
            thinkingOff: .enableThinkingFalse,
            useMaxCompletionTokens: false, sendTemperature: true, temperature: 0.2,
            keyURL: "https://cloud.siliconflow.cn/account/ak",
            hint: "模型 id 大小写敏感（inclusionAI 不是 InclusionAI）。国内站与海外站账号和 Key 不通用。"
        ),
        LLMProvider(
            id: "ollama",
            name: "Ollama（本地，免费）",
            baseURL: "http://localhost:11434/v1",
            models: [
                .init(id: "qwen2.5:3b", note: "首选 · 非思考模型，最省心（1.9GB）"),
                .init(id: "qwen3.5:2b", note: "更新更快，但默认开思考（2.7GB）"),
                .init(id: "qwen3.5:4b", note: "质量更稳（3.4GB）"),
            ],
            thinkingOff: .reasoningEffortNone,
            useMaxCompletionTokens: false, sendTemperature: true, temperature: 0.2,
            keyURL: nil,
            hint: "本地服务不校验鉴权，Key 随便填个非空串（如 ollama）即可。⚠️ 模型必须先 `ollama pull` 过，且 model 要和 `ollama list` 第一列完全一致（含 :3b 这种 tag）。首次请求有冷启动延迟，闲置 5 分钟会卸载。"
        ),
        LLMProvider(
            id: "custom",
            name: "自定义",
            baseURL: "",
            models: [],
            thinkingOff: .none,
            useMaxCompletionTokens: false, sendTemperature: true, temperature: 0.2,
            keyURL: nil,
            hint: "任何 OpenAI 兼容的 /chat/completions 都能接。如果你的模型默认会思考，记得在下面选对「关闭思考」的写法 —— 每家写法不一样，传错等于没关。"
        ),
    ]

    static func find(_ id: String) -> LLMProvider {
        all.first { $0.id == id } ?? all.first { $0.id == "custom" }!
    }
}
