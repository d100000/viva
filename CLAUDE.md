# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目是什么

**Viva** —— macOS 语音输入工具。按住热键（默认右⌘）说话，音频推给火山引擎豆包流式语音识别 2.0，识别文字实时显示在悬浮条里，每说完一句自动注入到当前光标处。可选接大模型做二次润色。

仓库根目录的 `01~08-*.md` 是调研/设计文档；可运行的代码全部在 `app/`。文档、注释、commit message 均使用中文（commit 格式：`fix:`/`feat:` + 中文描述）。

## 常用命令

```bash
# 编译 + 组装 .app + ad-hoc 签名（只有 Command Line Tools 也能跑）
cd app && ./build.sh          # 产物: app/dist/Viva.app
./build.sh debug              # debug 构建

# 打发布包（DMG + ZIP，版本号自动从 Info.plist 读）
cd app && ./package.sh        # 产物: app/dist/Viva-x.y.z.{dmg,zip}

# 协议自检 —— 改动 ASR/协议相关代码后的首选验证方式（不需要任何系统权限）
export DOUBAO_API_KEY=你的key
say -o /tmp/t.aiff "今天下午三点开会，讨论豆包流式语音识别的接入方案"
app/.build/release/Viva --selftest /tmp/t.aiff

# 运行 App / 看详细日志
open app/dist/Viva.app
DOUBAO_VERBOSE=1 app/dist/Viva.app/Contents/MacOS/Viva

# 测安装脚本（别用真 /Applications，拿沙盒 PREFIX 测）
VIVA_PREFIX=$(mktemp -d) VIVA_ZIP=app/dist/Viva-0.4.0.zip ./install.sh
```

没有测试目录、没有 lint 配置。验证手段就两个：`--selftest`（验协议/凭证/参数，不碰权限）和真机手测（麦克风/热键/上屏三条链路，需要用户授权，Claude 无法代测）。

## 发版流程

版本号的唯一来源是 `app/Resources/Info.plist` 的 `CFBundleShortVersionString`，`package.sh` 和 tag 都跟它对齐。

1. 改 Info.plist 里的版本号（`CFBundleShortVersionString` + `CFBundleVersion`）
2. `cd app && ./build.sh && ./package.sh`
3. 提交源码 → 打 tag `vX.Y.Z` → `gh release create` 挂上 DMG + ZIP
4. DMG 的 sha256 填进 `packaging/homebrew/viva.rb`，再同步到 `d100000/homebrew-tap` 仓库的 `Casks/viva.rb`

**发版规则**：只有用户明确要求时才打包发 Release；平时只提交源码，`dist/` 已在 .gitignore 里，不入库。

## 架构

Swift Package（`app/Package.swift`，swift-tools 6.0 但强制 `.swiftLanguageMode(.v5)` —— 大量 AppKit/CoreAudio 回调在 Swift 6 严格并发下报错海量，别改回 v6）。macOS 14+。无第三方依赖。源码全在 `app/Sources/Viva/`。

### 核心数据流

```
HotkeyManager(CGEventTap 捕获右⌘)
  → VoiceSession(状态机: idle→listening→finalizing→polishing)
      ├── AudioCapture      AVAudioEngine 采集 + 48k→16k 重采样 + 环形预缓冲(preRoll 防首字丢失)
      ├── DoubaoStreamingASR WebSocket 客户端 ←→ SaucProtocol(豆包二进制协议编解码)
      ├── LLMPolisher       可选润色, 走 LLMProvider(各家 OpenAI 兼容预设) + APIFormat
      ├── TextInjector      剪贴板+⌘V 或 CGEvent 逐字, 含 Secure Input 检测
      ├── HUDController     悬浮条, partial 逐字显示 / definite 定格
      └── HistoryStore      本地识别记录
AppState(单例 ObservableObject) —— UI 只读它, 业务逻辑只写它
MainWindow/SpeakView/SettingsView/HistoryView/StatsView/WelcomeView —— SwiftUI 界面
main.swift —— 入口 + --selftest 模式
```

- **VoiceSession 与上屏方式解耦**：partial 只进 HUD，写进目标 App 的最小单位是一句（definite）。将来做输入法形态只需替换注入层。
- **润色任务必须被 `polishTask` 持有**：abort() 要能取消它，否则 Esc 取消后润色迟到返回会污染下一次会话的状态机（见 VoiceSession.swift 注释）。

### 配置

`~/.config/viva/config.json`（权限 600），读取优先级：环境变量 > 文件 > 默认值。API Key 绝不写进源码。关键项见 `Config.swift` 内注释。

## 实测得出的硬约束（改参数前必读，都是踩过坑的）

- **`enableNonstream`（二遍识别）与热词互斥**（3/3 复现）：开启后 `corpus.context` 热词失效。默认关闭 —— 热词是本项目差异化支点，不能牺牲。
- **`endWindowSize` 必须小于说话的自然停顿**（300~600ms 安全区），否则逐句上屏退化成说完才一次性上屏。
- **热键别用 Fn(63)**：微信输入法和豆包输入法都抢占了它。
- **全局热键只依赖「辅助功能」，不依赖「输入监控」**：Viva 的 `HotkeyManager` 使用 `CGEvent.tapCreate(..., options: .defaultTap)`，这条路径由辅助功能（`AXIsProcessTrusted()`）授权。绝不能再用 `CGPreflightListenEventAccess()` 作为热键启动、健康检查或设置页状态的硬门槛，也不要引导用户开启输入监控；否则会把可用热键误判成不可用。普通组合热键还可使用 `RegisterEventHotKey`，同样无需输入监控，但 Viva 为支持单修饰键、按住/松开时序和吞键而采用 `.defaultTap`。
- **resourceId 用 `volc.seedasr.sauc.duration`（2.0，1元/小时）**；1.0 的 `volc.bigasr.sauc.duration` 贵 4.5 倍。
- **故意不做**退格回改已上屏文本 —— 算错一次会不可逆删掉用户自己的文字。
- `LLMProvider.swift` 的服务商预设表是逐家核实官方文档得来的：各家关闭「深度思考」的参数写法都不同（`thinkingOff`），传错等于没关；模型名 churn 极快，一律做成可编辑字符串 + 建议列表，绝不写死。

## 已知坑

- **TCC 授权绑定代码签名**，ad-hoc 签名每次编译都变 → 重新编译后热键失灵，需在「系统设置 → 隐私与安全性 → 辅助功能」移除再重新添加本 App。当前版本每 2 秒自动复查权限并补建热键监听，授权后不应要求用户重启 App。
- **ad-hoc 签名 ⇒ 无法公证 ⇒ 下载的包必被 Gatekeeper 拦**，提示「已损坏」（误导人，其实只是没证书）。所以 `install.sh` 和 cask 的 `postflight` 都必须 `xattr -dr com.apple.quarantine`，这一步是承重的，删了用户就打不开 App。`spctl -a` 对本 App 永远返回 rejected，但 App 实际能正常启动 —— 别拿 spctl 当验证标准。
- **`ditto -c -k` 别加 `--sequesterRsrc`**：那个参数是**生成** `__MACOSX/` 的元凶（Apple 公证文档里带它，那是给 notary service 用的）。本项目要给端用户干净的包，不加。
- **`ps -eo comm=` 会按列宽截断路径**，只有 `ps -p <pid> -o comm=` 给完整路径；且它报物理路径（`/private/var/…`），跟符号链接路径比较前两边都要 `cd && pwd -P` 解析。install.sh 靠这个判断「该退掉的是不是正要被替换的那个进程」。
- 豆包错误码：`45000001` 协议/参数非法；`45000081` 建连后太久没喂音频。排障带上启动时打印的 `logid`。
- `app/README.md` 部分内容仍是旧名「DoubaoVoiceInput」时期的（旧配置路径 `~/.config/doubao-voice` 等），以源码和根 README 为准。
