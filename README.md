<div align="center">

# Viva

**别打了，说吧。**

`Type at the speed of speech.`

macOS 语音输入工具 · 对接火山引擎豆包流式语音识别 · 按住热键说话，文字实时出现在光标处

```bash
curl -fsSL https://raw.githubusercontent.com/d100000/viva/main/install.sh | bash
```

</div>

---

## 这是什么

按住一个键说话，松开，文字就写进你当前光标所在的任意输入框。识别走**豆包流式语音识别 2.0**，说话时能看到文字在悬浮条里逐字出现，每说完一句自动上屏。

可选接大模型做二次润色（去口水词、修同音错字、补标点）。

**所有配置都是你自己的**：API Key 存在本机，识别记录和热词也全在本机。**音频**只发往你自己的火山账号，不经过任何第三方服务器。

> 关于润色的数据流向：只有你主动开启「AI 润色」时才会发生，且只发送识别出的**文本**（不发音频），发往你自己选的那家大模型服务商。**全新安装的默认服务商是下面提到的「Viva 中转站」**，此时文本会经过 `bobdong.cn` 中转 —— **该中转站由本项目作者运营，是本项目的收入来源**。介意的话换任意其它服务商，或者用 Ollama 做完全本地的润色。
>
> 另有一个默认**关闭**的开关「把当前 App 名一并发给模型」：打开后请求里会额外带上你所在 App 的名字（用于让模型按场景调整语气）。不打开就不会发。

---

## 安装

需要 **macOS 14 (Sonoma) 或更高**，Apple Silicon（Intel 需 Rosetta，未实测）。

四种方式任选其一：

| 方式 | 一句话 | Gatekeeper「已损坏」问题 |
|---|---|---|
| **① 一键脚本**（推荐） | 一条 `curl \| bash`，自动装最新版 | 脚本自动处理 ✅ |
| **② Homebrew** | `brew install --cask d100000/tap/viva` | cask 自动处理 ✅ |
| **③ 手动下载** | Releases 页下 DMG 拖进应用程序 | 需手动跑一条命令 ⚠️ |
| **④ 源码编译** | `git clone` + `./build.sh` | 不涉及（本机构建无隔离属性）✅ |

### 方式一：终端一条命令（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/d100000/viva/main/install.sh | bash
```

脚本会查最新版本、下载、去掉 Gatekeeper 隔离属性、装进 `/Applications`。装完：

```bash
open -a Viva
```

<details>
<summary>可选的环境变量</summary>

```bash
# 装到用户目录（不需要 sudo 写 /Applications）
curl -fsSL https://raw.githubusercontent.com/d100000/viva/main/install.sh \
  | VIVA_PREFIX="$HOME/Applications" bash

# 装指定版本
curl -fsSL https://raw.githubusercontent.com/d100000/viva/main/install.sh \
  | VIVA_VERSION=v0.8.0 bash

# 用已经下载好的包装（网络差时有用）
VIVA_ZIP=~/Downloads/Viva-0.8.0.zip ./install.sh
```

重复执行是安全的：已经是最新版会直接退出，升级时会先退掉正在运行的旧版本。

</details>

### 方式二：Homebrew

```bash
brew install --cask d100000/tap/viva
```

升级 `brew upgrade --cask viva`，卸载 `brew uninstall --cask viva`。
卸载默认**保留** `~/.config/viva/`（里面有你的 API Key 和历史记录），要一起清掉用 `brew uninstall --zap --cask viva`。

### 方式三：手动下载

去 [Releases](https://github.com/d100000/viva/releases) 下 `Viva-x.y.z.dmg`，双击打开，把 Viva 拖进 Applications。

**然后必须在终端跑这一条**，否则双击会提示「已损坏，应移到废纸篓」：

```bash
xattr -dr com.apple.quarantine /Applications/Viva.app
```

> ### ⚠️ 为什么需要这一步
>
> Viva 用**自签证书**签名 —— 我没有花 99 美元/年买 Apple 开发者证书，所以没法做公证（notarization）。macOS 会给一切从网上下载的文件打上 `com.apple.quarantine`，未公证的 App 带着这个属性就会被 Gatekeeper 拦死，而且提示语是「已损坏」，非常误导人 —— 它没损坏，只是没有 Apple 的证书链。
>
> 上面的**方式一和方式二已经自动处理了这一步**，只有手动下载才需要自己敲。不想敲命令也可以：双击被拦后，去 系统设置 → 隐私与安全性，页面下方会出现「仍要打开」。
>
> 不放心的话，用方式四从源码自己编译，一行代码都能审。

### 方式四：从源码编译

只需要 Command Line Tools，不用装完整 Xcode：

```bash
git clone https://github.com/d100000/viva.git
cd viva/app
./build.sh
open "dist/Viva.app"
```

### 更新

装好之后**不用管**：Viva 启动时和之后每 24 小时检查一次 [GitHub Releases](https://github.com/d100000/viva/releases)，「启动时自动更新到新版本」（设置 → 软件更新，默认开启）会在空闲时自动下载、校验、原地替换并重启；正在说话/润色时绝不动刀。关掉自动更新的话，发现新版时菜单栏会出现「⬆️ 升级」入口，设置页也有「检查更新」按钮。

其它方式装的同样可以手动升级：

```bash
brew upgrade --cask viva        # Homebrew 装的
# 或重跑一遍一键脚本（已是最新会直接退出，升级时自动退掉旧版本）
curl -fsSL https://raw.githubusercontent.com/d100000/viva/main/install.sh | bash
```

所有版本都用同一张固定证书签名，**更新后「辅助功能」授权保持有效**，不需要去系统设置里移除重加。

### 卸载

```bash
brew uninstall --cask viva      # Homebrew；加 --zap 连同 ~/.config/viva 一起清
# 手动装的：
rm -rf /Applications/Viva.app
rm -rf ~/.config/viva           # 可选：配置、API Key、识别历史都在这里面
```

---

## 快速开始

首次启动会走欢迎引导：填 API Key → 麦克风授权 → 辅助功能授权 → 试一句。

> 授权「辅助功能」后**必须重启 App**，热键才生效。

**建议先跑协议自检**（不需要任何权限，能把「协议/凭证」和「App 权限」两个风险源分开）：

```bash
export DOUBAO_API_KEY=你的火山APIKey
say -o /tmp/t.aiff "今天下午三点开会，讨论豆包流式语音识别的接入方案"
# 从源码编译的话用 .build/release/Viva，装好的用下面这条
/Applications/Viva.app/Contents/MacOS/Viva --selftest /tmp/t.aiff
```

详见 [app/README.md](app/README.md)。

### 可选：开启 AI 润色

润色要调一个大模型，三条路，按「要做几步」排：

| 方案 | 要做几步 | 适合谁 |
|---|---|---|
| **Ollama 本地** | 装 Ollama → `ollama pull` 一个模型 | 不想联网、不想花钱 |
| **各家云厂商** | 注册 → 实名 → 充值 → 开通模型 → 建 Key → 查模型名 | 已经有账号的 |
| **[Viva 中转站](https://bobdong.cn/?from=viva)** | 拿 Key → 填进去 → 点「拉取模型」 | 想最快用上的 |

配好后在设置 →「大模型润色」里选，或者在主界面直接点「AI 润色」胶囊。

> 中转站由本项目作者运营，是本项目的收入来源，并且**它是全新安装时润色的默认服务商**（排在服务商列表第一位，标着「推荐」）。它不影响语音识别，也不会在你没开启润色时发送任何东西 —— 上面三条路是平等的，换成另外两条 Viva 的功能都完整。

---

## 实测数据（本机 arm64 / macOS 26.5）

| 指标 | 实测 |
|---|---|
| 首字返回 | **586 ~ 936 ms** |
| 逐句上屏（句间停顿 0.9s） | 2.7s / 7.8s / 11.9s —— 每说完一句就上屏 |
| 成本 | **约 1 元/小时**（按实际说话时长计费） |

### ⚠️ 两条实测推翻官方说法的结论

**① `end_window_size` 必须小于你说话的自然停顿**，否则「边说边打字」直接退化成「说完才一次性上屏」。测试中设成 1500ms 后，句间停顿 900ms 的三句话全部憋到末尾才吐出来。真人换气通常 0.4–1.0 秒，**300–600ms 是安全区**。

**② `enable_nonstream`（二遍识别）与热词互斥**（3/3 复现）。官方说它「既快又准」，但实测开启后 `corpus.context` 的热词会失效：

| 说的内容 | 开启二遍 | 关闭二遍 |
|---|---|---|
| 流**式**语音识别 | 流**是** ❌ | 流**式** ✅ |
| **Claude** Code | **Cloth** Code ❌ | **Claude** ✅ |
| **上屏** | **尚平** ❌ | **上屏** ✅ |

本项目默认关闭 —— 热词是核心能力，不能牺牲。

---

## 主要特性

- **不占输入法槽** —— 全局热键触发，你可以继续用自己的拼音方案
- **首字不丢** —— 环形音频预缓冲，热键按下前 400ms 的声音一并送出
- **可编程热词** —— 直传 `corpus.context`，专有名词识别率的最大杠杆
- **去掉末尾句号** —— 往聊天框/搜索框塞一句话时那个句号是多余的。逐句上屏下用「先扣下、下一句到了再补回」实现，**不做退格回改**；问号感叹号和省略号原样保留
- **大模型润色** —— 八家服务商预设（Viva 中转站/火山方舟/DeepSeek/百炼/OpenAI/智谱/硅基流动/Ollama）+ 五种协议格式（OpenAI Chat、Responses、Anthropic Messages、Ollama 原生、Gemini）
- **模型列表自动拉取** —— 填好 Key 点一下，服务端有哪些模型自动列出来（已过滤掉向量/语音/画图这类选了必定调用失败的），轻量档排最前。模型名 churn 太快，写死的预设表迟早过期
- **历史与统计** —— 说话次数/时长/字数、语速、节省时间、连续天数、App 分布、活跃热力图
- **隐私自持** —— BYOK，零硬编码凭证，配置权限 600，不截屏、不读前台内容

---

## 项目结构

```
.
├── app/                      # macOS App（Swift + SwiftPM，无需 Xcode）
│   ├── Sources/Viva/         # 26 个源文件，约 8300 行
│   ├── tools/make_icon.swift # 图标生成器（CoreGraphics 直接画）
│   ├── build.sh              # 编译 + 组装 .app + 签名（固定自签证书，缺证书才回退 ad-hoc）
│   ├── make-signing-cert.sh  # 生成/恢复固定自签证书（授权跨更新保留的关键，跑一次即可）
│   └── package.sh            # 打发布用的 DMG + ZIP
├── install.sh                # 终端一键安装脚本
├── packaging/homebrew/        # Homebrew cask 公式
└── 0X-*.md                   # 调研与设计文档（见下）
```

---

## 调研文档

在写代码之前先做了完整调研，结论都留了下来 —— 包括**被实测推翻的部分**。

| 文档 | 内容 |
|---|---|
| [01 · 实现原理](01-语音输入法实现原理.md) | 十层管线、两大核心难点、延迟预算、云端 vs 端侧 |
| [02 · 豆包流式 ASR 接入](02-豆包流式ASR接入.md) | 协议逐字节详解、推荐参数、**13 条实战踩坑**、计费、一手实测数据 |
| [03 · 开源项目调研](03-开源项目调研.md) | 已对接豆包的项目清单、能抄谁、许可证陷阱 |
| [04 · 技术实现方案](04-技术实现方案.md) | 架构、注入兼容性矩阵、CGEvent 四大坑、IMK 可行性、权限与分发 |
| [05 · 产品设计方案](05-产品设计方案.md) | 竞品实况、差异化支点、定价、中文用户真实痛点 |
| [06 · 实现路径](06-实现路径与里程碑.md) | M0~M4 排期、**go/no-go 硬门槛**、风险登记 |
| [07 · 功能优化清单](07-功能优化清单.md) | 豆包 API 还没用上的能力、竞品功能对照、完整功能清单 |
| [08 · 中转站营销方案](08-中转站营销方案.md) | 免费工具 → 中转站的转化漏斗、产品内转化位、**开源项目做商业化的三条红线** |

> ⚠️ 文档里保留了两处**自我修正**：初版曾判断「对接豆包流式是开源生态空白」和「豆包输入法桌面端是盲区」，深度调研后发现两条都错了（GitHub 搜 `sauc/bigmodel` 有 1000+ 命中；豆包输入法 macOS 版 2026-05-12 已上线且已实现逐字流式上屏）。修正过程留在文档里，因为**错误的判断路径本身有参考价值**。

---

## 已知限制

- **不是逐字上屏**。中间结果只在悬浮条预览，写进输入框的最小单位是**一句**。真·逐字上屏需要 InputMethodKit 输入法形态，见 [04 章 §6](04-技术实现方案.md)。
- **绝不做退格回改**。算错一次就会不可逆地删掉用户自己的文字。
- macOS 14+，自签证书签名，无公证 —— 下载的包首次打开要过一次 Gatekeeper（见[安装](#安装)），且上不了 App Store（辅助功能与沙盒也不兼容）。签名身份固定，**更新/重编译不会丢「辅助功能」授权**。
