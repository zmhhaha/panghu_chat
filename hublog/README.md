# Hublog 业务服务

虎博（Hublog）的第一版模块化单体服务。当前实现将账号、关注关系、动态、Feed 和事件 Outbox 保存在 PostgreSQL，使用 Redis Streams 发布异步事件。

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

## API 当前范围

- `GET /health/live`、`GET /health/ready`
- `POST /api/v1/users`、`GET /api/v1/users/{user_id}`
- `POST /api/v1/users/{user_id}/follow`、`DELETE .../follow`
- `POST /api/v1/posts`、`GET /api/v1/posts/{post_id}`、`DELETE /api/v1/posts/{post_id}`
- `GET /api/v1/feed?cursor=...&limit=...`

当前登录用户由 OIDC 反向代理传入 `X-Auth-Request-User` 或 `X-Auth-Request-Email`。仅当 `ALLOW_DEV_AUTH=true` 时才接受 `X-Hublog-User-Id`，该开关在生产配置中必须保持关闭。

认证头中的值可以是 Hublog 用户 UUID、用户名或邮箱；首次登录后的 Casdoor 用户绑定流程需要在邀请注册模块中补充。

## 异步 Worker

```bash
python -m app.worker
```

Worker 从 PostgreSQL 领取 pending Outbox 记录，写入 Redis Stream `hublog.events`。下游 HBase、Elasticsearch、通知和统计消费者可按 `event_id` 实现幂等。
