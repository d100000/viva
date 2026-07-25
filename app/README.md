# 豆包语音输入（macOS）

按住右 ⌘ 说话，文字实时出现在光标处。对接火山引擎豆包流式语音识别。

> 这是 [调研文档](../README.md) 里 **M0 + M1 + M2 骨架**的可运行实现。
> 协议链路已实测跑通；麦克风/热键/上屏三条链路需要你授权后才能验证（见 §5）。

---

## 1. 快速开始

```bash
cd app
./build.sh
```

产物：`dist/豆包语音输入.app`

### 第一步：协议自检（不需要任何权限）⭐ 先做这个

```bash
export DOUBAO_API_KEY=你的火山APIKey
say -o /tmp/t.aiff "今天下午三点开会，讨论豆包流式语音识别的接入方案"
.build/release/DoubaoVoiceInput --selftest /tmp/t.aiff
```

它会把音频当作麦克风推给豆包，打印每一条 partial / definite 及其到达时刻。
**这一步能把「协议、凭证、参数」和「App 权限」两个风险源分开** —— 出问题时你能立刻知道是哪一边。

### 第二步：配置

```bash
open ~/.config/doubao-voice/config.json
```

至少要填 `apiKey`。热词强烈建议填 —— 见 §3 的实测数据。

### 第三步：启动

```bash
open "dist/豆包语音输入.app"
```

首次启动会依次要两个权限：**麦克风** → **辅助功能**。授权辅助功能后**必须重启 App**。

---

## 2. 实测数据（本机 arm64 / macOS 26.5.2）

用 `say` 合成的三句话、句间停顿 0.9s：

| 指标 | 实测 |
|---|---|
| **首字返回** | **586 ~ 936 ms** |
| definite 到达（3 句） | 2751 / 7774 / 11942 ms（`end_window_size=300`） |
| | 3274 / 8431 / 11968 ms（`end_window_size=600`） |
| | **11933 ms —— 只有一条**（`end_window_size=1500`） |

### ⚠️ 最关键的一条约束

> **`end_window_size` 必须小于你说话时的自然停顿，否则「边说边打字」直接退化成「说完才上屏」。**

测试音频停顿是 900 ms。设成 1500 ms 时永远触发不了判停，三句话全憋到末包才一次性吐出来。

真人口述换气通常 0.4~1.0 s，所以 **300~600 ms 是安全区**。默认给的是 600。

---

## 3. ⚠️ `enable_nonstream` 与热词冲突（实测 3/3 复现）

官方文档说二遍识别「既快又准」，但实测**开启后 `corpus.context` 的热词会失效**：

| 说的内容 | `enableNonstream: true` | `enableNonstream: false` |
|---|---|---|
| 流式语音识别 | 流**是**语音识别 ❌ | 流**式**语音识别 ✅ |
| Claude Code | **Cloth** Code ❌ | **Claude** code ✅ |
| 上屏 | **尚平** ❌ | **上屏** ✅ |
| ……的接入接口 | 句子完整 ✅ | **丢了句尾「接口」** ❌ |

**权衡是真实的**：二遍识别在句子完整性和尾字上确实更好，但会丢热词。

本项目默认 **`enableNonstream: false`** —— 热词是差异化支点，不能牺牲。
如果你的场景没有专有名词，可以改成 `true` 换取更完整的句子。

---

## 4. 配置项

`~/.config/doubao-voice/config.json`（权限 600）

| 键 | 默认 | 说明 |
|---|---|---|
| `apiKey` | — | 新版控制台的 `x-api-key`。也可用环境变量 `DOUBAO_API_KEY` |
| `appKey` / `accessKey` | — | 旧版控制台用这两个 |
| `resourceId` | `volc.seedasr.sauc.duration` | 豆包流式 2.0（1 元/小时）。1.0 是 `volc.bigasr.sauc.duration`，贵 4.5 倍 |
| `endpoint` | `.../api/v3/sauc/bigmodel_async` | 双向流式优化版 |
| `endWindowSize` | `600` | ⭐ 见 §2。快嘴 300 / 默认 600 / 思考 1500（会丧失逐句上屏） |
| `enableNonstream` | `false` | ⭐ 见 §3 |
| `enableDdc` | `true` | 去「嗯」「那个」等口水词 |
| `hotwords` | `[]` | ⭐ 专有名词识别率的最大杠杆，直传 `corpus.context`（限约 100 tokens） |
| `hotkeyKeyCode` | `54`（右⌘） | ⚠️ **别用 Fn(63)**：微信输入法和豆包输入法都抢占了它 |
| `preRollMs` | `400` | 环形预缓冲，解决首字丢失 |
| `useClipboardPaste` | `true` | true=剪贴板+⌘V（兼容性最好）；false=CGEvent 逐字 |
| `clipboardRestoreDelayMs` | `200` | iTerm2/Warp 会自动提到 1500 |
| `commitOnlyAtEnd` | `false` | true = 不逐句上屏，松手才一次性写入 |

改完在菜单栏点「重新加载配置」。

---

## 5. 这个版本做到了什么 / 没做到什么

### ✅ 已实测验证

- 豆包 sauc 二进制协议（无序号路线：首包 `0b0000` / 音频包 `0b0000` / 末包 `0b0010`）
- `volc.seedasr.sauc.duration`（**2.0**）确认支持 `bigmodel_async` + `show_utterances` + `definite`
  （所有开源实现用的都是 1.0 的 `bigasr`，2.0 此前无人验证）
- 逐句 definite 上屏的节奏
- 热词直传生效，以及它与 `enable_nonstream` 的冲突
- 首字延迟 ~600 ms

### ⚠️ 需要你授权后才能验证（我无法代测）

- 真实麦克风采集与 48k→16k 重采样
- 环形预缓冲是否真的消除了首字丢失
- CGEventTap 热键（长稳：跑 8 小时后是否还灵）
- 文本注入到真实 App（备忘录 / Chrome / VS Code / 微信 / iTerm2）

**这四条正是调研文档里 [M0.5 go/no-go 门槛](../06-实现路径与里程碑.md) 要求的冒烟测试。**

### ❌ 明确没做

- **逐字上屏到输入框**。partial 只在 HUD 里逐字显示，写进输入框的最小单位是**一句**。
  真·逐字上屏需要 InputMethodKit 输入法形态，见 [04 章 §6](../04-技术实现方案.md)。
- 退格回改已上屏文本 —— **故意不做**，算错一次就会不可逆地删掉用户自己的文字。
- LLM 润色、场景 Profile、语音指令编辑、免提模式。

---

## 6. 排障

| 现象 | 原因 / 处理 |
|---|---|
| 启动后没反应，菜单栏没图标 | 卡在系统麦克风授权弹窗上，点「允许」 |
| 热键按了没用 | 辅助功能权限。授权后**必须重启 App** |
| **重新编译后热键突然失灵** | ⚠️ TCC 授权绑定代码签名，ad-hoc 签名每次编译都变。去「系统设置 → 隐私与安全性 → 辅助功能」把本 App **移除再重新添加** |
| 文字没进输入框，提示「安全键盘输入」 | 密码框 / iTerm2 的 Secure Keyboard Entry 下无法注入，文本已复制，按 ⌘V |
| `45000001` | 协议拼错或参数非法 |
| `45000081` | 建连后太久没喂音频 |
| 想看详细日志 | `DOUBAO_VERBOSE=1 "dist/豆包语音输入.app/Contents/MacOS/DoubaoVoiceInput"` |

排障时把 `logid` 一起发给火山工单 —— 那是唯一线索，程序启动时会打印。

---

## 7. 代码结构

```
Sources/DoubaoVoiceInput/
├── main.swift              入口 + --selftest 自检模式
├── AppDelegate.swift       菜单栏、权限引导、设置
├── VoiceSession.swift      状态机：热键→采集→推流→上屏
├── AudioCapture.swift      AVAudioEngine + 重采样 + 环形预缓冲
├── DoubaoStreamingASR.swift WebSocket 客户端
├── SaucProtocol.swift      二进制协议编解码
├── HotkeyManager.swift     CGEventTap 右⌘，含 tap 静默禁用自愈
├── TextInjector.swift      剪贴板+⌘V / CGEvent 逐字，含 Secure Input 检测
├── HUDController.swift     悬浮窗，双态渲染
├── Config.swift            配置
└── Data+Gzip.swift         gzip 安全网
```

`VoiceSession` 与上屏方式解耦。将来做输入法版本，只需把「HUD 显示 partial / 注入 definite」
换成「`setMarkedText` / `insertText`」，上游一行不用改。
