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

### 网页自动登录

新镜像由 `auth/supervisor.mjs` 启动 DSH 并捕获启动 Token，OAuth 通过回环 3081 适配层访问 DSH。用户只需访问 `https://dsh.panghuer.top/` 并完成 Casdoor 登录。不要再从日志复制启动链接；新包装器不输出该凭据。

首次升级必须先 `bash build.sh`，再 `bash deploy.sh`，使新镜像、3081 upstream、白名单挂载和健康探针一起生效。若返回 503，检查 OAuth 就绪和 DSH 启动状态；若原生会话过期，刷新 `/` 重新兑换，不会自动重放 API 写请求。跨站请求仍被拒绝，真实 OAuth 跳转后的浏览器行为需在服务器验收。

适配层只解决网页登录，不能作为项目命令执行隔离已完成的证据。本地回归命令：`node --test panghu_chat/dsh/auth/adapter.test.mjs`。

| 凭据 | 轮换后要做什么 |
|---|---|
| `dsh-oidc` 的 client id/secret | 重启网页；不需要重建项目容器 |
| `OAUTH2_PROXY_COOKIE_SECRET` | 重启网页；**所有现存会话失效**，需要重新登录 |
| `dsh-model` 的模型密钥 | 重启网页；项目容器不挂载它，不受影响 |
| `secret/dsh/ssh` 传输密钥对 | **两边同时轮换**：写入 Vault（必须含配套的新 `known_hosts`）→ 重启两个 ExternalSecret → 重启项目容器（重新落位主机密钥）→ 重启网页。中途连不上是预期行为，不要用放宽主机密钥校验来绕过 |

```bash
kubectl -n dsh rollout restart deployment/dsh-web
kubectl -n dsh rollout status deployment/dsh-web --timeout=300s
```

`envFrom` 只在容器创建时解析，所以改 Secret 后**必须重启**才不会用到旧值。

## 传输与 profile 组合

网页容器每次启动都会跑一次 `auth/seed-profile.mjs`（由 `auth/supervisor.mjs` 在 spawn `dsh` 之前导入）：

1. 若 `$DSH_HOME/profiles/web` 不存在，跑一次 `dsh --profile web --help` 把它物化出来
2. 把镜像里的 `config/cordis.patch.yml` 写进 `profiles/web/cordis.patch.yml`
3. 从 `/opt/dsh-ssh-deps/*.tgz` **离线**装四个 provider（不联网、不跑 `npx`）
4. 把 `/secrets/ssh` 的密钥复制到 `~/.ssh` 并设成 ssh 要求的权限

**它失败即停**：任何一步抛错都让容器起不来。这是刻意的——一个起得来、却在本地偷偷执行命令的容器，比一个起不来的容器危险得多。所以在看到 `dsh-runner-` 前缀的 `hostname` 之前，「网页 Pod 起不来」都属于预期内的失败模式，**不要用放宽配置来绕过**。

排查第一步：

```bash
kubectl -n dsh logs deploy/dsh-web -c dsh | head -40
```

`[seed-profile]` 前缀的行会说明停在哪一步。

`profiles/web/cordis.patch.yml` **归镜像所有**：每次启动都覆盖。手工改它不会持久——改动要进 `config/cordis.patch.yml`，再重建镜像。

远端一侧：**init 容器 `prepare-keys`（root）**每次启动把 Secret 里的主机密钥复制进 `/state/keys` 并设成 sshd 接受的权限（Kubernetes 造的可写卷都是 group/world-writable，sshd 的 `StrictModes` 会拒绝），主容器只校验后启动 sshd。主机身份跨重启稳定，而私钥不在容器可写层留痕。`/state` 本身不需要持久——密钥的真源在 Vault。

### 三个必须记住的操作约束

**1. 每次新建会话，工作目录必须选 `/workspace`。**

选择器列的是**网页容器**的目录，而选中的目录会成为**远端命令的 `cwd`**。选别的会让每条命令报 `spawn bash ENOENT` —— 那是 Node 在说"找不到 cwd"，却在报可执行文件的名字，所以看起来像 runner 里没有 bash。`/workspace` 是唯一在两侧含义一致的路径：**网页容器里空着不用，项目容器里就是项目卷**。

**2. 重新供给项目后必须重启网页。**

`dsh-ssh` 只在启动时建连，**不自动重连**。`provision.sh --apply` 替换 runner Pod 会让连接作废，网页侧会一直用一个远端已不存在的连接。

```bash
kubectl -n dsh rollout restart deployment/dsh-web
```

**3. 只重建镜像不会触发滚动。**

镜像 tag 是 `:latest`、Pod 模板没变，所以 `kubectl apply` 会报 `unchanged`、**不会滚动**。必须显式：

```bash
kubectl -n dsh-runners rollout restart deployment/dsh-runner-<project>
```

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
