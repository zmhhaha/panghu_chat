# 虎博基础设施需求与现状评估

## 1. 文档目的

本文档独立记录虎博所需的通用基础服务，以及现有 `armbianbegin` 仓库和服务器的实际部署状况。本文不替代虎博业务架构、数据模型和实施路线文档。

评估信息：

- 评估日期：2026-08-07
- 服务器入口：`192.168.137.101`
- 检查方式：SSH 和 Kubernetes 只读检查
- 检查范围：节点、Pod、Service、StatefulSet、Deployment、存储、Ceph、Helm、监控、备份与平台治理资源

## 2. 虎博的通用服务需求

| 能力 | 第一版需求 | 主要用途 |
| --- | --- | --- |
| Kubernetes | 必需 | 承载应用、Worker 和通用服务 |
| PostgreSQL | 必需 | 用户、关系、权限、内容元数据、Outbox |
| Redis | 必需 | 缓存、会话、限流、计数和短期任务状态 |
| 身份认证 | 必需 | 登录、OIDC、邀请注册和账号生命周期 |
| API 入口 | 必需 | HTTPS、域名路由、认证、上传限制和限流 |
| 对象存储 | 必需 | 图片、视频、附件和签名上传 |
| 全文搜索 | 必需 | 动态、长文章、标签和用户搜索 |
| 异步事件 | 必需 | Feed 分发、搜索索引、通知和统计 |
| 密钥管理 | 必需 | 数据库、OIDC、SMTP 和对象存储凭据 |
| 邮件通知 | 必需 | 邀请、登录验证和系统通知 |
| 监控告警 | 必需 | 节点、Kubernetes、数据库、应用和业务指标 |
| 集中日志 | 必需 | 故障定位、审计和事件追踪 |
| 自动备份 | 必需 | PostgreSQL、Vault、etcd、对象和搜索索引恢复 |
| 媒体处理 | 第二阶段 | 图片压缩、缩略图、格式转换和视频转码 |
| HBase | 规模增长后 | 大规模时间线、Feed 和评论范围扫描 |
| Kafka/Redpanda | 规模增长后 | 高吞吐事件总线和数据平台接入 |
| Flink/Spark | 数据阶段 | 实时统计、离线分析、推荐和归档 |

## 3. 现有集群概况

现有环境是 5 节点 ARM64 Kubernetes 集群：

| 节点 | 角色 | CPU | 内存 |
| --- | --- | ---: | ---: |
| arm-cluster-master | control-plane | 8 核 | 约 16 GiB |
| nanopct4-server1 | worker | 6 核 | 约 4 GiB |
| nanopct4-server2 | worker | 6 核 | 约 4 GiB |
| nanopct4-server3 | worker | 6 核 | 约 4 GiB |
| orangepi5-max-server1 | worker | 8 核 | 约 16 GiB |

集群合计约 34 核 CPU、44 GiB 内存。Ceph 总容量约 436 GiB，已使用约 5.5 GiB，可用约 431 GiB。

当前没有 Kubernetes Metrics Server，因此无法通过 Metrics API 获得所有节点和 Pod 的实时使用量。资源 Requests 显示，三台 NanoPC T4 的内存预留已经达到 52% 至 59%，Orange Pi 节点约为 59%；部分节点的 Limits 存在明显超配。

## 4. 已部署且可复用的服务

| 服务 | 当前状态 | 虎博复用方式 |
| --- | --- | --- |
| Kubernetes 1.31 | 5 个节点 Ready | 部署虎博 API、Web 和 Worker |
| 私有镜像仓库 | 宿主机 Docker 运行，端口 5000 | 保存 ARM64 应用镜像 |
| PostgreSQL 16 | `data` 命名空间单实例运行 | 第一版事务主库 |
| Redis 7 | `data` 命名空间单实例运行 | 缓存、限流、计数和 Redis Streams |
| Casdoor | `oauth` 命名空间运行 | 虎博 OIDC 身份提供方 |
| oauth2-proxy | 多个项目已双副本运行 | Web 入口认证参考实现 |
| Vault | 单实例运行，当前已解封 | 保存虎博所有敏感配置 |
| External Secrets Operator | 正常运行 | 将 Vault Secret 同步至虎博命名空间 |
| Nginx Ingress | 正常运行 | 集群入口路由 |
| Cloudflare Tunnel | 主 Tunnel 双副本运行 | 公网域名和 TLS 入口 |
| Ceph RBD | StorageClass 正常 | PostgreSQL、Redis 等 RWO 持久卷 |
| CephFS | StorageClass 正常 | 需要 RWX 的共享文件 |
| SMTP 邮件服务 | 单实例正常运行 | 邀请邮件和基础邮件通知 |
| Ceph Prometheus | 宿主机运行 | 当前采集 Ceph 和节点指标 |
| Ceph Grafana | 宿主机运行，端口 3000 | 当前展示 Ceph 监控 |
| Ceph Alertmanager | 宿主机运行，端口 9093 | 当前承接 Ceph 告警 |

## 5. 仓库已有材料但集群未部署

以下组件在 `armbianbegin` 仓库中存在 Dockerfile、脚本或 Kubernetes 清单，但在实际集群中没有对应 Pod、Service 或工作负载：

- Hadoop/HDFS
- ZooKeeper
- HBase Master、RegionServer 和 Thrift
- Hive
- Spark
- Flink
- Gitea/Drone

这些内容不能视为当前可直接调用的在线服务。正式复用前需要重新检查镜像、ARM64 兼容性、资源配置、持久化、健康检查和版本关系。

## 6. 完全缺失的通用服务

| 优先级 | 缺失服务或能力 | 影响 |
| --- | --- | --- |
| P0 | Elasticsearch/OpenSearch | 无法提供全文搜索 |
| P0 | Ceph RGW、MinIO 或其他 S3 API | 无法实现标准媒体上传和对象管理 |
| P0 | 自动备份与恢复平台 | 数据库、Vault 和 etcd 没有可验证恢复链路 |
| P0 | Kubernetes 和业务监控 | 当前 Prometheus 不采集 Kubernetes、数据库和应用指标 |
| P0 | 集中日志平台 | 没有 Loki、Promtail 或同等服务 |
| P1 | Kafka/Redpanda 等独立消息队列 | 暂时只能使用 Redis Streams 承载异步事件 |
| P1 | Metrics Server | 无法使用 `kubectl top` 和基于资源指标的 HPA |
| P1 | 媒体处理服务 | 没有压缩、缩略图、转码和恶意文件检测 |
| P1 | 实时通知服务 | 没有统一 WebSocket、SSE 或 Web Push 服务 |
| P1 | 内容审核服务 | 没有敏感词、举报队列和审核工作台 |
| P1 | 通用任务治理 | 没有死信、重放、任务查询和统一重试平台 |
| P1 | API 防滥用能力 | 没有统一验证码、用户级限流和封禁策略 |
| P2 | OpenTelemetry 链路追踪 | 跨 API、Worker、数据库的请求链路不可观测 |
| P2 | 推荐和热榜服务 | 第一版只支持时间排序 |

## 7. 已部署服务的待补能力

### 7.1 PostgreSQL

当前为单实例。尚缺：

- PgBouncer 连接池
- 自动 `pg_dump` 或物理备份
- WAL 归档与时间点恢复（PITR）
- 主从复制和自动故障切换
- PostgreSQL Exporter 和慢查询告警
- 按应用创建独立数据库、用户和最小权限

### 7.2 Redis

当前为单实例，使用 AOF/RDB 和 `allkeys-lru`。尚缺：

- Sentinel 或 Redis Cluster
- Redis Exporter
- 自动备份和恢复验证
- 缓存、会话、幂等键和任务流的实例或策略隔离
- Redis Streams 消费组、重试和死信约定

### 7.3 身份认证

Casdoor 和 oauth2-proxy 已可用，但虎博仍需补充：

- 邀请制注册
- OIDC/JWT 的 API 原生校验
- Casdoor 用户与虎博本地用户的稳定绑定
- 注销、封禁和权限变更同步
- 账号删除和审计流程
- 清理仓库中 Casdoor/MySQL 的明文示例凭据

### 7.4 邮件服务

现有邮件服务只能同步调用 SMTP 发信。尚缺：

- 服务间调用鉴权
- 邮件模板和多语言
- 幂等键
- 队列、重试和死信
- 发送记录、退信和频率限制
- Vault Secret 迁移收口

### 7.5 网关

Nginx Ingress 和 Cloudflare Tunnel 已可用。尚缺统一的：

- 请求 ID
- 用户/IP 限流
- 上传大小和超时策略
- CORS 和安全响应头
- API 访问日志和审计
- NetworkPolicy 网络隔离

### 7.6 监控

Ceph Prometheus 当前仅采集 Ceph、Ceph Exporter 和 5 个 Node Exporter，没有采集：

- Kubernetes API、kubelet 和 Pod
- PostgreSQL、Redis、Vault、Ingress
- 虎博 API、Worker 和前端
- Outbox 积压、Feed 延迟、搜索索引延迟等业务指标

## 8. 当前运行风险

### 8.1 Ceph 健康告警

Ceph 当前为 `HEALTH_WARN`：

- cephadm 无法通过 SSH 连接 `arm-cluster-master` 本机
- 3 个 OSD 被识别为非 cephadm 管理的 stray daemon
- `nanopct4-server1`、`nanopct4-server2`、`nanopct4-server3` 的 MON 所在系统盘剩余空间偏低

Ceph 数据池仍为 `active+clean`，但应在部署 RGW 或新增重要数据前修复管理面问题。

### 8.2 单点故障

以下组件当前都是单点：

- Kubernetes control-plane 和 etcd
- PostgreSQL
- Redis
- Casdoor MySQL
- Vault
- 邮件服务

### 8.3 缺少备份

集群中没有业务 CronJob，宿主机也没有应用数据备份 timer。Kubernetes 没有安装 VolumeSnapshot CRD。当前没有发现 PostgreSQL、Vault、etcd 或业务 PVC 的自动备份计划。

### 8.4 密钥同步告警

检查时发现 `game-review-agent/game-auth` ExternalSecret 引用了不存在的 Vault Secret，持续产生 `UpdateFailed` Warning。该问题与虎博无直接关系，但说明密钥治理流程仍需要补强。

## 9. 虎博第一版建议组合

受当前内存容量和节点负载限制，第一版建议使用：

```text
PostgreSQL
+ Redis
+ Redis Streams
+ Ceph RGW
+ 单节点 Elasticsearch/OpenSearch
+ Casdoor/oauth2-proxy
+ Vault/External Secrets
+ Nginx Ingress/Cloudflare Tunnel
```

第一版暂不部署 Kafka 和 HBase：

- 使用 PostgreSQL 保存内容和时间线主数据。
- 使用 Redis 缓存 Feed、聚合计数，并通过 Redis Streams 处理异步事件。
- 保留 Transactional Outbox，使后续可以迁移到 Kafka。
- 数据量和查询压力达到明确阈值后，再部署 HBase 查询模型。
- Elasticsearch/OpenSearch 第一阶段单节点运行，限制 JVM 内存并设置索引单副本。

## 10. 建设顺序

1. 修复 Ceph `HEALTH_WARN` 和 cephadm 管理问题。
2. 建立 etcd、PostgreSQL、Vault 和 PVC 的自动备份及恢复演练。
3. 部署 Ceph RGW，建立虎博 Bucket、用户和签名上传策略。
4. 部署单节点 Elasticsearch/OpenSearch，建立索引模板和别名。
5. 扩展监控，覆盖 Kubernetes、PostgreSQL、Redis、Ingress 和虎博业务指标。
6. 部署集中日志平台和日志保留策略。
7. 安装 Metrics Server，并为关键服务补充资源基线。
8. 完成虎博 Casdoor/OIDC、邀请注册和本地用户绑定。
9. 定义 Outbox、Redis Streams 消费组、重试和死信规范。
10. 实现媒体处理、实时通知、内容审核和管理后台。
11. 根据实际流量决定是否引入 Kafka、HBase、Flink 和 Spark。

## 11. 上线前最低验收条件

- PostgreSQL、Vault 和 etcd 的备份可以完成实际恢复。
- 对象存储支持私有 Bucket、签名上传、访问控制和生命周期清理。
- 搜索索引可以从主库全量重建。
- 异步事件支持幂等、重试、死信和人工重放。
- 用户权限变化、屏蔽和删除能及时作用于 Feed 和搜索。
- API、数据库、Redis、对象存储和异步任务均有监控告警。
- 日志中不记录密码、Token、Cookie 和私密正文。
- Ceph 恢复为可接受的健康状态，并完成容量告警配置。
