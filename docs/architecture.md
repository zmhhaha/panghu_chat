# 虎博架构设计

## 1. 组件边界

第一阶段是一个模块化单体，模块边界如下：

| 模块 | 主要职责 |
| --- | --- |
| identity | 注册、登录、会话、个人资料、封禁 |
| social | 关注关系、圈子成员、屏蔽和拉黑 |
| content | 动态、长文章、草稿、版本、标签、删除 |
| feed | 用户时间线、首页 Feed、游标分页 |
| interaction | 点赞、评论、转发、计数 |
| search | ES 索引、搜索、索引重建 |
| notification | 提及、评论、点赞和系统通知 |
| moderation | 举报、审核、敏感词、审计 |
| media | 上传凭证、媒体元数据、缩略图和清理 |

模块之间通过应用服务接口或领域事件通信，禁止直接跨模块修改对方数据表。

## 2. 同步与异步边界

同步请求只负责用户必须立即看到的结果：身份校验、权限校验、主记录写入和读取。以下工作异步执行：

- HBase 时间线和 Feed 写入
- Elasticsearch 建索引和删除索引
- 通知生成
- 计数聚合和热度统计
- 图片/视频缩略图处理
- 数据分析和归档

使用 Transactional Outbox：业务事务和 Outbox 记录在同一个 PostgreSQL 事务中提交，分发器负责投递并记录重试状态。消费者以 `event_id` 做幂等键。

## 3. 内容状态机

```text
draft -> published -> hidden -> deleted
                  \-> archived
```

- `draft` 只对作者和有权限的管理员可见。
- `published` 可按可见范围访问。
- `hidden` 对普通用户不可见，但保留审计信息。
- `deleted` 先写删除标记，再异步清理 HBase、ES 和媒体文件。
- 任何状态转换都记录操作者、原因和时间。

## 4. 权限模型

可见范围最少包含：

- `public`：所有访客可见
- `followers`：作者关注者可见
- `circle`：指定圈子成员可见
- `private`：仅作者可见

权限判断必须经过应用层。ES 文档中的 `visibility` 和圈子信息只能用于缩小候选范围，不能替代最终授权。用户被拉黑、内容被删除或圈子成员变更后，读取接口必须实时重新校验。

## 5. Feed 策略

小型社群默认使用 Fanout-on-Write：发布事件触发 Feed Worker，把动态写入关注者的 `feed_inbox`。为了避免热点账户造成写放大：

- 关注者数量低于阈值时走推模式。
- 超过阈值时只写作者时间线，读取首页时合并热点作者内容。
- 阈值通过配置项控制，不能写死在业务代码中。

首页返回 `next_cursor`，游标包含时间戳和最后一条 `post_id`，避免数据插入导致分页重复或遗漏。

## 6. 可靠性要求

- 所有消费者支持至少一次投递。
- HBase、ES 和通知写入失败时使用指数退避重试。
- 重试超过上限进入死信队列，并提供管理员重放入口。
- 生产接口需要幂等键，例如客户端传递 `Idempotency-Key`。
- 删除、封禁、权限变更事件必须可审计、可重放。
- ES 索引使用版本别名，支持全量重建后原子切换。

## 7. API 初稿

```text
POST   /api/v1/auth/invitations
POST   /api/v1/auth/login
GET    /api/v1/users/{user_id}
POST   /api/v1/users/{user_id}/follow
DELETE /api/v1/users/{user_id}/follow
POST   /api/v1/posts
GET    /api/v1/posts/{post_id}
PATCH  /api/v1/posts/{post_id}
DELETE /api/v1/posts/{post_id}
GET    /api/v1/feed?cursor=...
POST   /api/v1/posts/{post_id}/likes
POST   /api/v1/posts/{post_id}/comments
GET    /api/v1/posts/{post_id}/comments?cursor=...
GET    /api/v1/search?q=...&cursor=...
GET    /api/v1/notifications?cursor=...
```

接口统一返回 `request_id`，列表接口统一使用游标分页，写接口统一返回资源版本和更新时间。

## 8. 安全与运维

- 邀请制或白名单注册，登录接口限流。
- 图片、视频上传使用短期签名 URL，服务端校验 MIME、大小和扩展名。
- Markdown/HTML 必须经过清洗，禁止脚本注入。
- 对外接口使用 HTTPS，敏感配置放入 Vault 或同等密钥管理系统。
- 记录登录、权限变更、删除、审核和管理员操作日志。
- 监控发布成功率、Feed 延迟、Outbox 积压、ES 延迟、HBase 读写延迟和死信数量。
