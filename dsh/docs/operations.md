# DSH 运维

## 项目生命周期

项目容器由所有者手工供给，**没有 runtime controller**。DSH 和项目容器都不管理 Kubernetes 资源。

| 动作 | 命令 |
|---|---|
| 渲染并检查（默认，不碰集群） | `bash provision.sh <project>` |
| 创建或更新 | `bash provision.sh --apply <project>` |
| 移除工作负载，保留数据 | `bash provision.sh --remove <project>` |
| 删除数据（破坏性） | `kubectl -n dsh-runners delete pvc dsh-ws-<project>` |

`--remove` 故意不删 PVC。删数据是独立动作，脚本只打印命令而不执行。

**移除前先取消注册**：确认 DSH 网页侧不再有任何 agent 工具指向 `dsh-runner-<project>.dsh-runners:2222`，否则工具会指向一个不存在的 Service。

多次 `--apply` 是幂等的（`kubectl apply` 语义）。改 `provision.local.env` 里的 `WORKSPACE_SIZE` 后重新 apply 会尝试扩容 PVC——**Ceph RBD 支持在线扩容，但缩容不会生效**，且缩容会静默失败而不是报错。

## 持久化与备份

两个卷，位置和内容都不同：

| PVC | 命名空间 | 挂载到 | 内容 |
|---|---|---|---|
| `dsh-home` | `dsh` | 网页容器 `/opt/data` | `DSH_HOME`、`.credentials.yaml`（原生会话签名授权） |
| `dsh-ws-<project>` | `dsh-runners` | 该项目容器 `/workspace` | 项目文件、已装依赖、`HOME` 与各类工具缓存 |

**恢复语义**：Pod 重建保留文件与依赖；**不保留**运行中的进程和终端状态。交互状态在同一存活容器内连续即可，跨重启不要求。

备份要点：

- `dsh-home` 里的 `.credentials.yaml` 是 DSH 原生生成的签名密钥。**备份必须加密并限制访问**——拿到它就能伪造会话。它不由 Vault 管理；如果要求所有密钥进 Vault，需要一个凭据提供者适配器，那是额外工作。
- 备份项目卷只得到文件，不得到"环境"。恢复时要保证 runner 镜像版本与当时一致，否则已装的二进制依赖可能与新镜像的 glibc / Node ABI 不匹配。
- 备份前把工作负载缩到 0 或确认没有命令在跑，避免拷到写了一半的 `node_modules`。

## 凭据轮换

| 凭据 | 轮换后要做什么 |
|---|---|
| `dsh-oidc` 的 client id/secret | 重启网页；不需要重建项目容器 |
| `OAUTH2_PROXY_COOKIE_SECRET` | 重启网页；**所有现存会话失效**，需要重新登录 |
| `dsh-model` 的模型密钥 | 重启网页；项目容器不挂载它，不受影响 |
| 项目作用域传输凭据（尚未创建） | 传输方案定下来之后再补 |

```bash
kubectl -n dsh rollout restart deployment/dsh-web
kubectl -n dsh rollout status deployment/dsh-web --timeout=300s
```

`envFrom` 只在容器创建时解析，所以改 Secret 后**必须重启**才不会用到旧值。

## 命令取消与超时

design 要求"可配置的单命令超时，并能取消整个进程组，且不删除项目存储"。当前实现里**这一项还没有落地**——它属于 DSH 侧配置（stage 2），依赖上游是否提供超时与取消的开关。

在它落地之前，一个失控的命令只能靠重启项目容器终止：

```bash
kubectl -n dsh-runners rollout restart deployment/dsh-runner-<project>
```

这会终止所有进程，但 `/workspace` 上的文件与依赖保留。用这条命令时注意：正在写的文件可能处于中间状态。

## 节点容量

网页与项目容器默认都钉在 `orangepi5-max-server1`（通过 `nodeSelector`）。该节点同时运行：

| 工作负载 | 内存 limit |
|---|---|
| Elasticsearch | 4Gi |
| PostgreSQL | 2Gi |
| Redis | 1Gi |
| embedding-service | 1Gi |
| Hermes（网页 + 三个 CronJob） | 最多 2Gi + 2Gi |
| **DSH 网页** | 2Gi |
| **每个项目容器** | 2Gi |

节点是 8 核 / 15.5 GiB。limits 只在争抢时生效，requests 合计仍在可调度范围内；但**同时活跃的内存上限已经接近节点容量**。

实践建议：

- 项目容器是 2Gi limit；跑大型前端构建或 JVM 项目时容易触顶。真的不够时优先调大项目容器的 limit，而不是网页的。
- 三台 NanoPC（`nanopct4-server*`）各只有 3.66 GiB 且被标记"内存极紧"，**不要**把项目容器挪过去。
- 集群有 `resource_scheduler` 的宿主级内存守卫：节点超 80% 会被打上 `memory.guard/over-80=true:NoSchedule`。design 明确要求**不要**给 DSH 加 toleration 去绕过它。

改落点是改 `k8s/web.yaml` 与 `provision.local.env` 里的 `NODE_HOSTNAME`。注意 RWO 卷与 `strategy: Recreate` 的组合：换节点会重新挂载卷，文件保留。

## 日志

- 项目容器内的命令输出对它自己的终端可见；DSH 网页侧按上游行为记录。
- **不要为了排查方便打开带 query 的完整 URL 日志**：DSH 首次登录的 launch token 出现在 URL 里。见 `cloudflare-tunnel/operator/DSH.md`。
- 网页容器与项目容器都是 `readOnlyRootFilesystem: true`，日志不会在容器可写层无限累积；但如果项目容器往 `/workspace` 写大日志，那会占项目卷容量。
