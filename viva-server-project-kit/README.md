# Viva Server 新项目交接包

这个目录已经集中保存 Viva 托管服务端的产品研究、成本模型、接口契约、数据库设计、安全规则和部署模板，可整体复制或作为新 `viva-server` 仓库的需求来源。

## 目录内容

- [`Viva-服务端化部署方案.html`](./Viva-服务端化部署方案.html)：架构选择、开源调研、延迟、成本、产品套餐、风险和路线图。
- [`server-handoff/00-START-HERE.md`](./server-handoff/00-START-HERE.md)：交接包入口、文件权威关系和新项目使用方法。
- [`server-handoff/AI-IMPLEMENTATION-PROMPT.md`](./server-handoff/AI-IMPLEMENTATION-PROMPT.md)：可直接交给新项目编码 AI 的首条任务。
- [`server-handoff/01-SERVER-IMPLEMENTATION-SPEC.md`](./server-handoff/01-SERVER-IMPLEMENTATION-SPEC.md)：完整研发与生产部署规格。
- `server-handoff/openapi.yaml`、`asyncapi.yaml`：REST 和实时语音机器契约。
- `server-handoff/schema.sql`、`database-grants.sql`：数据库模型和四角色最小权限。
- `server-handoff/docker-compose.local.yml`、`nginx.example.conf`：本地开发和单机/Beta 部署基线。
- `client-reference/`：当前客户端音频采集、SAUC、ASR、会话和润色实现的只读参考副本，用于协议核对和生成 golden fixtures，不应直接编译进服务端。

## 新项目建议启动方式

新建空仓库 `viva-server`，把本目录中的 `server-handoff` 复制为新仓库的 `docs/handoff`：

```bash
mkdir -p viva-server/docs
cp -R viva-server-project-kit/server-handoff viva-server/docs/handoff
cp -R viva-server-project-kit/client-reference viva-server/docs/client-reference
cp viva-server-project-kit/Viva-服务端化部署方案.html viva-server/docs/
```

然后：

1. 让编码 AI 完整读取 `docs/handoff/00-START-HERE.md`。
2. 将 `docs/handoff/AI-IMPLEMENTATION-PROMPT.md` 作为首条开发任务。
3. 第一轮只实施 M0：仓库骨架、配置、迁移、数据库权限、Compose、CI 和健康检查。
4. M0 验收后，再依次实施 M1–M7；不要跳过 Fake Upstream、认证和协议黄金测试直接连接真实火山。

## 已固定的服务端方向

- Go 模块化单体，同一代码库部署为 `api`、`gateway`、`worker`。
- 一条客户端 WSS 对应一条火山 WSS，SAUC 二进制帧默认原样转发。
- 客户端不保存火山或方舟长期密钥；用户安装后直接获得受限 Guest 试用。
- 普通用户使用 P-256 DPoP；Refresh Token 强制旋转和 family reuse detection。
- PostgreSQL 是永久事实来源；Valkey 仅处理限流、重放、预留和租约。
- 数据库使用 `viva_api`、`viva_gateway`、`viva_worker`、`viva_migrator` 四个独立身份。
- 音频、转写正文和 Prompt 默认不落库、不写日志。
- 首版 LLM 使用产品专用方舟 Adapter；不向客户端开放通用模型代理。

## 生产前必须补齐

- 正式域名、备案、云账号和北京双可用区。
- 火山 ASR/方舟正式资源、并发容量及集中托管/转供的书面商务确认。
- 支付商、邮件服务商和管理员企业 OIDC。
- 用户协议、隐私政策、套餐价格、退款规则和试用额度。
- Docker/PostgreSQL/Nginx 的真实执行、压测、备份恢复与发布排空演练。

禁止把真实 API Key、数据库密码或生产证书写入此目录或新仓库。
