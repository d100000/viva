<div align="center">

# Viva

**话音未落，字已上屏。**

`Faster than your keyboard.`

最快的 macOS 语音输入 · 顶级豆包流式识别大模型驱动 · 按住说话，首字亚秒级返回，边说边写进光标处

```bash
curl -fsSL https://raw.githubusercontent.com/d100000/viva/main/install.sh | bash
```

</div>

---

## 这是什么

按住一个键说话，松开，文字就写进你当前光标所在的任意输入框。识别走**豆包流式语音识别 2.0**，说话时能看到文字在悬浮条里逐字出现，每说完一句自动上屏。

可选开启服务端大模型润色和改口纠正（去口水词、修同音错字、补标点）。

客户端不再保存或接收火山引擎与大模型供应商 API Key，也不允许用户修改供应商、模型或上游地址：

- 音频加密发送到 Viva 服务，再由服务端转发到受控的语音识别供应商。
- 只有开启润色或改口纠正时，识别文本才会发送到 Viva 服务；音频不会重复发给大模型。
- 识别历史、本地改词记忆和产品偏好保存在本机；Access/Refresh Token 与稳定设备 ID 作为一个原子会话保存。正式 Team ID 签名版本使用 macOS Keychain，本地自签版本使用仅当前 macOS 用户可读的受限文件。

> 正式客户端固定连接 `https://viva.bobdong.cn`。开发联调请在设置中开启“测试模式”，连接同一 origin 下同时提供 REST 与 WebSocket 的本地 Viva 服务。

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
卸载默认**保留** `~/.config/viva/`（历史记录、本地改词记忆与产品偏好），要一起清掉用 `brew uninstall --zap --cask viva`。

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
rm -rf ~/.config/viva           # 可选：配置、日志和识别历史都在这里面
```

---

## 快速开始

首次启动先用邮箱验证码注册或登录，新邮箱会自动创建账户，之后完成麦克风和辅助功能授权。用户不需要填写任何供应商 API Key、模型名或服务地址。

> 授权「辅助功能」后**必须重启 App**，热键才生效。

开发者连接本地服务时，先跑账户链路自检，再跑 ASR 自检（都不需要麦克风或辅助功能权限）：

```bash
say -o /tmp/t.aiff "今天下午三点开会，讨论豆包流式语音识别的接入方案"
cd app
VIVA_TEST_MODE=1 \
VIVA_TEST_BACKEND_URL=http://127.0.0.1:8080 \
.build/release/Viva --account-selftest client-test@example.com

VIVA_TEST_MODE=1 \
VIVA_TEST_BACKEND_URL=http://127.0.0.1:8080 \
VIVA_SELFTEST_KEEP_SESSION=1 \
.build/release/Viva --account-selftest client-asr-test@example.com

VIVA_TEST_MODE=1 \
VIVA_TEST_BACKEND_URL=http://127.0.0.1:8080 \
.build/release/Viva --selftest /tmp/t.aiff
```

详见 [app/README.md](app/README.md)。

### 可选：开启 AI 润色

在设置中开启“识别完成后用大模型润色”或“改口自动纠正”即可。模型、Prompt、供应商凭证和路由由 Viva 服务端统一管理，客户端不会出现供应商、模型名、Base URL 或 API Key 输入框。

测试模式同样只填写一个本地 loopback origin，客户端会固定调用：

- `POST /v1/auth/otp/request` 与 `POST /v1/auth/otp/verify`
- `POST /v1/asr/tickets` 后使用服务端返回的一次性 WebSocket URL
- `http://…/v1/text/polish`
- `http://…/v1/text/polish/stream`

---

## 托管链路验收

当前客户端已对本地 Viva Server 完成以下端到端验证：

| 链路 | 验证结果 |
|---|---|
| 账户 | 邮箱 OTP 注册/登录、`/v1/me`、积分余额 |
| Token | Bearer Access Token、Refresh Token 轮换、固定幂等键、按签名类型选择安全持久化 |
| LLM | 产品专用润色 schema、SSE `delta/final/usage/done`、结算后余额同步 |
| ASR | 一次性 ticket、`viva.sauc.v1`、Gateway accepted/ready、SAUC 音频与 final |

本地 Fake Volc 只用于协议正确性回归，它的延迟不代表生产供应商延迟。

---

## 主要特性

- **不占输入法槽** —— 全局热键触发，你可以继续用自己的拼音方案
- **首字不丢** —— 环形音频预缓冲，热键按下前 400ms 的声音一并送出
- **本地改词记忆** —— 识别结果返回后在本机做确定性替换，不向供应商发送自定义词表
- **去掉末尾句号** —— 往聊天框/搜索框塞一句话时那个句号是多余的。逐句上屏下用「先扣下、下一句到了再补回」实现，**不做退格回改**；问号感叹号和省略号原样保留
- **托管大模型处理** —— 产品级润色、改口纠正与 SSE 流式反馈；客户端不能发送任意模型、Prompt 或上游地址
- **账户即服务** —— 邮箱验证码注册/登录、短期 Bearer Access Token、轮换 Refresh Token 与本机持久会话
- **历史与统计** —— 说话次数/时长/字数、语速、节省时间、连续天数、App 分布、活跃热力图
- **供应商密钥不落客户端** —— 火山与 LLM Key 只存在服务端；本地配置权限 600，不截屏、不读取窗口内容

---

## 项目结构

```
.
├── app/                      # macOS App（Swift + SwiftPM，无需 Xcode）
│   ├── Sources/Viva/         # 26 个源文件，约 8300 行
│   ├── tools/make_icon.swift # 图标生成器（CoreGraphics 直接画）
│   ├── build.sh              # 编译 + 组装 .app + 签名（Release 强制固定身份，Debug 才允许 ad-hoc）
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
- 正式客户端固定连接 `https://viva.bobdong.cn`，账户、语音识别和大模型请求均从该受信任 origin 派生。
- macOS 14+，自签证书签名，无公证 —— 下载的包首次打开要过一次 Gatekeeper（见[安装](#安装)），且上不了 App Store（辅助功能与沙盒也不兼容）。签名身份固定，**更新/重编译不会丢「辅助功能」授权**。
