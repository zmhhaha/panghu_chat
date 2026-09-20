# DSH 部署问题记录

> 时间：2026-09-19。**这份文件记录从部署到跑通之间遇到的每一个问题、根因和修法。** 大部分不是"配错了"，而是若干**看着对、实际不对**的陷阱——每一条都花了实机排查才定位。
>
> 相关：[ssh-remote.md](ssh-remote.md)（方案与审计）、[landlock.md](landlock.md)、[boundaries.md](boundaries.md)、[operations.md](operations.md)。

## 结论摘要

**14 个问题，其中 4 个属于"配置完全合法、无任何报错、只是不生效"的静默陷阱。** 最难的三条：

| # | 陷阱 | 为什么难 |
|---|---|---|
| 8 | 按 id 的补丁**不能改 `name`** | YAML 合法、加载无错、**静默无效** |
| 13 | `AllowTcpForwarding no` **连坐 streamlocal** | `sshd -T` 显示 streamlocal 是允许的，只有运行期才拒 |
| 10 | OpenSSH 的 `~` **不是 `$HOME`** | 报错指向密钥缺失，实际是找错目录 |

**最终状态（2026-09-20）**：`hostname` 返回 `dsh-runner-<project>-...`、`pwd` 返回 `/workspace`、`ls -la` 看到的是项目卷。**agent 的命令、文件、终端全部落在项目容器里。**

---

## 一、建立传输（部署初期）

### 1. 网页 Pod 在项目容器之前起不来

**症状**：`CrashLoopBackOff`，`failed to apply loader entry ssh (@deepseek-ai/dsh-ssh): SSH helper disconnected`

**根因**：`dsh-ssh` 在**装载时**就要连上远端。按部署顺序先起网页、后供给项目容器，中间必然失败。

**修法**：不用修——**这是设计要的**。DSH 宁可起不来，也不肯退回在网页容器里本地执行。跑完 `provision.sh --apply` 后会在下次重试时自己恢复。

**值得记**：这条要写进 README，否则看到 `CrashLoopBackOff` 的人第一反应是去放宽网页侧配置。

### 2. `install: cannot change permissions of '/state'`

**根因**：pod 的 `fsGroup: 10000` 让 kubelet 把 emptyDir 建成 **root 所有、组 10000**。非 root 进程能往里写（组权限够），但**不能 chmod 一个不属于自己的目录**。

**修法**：不再 chmod 目录本身，只对新建的文件用 `install -m`。

### 3. `Host key verification failed`

**根因**：**OpenSSH 的 `~` 展开用的是 passwd 里的 home（`/home/dsh`），不是 `$HOME`（`/opt/data`）**。而镜像里 `/home/dsh` 在**只读根**上，根本放不了密钥。

播种脚本按 `$HOME` 写密钥、ssh 去 `/home/dsh` 找——两边对不上。

**修法**：`config/ssh_config` 用**绝对路径** `/opt/data/.ssh/...`。

**值得记**：报错说"主机密钥验证失败"，很容易往 known_hosts 方向查，实际是**客户端根本没读到密钥**。

### 4. `Permission denied (publickey)`，而指纹完全对得上

**症状**：`ssh -v` 显示 offered key 的指纹与 runner 上 `authorized_keys` 的指纹**完全一致**，但仍被拒。

**根因**：sshd 的 `StrictModes` 会对密钥路径**逐级**校验，任何一级 group/world-writable 都拒绝。而 **Kubernetes 造的所有可写卷都是这样**：

- emptyDir → `drwxrwsrwx`
- secret 卷 → `drwxrwsrwt`

**修法**：加一个 **root initContainer**，把卷根 chmod 0755，另建一个 0700 的 `/state/keys` 放密钥。非 root 进程做不到 chmod 别人的目录——**这是那个 init 容器存在的唯一理由**。

### 5. init 容器进不去自己刚建的目录

**症状**：`install: cannot stat '/state/keys/...': Permission denied`

**根因**：caps 砍到只剩 `CHOWN`，root 就**没有 `DAC_OVERRIDE`**，进不去自己刚 chown 给 10000 的 0700 目录。

**修法**：补 `DAC_OVERRIDE`；并把顺序改成**先以 root 建目录装文件、最后再 chown**。

---

## 二、让组合生效

### 6. 按 id 的补丁**不能改 `name`**

**症状**：`cordis.patch.yml` 改完、`kubectl apply`、重启——**配置树里那几行原封不动**。没有任何报错。

**根因**：profile 的 id 定向补丁只能改行的**行为**（`config`、`disabled`），**不能改它绑哪个插件**。带不匹配 `name` 的补丁行会被静默忽略。

**判据**：四条覆盖里唯一生效的 `sandbox-policy` 恰好是**只改 `config`** 的那条；而仓库里所有现成的补丁层（`dsh-base` 被 `dsh-web-app` 打的那些）**没有一条改过 `name`**。

**修法**：改成 **停用 base 行 + 插入新行**。服务名（`ctx.subprocess` 等）才是消费方解析的东西，行 id 不是。

**值得记**：这是本次最阴的一条——**文件合法、YAML 合法、加载无错、只是什么也没发生**。

### 7. 组合的作用范围

**要点**：`standard` agent preset 的头部注释写明了架构——**工具在 preset 里，但执行服务在 host plane**（"the sandbox and approval stack"、"their executors `bash-sandbox`/`pwsh-sandbox`"、"the `fs` service and its policy"）。

而 host plane 正是 `cordis.patch.yml` 覆盖的那一层。所以覆盖三行就够。

**同时**：官方 README 那句 "Web workspace UI paths still assume host filesystem access" 是**真的**，但它指的是**另一族插件**（见 §14），不是执行层。

---

## 三、沙箱（三个阶段，两次修正）

### 8. `workspace-write` 拒绝执行一切

**症状**：`sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host`

**两个后端，两个不同的阻塞原因**——这点被写错过两次，必须分清：

| 后端 | 阻塞在哪 | 证据 |
|---|---|---|
| **bubblewrap** | **容器的 capability 集**（内核无罪） | master 上同内核、root 身份跑同一探测 → `rc=0` |
| **Landlock** | **内核**（没编译） | 全舰队三种内核都是 `CONFIG_SECURITY_LANDLOCK is not set`，syscall `ENOSYS` |

**混成一句"环境不行"会掩盖**：Landlock 换节点没用，bubblewrap 换容器配置也没用（见下）。

### 9. `CAP_SYS_ADMIN` 那次测试**是无效的**

**症状**：给非 root 容器加 `CAP_SYS_ADMIN`，bwrap 仍然失败，于是当时记成"加能力也没用"。

**根因**：**`no_new_privs` 会在 exec 时丢掉这个 capability**——实测 `CapEff` 仍是 `0`。那次根本没测到。

**正确结论**：root + `CAP_SYS_ADMIN` **确实能让探测通过**（`CapEff 200000`）。

### 10. 但 root + `CAP_SYS_ADMIN` 买到的是**假约束**

**症状**：bwrap 探测通过了，看起来有沙箱了。

**根因**：**DSH 的 bwrap profile 没有 `--unshare-user`**——它假设调用者是**非特权**的。实测被包裹的进程：

```
inner uid: 0
inner CapEff: 0000000000200000      ← 仍持 CAP_SYS_ADMIN
mount -o remount,rw /: REMOUNTED    ← 自己把只读改回可写
改完再写 /etc: WROTE
```

**而且** sshd 认证后会降权到 uid 10000，能力全丢，连"通过"都拿不到。

**两条路互相堵死**：降权 → 探测失败；root → 探测通过但约束是假的。

**修法**：**拒绝**这条路线——它把容器变成近乎 privileged，却不兑现承诺。

### 11. Landlock 迁移：门禁必须撤

**经过**：改用 Landlock（boot 时强制 `landlock-run --probe`）。但全舰队内核都没编译 Landlock，所以那个门禁**只可能拒绝启动**。

**修法**：**部署前撤掉**。设计是对的、事实是错的——留着它会让整个 DSH 停摆。

**教训**：`|| fail` 的门禁要确认它在目标环境**能通过**，否则它就是一个定时炸弹。现在是改成一行诊断日志。

### 12. seccomp 回退

`seccompProfile: Unconfined` 当初**只为**让 bwrap 建 namespace。bubblewrap 已从镜像移除 → 改回 `RuntimeDefault`。**纯收益**。

---

## 四、审计发现

### 13. `tool-jobs` **不是**回退路径（虚惊）

**为什么可疑**：官方远程家族**不覆盖 jobs**，而 `dsh-jobs-local` 的 README 说「runs background jobs **inside the harness process**」。

**实测**：它的 `lib/index.js` 只 import `dsh-jobs` / `dsh-scope` / `dsh-timeout` / `schemastery`——**没有 `child_process` / `spawn` / `Worker` / `fork`**。它是**内存登记表**；执行仍走 `ctx.subprocess`（已指向远端）。

### 14. 三个 `-local` 插件官方没有 `-ssh` 版

`file-reference-local` / `attachment-local` / `spill-local` 仍在**网页容器**上操作。

`dsh-file-reference-local` 的 README 就是判据：*"Choose this package when `read` uses the Harness host filesystem; remote or virtual namespaces need matching discovery."*

**处置**：`file-reference-local` **停用**（它把网页容器的路径当 `@file` 候选给模型，而那些路径 `read` 一个也打不开）；另两个**保留**——`attachment-local` 还负责为模型请求归一化图片，盲停可能打断带图请求。

### 15. runner 内没有 uid 分离

sshd 与 agent 命令**同 uid（10000）**，传输密钥归这个 uid → **agent 可写自己的主机密钥**。影响是**自伤式 DoS**（改密钥 → 网页侧 `known_hosts` 失效 → 下次连接被拒），不是提权。**不改**。

---

## 五、最后的阻塞：`AllowTcpForwarding no` 连坐 streamlocal

**症状**（改了 `danger-full-access` 之后）：沙箱错误消失了，但 bash 变成

```
Error: Client network socket disconnected before secure TLS connection was established
```

**误导之处**：这个报错读起来像"连不上"，而且 **fs 工具完全正常**——只有 bash 挂。

**根因**：`dsh-ssh` 的架构是

> The OpenSSH master carries private administrative RPC. **Each program stream uses a separate forwarded Unix socket** and an independent SSH channel.

- **fs** 走 master（管理 RPC）→ 一直正常
- **bash** 走**独立转发 socket** → 一直被拒

而 `runner/sshd_config` 里写着 `AllowTcpForwarding no`。**OpenSSH 会因此拒绝 streamlocal 的远程转发请求**，尽管配置里 `AllowStreamLocalForwarding yes`、`sshd -T` 也确认是 yes——**只有运行期才拒**：

```
Received request from 10.244.4.123 to remote forward to path "/tmp/fwd4",
but the request was denied.
```

**修法**：`AllowTcpForwarding yes`。

**权衡**（有界）：sshd 的**预期**客户端是网页 Pod，而网页 Pod **本来就在这里有一个 shell**。所以能开的隧道不超出调用方已有的能力。

> 🔴 **更正（2026-09-20 实测）**：原文还写了"（NetworkPolicy 只放行它）"与"runner 自己的出网被 NetworkPolicy 限到公网"，**两条都不成立**——集群 CNI 是 `kube-flannel`，不实现 NetworkPolicy。实际上集群内**任何** Pod 都能连到这个端口。结论仍然成立（不超出网页 Pod 已有的能力），但成立的理由不是网络隔离。见 [boundaries.md](boundaries.md) 顶部更正。

**值得记**：这是一个**纯配置陷阱**——写的时候完全合理（"转发全关"是收紧），结果关掉了这个服务存在的理由。

---

## 六、权限模式决策

**`danger-full-access` 不是"拆掉边界"，是"打开执行开关"。**

已验证 `dsh-bash-sandbox` 在 `danger-full-access` 下**直接短路**：

```js
if (mode === "danger-full-access") return super.start(spec)   // 不调 confine()
```

| | bash | DSH 内层文件约束 | K8s 容器边界 |
|---|---|---|---|
| `workspace-write` | ❌ | 无（本来就给不出） | 不变 |
| `danger-full-access` | ✅ | 无（不尝试给） | **不变** |

**后两列完全一样。** 安全差量≈0——因为真正的边界从来不在 DSH 里，而在容器那层（无 capabilities、只读根、无集群凭据）。

> 🔴 **更正（2026-09-20 实测）**：原文这里还列了"NetworkPolicy 挡内网"，**不成立**。集群 CNI 是 `kube-flannel`，不实现 NetworkPolicy。**列在"容器那层"的边界项里，网络一项现在是空的**——见 [boundaries.md](boundaries.md) 顶部更正。

---

## 七、运维注意

### 重新供给项目后必须重启网页

`dsh-ssh` **只在启动时建连，且不自动重连**。`provision.sh --apply` 会替换 runner Pod → 连接作废 → 网页侧一直用一个远端已不存在的连接。`provision.sh` 结尾会打印这条命令。

### 只重建镜像不会触发滚动

镜像 tag 是 `:latest`，Deployment spec 不变 → `kubectl apply` 报 `unchanged` → **不会滚动**。必须显式：

```bash
kubectl -n dsh-runners rollout restart deployment/dsh-runner-armbianbegin
```

### 排查顺序

```bash
kubectl -n dsh logs deploy/dsh-web -c dsh | head -40          # 先看 [seed-profile]
kubectl -n dsh-runners logs -l role=runner -c runner --tail=40 # 再看 sshd
kubectl -n dsh-runners exec deploy/dsh-runner-armbianbegin -c runner -- /usr/sbin/sshd -T | grep -i forward
```

第三条是排查转发类问题的关键——**`sshd -T` 只报配置，不报"实际会不会被拒"**。

---

## 八、工作区选择器的 cwd 必须两边都存在

**症状**：转发修好之后，bash 换成 `Error: spawn bash ENOENT`。

**误导之处**：读起来像"runner 里没有 bash"。实测 **`/bin/bash` 存在**。

**根因**：**Node 的 `spawn` 在 `cwd` 不存在时也返回 `ENOENT`，而且报的是可执行文件的名字。** 会话的工作目录是界面上选的 `/opt/data/github`——那是**网页容器**的路径——被当作远端 `cwd` 发过去，runner 上没有这个目录。

**为什么难发现**：`Client network socket disconnected` 把它盖住了。转发没修好时 spawn 根本走不到这一步；转发一修，下一层立刻露出来。

**修法**：网页 Pod 挂一个**空的** `/workspace`，让选择器能列出这个路径。选中后 session cwd = `/workspace`，两边都存在，而且**含义正确**——这边空着不用，那边就是项目卷。

**选择器为什么帮不上忙**：`browse` 选择器列的是**它所在容器**的目录，而选中的目录会成为远端 spawn 的 `cwd`。所以"在界面上选一个目录"这个动作，天然会把网页容器的路径当成远端的路径。

**这是 §14 那条"工作区 UI 仍假设宿主机文件系统"限制的第三次现身**：先是 `@file` 补全，再是远端 spawn 的 cwd，这次是选择器的根目录。前两个是功能缺口，第三个是**必须按它的规矩用**——工作目录只能选 `/workspace`。
