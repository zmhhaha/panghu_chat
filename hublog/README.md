# Hublog 业务服务

虎博（Hublog）的第一版模块化单体服务。当前实现将账号、关注关系、动态、Feed 和事件 Outbox 保存在 PostgreSQL，使用 Redis Streams 发布异步事件。

访问 `/` 可使用内置响应式 Web 界面，完成统一登录后的动态浏览、发布和本人内容删除；Web 静态资源随 API 镜像一起发布，不需要单独部署前端容器。

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

`deploy.sh` 默认也会调用 `build.sh`，因此首次部署可直接执行 `bash deploy.sh`。它会初始化 Hublog 专用 PostgreSQL 数据库和账号、写入 Vault、执行迁移、部署 API/Worker、接入统一 SSO 并应用 TunnelRoute。可通过 `IMAGE_TAG` 指定镜像版本，通过 `--skip-build`、`--skip-sso` 和 `--skip-tunnel` 跳过对应阶段。

## API 当前范围

- `GET /health/live`、`GET /health/ready`
- `GET /api/v1/auth/session`、`GET /api/v1/users/{user_id}`
- `POST /api/v1/users/{user_id}/follow`、`DELETE .../follow`
- `POST /api/v1/posts`、`GET /api/v1/posts/{post_id}`、`DELETE /api/v1/posts/{post_id}`
- `GET /api/v1/feed?cursor=...&limit=...`

当前登录用户由 oauth2-proxy 传入 `X-Auth-Request-Sub`、`X-Forwarded-User` 和 `X-Forwarded-Email`。业务账号只绑定稳定的 Casdoor `sub`；用户名和邮箱仅用于首次建档与展示。仅当 `ALLOW_DEV_AUTH=true` 时才接受 `X-Hublog-User-Id`，该开关在生产配置中必须保持关闭。

生产部署使用 [oauth/k8s/deploy-hublog-proxy.sh](../../oauth/k8s/deploy-hublog-proxy.sh) 生成 Hublog 专用 oauth2-proxy。首次认证默认自动创建本地用户；设置 `SSO_AUTO_PROVISION=false` 可以改为只允许已绑定用户。

## 异步 Worker

```bash
python -m app.worker
```

Worker 从 PostgreSQL 领取 pending Outbox 记录，写入 Redis Stream `hublog.events`。下游 HBase、Elasticsearch、通知和统计消费者可按 `event_id` 实现幂等。
