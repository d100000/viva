# 豆包 / 火山引擎 流式语音识别接入详解

> 全部内容基于火山引擎官方文档《流式语音识别 WebSocket》（文档中心 6561/1354869，页面标注最近更新 2026-06-26）与《计费说明》（6561/1359370，最近更新 2026-07-08）实测整理。

---

## 1. 先搞清楚：你要用哪一个产品

火山引擎语音识别有一堆容易混淆的产品，语音输入法**只应该看流式那一栏**：

| 产品 | 适用 | Resource ID | 后付费单价 |
|---|---|---|---|
| **豆包流式语音识别模型 2.0** ⭐ | **实时语音输入（推荐）** | `volc.seedasr.sauc.duration`（小时版）<br>`volc.seedasr.sauc.concurrent`（并发版） | **1 元/小时** |
| 大模型流式语音识别（1.0） | 老版本 | `volc.bigasr.sauc.duration` / `.concurrent` | 4.5 元/小时 |
| 豆包录音文件识别模型 2.0 | 整段音频离线转写 | `volc.bigasr.auc_turbo` 等 | 0.8 元/小时 |
| 豆包端到端实时语音大模型 | 语音对话（S2S），**不是转写** | — | 按 token |
| 豆包同声传译 2.0 | 边说边翻译 | — | 按 token |

> **选型结论：用「豆包流式语音识别模型 2.0」小时版**（`volc.seedasr.sauc.duration`）。
> 它比 1.0 便宜 4.5 倍，默认并发 50（1.0 只有 10），且是 Seed-ASR 2.0 模型，中文/方言效果更好。

---

## 2. 三个端点，选哪个

| 端点 | 模式 | 行为 | 适用 |
|---|---|---|---|
| `/api/v3/sauc/bigmodel` | 双向流式 | 每输入一包返回一包，尽快吐字 | 早期版本 |
| `/api/v3/sauc/bigmodel_nostream` | 流式输入 | 音频 >15 s 或收到最后一包才返回，**准确率更高** | 短语音一次性转写 |
| **`/api/v3/sauc/bigmodel_async`** ⭐ | **双向流式（优化版）** | **只在结果有变化时才返回新包**，RTF 与首字/尾字延迟均更优 | **语音输入法首选** |

完整地址：

```
wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async
```

> **为什么选 `bigmodel_async`**：
> 1. 官方明确「双向流式版本，更推荐使用双向流式模式（优化版），性能相对更优」。
> 2. **只有它支持 `enable_nonstream`（二遍识别）** —— 这是「又快又准」的关键：双向流式先逐字快速上屏，VAD 判停时用非流式模型**重新识别该分句**再给出高准确率的最终结果。既满足实时上屏，又保证最终质量。旧版链路不支持。
> 3. 不是每包都回包，客户端处理压力和流量都更小。

---

## 3. 鉴权

鉴权信息放在 **WebSocket 建连的 HTTP 请求头**里（不是 URL query，也不是首包 JSON）。

### 新版控制台（推荐）

| Header | 说明 | 示例 |
|---|---|---|
| `X-Api-Key` | 控制台获取的 APP Key | `123456789` |
| `X-Api-Resource-Id` | 资源 ID | `volc.seedasr.sauc.duration` |
| `X-Api-Request-Id` | 本次任务 ID，建议随机 UUID | `67ee89ba-7050-…` |
| `X-Api-Sequence` | 发包序号，**固定值 `-1`** | `-1` |

### 旧版控制台

| Header | 说明 |
|---|---|
| `X-Api-App-Key` | 控制台的 APP ID |
| `X-Api-Access-Key` | 控制台的 Access Token |
| `X-Api-Resource-Id` | 同上 |
| `X-Api-Request-Id` | 同上 |
| `X-Api-Sequence` | `-1` |

另可传 `X-Api-Connect-Id`（随机 UUID）用于链路追踪。

### 响应头（务必记录）

| Header | 用途 |
|---|---|
| **`X-Tt-Logid`** | 服务端 logid，**排障时提工单必需，一定要打日志** |
| `X-Api-Connect-Id` | 回显的追踪 ID |

---

## 4. 二进制协议

WebSocket 的 frame payload 里跑的是火山自定义的二进制协议。**所有整数字段一律大端（big-endian）。**

### 4.1 通用 Header（4 字节）

```
 Byte |  bit7 bit6 bit5 bit4 | bit3 bit2 bit1 bit0
------+----------------------+---------------------
  0   |  Protocol version(4) |   Header size(4)
  1   |  Message type(4)     |   Type specific flags(4)
  2   |  Serialization(4)    |   Compression(4)
  3   |            Reserved (8)
```

| 字段 | 取值 |
|---|---|
| **Protocol version** | `0b0001` = v1（目前只有这个） |
| **Header size** | `0b0001` → 实际 header 字节数 = 值 × 4 = 4 字节 |
| **Message type** | `0b0001` full client request（客户端首包，带参数）<br>`0b0010` audio only request（客户端音频包）<br>`0b1001` full server response（服务端识别结果）<br>`0b1111` server error（服务端错误） |
| **Type specific flags** | `0b0000` header 后 4 字节**不是** sequence<br>`0b0001` header 后 4 字节是 sequence 且**为正**<br>`0b0010` header 后 4 字节**不是** sequence，仅标识**这是最后一包（负包）**<br>`0b0011` header 后 4 字节是 sequence 且**必须为负**（最后一包） |
| **Serialization** | `0b0000` 无序列化（音频裸字节）<br>`0b0001` JSON |
| **Compression** | `0b0000` 不压缩<br>`0b0001` gzip |
| **Reserved** | `0x00` 填充 |

> ⚠️ **最容易踩的坑**：`Message type specific flags` 的语义是「header 之后的 4 字节要不要解释成 sequence」。
> 如果你用 `0b0000`，那么 header 后**直接跟 payload size**；
> 如果你用 `0b0001`/`0b0011`，header 后是 **4 字节 sequence，再跟 payload size**。
> 客户端这两个字节都算错的话，服务端会直接回 `45000001 请求参数无效`。

### 4.2 三种客户端消息的字节布局

**① Full client request（建连后的第一包，携带所有参数）**

```
+--------+------------------+------------------------+
| Header |  Payload size    |        Payload         |
| 4 B    |  4 B (uint32 BE) |  gzip(JSON) 或 JSON     |
+--------+------------------+------------------------+
  flags = 0b0000（官方 Demo 用法：不带 sequence）
  serialization = 0b0001 (JSON)
  compression   = 0b0001 (gzip)
```

**② Audio only request（音频包，发很多次）**

```
+--------+------------------+------------------------+
| Header |  Payload size    |    gzip(PCM bytes)     |
+--------+------------------+------------------------+
  message type   = 0b0010
  flags          = 0b0000  （普通包）
                 = 0b0010  （最后一包 / 负包）
  serialization  = 0b0000  （raw bytes，音频不是 JSON）
  compression    = 0b0001  （gzip，可选）
```

**③ Full server response（服务端返回）**

```
+--------+-----------+------------------+------------------------+
| Header | Sequence  |  Payload size    |     gzip(JSON)         |
| 4 B    | 4 B       |  4 B             |                        |
+--------+-----------+------------------+------------------------+
  message type = 0b1001
```

**④ Server error**

```
+--------+------------------+-------------------+------------------+
| Header | Error code (4B)  | Error msg size(4B)|  Error msg(UTF8) |
+--------+------------------+-------------------+------------------+
  message type = 0b1111
```

### 4.3 交互时序

```
Client                                          Server
  │                                                │
  ├── HTTP GET (Upgrade) + 鉴权 Header ──────────►│
  │◄────────── 101 Switching Protocols ────────────┤
  │              + X-Tt-Logid                      │
  │                                                │
  ├── Full client request (JSON 参数) ───────────►│
  │◄────────── Full server response (seq=1) ───────┤
  │                                                │
  ├── Audio only request #1 (200ms PCM) ─────────►│
  │◄────────── Full server response (seq=2) ───────┤  partial
  ├── Audio only request #2 ─────────────────────►│
  │◄────────── Full server response (seq=3) ───────┤  partial
  │                 ...                            │
  │                                                │  definite:true
  ├── Audio only request #N (flags=0b0010 末包) ──►│
  │◄────────── Full server response (最终结果) ─────┤
  │                                                │
  └────────────── close ───────────────────────────┘
```

---

## 5. 首包参数：针对「语音输入法」的推荐配置

### 5.1 完整参数说明（节选关键项）

**`audio` 段（必填）**

| 字段 | 推荐值 | 说明 |
|---|---|---|
| `format` | `"pcm"` | pcm/wav/ogg/mp3；pcm、wav 内部必须是 `pcm_s16le` |
| `codec` | `"raw"` | raw(=PCM) / opus；format=ogg 时必须 opus |
| `rate` | `16000` | **目前只支持 16000** |
| `bits` | `16` | 只支持 16 |
| `channel` | `1` | 单声道 |
| `language` | 留空 | ⚠️ **仅 `bigmodel_nostream` 支持**。留空时模型自动支持中英文 + 上海话/闽南语/四川/陕西/粤语/冀鲁/兰银/江淮 |

**`request` 段（必填）**

| 字段 | 推荐值 | 为什么 |
|---|---|---|
| `model_name` | `"bigmodel"` | 必填，目前只有这个值 |
| **`enable_nonstream`** | ⚠️ **`false`** | 二遍识别：判停后用非流式模型重识别该分句。**仅 `bigmodel_async` 支持**。<br>⚠️ **实测 3/3 复现：开启后 `corpus.context` 热词会失效** —— 见 §11。它在句子完整性/尾字上确实更好，但丢热词的代价通常更大 |
| **`show_utterances`** | **`true`** | ⭐ **必开**，否则拿不到 `utterances` 和 `definite`，就无法判断哪句可以提交上屏 |
| **`result_type`** | `"full"` 或 `"single"` | `full`=全量返回（默认）；`single`=增量，不返回之前分句。**输入法建议 `single`**，减少 diff 计算量 |
| **`end_window_size`** | **`500`~`800`** | ⭐ 强制判停时间（ms），默认 800，最小 200。静音超过该值直接判停出 `definite`。**这是尾字延迟的主要来源**，实时性优先可调 500 |
| `force_to_speech_time` | `1000` | 音频时长超过该值才开始尝试判停。避免刚开口就被切断。官方注明可能影响准确率 |
| `vad_segment_duration` | 不设 | 语义切句最大静音阈值，默认 3000 ms。**配置了 `end_window_size` 后此参数失效** |
| `enable_punc` | `true` | 自动标点（默认 true） |
| `enable_itn` | `true` | 文本规范化：「一九七零年」→「1970年」（默认 true） |
| `enable_ddc` | `true` | 语义顺滑，去口水词（默认 false）。**语音输入强烈建议开** |
| `enable_accelerate_text` | `false` | 加速首字返回，但**降低首字准确率**。除非极致追求延迟，否则别开 |
| `accelerate_score` | `0` | 配合上面，0~20，越大越快越不准 |
| `output_zh_variant` | 不设 | 需要繁体时设 `traditional`/`tw`/`hk` |
| `enable_speaker_info` | `false` | 说话人分离，输入法场景不需要（且要配 `ssd_version:"200"`） |
| `sensitive_words_filter` | 不设 | 除非有合规要求 |

**`corpus` 段（热词，强烈建议用）**

| 字段 | 说明 |
|---|---|
| `context` | ⭐ **热词直传**（优先级高于热词表）。双向流式支持 **100 tokens**，nostream 支持 5000 词。格式是 **JSON string（要转义）**：<br>`"context": "{\"hotwords\":[{\"word\":\"火山引擎\"},{\"word\":\"张三\"}]}"` |
| `context`（对话上下文用法） | 传 `context_type: "dialog_ctx"` + `context_data` 数组，限 **800 tokens / 20 轮**，超出按时间从新到旧截断。豆包 2.0 还支持传 `image_url`（≤500 KB，jpeg/jpg/png）做视觉上下文辅助转录 |
| `boosting_table_name` / `boosting_table_id` | 自学习平台配置的热词词表 |
| `correct_table_name` / `correct_table_id` | 替换词词表（强制 A→B） |

**`user` 段（可选，便于服务端日志过滤）**：`uid` / `did` / `platform` / `sdk_version` / `app_version`

### 5.2 语音输入法的推荐首包 JSON

```jsonc
{
  "user": {
    "uid": "device-uuid-或用户ID",
    "platform": "macOS 15.5",
    "app_version": "0.1.0"
  },
  "audio": {
    "format": "pcm",
    "codec": "raw",
    "rate": 16000,
    "bits": 16,
    "channel": 1
  },
  "request": {
    "model_name": "bigmodel",

    // —— 又快又准的核心组合 ——
    "enable_nonstream": false,     // ⚠️ 开启会让热词失效，见 §11 实测
    "show_utterances": true,       // 必开，才有 definite
    "result_type": "single",       // 增量返回，减少客户端 diff

    // —— 实时性调优 ——
    "end_window_size": 600,        // 判停 600ms（默认800，越小越快越碎）
    "force_to_speech_time": 1000,  // 前 1s 不判停，避免开口即断

    // —— 文本质量 ——
    "enable_punc": true,
    "enable_itn": true,
    "enable_ddc": true,            // 去口水词，语音输入必开

    // —— 热词（把用户词库塞进来）——
    "corpus": {
      "context": "{\"hotwords\":[{\"word\":\"火山引擎\"},{\"word\":\"豆包\"},{\"word\":\"Claude Code\"}]}"
    }
  }
}
```

---

## 6. 返回结果解析

```jsonc
{
  "audio_info": { "duration": 3696 },
  "result": {
    "text": "这是字节跳动，今日头条母公司。",   // 全量文本（result_type=full 时）
    "utterances": [
      {
        "text": "这是字节跳动，",
        "start_time": 0,
        "end_time": 1705,
        "definite": true,                      // ⭐ 这句已定稿，可以提交上屏
        "words": [
          { "text": "这", "start_time": 740, "end_time": 860, "blank_duration": 0 },
          { "text": "是", "start_time": 860, "end_time": 1020, "blank_duration": 0 }
          // ...
        ]
      },
      {
        "text": "今日头条母公司。",
        "start_time": 2110, "end_time": 3696,
        "definite": true,
        "words": [ /* ... */ ]
      }
    ]
  }
}
```

**上屏逻辑伪代码**：

```python
committed = ""      # 已经上屏的文本
preview   = ""      # 悬浮窗/预编辑区显示的未定稿文本

def on_server_response(resp):
    global committed, preview
    utts = resp["result"].get("utterances", [])

    new_definite = "".join(u["text"] for u in utts if u["definite"])
    pending      = "".join(u["text"] for u in utts if not u["definite"])

    if new_definite:
        commit_to_app(new_definite)     # 真正写入输入框
        committed += new_definite

    preview = pending
    update_floating_hud(preview)        # 只在悬浮窗/预编辑区显示
```

> ⚠️ 注意 `result_type` 的差异：
> - `full`：`utterances` 含**本次连接的所有分句**，`definite` 的句子会重复出现 → 需要用「已提交分句数」做游标，避免重复上屏。
> - `single`：只返回新分句 → 直接追加即可，**推荐**。

---

## 7. 错误码

| 错误码 | 含义 | 实战排查 |
|---|---|---|
| `20000000` | 成功 | — |
| `45000001` | 请求参数无效 | 90% 是**二进制协议拼错**（header flags / payload size / 大端写反），或首包 JSON 缺 `model_name`、`audio.format`；也可能是 `X-Api-Request-Id` 重复 |
| `45000002` | 空音频 | 一个音频包都没发就发了末包；或 VAD 把所有音频都滤掉了 |
| `45000081` | 等包超时 | 建连后长时间不发音频包。**连接预热方案必须配心跳或短超时重建** |
| `45000151` | 音频格式不正确 | 采样率不是 16000、位深不是 16、声道不是 1，或声称 pcm 实际发了 wav 头 |
| `550xxxxx` | 服务内部错误 | 带 `X-Tt-Logid` 提工单 |
| `55000031` | 服务器繁忙 | 服务过载，需退避重试 |

---

## 8. 计费与成本测算

### 8.1 单价（2026-07 官方刊例价）

**豆包流式语音识别模型 2.0**

| 计费方式 | 价格 |
|---|---|
| **后付费** | **1 元/小时** |
| 资源包 30 小时 | 28 元（≈0.93 元/小时） |
| 资源包 1000 小时 | 900 元（0.9 元/小时） |
| 资源包 10000 小时 | 8800 元（0.88 元/小时） |
| 资源包 100000 小时 | 85000 元（0.85 元/小时） |
| 资源包 300000 小时 | 240000 元（0.8 元/小时） |
| **并发增购** | 100 元/并发/月（**正式版默认已含 50 并发**） |
| **纯并发版** | 500 元/并发/月（不再收小时费） |

对比「大模型流式语音识别 1.0」：后付费 4.5 元/小时，默认仅 10 并发 —— **贵 4.5 倍，没有理由用**。

### 8.2 关键计费规则

> 官方原文：「按时长计费的，累加**每次调用的语音时长**，精确至毫秒，最终折算为小时计费。」
> 「语音识别相关能力，双声道计费模式，按单声道计费，即音频时长进行计费。」

**这意味着：计费按你发送的音频时长算，不是按连接时长算。**

→ **本地 VAD 就是直接省钱**：把静音段不发出去，成本按说话占比线性下降。
一个人「按住说话」时通常有 30~50% 是停顿，VAD 掐掉后成本能省三到四成。

### 8.3 成本测算

| 用户类型 | 每日有效说话时长 | 月成本（后付费 1 元/h） |
|---|---|---|
| 轻度（每天 10 分钟） | 10 min | **约 5 元/月** |
| 中度（每天 30 分钟） | 30 min | **约 15 元/月** |
| 重度（每天 2 小时） | 120 min | **约 60 元/月** |

> **产品结论**：
> - 做**个人自用工具** → 一年几十块，忽略不计。
> - 做**商业产品** → 订阅定价必须覆盖重度用户。参考 Wispr Flow 等海外产品 $12~15/月的定价，国内定价 ¥19~29/月是合理区间，重度用户仍有毛利，但要设**用量上限或阶梯**防止被薅。
> - **并发不是瓶颈**：语音输入法是「一个用户一条连接、且只在按住时才占用」，默认 50 并发足以支撑**几百到上千 DAU**（因为并发是「同一时刻」的连接数，而单次说话只有几十秒）。

### 8.4 省钱清单

1. ✅ **本地 VAD 过滤静音** —— 直接省 30~40%
2. ✅ **松手立刻发末包并关连接** —— 别让连接空转（也避免 `45000081`）
3. ✅ 用**资源包**而非后付费（1000 小时档 0.9 元/小时）
4. ⚠️ 连接预热要控制空闲时长，别为了省 200 ms 延迟而挂一堆空连接

---

## 9. 参考实现骨架（Python）

> 官方在文档页提供了 Python / Go / Java 的完整 Demo 压缩包（`sauc_python.zip` / `sauc_go.zip` / `sauc.zip`），**建议先下载官方 Demo 跑通再改造**，能省掉大量协议调试时间。
> 下面是核心逻辑的最小实现，用于理解协议。

```python
import gzip, json, uuid, struct, asyncio, websockets

WS_URL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"

# ---------- 协议常量 ----------
PROTOCOL_VERSION = 0b0001
HEADER_SIZE      = 0b0001          # ×4 = 4 bytes

CLIENT_FULL_REQUEST = 0b0001
CLIENT_AUDIO_ONLY   = 0b0010
SERVER_FULL_RESPONSE= 0b1001
SERVER_ERROR        = 0b1111

FLAG_NONE           = 0b0000
FLAG_POS_SEQUENCE   = 0b0001
FLAG_LAST_NO_SEQ    = 0b0010
FLAG_NEG_SEQUENCE   = 0b0011

SER_NONE = 0b0000
SER_JSON = 0b0001
COMP_NONE = 0b0000
COMP_GZIP = 0b0001


def build_header(msg_type, flags, serialization, compression):
    return bytes([
        (PROTOCOL_VERSION << 4) | HEADER_SIZE,
        (msg_type << 4) | flags,
        (serialization << 4) | compression,
        0x00,
    ])


def build_full_client_request(params: dict) -> bytes:
    payload = gzip.compress(json.dumps(params).encode("utf-8"))
    return (build_header(CLIENT_FULL_REQUEST, FLAG_NONE, SER_JSON, COMP_GZIP)
            + struct.pack(">I", len(payload))      # 大端 uint32
            + payload)


def build_audio_request(pcm: bytes, is_last: bool) -> bytes:
    payload = gzip.compress(pcm)
    flags = FLAG_LAST_NO_SEQ if is_last else FLAG_NONE
    return (build_header(CLIENT_AUDIO_ONLY, flags, SER_NONE, COMP_GZIP)
            + struct.pack(">I", len(payload))
            + payload)


def parse_server_message(data: bytes):
    header_size   = (data[0] & 0x0F) * 4
    msg_type      = data[1] >> 4
    flags         = data[1] & 0x0F
    compression   = data[2] & 0x0F
    body          = data[header_size:]

    if msg_type == SERVER_ERROR:
        code = struct.unpack(">I", body[:4])[0]
        size = struct.unpack(">I", body[4:8])[0]
        msg  = body[8:8 + size].decode("utf-8", "ignore")
        return {"type": "error", "code": code, "message": msg}

    # full server response: [sequence?][payload size][payload]
    seq = None
    if flags in (FLAG_POS_SEQUENCE, FLAG_NEG_SEQUENCE):
        seq = struct.unpack(">i", body[:4])[0]   # 有符号，末包为负
        body = body[4:]

    size    = struct.unpack(">I", body[:4])[0]
    payload = body[4:4 + size]
    if compression == COMP_GZIP:
        payload = gzip.decompress(payload)

    return {"type": "result", "sequence": seq, "data": json.loads(payload)}


async def recognize(pcm_chunks, app_key, resource_id="volc.seedasr.sauc.duration"):
    headers = {
        "X-Api-Key":         app_key,          # 新版控制台
        "X-Api-Resource-Id": resource_id,
        "X-Api-Request-Id":  str(uuid.uuid4()),
        "X-Api-Connect-Id":  str(uuid.uuid4()),
        "X-Api-Sequence":    "-1",
    }

    params = {
        "user":  {"uid": "demo"},
        "audio": {"format": "pcm", "codec": "raw",
                  "rate": 16000, "bits": 16, "channel": 1},
        "request": {
            "model_name": "bigmodel",
            "enable_nonstream": True,
            "show_utterances": True,
            "result_type": "single",
            "end_window_size": 600,
            "force_to_speech_time": 1000,
            "enable_punc": True,
            "enable_itn": True,
            "enable_ddc": True,
        },
    }

    async with websockets.connect(WS_URL, additional_headers=headers,
                                  max_size=10 * 1024 * 1024) as ws:
        print("logid:", ws.response.headers.get("X-Tt-Logid"))   # 排障必存

        await ws.send(build_full_client_request(params))
        print(parse_server_message(await ws.recv()))

        async def sender():
            chunks = list(pcm_chunks)
            for i, chunk in enumerate(chunks):
                await ws.send(build_audio_request(chunk, is_last=(i == len(chunks) - 1)))
                await asyncio.sleep(0.2)          # 200ms 一包

        async def receiver():
            async for raw in ws:
                msg = parse_server_message(raw)
                if msg["type"] == "error":
                    print("ERROR", msg); break
                for u in msg["data"].get("result", {}).get("utterances", []):
                    tag = "✅definite" if u.get("definite") else "…partial"
                    print(f"{tag}  {u['text']}")

        await asyncio.gather(sender(), receiver())
```

---

## 10. 实战踩坑 ⚠️（来自 1000+ 开源实现的交叉验证）

> 本节来自对 GitHub 上真实生产实现（`typeflux` / `type4me` / `openless` / `univoice` 等）的源码级调研。
> **这些坑在官方文档里一个字都没有，但每一个都会让你的第一个 sprint 崩在联调上。**

### 10.1 协议有两条都能跑通的路线，但绝对不能混用 ⭐

| | **路线 A：无序号**（推荐） | **路线 B：正序号**（官方 Demo） |
|---|---|---|
| full client request flags | `0b0000` | `0b0001`（header 后跟 4B int32 大端，从 1 开始） |
| audio only request flags | `0b0000` | `0b0001`，每包递增 |
| 末包 flags | **`0b0010`** | **`0b0011`，且序号字段必须写成负数**（`-next_seq`） |
| 采用者 | `typeflux`、`type4me`、`Chauncy-Guo/doubao-asr` —— **已在数千用户的 macOS 工具上线验证** | 官方文档示例、`openless`、`univoice` |

> ⚠️ **混用会导致服务端按位置解析错位**（比如首包用 `0b0000` 但末包用 `0b0011`）。
> **建议选路线 A**：更简单，且被所有 macOS 语音输入工具验证过。选定后代码只支持这一条，不要做兼容分支。

> ⚠️ 官方文档的示例段**自相矛盾**：把 `b0000` 注释成 "use_specific_pos_sequence"，又把 audio only request 的 `b0000` 注释成「用户设置正数 sequence number」。**以协议表为准（`0b0000` = 不带序号），示例注释是错的。**

走路线 B 时：sequence 必须由**单一 worker 串行发送**，保证「序号单调 == 实际发送顺序」，并发发送会乱序。

### 10.2 `definite: true` 绝对不是流结束标志 ⭐⭐

`openless` 的源码注释记录了这个 bug：

> 一收到第一个 `definite: true` 就关闭接收循环 → **用户后续讲的内容全部丢失（实测丢了 9 秒）**。

**流是否结束只信帧头 flags**（`lastPacket` / `negativeSequence` / `asyncFinal`），**永远不要用 payload 里的 `definite` 判断。**

### 10.3 `bigmodel_async` 的 final 帧标志位不在官方表里

服务端最终帧用 `flags = 0b0100` 标记（`typeflux` 命名 `asyncFinal`，`Chauncy-Guo` 命名 `ASYNC_FINAL`）。

⚠️ **但这个位的语义是路线相关的**：
- 走正序号路线的 `openless` 里根本没有 `0b0100`（`is_final()` 只判 `0b0010`/`0b0011`）
- 在火山「端到端实时语音大模型」协议里，`0b0100` 表示后跟 4 字节 event 号 —— **两套协议不要混抄**

→ **必须抓包确认后写死一条，不要照抄任何一份实现。**

### 10.4 错误帧格式：官方文档与两个首选参考实现互相打架

官方文档说错误帧（`0b1111`）是 `header + 4B error code + 4B message size + UTF-8`（**没有 payload size 在前**）。

但实测：`typeflux` 跳过 error code 直接把后 4 字节当 payload size 再 JSON 解析；`type4me` 干脆复用正常响应解码器 —— **两者都声称线上可用**。

→ **不能照抄任何一方。在定型前，错误帧一律先 dump 原始字节。**

### 10.5 收到 `msgType = 0x0F` 不一定是错误

`type4me` 的实测经验：

```swift
if msgType == 0x0F {
    if audioPacketCount == 0 {
        // 真错误：鉴权失败 / 参数非法
    } else {
        // bigmodel_async 的「session 结束」信号，不是错误
    }
}
```

### 10.6 gzip 是可选的，但解包必须动态判断

上行：`typeflux`/`type4me`/`Chauncy` 全部 `compression = 0b0000` 不压缩，服务端正常工作；`univoice`/`xiaozhi-esp32-server` 全程 gzip。

**下行：服务端用与请求相同的压缩方式，但解析时必须读 header 第 2 字节低 4 位判断，不能写死。**

同理：`headerSize = (byte0 & 0x0F) * 4`，按 `byte1` 的 flags 位判断有无 sequence/final —— **绝不要写死偏移**。

### 10.7 `45000081` 等包超时：连接预热的代价

**真实触发原因**：连接已建立但一段时间（实测十几秒量级）没喂音频包，服务端把 session 判死；下一轮再用这条连接就返回空结果。

这直接影响 [04 章](04-技术实现方案.md)的「连接预热」优化：

- 预热能省 100~300 ms 握手延迟，但挂着不发包就会撞 `45000081`
- `type4me` 还记录了配套坑：**长时间空闲的共享 `URLSession` socket 首次 write 会失败，必须捕获后用全新 session 重试一次**

> **更安全的替代方案**：用**本地环形音频预缓冲**（回溯 300~500 ms）替代网络预热 —— 纯本地、无网络风险、无额外计费。
> 或者组合：预缓冲兜底 + 短窗口（≤8s）预热 + 失败重试。

### 10.8 ⚠️ 本地 VAD 门控可能污染流式模型 cache

这是与「省钱」直接冲突的一条，**必须拍板**：

> `casperkwok/VoiceAgent` 的实战反例：**「只在 VAD=SPEECH 时喂 ASR」会污染流式模型的 cache，导致乱码与重复字**，修复方式是改回连续喂。

**结论：省钱的粒度应该是「会话级」而不是「数据包级」。**

| ❌ 不要这样 | ✅ 应该这样 |
|---|---|
| 一直保持连接，静音的包不发（包级门控） | 说话期间**连续喂满**；静音超阈值（如 1.5 s）**直接发末包收尾并断连**（会话级门控） |
| 既撞 `45000081`，又可能照常计费，还污染 cache | 干净、省钱、不影响识别质量 |

### 10.9 健康检查不能用「N 秒没收包就重连」

`bigmodel_async` **明确只在结果有变化时才回包** —— 静默不收包是正常的。用超时判断连接死活会导致误重连。

### 10.10 兜底策略（来自 `openless` / `type4me`）

1. 发完末包后设 **final 等待超时**（`openless` 用 `FINAL_RESULT_TIMEOUT = 12s`）
2. **全程缓存 `last_partial_text`** —— 服务端在 final 帧之前断连时用 partial 兜底返回，而不是直接报错
3. 收包循环出错时按「是否已发末包 / 是否发过音频」三分支判断是正常结束、鉴权错误还是网络中断

### 10.11 ⚠️ 2.0 的 Resource ID 没有任何开源实现验证过

**所有能找到的开源实现用的都是 1.0 的 `volc.bigasr.sauc.*`。**

以下问题**必须自己实测**，选错会直接 `45000001` 或把费用打到错误资源包上：

- [ ] 2.0（`volc.seedasr.sauc.duration`）是否需要单独开通？
- [ ] 2.0 下 payload 的 `model_name` 该填什么？（官方说「目前只有 bigmodel」）
- [ ] 2.0 是否同样支持 `bigmodel_async` / `show_utterances` / `definite` / `corpus.context` 热词直传？

### 10.12 别开不必要的参数

`show_speech_rate` / `show_volume` / `enable_lid` / `enable_emotion_detection` / `enable_gender_detection` 这类参数在双向流式优化版上**会默认开启 VAD 分句（800 ms 判停）**，改变你的分句行为。

> **除必需项外一个都不要开。**

### 10.13 关于计费口径的一则澄清

调研过程中有 agent 质疑「按音频时长计费」这条未经证实（因为计费页是 JS 渲染，`WebFetch`/`curl` 取不到正文）。

**本文档的计费数据是用浏览器直接加载官方计费页取得的原文**，以下两条可以放心采信：

> 「按时长计费的，累加**每次调用的语音时长**，精确至毫秒，最终折算为小时计费。」
> 「豆包流式语音识别模型 2.0 · 并发 · 100 元/并发/月 · **正式版默认支持 50 并发**，超出部分按需增购」

同时「**豆包流式语音识别模型 2.0-并发版：500 元/并发/月，不再收取按小时调用费用**」是**另一套互斥的计费模式**（特殊商务模式），不是说默认没有并发。两条同时成立，不矛盾。

> 尽管如此，**上线前仍建议做一次对照实验**：A 组发 10 分钟连续音频，B 组建连后 20 分钟只发静音，隔天拉账单反推最小计费粒度。

---

## 11. ⭐ 一手实测数据（2026-07-25，本机 arm64 / macOS 26.5.2）

> 用 `app/` 里的 `--selftest` 模式跑出来的真实数字。此前本文档所有延迟都是估算。
> 样本：`say` 合成的中文语句，句间静音 0.9 s。**样本量小（n=3~9），但下面两条结论都稳定复现。**

### 12.1 已确认可用

| 项 | 结果 |
|---|---|
| **`volc.seedasr.sauc.duration`（2.0）** | ✅ **确认支持 `bigmodel_async` + `show_utterances` + `definite` + 热词直传**。此前所有开源实现用的都是 1.0 的 `bigasr`，2.0 无人验证过 —— 这个未知项现已消除 |
| 新版控制台鉴权 | ✅ 单个 `x-api-key` 头即可，无需 `X-Api-App-Key`/`X-Api-Access-Key` |
| 协议路线 | ✅ **无序号路线**（首包 `0b0000` / 音频包 `0b0000` / 末包 `0b0010`）+ **不压缩** 工作正常 |
| **首字返回延迟** | **586 ~ 936 ms**（中位数约 610 ms） |

### 12.2 ⚠️ `end_window_size` 决定「边说边打字」成不成立

三句话、句间停顿 900 ms，`definite` 到达时刻：

| `end_window_size` | definite 到达 | 效果 |
|---|---|---|
| **300 ms** | 2751 / 7774 / 11942 ms | ✅ 逐句上屏 |
| **600 ms** | 3274 / 8431 / 11968 ms | ✅ 逐句上屏 |
| **1500 ms** | **11933 ms —— 只有一条** | ❌ **三句全憋到末包一次性吐出** |

> **硬约束：`end_window_size` 必须小于说话时的自然停顿，否则「边说边打字」直接退化成「说完才上屏」。**
>
> 原因很直白：1500 ms > 900 ms 的停顿 → 永远触发不了判停 → 只有末包才出结果。
> 真人口述换气通常 0.4~1.0 s，所以 **300~600 ms 是安全区**。
>
> 这也意味着 [05 章](05-产品设计方案.md) §5.4 的「思考模式 1500~3000 ms」**代价比预想的大** ——
> 它不是「上屏慢一点」，而是**完全丧失逐句上屏**。这个档位应当改名或去掉。

### 12.3 ⚠️ `enable_nonstream` 与热词互斥（3/3 复现）

同一段音频、同一份热词表，只切换 `enable_nonstream`：

| 说的内容 | `true`（二遍识别） | `false`（纯流式） |
|---|---|---|
| 流**式**语音识别 | 流**是**语音识别 ❌ | 流**式**语音识别 ✅ |
| **Claude** Code | **Cloth** Code ❌ | **Claude** code ✅ |
| **上屏** | **尚平** ❌ | **上屏** ✅ |
| ……接入**接口** | 句子完整 ✅ | **丢了句尾「接口」** ❌ |
| 讨论 | 讨**讨论**（重复字） ❌ | 讨论 ✅ |

**机制推测**：热词在流式一遍生效（partial 里能看到正确的「豆包流式语音识别」），
但判停后二遍识别用非流式模型**重新识别该分句**时没有带上 `corpus.context`，
于是正确结果被一个不带热词的结果覆盖掉了。

**结论**：这不是「谁更准」，而是**两种能力互斥**：

| 你的场景 | 建议 |
|---|---|
| 有专有名词（技术术语、人名、产品名）—— 例如给 Claude Code 口述 | **`enable_nonstream: false`**，靠热词 |
| 纯日常口语，无专有名词 | `enable_nonstream: true`，换取更完整的句子 |

> ⚠️ 这条与官方文档「既可以满足客户实时上屏需求（快），又可以在最终结果中保证识别准确率（准）」
> 的表述冲突。以实测为准，但建议你在自己的音频上复跑一遍确认
> —— 我的样本是 TTS 合成音，真人语音表现可能不同。

### 12.4 仍未实测

麦克风采集链路、环形预缓冲的实际效果、CGEventTap 长稳、文本注入兼容性 —— 这四条需要授予权限后在真机上验证，见 [06 章 M0.5](06-实现路径与里程碑.md)。

---

## 12. 接入 Checklist

**第一周不要写 App，只写一个 CLI 抓包工具** —— 读本地 wav 推流，把每一帧的原始 header 字节、解析结果、payload、以及握手响应头里的 `X-Tt-Logid` 全部打印出来。用它把协议组合实测定型。

- [ ] 火山引擎控制台开通「豆包流式语音识别模型 2.0」，拿到 App Key / Access Token
- [ ] 下载官方 `sauc_python.zip` Demo 先跑通，确认账号可用
- [ ] ⭐ **实测 2.0 的 `volc.seedasr.sauc.duration` 是否支持 `bigmodel_async` / `show_utterances` / `definite` / 热词直传**（无任何开源实现验证过，见 §10.11）
- [ ] ⭐ **选定协议路线并写死**：推荐路线 A（无序号：首包 `0b0000` / 音频包 `0b0000` / 末包 `0b0010`），不做兼容分支
- [ ] 解码器按 flags 位**动态解析**（`headerSize=(b0&0x0F)*4`、按 b1 判 seq/final、按 b2 低 4 位判解压），不写死偏移
- [ ] 用一段本地 16k PCM wav 模拟推流验证协议（**先不接麦克风**）
- [ ] 打印并保存 `X-Tt-Logid`
- [ ] 验证 `definite` 能正常出现（必须 `show_utterances:true`）
- [ ] ⭐ **确认流结束只判帧头 flags，不判 `definite`**（见 §10.2，这是会丢用户内容的 bug）
- [ ] **dump 错误帧原始字节**，自己定型解析格式（官方文档与参考实现不一致，见 §10.4）
- [ ] 调 `end_window_size`，实测尾字延迟；做成「快嘴 300~500ms / 思考 1500~3000ms」两档
- [ ] 除必需项外**不开任何额外参数**（`show_speech_rate` 等会强制改变分句行为）
- [ ] VAD 用**会话级门控**而非包级（包级会污染流式 cache，见 §10.8）
- [ ] 实现 final 等待超时（~12s）+ `last_partial_text` 兜底
- [ ] 压测：连续说 5 分钟不松手，确认连接不断、内存不涨
- [ ] 异常路径：拔网线、切 Wi-Fi、服务端报错，确认都能优雅降级并给用户反馈
- [ ] **计费对照实验**：A 组发 10 分钟连续音频 / B 组建连后 20 分钟只发静音，隔天拉账单反推口径
