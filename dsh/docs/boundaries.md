# DSH 网络边界

本文件解释 `k8s/networkpolicies.yaml` 为什么是现在这样，以及它**不**覆盖什么。

> ## 🔴 2026-09-20 实测更正：这条边界当前不存在
>
> **本文件以下所有"拒绝内网""挡住全部内网"的说法，描述的是策略的意图，不是现状。**
>
> 实测确认（SSH 到 `arm-cluster-master`，全程只读）：集群 CNI 是 **`kube-flannel`**，无 Calico / Cilium / kube-router / antrea。**flannel 不实现 NetworkPolicy，因此 `k8s/networkpolicies.yaml` 里的全部规则都是空转的。**
>
> 从 `dsh-runner-armbianbegin` 容器内做 TCP 探测，策略声称拒绝的 7 个目标**全部连通**：
>
> | 目标 | 本文件声称 | 实测 |
> |---|---|---|
> | `llm-service.llm.svc:80` | 拒绝 | **CONNECTED** |
> | `rag-service.data.svc:8080` | 拒绝 | **CONNECTED** |
> | `embedding-service.data.svc:8080` | 拒绝 | **CONNECTED** |
> | `postgres.data.svc:5432` | 拒绝 | **CONNECTED** |
> | `redis.data.svc:6379` | 拒绝 | **CONNECTED** |
> | **`kubernetes.default.svc:443`** | 拒绝 | **CONNECTED** |
> | **`vault.vault.svc:8200`** | 拒绝 | **CONNECTED** |
>
> **实际承担边界的只剩**：无 capabilities、只读根、无集群凭据、无 hostPath，以及 runner 里没有模型密钥和 `DSH_HOME`。**网络不是其中之一**——而 runner 正以 `danger-full-access` 执行 agent 生成的任意代码。
>
> **本文件其余部分的设计推理仍然有效**（DNAT 端口不确定性、IPv6 缺口、DNS 不构成白名单、except 清单的取舍），但请一律按"**意图**"读，不按"现状"读。
>
> 完整证据与修复方向见 [infrastructure-assessment.md](../../docs/infrastructure-assessment.md) 第 8.0 节与 [network-policy-engine.md](../../../docs/network-policy-engine.md)。

> ### 🟡 2026-09-22 现状：引擎已就位，**复验还没跑**
>
> 上面那条更正描述的是 2026-09-20 的实测。此后发生了三件事：
>
> 1. **策略引擎到位了。** 集群 CNI 于 2026-09-21 由 `kube-flannel` 换成 **Calico**（[calico-migration-run.md](../../../docs/calico-migration-run.md)），NetworkPolicy 第一次真的被执行——而这原本就是换 CNI 的唯一目的（"kube-router 不支持 except"那条理由是**误判**，见该文顶部横幅）。
> 2. **策略本身修好了。** `k8s/networkpolicies.yaml` 里那条 `198.18.0.0/15` 已删除并加注防复发。
> 3. **复验脚本就绪了**：`../verify-network-boundary.sh`，从真实项目容器里探测，判据与期望值见本文末「怎么复验」。
>
> **但那次正式复验还没有执行过。** 零散探针观察到的形状是对的（内网 ClusterIP 不可达、公网可达），可**没有一次带输出的完整运行**。
>
> ⇒ **本页下面所有"边界不成立"的结论在看到复验输出之前继续有效。** 不要按"已经修好了"去读，也不要把网络隔离计入任何已完成的验收。

## 边界是什么：挡内网，不是管控出站

> ⚠️ **本节是设计意图，当前未生效**（见上方更正）。

需求是**项目容器不能直接访问集群内部的 Service**，外网本来就该放行——项目容器要 `npm install`、要 `git clone` 公网仓库。

这恰好落在地址粒度上，因此**不需要 egress 代理**：

- 集群 Pod CIDR 是 `10.244.0.0/16`，Service CIDR 也在 `10.0.0.0/8` 内。
- 一条 `ipBlock: 0.0.0.0/0` + `except` 私网段的 NetworkPolicy 规则，就等价于"允许一切公网地址、拒绝一切内部地址"。
- 用代理反而多引入一个常驻组件，还要额外防它被绕过。

> OpenSpec change 的 design 原本写的是"项目容器只能经受控 egress 代理访问公网 HTTP/HTTPS"。所有者澄清后已改为本方案，store 里的 design / proposal / spec 都已同步。

## except 清单

在 Hermes 已有的 9 条基础上补齐了调查中发现的缺口，共 12 条：

```
10.0.0.0/8        172.16.0.0/12     192.168.0.0/16    127.0.0.0/8
169.254.0.0/16    100.64.0.0/10     0.0.0.0/8         224.0.0.0/4
240.0.0.0/4       192.0.0.0/24      192.88.99.0/24    255.255.255.255/32
```

后三条是 Hermes 那份清单里没有的：`192.0.0.0/24`（IETF 协议保留）、`192.88.99.0/24`（6to4 中继，已废弃）、`255.255.255.255/32`（广播）。

> 🔴 **`198.18.0.0/15` 曾经在这份清单里，已于 2026-09-21 删除——不要加回来。**
>
> 它看起来只是一条"RFC 2544 基准测试保留段"，很安全。但**本网络的软路由跑 OpenClash fake-ip DNS，把所有外部域名都解析到 `198.18.x.x`**（`auth.panghuer.top -> 198.18.0.12`、`registry.npmmirror.com -> 198.18.8.175`）。把它列进 except，等于**把整个公网排除掉**。
>
> 实测：13 条（含它）→ 内网断、公网断；12 条（去掉）→ 内网断、公网通。
>
> 症状是"策略看起来在正常工作，但连公网也不通"，极易误判成引擎缺陷（我为此误判过 kube-router，还多做了一次换 CNI）。相关记录见 [../../../cloudflare-tunnel/TROUBLESHOOTING-1033.md](../../../cloudflare-tunnel/TROUBLESHOOTING-1033.md) 与 [../../../docs/calico-migration-run.md](../../../docs/calico-migration-run.md)。

`169.254.0.0/16` 挡住链路本地，其中包含云元数据地址 `169.254.169.254`。
`127.0.0.0/8` 挡住回环，同时防止以回环为跳板打 Pod 内的 localhost 服务。

## 为什么按端口不设限（项目容器）

`runner-egress` 对公网**不限制端口**，只限制目标地址段。包管理器、VCS、语言工具链各自选端口，限制端口只会制造难以排查的故障，而需求本身是"挡内网"而不是"管控出站"。

网页容器不同：它只需访问 Casdoor，因此只放行公网 443。

## 域名不受保护——这是有意为之

一条公有 DNS 名解析到内网地址时**同样被拒**，因为 NetworkPolicy 匹配的是解析后的目标地址。所以经典的 DNS rebinding 攻击（先解析到公网、再解析到内网）在这里天然无效。

> ⚠️ **该防护当前不成立**（策略未生效，见顶部更正）。实测中 runner 能直连全部内网 Service，因此 DNS rebinding 这一路自然也没有被挡住。

反过来说：**这套策略不是域名白名单**。项目容器可以访问任意公网地址。如果需要"只允许特定公网域名"，那是另一个需求，需要代理或 CNI 的 L7 能力。

## 端口号的一个细节

`web-egress` 里指向项目容器的规则用的是 `port: 2222`，而 `templates/runner.yaml` 里 Service 的 `port` 和容器 `containerPort` **都**是 2222。

这是有意的：Kubernetes NetworkPolicy 的端口匹配发生在 DNAT 之前还是之后取决于 CNI 实现。如果 Service port 与 container port 数字不同，规则写哪个值会变成一个必须实测才能确定的问题（Hermes → Hublog 那条规则就踩过这个坑，见 `docs/hermes-code-review.md` 的 H1）。让两者相等可以直接绕开这个不确定性。

**后续改传输端口时，务必保持 Service port 与 containerPort 相同。**

## IPv6：当前是缺口

全仓库没有任何 IPv6 处理，`ipBlock` 也只有 `0.0.0.0/0` 一条——**IPv6 出站不受这套策略约束**。

当前判断影响有限：`cluster_config.sh` 里 `POD_CIDR` 是 `10.244.0.0/16`，集群是纯 IPv4。

但这是一个**必须显式确认**的假设，不是已知事实。服务器验收时要确认：

- 节点本身有没有全局 IPv6 地址
- Pod 是否拿到 IPv6（`kubectl get pod -o wide` 的 IP 列是否出现 `::`）
- 从项目容器内 `curl -6` 一个公网地址是否通

如果存在 IPv6 出口，两条路：给 `ipBlock` 补等价的 IPv6 `except` 规则，或在 Pod 网络上禁用 IPv6。**在确认之前不要把这条策略当成完整的边界。**

## 未纳入本方案的控制

- **ResourceQuota / LimitRange**：design 提到"namespace 配额兜底"，但全仓库没有先例。当前靠每个容器的显式 `resources` 限制兜底。
- **PID 限制**：design 要求"runtime PID limits"。当前未设置，需要确认集群的容器运行时是否支持。
- **共享内核风险**：以上控制降低干扰，但不消除共享内核的攻击面。高风险负载需要独占节点或经过验证的更强沙箱运行时。

## 部署后实测：本机没有可用的沙箱后端

2026-09-18 部署后的自检（在 DSH 网页里执行）报告：

- 工作目录是 `/opt/data/github`——**在网页容器的 `DSH_HOME` 里**，不是项目容器
- 可用工具是 bash / write / read / edit / glob / grep，全部本地
- 镜像内**没有可用的沙箱后端**（缺 bubblewrap 与 Landlock），于是：

```
sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host
```

`workspace-write` 模式下任何 bash 命令都会被拒，只有提升到 `danger-full-access` 才能执行。

### 这意味着什么

两件事叠加，比"远程执行还没做"更严重：

1. **命令在网页容器里跑**，而那个容器带着模型密钥（`dsh-model` 的 `envFrom`）。
2. **没有任何沙箱**——本机后端缺失，可用模式只剩完全放行。

于是 designer 明确写下的一条要求当前不成立：

> DSH_HOME and credential paths are not agent-readable or writable.

agent 的工作目录**就在 `DSH_HOME` 内部**，因此 `dsh-home` PVC 上的 `.credentials.yaml`（原生会话签名密钥）对它是可读可写的。加上网页 Pod 的 NetworkPolicy 允许公网 443，从抓取内容里注入一条指令就可能把密钥带出去。

### 不要靠装 bubblewrap 来解决

在网页镜像里补 bubblewrap 或调内核参数能让 `workspace-write` 重新可用，但那**只是让错误的架构变得舒服一点**：命令依然在持有模型密钥和会话签名密钥的容器里执行，凭据暴露一点没变。

要修的是传输——让命令落到项目容器，本地自然就不需要沙箱后端了。在那之前，把当前部署当作实验环境：不要指向真实仓库，不要在里面处理凭据。

> **最终结论（2026-09-19，含一次重要修正）**：传输已上线并验证——**文件工具确实跑在项目容器里**。但 **bash、以及一切要起进程的路径都不可用**。
>
> ⚠️ **早前把这条记成"内核不给"是错的。** master 节点上**同一个内核**跑同一个探测是 `rc=0` 通过。真正的瓶颈是**容器的 capability 集**：
>
> - 容器里 uid 10000 无 capabilities 时，bwrap 建得了 namespace 但**挂不了 proc**
> - 非 root 用户加 `CAP_SYS_ADMIN` **不生效**——`CapEff` 仍是 `0`，`no_new_privs` 在 exec 时丢掉了它。所以"加能力也无效"那个结论当初根本没测到
> - root + `CAP_SYS_ADMIN` 确实能让探测通过，**但约束是假的**：DSH 的 bwrap profile 没有 `--unshare-user`，被包裹的进程仍持 `SYS_ADMIN`，实测可以 `mount -o remount,rw /` 把只读根改回去，然后写 `/etc`
> - 而且 sshd 认证后会**降权到 uid 10000**，capability 全丢，连"通过"都拿不到
>
> 两条路互相堵死。所以**换内核、换节点都不解决**，改 capability 也只是买到一个假约束、还把容器变成近乎 privileged。完整实测见 [ssh-remote.md](ssh-remote.md) 第十节。
>
> 后果（**2026-09-20 已解决**）：agent **能读写文件，也能跑命令**。做法是会话走 `danger-full-access` —— 它与 `workspace-write` 在"文件约束"上实际等价（都等于没有），差别只在 bash 能不能跑。**边界由 K8s 容器承担**，不是 DSH 内层。见 [ssh-remote.md](ssh-remote.md) 第十三节。
>
> ✅ **已完成**：bubblewrap 已移出 runner 镜像，`seccompProfile` 改回 `RuntimeDefault` —— 那是**只为**让 bwrap 建 namespace 才放宽的。

### 也不要用 danger-full-access 当常规配置

自检里提到逐条批准 bash 很烦，于是建议改会话策略。这个方向是对的诊断、错的结论：审批疲劳是真实成本，但解法是消除本地执行，而不是把策略永久放宽到完全不沙箱。

### 附带发现：agent 现在拥有自己的配置与插件

`dsh --help` 暴露的架构是：

- `--profile <name>`：**`$DSH_HOME/profiles` 下的一个 profile**
- `--patch <path>`：在 profile 层之上叠加的补丁层
- `dsh plugin ...`：**把剩余参数转发给 profile 目录里的 pnpm**

也就是说配置和插件都在 `DSH_HOME` 里面（本部署是 `/opt/data/profiles/`）。而 agent 的工作目录是 `/opt/data/github`——**同一棵子树的兄弟目录，同一个 UID，可写**。

于是 agent 可以直接改 `$DSH_HOME/profiles/web/` 下的补丁层，改掉自己的策略。

> **更正（2026-09-18）**：本条原先还写了「可以跑 `dsh plugin --profile web add <包>` 装插件」。实测 `dsh plugin` 当前不可用——镜像里没有 pnpm（`dsh: pnpm not found on PATH`）。插件安装这条具体路径暂时走不通，但 **profile 目录可写**这条仍然成立，补丁层是文件。详见 [profile-architecture.md](profile-architecture.md)。

另外，`sandbox-policy.workspaceRoot` 取的是 `process.cwd()`，而容器的 `WORKDIR` 就是 `/opt/data`（即 `DSH_HOME`）。所以即使补上沙箱后端，`workspace-write` 的允许范围也是**整个 DSH_HOME**——名字里的 "workspace" 在这里并不构成限制。

design 对这两条的原文要求正好相反：

> Disable agent access to plugin installation / policy mutation where supported; plugins share host-process privilege.

> Policy/plugin installation and service credential files remain outside project write access.

这条比"能读 `.credentials.yaml`"更值得注意：它是一条**直接的代码执行升级路径**——插件与宿主进程同权限，而宿主就是持有模型密钥与会话签名密钥的那个容器。

把工作目录移出 `DSH_HOME` 只能挡住文件工具，挡不住 bash。**唯一真正的修法还是把执行移出这个容器。**

---

## 结果（2026-09-19）：执行已经移出去了

上面这条结论的目的达到了。

- agent 的**文件操作与命令执行都落在** `dsh-runner-<project>` 里
- 那里**没有模型密钥、没有 `.credentials.yaml`、没有 `DSH_HOME`** —— "插件与宿主进程同权限、而宿主持有密钥"这个担心不再成立
- 边界由 **Kubernetes 容器**承担：无 capabilities、只读根、无集群凭据、无 hostPath
- ⚠️ ~~NetworkPolicy 挡住全部内网~~ —— **2026-09-20 实测该条不成立，见顶部更正**。当前 runner 可达集群内全部 Service，包括 Kubernetes API 与 Vault

关于沙箱模式：会话走 `danger-full-access`，但**它不是"拆掉边界"**。DSH 的内层沙箱在这套硬件上**本来就给不出约束**（bubblewrap 被容器 capability 集挡住、Landlock 内核没编译），两个模式在"文件约束"上实际等价，差别只在 bash 能不能跑。完整推理见 [ssh-remote.md](ssh-remote.md) 第十、十三节。

部署期间踩到的 14 个坑与根因见 [deployment-issues.md](deployment-issues.md)。

---

## 怎么复验（2026-09-22 就绪，尚未执行）

```sh
bash verify-network-boundary.sh --explain   # 先看判据，不碰集群
bash verify-network-boundary.sh             # 端到端复验，退出码 0 才算过
```

它从**真实项目容器**里探测（`kubectl exec` 进 `dsh-runner-<project>`）。这一条是刻意的：`network-policy/` 里的 `verify.sh` 与 `probe-matrix.sh` 用的都是**新建的一次性探针 Pod**，只能证明"引擎能工作"，证明不了"真实策略挂在真实 runner 上是对的"——那两个脚本的 README 自己就是这么写的。本文件顶部那次失败测量是手工做的，这次把它变成可重复执行的。

### 判据

| 组 | 目标 | 期望 |
|---|---|---|
| 内网 | `llm-service.llm:80`、`rag-service.data:8080`、`embedding-service.data:8080`、`postgres.data:5432`、`redis.data:6379`、`kubernetes.default:443`、`vault.vault:8200` | **TIMEOUT**（被丢弃） |
| 内网 | 项目容器所在节点、`169.254.169.254:80` | **TIMEOUT** |
| 公网 | `registry.npmmirror.com:443`、`github.com:443`、`auth.panghuer.top:443` | **可达** |
| DNS | `kubernetes.default.svc…` 与 `auth.panghuer.top` | 都能解析（策略显式放行 kube-dns 53） |
| IPv6 | Pod 的 `podIPs`、容器连一个 v6 字面量 | 只报告，不判定——见上文「IPv6：当前是缺口」一节 |

前三行的内网目标**与本文顶部那次失败的 7 个逐条相同**，所以新旧输出可以直接并排看。

`auth.panghuer.top` 是那次 fake-ip 事故的回归守卫：它解析到 `198.18.x.x`，也就是曾经被误列进 `except` 的那个段。**如果哪天有人又往 except 里加"保留段"，先变红的就是它。**脚本会把每个公网目标实际解析到的地址打出来，一眼就能看出走的是不是 fake-ip。

### 两个分类细节

- **`ECONNREFUSED` 算「可达」，不算「被拦」。** 回 RST 说明包**到了对端**，只是那里没服务在听——这是你能连上的主机在没有监听端口时的样子。`probe-matrix.sh` 把它记成 `BLOCKED`，在这里会制造假 PASS。
- **先核对集群上的策略，不只看仓库文件。** 仓库里改了 ≠ 集群上生效了（2026-09-20 实测踩过：文件已修，集群上还是旧版）。脚本会直接读集群里 `runner-egress` 的 `except` 列表，发现还含 `198.18.0.0/15` 就带着修法停下。

### 不在本次范围内

- **`dsh/web-egress`（网页 Pod）没测。** 本脚本只覆盖项目容器。网页 Pod 的边界是独立的：它只放行公网 443 + DNS + 到 runner 的 2222，改错会让 Casdoor 登录直接断（2026-09-20 差点发生）。
- **`hermes` 那四条策略没测。** 同一批生效的，同样只有引擎侧验证。



