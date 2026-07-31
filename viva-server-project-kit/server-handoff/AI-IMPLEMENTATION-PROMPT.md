# 可直接交给新项目编码 AI 的启动提示词

将下面“开始”到“结束”之间的内容作为新 `viva-server` 项目的首条任务。复制本交接目录到新仓库 `docs/handoff/` 后再启动。

---

## 开始

你正在从零实现 `viva-server`：Viva macOS 语音输入软件的托管服务端。用户安装客户端后不需要填写火山引擎或大模型 API Key；实时音频和文本润色统一请求本服务，再由服务端安全调用火山 Seed-ASR 2.0 和火山方舟。

### 1. 先完整读取以下文件

必须逐个完整读取，不能只读摘要：

1. `docs/handoff/00-START-HERE.md`
2. `docs/handoff/01-SERVER-IMPLEMENTATION-SPEC.md`
3. `docs/handoff/openapi.yaml`
4. `docs/handoff/asyncapi.yaml`
5. `docs/handoff/schema.sql`
6. `docs/handoff/postgres-init.local.sql`
7. `docs/handoff/database-grants.sql`
8. `docs/handoff/.env.example`
9. `docs/handoff/docker-compose.local.yml`
10. `docs/handoff/nginx.example.conf`

如果文件之间存在冲突：安全与不可变约束最高；REST 以 OpenAPI 为准；WebSocket 以 AsyncAPI 为准；数据库对象以 `schema.sql` 为准，运行角色权限以 `database-grants.sql` 为准。不要静默自行选择，先在 `docs/decisions/` 写 ADR 并说明迁移影响。

### 2. 总体目标

实现一个 Go 模块化单体代码库，构建同一套领域代码的三个独立运行角色：

- `api`：bootstrap、登录、Token、用户、设备、套餐、用量、订单、Polish SSE、管理 API。
- `gateway`：ASR WebSocket 鉴权、DPoP、额度/并发租约、SAUC 校验、火山双向透明 relay、计量。
- `worker`：OTP、Webhook、用量、对账、隐私任务、outbox 和定时任务。

存储：

- PostgreSQL 是永久事实来源。
- Valkey/Redis-compatible store 只处理限流、DPoP 重放、额度预留、并发租约和短缓存。
- 音频、转写正文和 LLM 正文默认不落库、不写日志、不进入指标或 Trace。

### 3. 固定技术选型

- Go 当前稳定版，仓库锁定具体 toolchain。
- `net/http` + `go-chi/chi/v5`。
- `github.com/coder/websocket`。
- `pgx/v5`、`sqlc`、`goose`。
- `go-redis/v9` 连接 Valkey/Redis-compatible store。
- `log/slog` JSON 日志。
- OpenTelemetry + Prometheus。
- JWT/JWK/DPoP 使用维护良好的 JOSE 库。
- OpenAPI 驱动 REST 类型和 strict server 接口。
- 首版 LLM 直接实现火山方舟 Adapter；不要先引入 LiteLLM。
- 首版不引入 Kubernetes、Kafka、Service Mesh、通用 OpenAI Proxy 或大量微服务。

### 4. 不可违反的实时协议规则

- 一条客户端 WebSocket 对应一条火山 WebSocket。
- 客户端每条 binary message 对应火山一条 binary message。
- 不合包、不转码、不二次压缩 PCM、不启用 per-message deflate。
- 火山返回 binary message 按字节原样回传。
- text message 只用于 `gateway.*` 控制事件；客户端 binary 仍是现有 SAUC。
- full request 只读解析和白名单校验；默认要求 managed client 已使用伪设备 uid，从而原样转发。
- 音频逐帧热路径不访问 PostgreSQL、不发消息队列、不写同步业务日志。
- 两个方向都只有一个 writer；所有 queue/channel 有界。
- 任一方向失败时 cancel 同一 session Context、关闭两侧、释放租约并幂等落用量。

### 5. 安全底线

- 代码、镜像、配置、测试 fixture 中禁止真实 Secret。
- 桌面 App 是 public client，不能依赖 App 内静态 Secret。
- Guest bootstrap 生成设备 P-256 key；生产使用 DPoP。
- 普通用户接口严格使用 RFC 9449：`Authorization: DPoP <access-token>` 与独立 `DPoP: <proof-jwt>`；管理员 OIDC 接口仍使用 Bearer。
- Access Token 10 分钟；高风险接口依据 `auth_time`/`amr` 强制 5 分钟 step-up，不接受 body 自报认证状态。
- Refresh Token 随机、不透明、只存 HMAC hash、每次旋转、检测 family reuse；刷新接口必须支持短期加密幂等重试，数据库保证一个旧 Token 最多产生一个后继。
- Provider endpoint/resource/model/Header 全部服务端 allowlist；客户端不能传上游 URL。
- 管理 API 使用独立 OIDC audience、SSO、MFA 和 RBAC。
- 不记录音频、正文、Prompt、Authorization、DPoP、Cookie、Refresh Token 或 Provider Key。
- 金额使用整数最小货币单位；用量和支付写操作必须幂等。
- PostgreSQL 必须使用 `viva_api`、`viva_gateway`、`viva_worker`、`viva_migrator` 四个独立身份；任何运行角色不得使用 owner/migrator 凭证，Gateway 权限测试必须证明其不能读取 identity、订单、退款、支持备注或 PII 表。

### 6. 实施顺序

严格执行以下里程碑，一次只实现一个；每个里程碑完成后停止并提交验收报告，不自动跳到下一阶段。

#### M0：仓库和契约

创建：

- `cmd/api`、`cmd/gateway`、`cmd/worker`、`cmd/migrate`。
- 主规格中的 `internal/` 模块边界。
- Makefile、Dockerfile、Compose、CI。
- 配置严格校验、统一错误、request ID、Recovery、日志脱敏和 Telemetry 骨架。
- `make local-secrets`：仅在缺失时生成测试 key/JWKS、peppers 和假凭证，0600 权限且加入 `.gitignore`；Gateway 只挂载验签 JWKS，不挂载 JWT 私钥或 PII/Refresh pepper。
- OpenAPI/AsyncAPI lint，OpenAPI 类型生成和漂移检查。
- 迁移目录以 `schema.sql` 拆成可执行版本。
- 把 `database-grants.sql` 纳入迁移后的强制步骤，并增加数据库权限集成测试；新增表未归类权限时 CI 失败。
- Compose 必须以真实 TCP 认证查询判定 PostgreSQL ready，并由一次性 `db-grants` 服务在 migration 后应用权限；为已有本地数据卷提供备份后 bootstrap 或明确的可丢弃卷重建说明。

预期命令：

```text
make fmt
make lint
make generate
make test
make integration
make check
docker compose up -d postgres valkey mailpit minio
```

M0 不接真实火山。

#### M1：SAUC 协议 PoC

- 实现最小 SAUC header/payload parser、gzip 输出限制和 full request validator。
- 实现 Fake Volc WebSocket，可脚本化 partial、definite、final、错误、超时和慢连接。
- 实现 1:1 binary relay、bounded buffer、超时、cancel、close 和优雅下线。
- 从现有 Viva 客户端生成 golden fixtures，补 fuzz test。

验收：1,000 次固定会话无帧重排、泄漏和 goroutine 增长。

#### M2：认证和设备

- Guest bootstrap、设备 public JWK、Token Endpoint DPoP、DPoP Access Token、JWT/JWKS。
- Refresh rotation、family reuse detection、设备撤销。
- Refresh Idempotency-Key、响应丢失重试、并发旋转唯一后继和 `auth_time` step-up。
- 邮箱 OTP mock adapter；保留 Apple/OIDC adapter 接口。
- Guest 升级保持 user ID。

验收：Token 重放、越权、撤销、未知 kid、错误算法和限流测试通过。

#### M3：真实 ASR Gateway

- 火山 Provider Adapter 和 SecretSource。
- Redis 原子 entitlement reservation/concurrency lease。
- `gateway.*` text 事件和 Provider 错误映射。
- 音频字节计量、ASR session 和 usage ledger 幂等落账。
- 与 Viva 托管模式联调，但保留客户端 BYOK 回退直到灰度完成。

验收：直连/中转固定语料 A/B 达到文档 SLO；成本和并发硬上限生效。

#### M4：用户、用量和隐私

- `/me`、设备、usage summary/sessions。
- Entitlement cache、账期 counter、管理用户只读查询。
- 数据导出、注销、诊断报告/上传、短期对象存储和保留策略。
- support_agent 的设备撤销、验证重发和支持备注接口。

#### M5：Polish

- 火山方舟 Adapter、固定 Prompt version、非流式和 SSE。
- model tier、Token 预留/结算、timeout、结果 sanity。
- 不暴露通用 chat completion。

#### M6：套餐和支付

- Plan/version、order/subscription、mock Billing Provider。
- 正式 Provider Adapter、Webhook 原始 body 签名、幂等、乱序、独立部分退款实体和对账。
- Admin quota adjustment 和 audit。

#### M7：生产硬化

- 北京双可用区 Terraform/部署说明。
- Dashboard、SLO、告警、成本熔断。
- 蓝绿、80秒 WebSocket 排空、回滚、PITR 和恢复演练。
- 安全、隐私和 Go/No-Go 清单。

### 7. 每个里程碑的强制输出

结束时输出：

1. 本阶段完成文件和行为。
2. 实际执行的测试命令及结果。
3. OpenAPI/AsyncAPI/schema 是否有变化。
4. 安全和隐私检查结果。
5. 已知风险和明确未完成项。
6. 数据迁移与回滚方式。
7. 下一里程碑开始前需要的唯一输入。

不要以“代码已写”为完成标准；必须有测试证据。

### 8. 工程行为要求

- 先查看当前工作树，保留用户已有改动。
- 编辑使用小步、可审查的补丁。
- 领域 Handler 不直接执行 SQL；Repository 不接收来自客户端的任意 user ID 权限范围。
- 外部时间、随机数、ID、Secret、Provider 和邮件/支付均封装为可替换接口。
- 测试优先 Fake 和 testcontainers；真实 Provider 测试必须显式 opt-in。
- 不因缺少真实域名、支付商或生产 Key 阻塞基础实现，使用 Adapter 和 placeholder 配置。
- 遇到会改变公开契约、存储兼容、安全边界或产品计费的选择时才向用户提问。
- 所有注释、文档和交付说明使用中文；Go 标识符和协议字段使用规范英文。

### 9. 当前第一项任务

现在只执行 M0。先输出一份不超过 15 项的实施计划，然后创建仓库骨架、配置、契约校验、数据库迁移、本地依赖、CI 和最小健康接口。不要提前实现真实火山、支付或生产部署。

## 结束
