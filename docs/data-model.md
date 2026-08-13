# 虎博数据模型

## 1. PostgreSQL 主表

### users

```text
id              UUID/UUIDv7 主键
username        唯一用户名
display_name    展示名称
avatar_url      头像地址
bio             简介
status          active/blocked/deleted
created_at      创建时间
updated_at      更新时间
```

### follows

```text
follower_id     关注者
followee_id     被关注者
status          active/muted/blocked
created_at      创建时间
```

主键为 `(follower_id, followee_id)`，另建 `(followee_id, follower_id)` 索引。

### posts_meta

```text
id              UUIDv7 动态 ID
author_id       作者 ID
post_type       short/article
status          draft/published/hidden/deleted/archived
visibility      public/followers/circle/private
title           长文章标题
content_ref     正文存储引用
version         内容版本
created_at      创建时间
updated_at      更新时间
deleted_at      删除时间
```

正文可以先使用 `content_ref` 指向 PostgreSQL 正文表；未来迁移到 HBase 时只改变引用，不改变业务 API。

### post_visibility

保存圈子 ID、例外用户、屏蔽用户等权限扩展关系。权限变更不直接改 ES 文档，而是由应用层实时判断并发送缓存失效事件。

### outbox_events

```text
id              事件 ID
event_type      事件类型
aggregate_id    业务对象 ID
aggregate_ver   对象版本
payload         JSON
status          pending/published/failed
retry_count     重试次数
created_at      创建时间
published_at    投递时间
```

## 2. HBase 表与 RowKey

### post_by_id

```text
rowkey: post_id
cf:meta  author_id, post_type, visibility, status, created_at, version
cf:body  title, markdown, rendered_html
cf:media media_ids
```

### user_timeline

```text
rowkey: author_id#reverse_timestamp#post_id
cf:post  post_id, author_id, post_type, visibility, created_at
```

`reverse_timestamp` 用 `Long.MAX_VALUE - created_at_millis` 计算，使最新记录排在前面。

### feed_inbox

```text
rowkey: receiver_id#reverse_timestamp#post_id
cf:feed  author_id, post_id, created_at, source
```

大规模部署时可在用户 ID 前增加 hash bucket，降低单 Region 热点；朋友规模的第一版先保持简单 RowKey。

### comments_by_post

```text
rowkey: post_id#reverse_timestamp#comment_id
cf:comment author_id, content_ref, status, created_at
```

HBase 中不保存容易频繁变化的总计数。点赞数、评论数、转发数先在 Redis 聚合，再周期性写入 PostgreSQL/HBase。

## 3. Elasticsearch 文档

索引建议：`hubo-post-v1`，通过 `hubo-post-current` 别名访问。

```json
{
  "post_id": "uuidv7",
  "author_id": "uuidv7",
  "author_name": "展示名称快照",
  "post_type": "short",
  "title": "文章标题",
  "content": "可搜索正文",
  "tags": ["技术", "生活"],
  "visibility": "followers",
  "status": "published",
  "created_at": "2026-08-07T00:00:00Z"
}
```

ES 文档可包含展示名称快照，但详情页必须从主数据源重新加载作者和权限信息。内容更新、隐藏和删除都通过事件更新索引。

## 4. ID、时间和分页

- 业务 ID 使用 UUIDv7 或 Snowflake，避免数据库自增 ID 暴露业务规模。
- 服务端统一保存 UTC，展示层转换为用户时区。
- Feed、评论和搜索统一使用游标分页。
- 游标应包含最后一条记录的时间戳和 ID，并签名防止客户端篡改。
