# Viva 语音输入（macOS）

按住全局热键说话，松开后将识别结果写入当前光标。客户端只连接 Viva 托管服务，用户不需要申请或填写火山引擎与大模型 API Key。

## 1. 当前产品流程

1. 用户输入邮箱并获取 6 位验证码。
2. 新邮箱自动注册，已有邮箱直接登录。
3. 客户端把 Access Token、轮换 Refresh Token、过期时间和设备 ID 作为单个原子值保存。带 Apple Team ID 的正式签名版本使用 macOS Keychain；没有 Team ID 的本地自签版本使用权限为 `0700/0600` 的本机会话文件，避免每次重编译都弹出系统密码框。
4. 每次语音会话先用 Bearer Token 申请一次性 ASR ticket，再连接服务端返回的 WebSocket URL。
5. 润色和改口纠正固定调用 Viva 产品级 LLM 接口；模型、Prompt、供应商地址和密钥只由服务端管理。

未登录时主窗口只显示账户入口。Refresh 失效、二次 401 或账号停用时，本地会话会被清理并回到登录页。

## 2. 编译

需要 macOS 14+、Apple Silicon 和 Command Line Tools：

```bash
cd app
./build.sh release
```

产物：`dist/Viva.app`。Release 构建优先使用 `VIVA_SIGN_IDENTITY`，否则使用本机 `Viva Self-Signed` 固定证书；没有可用身份时直接失败，避免生成会反复丢失系统权限授权的 ad-hoc 客户包。只有 Debug 构建允许 ad-hoc 兜底。

## 3. 本地联调

先在 `viva-服务端` 项目启动单端口本地服务：

```bash
make run-local
```

默认 origin 是 `http://127.0.0.1:8080`。测试模式只接受 `localhost`、`127.0.0.0/8` 或 `::1` 的无路径 HTTP/HTTPS origin，不能用它指向任意第三方上游。

### 账户、Refresh 和 LLM SSE 自检

本地服务会在 OTP 响应中返回 `dev_code`；正式环境不会返回，因此该自检不得对生产运行。

```bash
VIVA_TEST_MODE=1 \
VIVA_TEST_BACKEND_URL=http://127.0.0.1:8080 \
.build/release/Viva --account-selftest client-test@example.com
```

该命令验证 OTP 注册/登录、强制 Refresh、`/v1/me`、积分余额、LLM SSE 和退出。它不会打印 OTP、Token 或 ticket。

### ASR ticket 和 SAUC 自检

先保留一份测试登录会话：

```bash
VIVA_TEST_MODE=1 \
VIVA_TEST_BACKEND_URL=http://127.0.0.1:8080 \
VIVA_SELFTEST_KEEP_SESSION=1 \
.build/release/Viva --account-selftest client-asr-test@example.com
```

再把任意音频统一转为 16kHz/16bit/单声道 PCM 推给 Viva Gateway：

```bash
say -o /tmp/viva-test.aiff "今天下午三点开会"
VIVA_TEST_MODE=1 \
VIVA_TEST_BACKEND_URL=http://127.0.0.1:8080 \
VIVA_VERBOSE=1 \
.build/release/Viva --selftest /tmp/viva-test.aiff
```

自检应依次看到 ticket 申请、`gateway.session.accepted`、`gateway.upstream.ready`、partial、definite/final 和 upstream log ID。

## 4. 客户端配置边界

普通用户可配置：

- 热键、麦克风、预缓冲和上屏方式；
- 本地改词记忆与预设替换规则；
- 是否启用润色、改口纠正和 SSE 过程显示；
- 自动更新、历史与隐私设置。

客户端不允许配置：

- 火山引擎或 LLM API Key；
- 语音/模型供应商、模型名、Prompt 或上游地址；
- 服务端当前不接收的热词、dialog context、判停、ITN/DDC/标点、繁体、首字加速或 nonstream 参数。

“开发者选项”默认折叠，仅在本地联调时允许切换 loopback Viva origin。

## 5. 协议与安全要点

- 受保护 REST 请求使用 `Authorization: Bearer <access_token>`。
- Refresh Token 每次使用后都必须轮换；同一 origin 的并发 401 只允许一个 Refresh 请求。
- Refresh 网络重试复用持久化的 `Idempotency-Key`，避免触发 reuse detection。
- ASR ticket 一次性使用、不持久化、不写日志；WebSocket 不携带长期 Authorization。
- 服务端响应错误按 HTTP 状态码和稳定 `error.code` 处理，日志只记录 request ID 和错误码。
- 音频、转写正文、OTP、Token、ticket 和供应商密钥不进入客户端请求日志。

## 6. 代码结构

```text
Sources/Viva/
├── AccountView.swift            邮箱 OTP 注册/登录、积分与退出
├── ManagedBackendAuth.swift     Bearer、Refresh 轮换、登录状态存储与 ASR ticket
├── DoubaoStreamingASR.swift     Viva Gateway WebSocket + SAUC
├── LLMPolisher.swift            产品级润色 JSON/SSE 客户端
├── VoiceSession.swift           采集、识别、润色、上屏状态机
├── Config.swift                 固定生产 origin 与 loopback 测试 origin
├── SettingsView.swift           账户和客户端行为设置
└── main.swift                   App 入口与账户/ASR 自检
```

## 7. 生产服务

`Config.productionBackendBaseURL` 固定为 `https://viva.bobdong.cn`。正式账户、语音识别 WebSocket 和大模型请求均从该受信任 origin 派生；本地测试模式仍只接受 loopback origin。
