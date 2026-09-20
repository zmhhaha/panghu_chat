# 虎博基础设施需求与现状评估

## 1. 文档目的

本文档独立记录虎博所需的通用基础服务，以及现有 `armbianbegin` 仓库和服务器的实际部署状况。本文不替代虎博业务架构、数据模型和实施路线文档。

### 修订记录

| 日期 | 变化 |
|---|---|
| 2026-08-07 | 初版。SSH + Kubernetes 只读检查 |
| **2026-09-20** | **全面复核。集群规模、已部署服务、缺失清单均大幅变化；新增第 8.0 节，记录全集群 NetworkPolicy 未生效的实测结论。** |

评估信息：

- **复核日期：2026-09-20**
- 服务器入口：`192.168.137.101`（`arm-cluster-master`）
- 初版检查方式：SSH 和 Kubernetes 只读检查
- **复核方式：SSH 到 `arm-cluster-master`，全部为 `kubectl get` / `describe` / `logs` 只读查询；内网连通性结论由 `dsh-runner` 容器内的 TCP 探测实测得出，非清单推断。** 全部检查未做任何变更。
- 检查范围：节点与资源、CNI 与网络策略、命名空间与工作负载、存储、Vault、Ceph、路由、CronJob、ExternalSecret、集群事件

> **复核的局限**：集群没有 Metrics Server，因此**所有资源数字都是 Requests/Limits，不是实际用量**。本文不对"实际负载是否健康"下结论。此外未检查监控告警、日志保留、部分业务服务的功能正确性。

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

## 3. 集群概况（2026-09-20 实测）

5 节点 ARM64 Kubernetes 集群，全部 Ready，年龄 79 天。Kubernetes **v1.31.14**，Armbian 26.5.1 bookworm，容器运行时 docker 29.6.1。

| 节点 | IP | 角色 | 污点 | CPU 请求 | 内存请求 |
| --- | --- | --- | --- | ---: | ---: |
| arm-cluster-master | 192.168.137.101 | control-plane | control-plane | 950m (11%) | 290Mi (1%) |
| nanopct4-server1 | 192.168.137.201 | worker | — | 100m (1%) | 50Mi (1%) |
| nanopct4-server2 | 192.168.137.202 | worker | `memory.guard/over-80` | 630m (10%) | 978Mi (26%) |
| nanopct4-server3 | 192.168.137.203 | worker | — | 715m (11%) | 1426Mi (38%) |
| orangepi5-max-server1 | 192.168.137.211 | worker | — | **6275m (78%)** | **12396Mi (78%)** |

资源合计约 34 核 CPU、44 GiB 内存。Ceph 总容量 **436 GiB**，已用 **11 GiB**，可用 **425 GiB**。

**两个需要正视的数字：**

- **`orangepi5-max-server1` 的 CPU 与内存请求都已到 78%。** DSH 网页、DSH runner、Hermes、Elasticsearch、PostgreSQL、Redis、embedding、rag 全部钉在这一台上。Limits 超配严重（该节点 CPU limits 1017%、内存 limits 543%）。
- **集群没有 Metrics Server**，`kubectl top` 不可用，因此**无法知道实际用量**，只能看到请求值。上面这些百分比是"已经许出去多少"，不是"用了多少"。

> ⚠️ 初版记录的 5 节点与本表一致。`cluster_config.sh` 的 `ALL_NODES` 里还列了 `orangepi5-plus-server1`，但**该节点目前不在集群中**。

## 4. 已部署且可复用的服务（2026-09-20 实测）

初版列了 16 项，本版列 30 项——**集群规模已明显超出初版评估的范围**。

### 4.1 平台底座

| 服务 | 当前状态 |
| --- | --- |
| Kubernetes 1.31.14 | 5 节点 Ready |
| **CNI** | **`kube-flannel`（每节点一个 DaemonSet）。无 Calico / Cilium / kube-router / antrea——见 8.0** |
| 私有镜像仓库 | 宿主机 Docker 运行，端口 5000 |
| Nginx Ingress | `ingress-nginx` 单副本 |
| Cloudflare Tunnel | `cf-tunnel-main` 双副本 + `cf-tunnel-operator` |
| Ceph RBD / CephFS | StorageClass 正常；20 个 PVC 全部 Bound |
| **Ceph RGW** | **✅ 已部署（2 daemons active）——初版列为 P0 缺失** |
| Vault | 单实例，`Initialized=true`、**`Sealed=false`**、shamir 5/3、**file 存储**、**HA 关闭**、v1.18.0 |
| External Secrets Operator | 3 个 Deployment 正常；**60 个 ExternalSecret，1 个失败** |

### 4.2 数据与检索

| 服务 | 状态 |
| --- | --- |
| PostgreSQL 16 | `data/postgres-0`，69 天，10Gi RWO |
| Redis 7 | `data/redis-0`，69 天，5Gi RWO |
| **Elasticsearch** | **✅ 已部署**（`data/elasticsearch-0`，39 天，30Gi RWO）——初版列为 P0 缺失。**已启用安全认证**（匿名请求返回 401） |
| **rag-service** | ✅ `data/`，ClusterIP，8080 |
| **embedding-service** | ✅ `data/`，8080 |
| sqlite | `data/`，5Gi |

> ⚠️ `data` 命名空间同时存在 `data-postgres-0` 与 `postgres-data`、`data-redis-0` 与 `redis-data` 两组 PVC，疑似历史遗留。未确认哪一组在用。

### 4.3 身份、LLM、GitOps

| 服务 | 状态 |
| --- | --- |
| Casdoor | `oauth/casdoor` |
| oauth2-proxy | **21 个实例**（每个暴露的服务一套，多为双副本） |
| **llm-service** | ✅ `llm/`，9 天。集群统一 LLM 入口 |
| **Gitea** | ✅ `gitops/`——初版列为"仓库有材料但集群未部署"，**现已部署** |
| **Drone** | ✅ `gitops/drone-runner` 双副本 + `drone-builds` 命名空间——同上，**现已部署** |
| OpenSpec | `openspec/`，20 天 |
| Hublog | `hublog-api` 双副本 + `hublog-worker` |
| content-agents | `content-llm-service` + **7 个 CronJob** |
| 邮件服务 | `email-service/email`，76 天 |

### 4.4 应用与 Agent

Portal 5 个（`main-portal`、`agent-portal`、`chat-portal`、`game-portal`、`tool-portal`），Agent 命名空间约 20 个（`research-agent`、`scientific-agent`、`literature-downloader`、`bingbichunqiu`、`daofaziran`、`fofawubian`、`xiaotanrenjian`、`yimaneili`、`zhenzhuzhida`、`zhongkuifumo`、`zhougongjiemeng`、`school-of-one`、`txt2img` 等），游戏类 4 个（`qianfu`、`xuye`、`guanliao`、`shapan`），`game-review-agent`。

### 4.5 本目录新增（初版评估时不存在）

| 服务 | 命名空间 | 年龄 | 说明 |
| --- | --- | --- | --- |
| **DSH** | `dsh` / `dsh-runners` | 46h | `dsh-web` 2/2 Running；`dsh-runner-armbianbegin` 1/1 Running |
| **Hermes** | `hermes` | 3d17h | `hermes-web` 2/2 Running；3 个 CronJob 全部 `suspend: true` |

**集群总计：45 个命名空间，164 个 Pod**（158 Running / 5 Completed / 1 Error）。

### 4.6 公网暴露面

**28 条生效的 `TunnelRoute`**（`kubectl get tunnelroute -A`），包括 `auth`（Casdoor）、`gitea`、`drone`、`hublog`、`openspec-service`、5 个 portal、以及约 18 个 agent UI。**仓库里可查到的路由 YAML 只有其中一小部分**——大部分是直接在集群里创建的。

## 5. 仓库已有材料但集群未部署

初版列了 7 项。复核后：

| 组件 | 08-07 | 09-20 |
| --- | --- | --- |
| Gitea | 未部署 | **✅ 已部署**（`gitops`） |
| Drone | 未部署 | **✅ 已部署**（`gitops` + `drone-builds`） |
| Hadoop/HDFS | 未部署 | 仍未部署 |
| ZooKeeper | 未部署 | 仍未部署 |
| HBase Master / RegionServer / Thrift | 未部署 | 仍未部署 |
| Hive | 未部署 | 仍未部署 |
| Spark | 未部署 | 仍未部署 |
| Flink | 未部署 | 仍未部署 |

后六项在命名空间中**无对应工作负载**，不能视为当前可调用的在线服务。

## 6. 缺失的通用服务（2026-09-20 复核）

| 优先级 | 缺失项 | 08-07 | 09-20 |
| --- | --- | --- | --- |
| ~~P0~~ | ~~Elasticsearch/OpenSearch~~ | 缺失 | **✅ 已解决** |
| ~~P0~~ | ~~Ceph RGW / S3 API~~ | 缺失 | **✅ 已解决**（RGW 已部署） |
| **P0** | **自动备份与恢复平台** | 缺失 | **❌ 仍未解决** |
| **P0** | **Kubernetes 与业务监控** | 缺失 | **❌ 仍未解决** |
| **P0** | **集中日志平台** | 缺失 | **❌ 仍未解决** |
| P1 | Metrics Server | 缺失 | **❌ 仍未解决** |
| P1 | Kafka/Redpanda | 缺失 | 仍未部署 |
| P1 | 媒体处理服务 | 缺失 | 仍未部署 |
| P1 | 实时通知服务 | 缺失 | 仍未部署 |
| P1 | 内容审核服务 | 缺失 | 仍未部署 |
| P1 | 通用任务治理 | 缺失 | 仍未部署 |
| P1 | API 防滥用能力 | 缺失 | 仍未部署 |
| P2 | OpenTelemetry 链路追踪 | 缺失 | 仍未部署 |
| P2 | 推荐和热榜服务 | 缺失 | 仍未部署 |

**三个 P0 已经挂了六周以上没有变化。**

## 7. 已部署服务的待补能力

### 7.1 PostgreSQL
仍为单实例。请求的 PgBouncer、自动 `pg_dump`、WAL 归档与 PITR、主从复制、Exporter 与慢查询告警、按应用最小权限**全部未落实**。

### 7.2 Redis
仍为单实例，AOF/RDB + `allkeys-lru`。Sentinel/Cluster、Exporter、自动备份、实例或策略隔离、Streams 消费组与死信约定**均未落实**。

### 7.3 身份认证
Casdoor + 21 个 oauth2-proxy 已可用。邀请制注册、API 原生 JWT 校验、本地用户绑定、注销/封禁同步、账号删除审计**均未落实**（`authenticated_emails_file` 白名单模式已在 DSH 与 Hermes 上落地，是本仓库首例）。

### 7.4 邮件服务
仍只能同步调用 SMTP。服务间鉴权、模板、幂等键、队列重试死信、发送记录与频率限制**均未落实**。

### 7.5 网关
Nginx Ingress + Cloudflare Tunnel + TunnelRoute operator 可用。**仍缺**：请求 ID、用户/IP 限流、上传大小与超时策略、CORS 与安全响应头、API 访问日志与审计。

> **初版把"NetworkPolicy 网络隔离"列在本节。复核后该条升级为独立的一级风险，见 8.0。**

### 7.6 监控
**与初版完全相同**：Ceph Prometheus 仅采集 Ceph、Ceph Exporter 和 5 个 Node Exporter；集群内**没有任何 Prometheus / Loki / Promtail / Grafana / Alertmanager / metrics-server Pod**，也没有 Metrics API。Kubernetes API、kubelet、PostgreSQL、Redis、Vault、Ingress 和全部业务指标**均不可观测**。

## 8. 当前运行风险

### 8.0 【新增·最高优先级】全集群 NetworkPolicy 均未生效

**这是本次复核最重要的发现，且已实测确认，不是清单推断。**

集群 CNI 是 **`kube-flannel`**（5 个节点各一个 DaemonSet）。`kube-system` 里除 `kube-proxy` 外**没有任何其他 DaemonSet**，全集群**没有 Calico、Cilium、kube-router、antrea**，也没有任何策略相关 CRD。

**flannel 本身不实现 NetworkPolicy**——它只做覆盖网络。因此：

> **集群里现存的 13 个 NetworkPolicy 对象全部是空转的。**

现存 NetworkPolicy（`data/embedding-service`、`data/rag-service`、`llm/llm-service`、`dsh/default-deny`+`tunnel-ingress`+`web-egress`、`dsh-runners/default-deny`+`runner-ingress`+`runner-egress`、`hermes/default-deny`+`tunnel-ingress`+`research-egress`+`hublog-publisher`）**没有一条在起作用**。

**实测证据**——从 `dsh-runner-armbianbegin` 容器内做 TCP 连接探测，而该容器的策略明确声称"项目容器不能访问集群 Service、Pod/Service CIDR、节点地址"：

| 目标 | 策略声称 | 实测 |
| --- | --- | --- |
| `llm-service.llm.svc:80` | 拒绝 | **CONNECTED** |
| `rag-service.data.svc:8080` | 拒绝 | **CONNECTED** |
| `embedding-service.data.svc:8080` | 拒绝 | **CONNECTED** |
| `postgres.data.svc:5432` | 拒绝 | **CONNECTED** |
| `redis.data.svc:6379` | 拒绝 | **CONNECTED** |
| **`kubernetes.default.svc:443`** | 拒绝 | **CONNECTED** |
| **`vault.vault.svc:8200`** | 拒绝 | **CONNECTED** |

**影响范围：**

1. **DSH 的整个安全论证不成立。** DSH 跑在 `danger-full-access`（内层沙箱在该硬件上给不出约束），其设计文档把"Kubernetes 容器 + NetworkPolicy 挡内网"当作唯一边界。实测证明**后半句不存在**。runner 正以该 uid 执行 agent 生成的任意代码，**可直连集群内全部服务、Kubernetes API 和 Vault**。
2. **Hermes 的 `default-deny` 不存在。** 工作台、采集、研究、发布四个角色的网络隔离全部为空。
3. **llm-service / rag-service / embedding-service 的标签门禁不存在。** `llm-client` / `rag-client` / `embedding-client` 标签不产生任何准入效果。
4. **平台文档中"本仓库最高频的坑：调用方必须打标签，否则表现为超时"这一说法，在本集群上没有依据**——该结论看起来是文档间的相互引用，不是本集群的实测经验。

**修复方向**（未实施）：安装 Calico 或 Cilium 作为策略引擎。换 CNI 影响面大，可评估"保留 flannel 数据面 + 叠加仅做策略的组件"的路径。**在修复之前，不应向 DSH 授予任何集群凭据，也不应把"网络隔离"计入任何安全论证。**

### 8.1 Ceph 健康告警——与初版完全相同，六周未改善

`HEALTH_WARN`，三条与 08-07 一字不差：

- `1 hosts fail cephadm check`（初版：cephadm 无法通过 SSH 连接 `arm-cluster-master` 本机）
- `3 stray daemon(s) not managed by cephadm`
- `mons nanopct4-server2, nanopct4-server3 are low on available space`

数据面健康：8 pools / 225 pgs 全部 `active+clean`，3.46k objects / 3.6 GiB，OSD 0/1/2 各 145 GiB、使用率 2.47%–2.67%。**数据面没有问题，管理面问题已挂六周。**

### 8.2 单点故障——与初版相同

etcd、PostgreSQL、Redis、Casdoor MySQL、Vault、邮件服务**全部是单点**。

对 Vault 补充实测细节：**file 存储后端、HA 关闭、单实例**。它承载了全平台的敏感配置，包括 DSH 的 SSH 传输密钥对、各服务模型密钥、OIDC 凭据、Hublog token。

### 8.3 缺少备份——与初版相同，且 Vault 尤其突出

集群内**没有任何备份 CronJob**（唯一的业务 CronJob 都在 `content-agents`，是采集类）。无 VolumeSnapshot CRD，无 Velero。

- **PostgreSQL**：69 天数据，无备份链路
- **Vault**：file 后端 + 单实例 + HA 关闭 + **无备份**。Vault 丢失意味着全平台凭据需要重新签发，DSH 的传输密钥对需要重新生成并重新部署
- **etcd**：无快照
- 全部 20 个 PVC：无快照

### 8.4 密钥同步告警——与初版相同，六周未修

`game-review-agent/game-auth` ExternalSecret 持续 `SecretSyncedError`：`error processing spec.dataFrom[0].extract, err: Secret does not exist`。初版 08-07 就记录了同一条，**至今仍在报错**（最近一次 77 秒前）。

全集群 60 个 ExternalSecret 中**仅此 1 个失败**，说明密钥治理整体健康，但这条告警缺少一个"谁负责清理"的归属。

### 8.5 【新增】`finance-news-agent` 持续失败

`content-agents/finance-news-agent`（`*/30 * * * *`）反复 `BackoffLimitExceeded`，最近两次分别在 26 分钟前与 56 分钟前。**每 30 分钟失败一次，无人处理。** 失败原因未能取得（Pod 已被回收）。

### 8.6 【新增】节点容量集中于单台

`orangepi5-max-server1` 同时承载：DSH 网页 + DSH runner + Hermes + Elasticsearch + PostgreSQL + Redis + embedding-service + rag-service。该节点 CPU/内存请求均达 **78%**，limits 超配 1017% / 543%。

在该节点上继续新增服务之前，需要先恢复容量可见性（装 Metrics Server），否则无法判断是否还有余量。

## 9. 虎博第一版建议组合

（初版结论，**已更新**：Ceph RGW 与 Elasticsearch 现已就绪）

```text
PostgreSQL          ✅ 已就绪
+ Redis             ✅ 已就绪
+ Redis Streams     ✅ 已就绪
+ Ceph RGW          ✅ 已就绪（新）
+ 单节点 ES         ✅ 已就绪（新）
+ Casdoor/oauth2-proxy  ✅ 已就绪
+ Vault/External Secrets ✅ 已就绪
+ Nginx Ingress/Cloudflare Tunnel ✅ 已就绪
```

**初版建议的组合现已全部具备。** 第一版的技术前提下不再有阻塞项；剩下的阻塞项在**运维面**（备份、监控、日志、网络隔离），见第 8 节。

第一版暂不部署 Kafka 和 HBase 的判断**维持不变**。

## 10. 建设顺序（2026-09-20 修订）

初版顺序的前两条与监控一条**一条都没做**，本次按实际风险重排：

1. **【新增·最高】修复 NetworkPolicy 不生效**——装策略引擎，或在设计上接受"无网络隔离"并据此收紧其他控制。**这一条不解决，第 2 条以下的网络相关设计都建立在错误前提上。**
2. **建立 etcd、PostgreSQL、Vault 和 PVC 的自动备份及恢复演练**——初版第 2 条，六周未动。Vault 优先级最高。
3. **修复 Ceph `HEALTH_WARN` 和 cephadm 管理问题**——初版第 1 条，六周未动。
4. **安装 Metrics Server，并扩展监控覆盖 Kubernetes / PostgreSQL / Redis / Ingress 和业务指标**——合并初版第 5、7 条。容量已经到 78%，这件事的前置性比初版更高。
5. 部署集中日志平台和日志保留策略。
6. 清理 `game-review-agent/game-auth` 失效 Secret；建立"谁负责清理"的归属约定。
7. 处理 `finance-news-agent` 的持续失败。
8. 定义 Outbox、Redis Streams 消费组、重试和死信规范。
9. 实现媒体处理、实时通知、内容审核和管理后台。
10. 根据实际流量决定是否引入 Kafka、HBase、Flink 和 Spark。

> 初版第 3、4 条（Ceph RGW、ES）**已完成**。

## 11. 上线前最低验收条件

（初版 8 条，复核后逐条标注现状）

| 验收条件 | 现状 |
| --- | --- |
| PostgreSQL、Vault 和 etcd 的备份可以完成实际恢复 | ❌ **无任何备份** |
| 对象存储支持私有 Bucket、签名上传、访问控制和生命周期清理 | ⚠️ RGW 已部署，策略未复核 |
| 搜索索引可以从主库全量重建 | ⚠️ ES 已部署且启用认证，重建路径未验证 |
| 异步事件支持幂等、重试、死信和人工重放 | ❌ 未实现 |
| 用户权限变化、屏蔽和删除能及时作用于 Feed 和搜索 | ❌ 未实现 |
| API、数据库、Redis、对象存储和异步任务均有监控告警 | ❌ **监控只覆盖 Ceph 与节点** |
| 日志中不记录密码、Token、Cookie 和私密正文 | ⚠️ 未复核（且无集中日志，无法检索验证） |
| Ceph 恢复为可接受的健康状态，并完成容量告警配置 | ❌ **仍是 `HEALTH_WARN`，三条告警六周未变** |

**另需新增一条：**

| 验收条件 | 现状 |
| --- | --- |
| **集群网络隔离实际生效（而非仅存在 NetworkPolicy 对象）** | ❌ **实测未生效，见 8.0** |
