# Hublog 业务服务

虎博（Hublog）的第一版模块化单体服务。当前实现将账号、关注关系、动态、评论、Feed 和事件 Outbox 保存在 PostgreSQL，使用 Redis Streams 发布异步事件。

访问 `/` 可使用内置响应式 Web 界面，完成统一登录后的全站虎博浏览、个人发布流查看、发布、评论和本人内容删除；Web 静态资源随 API 镜像一起发布，不需要单独部署前端容器。

## 本地运行

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
export DATABASE_URL='postgresql+asyncpg://hublog:password@localhost:5432/hublog'
export REDIS_URL='redis://:password@localhost:6379/0'
export AUTO_CREATE_SCHEMA=true
uvicorn app.main:app --reload --port 8080
```

生产环境使用 `k8s/migration-job.yaml` 执行 `python -m app.migrate` 建表，不启用 `AUTO_CREATE_SCHEMA`。迁移 Job 成功后再部署 API 和 Worker。

## 构建与部署

在 ARM64 集群主节点执行：

```bash
cd ~/armbianbegin/panghu_chat/hublog
bash build.sh
bash deploy.sh --skip-build
```

`deploy.sh` 默认也会调用 `build.sh`，因此首次部署可直接执行 `bash deploy.sh`。它会初始化 Hublog 专用 PostgreSQL 数据库和账号、写入 Vault、执行迁移、部署 API/Worker、接入统一 SSO 并应用 TunnelRoute。镜像构建默认使用清华 PyPI 镜像；可通过 `PIP_INDEX_URL` 切换到其它国内或内网源。还可通过 `IMAGE_TAG` 指定镜像版本，通过 `--skip-build`、`--skip-sso` 和 `--skip-tunnel` 跳过对应阶段。

## API 当前范围

- `GET /health/live`、`GET /health/ready`
- `GET /api/v1/auth/session`、`GET /api/v1/me/posts`、`GET /api/v1/users/{user_id}`
- `POST /api/v1/users/{user_id}/follow`、`DELETE .../follow`
- `POST /api/v1/posts`、`GET /api/v1/posts/{post_id}`、`DELETE /api/v1/posts/{post_id}`
- `GET /api/v1/posts/{post_id}/comments`、`POST /api/v1/posts/{post_id}/comments`、`DELETE /api/v1/comments/{comment_id}`
- `GET /api/v1/feed?scope=all|following&cursor=...&limit=...`
- `GET /api/v1/users/{user_id}/relationship`
- `GET /api/v1/notifications?cursor=...&limit=...`
- `POST /api/v1/notifications/{notification_id}/read`、`POST /api/v1/notifications/read-all`

`/api/v1/feed?scope=all` 返回当前用户可见的全站虎博；`scope=following` 返回本人和已关注用户的虎博，并遵守公开/关注者可见权限。`/api/v1/me/posts` 只返回本人发布的虎博（包括公开、仅关注者和仅自己）。首页提供“全部”和“关注”两个流切换，话题流和推荐流仍保留为后续独立接口。

评论继承所属虎博的可见范围。评论列表按时间倒序分页加载，登录用户可以发表评论、回复任意一条有效评论，并可以软删除自己的评论。虎博响应包含 `comment_count`，评论分页响应同时包含 `total_count` 用于校准计数。

`POST /api/v1/posts` 支持可选的 `Idempotency-Key` 请求头。同一个用户重复使用相同键和相同正文会返回原虎博；相同键对应不同正文会返回 `409`，避免机器人任务重试造成重复发布。

通知记录保存在 PostgreSQL 中，评论/回复通知发给虎博作者和被回复者，关注通知发给被关注者。通知使用独立 UUID，带有关联的 `post_id`/`comment_id`、已读时间和游标分页；Web 顶部通知面板显示未读数，支持单条和全部标记已读。

当前发博流、评论流和 Feed 流在同一服务中保持独立的数据与接口边界。发博和评论写操作分别产生 `Post*`、`Comment*` Outbox 事件；Feed 只编排虎博曝光，评论正文通过评论流接口按需读取。后续可以分别拆服务，或由异步消费者构建评论计数、通知和热门评论摘要。

当前登录用户由 oauth2-proxy 传入 `X-Auth-Request-Sub`、`X-Forwarded-User` 和 `X-Forwarded-Email`。业务账号只绑定稳定的 Casdoor `sub`；用户名和邮箱仅用于首次建档与展示。仅当 `ALLOW_DEV_AUTH=true` 时才接受 `X-Hublog-User-Id`，该开关在生产配置中必须保持关闭。

生产部署使用 [oauth/k8s/deploy-hublog-proxy.sh](../../oauth/k8s/deploy-hublog-proxy.sh) 生成 Hublog 专用 oauth2-proxy。首次认证默认自动创建本地用户；设置 `SSO_AUTO_PROVISION=false` 可以改为只允许已绑定用户。

## 机器人机器身份

机器人不需要浏览器跳转、SSO Cookie 或人工点击登录。Hublog API 同时接受两种身份来源：

1. 人类用户通过 oauth2-proxy 登录 Casdoor，由代理注入 SSO Header。
2. 机器人直接发送 `Authorization: Bearer <service-token>`，由 Hublog 校验 Vault 管理的服务 Token。

服务 Token 是带强制过期时间的高熵随机字符串，Hublog/Vault 只保存 SHA-256 哈希和机器人身份映射，不保存明文 Token。Token 的 `subject` 使用 `service:<bot-name>` 命名空间，并映射到 `users.sso_subject`；首次有效请求可以自动创建对应的 Hublog 机器人用户。机器人随后可以复用现有的发博、评论、Feed、通知和自己的内容接口，业务行为与普通登录用户一致；不会获得管理权限，私密内容仍按 Hublog 的正常可见性和关注关系规则判断。

### 生成与存储

在开发机或集群主机上一次性生成三个机器人凭据：

```bash
cd ~/armbianbegin/panghu_chat/hublog
bash scripts/generate-service-token.sh
```

脚本默认使用当前时间后 180 天作为过期时间；也可以通过 `TOKEN_EXPIRES_AT` 固定过期时间：

```bash
TOKEN_EXPIRES_AT=2027-02-20T00:00:00Z bash scripts/generate-service-token.sh
```

脚本一次性生成 GitHub、国际新闻和热梗三个机器人的凭据。它输出每个机器人的 `SERVICE_TOKEN_*`，只写入对应机器人的 Secret；同时输出合并后的 `HUBLOG_SERVICE_TOKENS` JSON，只写入 Vault。不要把任何一部分提交到 Git。

如只需要生成一个机器人，也可以直接调用底层脚本：

```bash
python3 scripts/generate-service-token.py \
  --name github-trending \
  --username github_trending_bot \
  --display-name 'GitHub 热门项目机器人' \
  --expires-at 2027-02-20T00:00:00Z
```

随后应用 Hublog 的两个 ExternalSecret，并滚动重启 API 让 `envFrom` 重新读取 Secret：

```bash
kubectl apply -f ~/armbianbegin/vault/inventory/hublog-externalsecret.yaml
kubectl apply -f ~/armbianbegin/vault/inventory/hublog-bot-auth-externalsecret.yaml
kubectl -n hublog rollout restart deployment/hublog-api
kubectl -n hublog rollout status deployment/hublog-api
```

API 会从可选的 `hublog-bot-auth` Secret 中读取 `HUBLOG_SERVICE_TOKENS` 哈希映射；没有配置机器人凭据时，普通 Hublog 部署仍可正常运行。机器人自己的明文 Token 应通过机器人部署的 Secret/ExternalSecret 注入，不能复用其他机器人或个人账号的凭据。

### 调用方式

集群内机器人应调用 Hublog 的 ClusterIP Service，避免经过面向浏览器的 oauth2-proxy 登录页：

```bash
curl -X POST \
  'http://hublog-api.hublog.svc.cluster.local/api/v1/posts' \
  -H "Authorization: Bearer ${HUBLOG_SERVICE_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: github-trending:2026-08-23:content-hash' \
  -d '{"title":"GitHub 今日热门","content":"...","visibility":"public","tags":["GitHub","开源"]}'
```

公网地址仍然适合浏览器访问；如果机器人必须从集群外调用，应单独配置允许 Bearer Token 的机器入口，不要让机器人跟随浏览器 OAuth 重定向。

### 轮换与停用

服务 Token 过期后 API 会拒绝请求。轮换时生成新 Token、更新 Vault 中的 JSON、等待 ExternalSecret 同步并滚动重启 API，再更新对应机器人 Secret；旧 Token 可以立即从 JSON 中删除。机器人用户本身不会因 Token 轮换而变化，历史虎博和事件仍归属于同一个 `service:<bot-name>` 身份。

## 异步 Worker

```bash
python -m app.worker
```

Worker 从 PostgreSQL 领取 pending Outbox 记录，写入 Redis Stream `hublog.events`。下游 HBase、Elasticsearch、通知和统计消费者可按 `event_id` 实现幂等。
