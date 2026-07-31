# Viva 托管服务端：新项目实施交接包

> 文档状态：实施基线 v1.0
> 生成日期：2026-07-28
> 适用范围：Viva macOS 客户端的托管语音识别、大模型润色、用户、设备、套餐、用量和管理后台服务

## 1. 这个目录是什么

这个目录是一套可以完整复制到新服务端仓库的实施交接包。目标不是只描述架构，而是给人类研发团队或编码 AI 一组明确、可验证、不会互相矛盾的工程契约。

复制到新项目后，建议保留原文件名，并在根目录 README 中链接本目录。

## 2. 文件清单

| 文件 | 作用 | 权威级别 |
|---|---|---:|
| `01-SERVER-IMPLEMENTATION-SPEC.md` | 完整产品、架构、认证、接口、数据、部署、安全和验收方案 | 最高业务权威 |
| `openapi.yaml` | REST API 的机器可读契约 | REST 接口权威 |
| `asyncapi.yaml` | WebSocket 握手、SAUC 二进制帧和网关控制事件契约 | 实时协议权威 |
| `schema.sql` | PostgreSQL 初始逻辑模型、约束和索引 | 数据模型权威 |
| `postgres-init.local.sql` | 本地创建四个非共享数据库角色；仅测试凭证 | 本地数据库引导 |
| `database-grants.sql` | API、Gateway、Worker 的最小数据库授权矩阵 | 数据库权限权威 |
| `.env.example` | 所有配置项、默认值和 Secret 引用约定 | 配置权威 |
| `docker-compose.local.yml` | 本地开发和集成测试基线 | 本地环境权威 |
| `nginx.example.conf` | 单机/Beta 的 WSS、SSE 反向代理基线 | 部署参考 |
| `AI-IMPLEMENTATION-PROMPT.md` | 可直接交给新项目编码 AI 的启动提示词 | 执行入口 |

发生冲突时按以下顺序处理：

1. 安全、隐私和“不可变约束”优先。
2. REST 请求与响应以 `openapi.yaml` 为准。
3. WebSocket 消息与状态机以 `asyncapi.yaml` 为准。
4. 数据字段与唯一性约束以 `schema.sql` 为准，运行角色数据库权限以 `database-grants.sql` 为准。
5. 其他工程实现以主规格为准。
6. 不允许编码 AI 静默发明新接口；确需变化时必须先更新契约和变更记录。

## 3. 一句话架构

```text
Viva 客户端
  ├─ WSS → Go ASR Gateway → 服务端注入火山凭证 → 火山 Seed-ASR 2.0
  ├─ HTTPS/SSE → Control API / Polish Service → 火山方舟或内网 LiteLLM
  └─ HTTPS → 认证、用户、设备、套餐、用量、订单和远程配置

PostgreSQL = 永久事实来源
Redis      = 限流、额度预留、并发租约和短缓存
Worker     = 用量入账、支付 Webhook、邮件、对账和异步任务
```

## 4. 已确定、不再让新项目重复讨论的决策

- 服务端使用 Go，首版采用模块化单体代码仓库，按 `api`、`gateway`、`worker` 三种运行角色部署。
- ASR 第一阶段使用 SAUC 二进制透明代理。一条客户端 WebSocket 严格对应一条火山 WebSocket。
- 音频仍由客户端编码为 16kHz、16bit、mono PCM，并维持当前 SAUC 分包和返回解析。
- 网关不得合并帧、重压缩音频、改变 sequence/flags/gzip 或把火山二进制响应转成另一种语义。
- 火山 ASR、方舟和任何其他大模型长期密钥只存在于服务器 Secret Manager/KMS 和运行内存。
- 桌面客户端是 public client，不在 App 内放所谓“客户端 Secret”。
- 用户首次安装可自动获得受限 guest 试用身份；正式购买前通过邮箱验证码或受支持的 OIDC 身份升级账号。
- Access Token 使用短期 JWT；Refresh Token 使用随机不透明 Token、服务端仅保存哈希并强制轮换。
- 生产阶段使用 DPoP 将 Token 绑定到客户端 Keychain/Secure Enclave 中的 P-256 设备密钥。
- 音频默认不落盘；转写正文和润色正文默认不写数据库、不写日志、不进入监控。
- LLM 接口是产品专用的“润色/改口”接口，不向客户端暴露通用 OpenAI Key 或任意 Prompt 代理。
- PostgreSQL 是用户、订单、订阅和用量账本的事实来源；Redis 不是永久账本。
- ASR 数据面逐帧路径不访问 PostgreSQL、不写同步日志、不调用支付或计费服务。
- 首发部署在中国大陆北京双可用区；先使用 Docker/云容器和托管 PostgreSQL、Redis，达到明确规模再迁移 Kubernetes。
- 生产发布必须支持 WebSocket 排空；不能直接杀死仍在识别的会话。

## 5. 新项目建议仓库结构

```text
viva-server/
├── cmd/
│   ├── api/                 # Control API、用户、套餐、管理接口
│   ├── gateway/             # ASR WebSocket 数据面
│   ├── worker/              # 用量、支付、邮件、对账、隐私任务
│   └── migrate/             # 独立数据库迁移命令
├── internal/
│   ├── accounts/
│   ├── admin/
│   ├── asrproxy/
│   ├── auth/
│   ├── billing/
│   ├── clientconfig/
│   ├── devices/
│   ├── entitlements/
│   ├── polish/
│   ├── privacy/
│   ├── usage/
│   └── platform/
│       ├── db/
│       ├── httpx/
│       ├── redisx/
│       ├── secrets/
│       └── telemetry/
├── migrations/
├── api/
│   ├── openapi.yaml
│   └── asyncapi.yaml
├── deploy/
│   ├── docker/
│   ├── terraform/
│   │   └── volcengine-beijing/
│   └── observability/
├── test/
│   ├── integration/
│   ├── protocol-golden/
│   ├── load/
│   └── fixtures/
├── docs/
├── Dockerfile
├── docker-compose.yml
├── Makefile
├── go.mod
└── README.md
```

## 6. 开始实施前只需要补齐的业务配置

这些项目不会改变核心架构，但新项目必须通过配置或适配器明确选择：

- 正式域名：API 域名、语音 WSS 域名、管理后台域名。
- 云账号和北京地域具体可用区。
- 火山 ASR App/Access/API Key 和资源 ID的 Secret 引用。
- 火山方舟 Endpoint ID、模型档位和 Secret 引用。
- 邮件验证码服务商。
- 支付服务商；没有确定时先实现 `mock` Provider 和完整签名接口。
- 用户协议、隐私政策和价格版本号。
- 免费试用时长、套餐额度、全局成本预算和供应商并发额度。
- 管理后台使用的企业 OIDC/SSO Provider。

这些值不得硬编码在业务代码中。

## 7. 推荐执行方式

1. 把整个 `server-handoff` 目录复制到新仓库 `docs/handoff/`。
2. 将 `docs/handoff/.env.example` 复制为仓库根目录 `.env`，只填写本地 mock 配置；真实 Secret 不进文件。
3. 在 M0 实现并执行 `make local-secrets`，生成仅供本地使用的测试 key/JWKS、peppers 和假 Provider 凭证；目录加入 `.gitignore`，文件权限 0600。
4. 本地 PostgreSQL 首次初始化由 `postgres-init.local.sql` 创建四个独立角色；迁移完成后必须以 migrator 执行 `database-grants.sql`，并用 CI 验证 Gateway 无法读取 identity、订单或 PII 表。
5. 将 `AI-IMPLEMENTATION-PROMPT.md` 的内容作为新项目 AI 的首条任务。
6. 严格按主规格中的里程碑实施，每个里程碑单独验收。
7. 第一阶段只完成协议 PoC 和 Fake Upstream，不先做支付或复杂后台。
8. 协议 PoC 通过后再接真实火山测试账号。
9. 对外 Beta 前完成用户、额度、日志脱敏、成本熔断和隐私流程。
10. 正式收费前完成双可用区、账单对账、备份恢复、安全测试和发布排空演练。

### 本地旧 PostgreSQL 卷升级

新项目直接使用空卷即可。若本机曾运行早期单角色模板，initdb 脚本不会自动作用于已有卷：

- 本地数据可丢弃时，先确认目标 Compose 项目名，再执行 `docker compose -f docs/handoff/docker-compose.local.yml down -v`；这会删除该项目的本地 PostgreSQL/Valkey/MinIO 卷，不能用于生产或含需保留数据的环境。
- 需要保留本地数据时先备份，再只启动 PostgreSQL，以旧 owner（早期模板默认为 `viva`）执行容器内 `/docker-entrypoint-initdb.d/00-viva-local-roles.sql`，随后运行 `docker compose -f docs/handoff/docker-compose.local.yml --profile app run --rm db-grants`。旧 owner 不同时必须替换为实际 owner。

```bash
docker compose -f docs/handoff/docker-compose.local.yml up -d postgres
docker compose -f docs/handoff/docker-compose.local.yml exec -T postgres \
  psql -U viva -d viva -f /docker-entrypoint-initdb.d/00-viva-local-roles.sql
docker compose -f docs/handoff/docker-compose.local.yml exec -T postgres \
  psql -U viva -d viva -v ON_ERROR_STOP=1 \
  -c 'REASSIGN OWNED BY viva TO viva_migrator'
docker compose -f docs/handoff/docker-compose.local.yml --profile app run --rm db-grants
```

早期模板的 `viva` 是本地 superuser，因此可以转移旧对象所有权；若实际旧 owner、权限或对象布局不同，停止套用命令并由 DBA 生成迁移。生产数据库角色升级必须使用经审查的 DBA/IaC 变更，不复制本地密码或上述命令。

## 8. 明确的非目标

首版不做：

- Kubernetes、服务网格、跨地域 active-active。
- 通用 OpenAI API 中转站。
- 把用户音频长期保存到对象存储。
- WebRTC、TTS、全双工语音 Agent、电话/SFU。
- 客户端可自由指定火山 endpoint、resource ID、模型或任意上游 URL。
- 自研密码登录系统。
- 用设备 ID、App 内常量或混淆字符串冒充可信客户端认证。
- 火山异常时静默切换其他 ASR，并宣称结果完全一致。

## 9. 完成交付的判断标准

新服务端只有同时满足以下条件才算“安装即用”方案完成：

- 新用户安装后不填写火山或 LLM API Key 即可获得受限试用。
- 客户端包内和本地配置中不存在供应商长期密钥。
- ASR 代理不会改变 SAUC 二进制返回语义，固定语料与直连结果同档。
- 中转相对直连新增延迟达到主规格 SLO。
- 用户、设备、Token、套餐、额度、订单、用量、注销和数据导出均有完整接口与审计。
- 任何匿名、付费和管理员权限都可服务端撤销。
- 供应商并发和每日成本有服务端硬上限。
- 单节点发布或故障不会无条件中断所有新会话。
- 日志、指标和 Trace 不包含音频、转写正文、Prompt、Token 或供应商密钥。
- 数据库能够按目标 RPO/RTO 恢复，支付和用量重复消息不会重复入账。
