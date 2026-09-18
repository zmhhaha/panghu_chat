# DSH 网络边界

本文件解释 `k8s/networkpolicies.yaml` 为什么是现在这样，以及它**不**覆盖什么。

## 边界是什么：挡内网，不是管控出站

需求是**项目容器不能直接访问集群内部的 Service**，外网本来就该放行——项目容器要 `npm install`、要 `git clone` 公网仓库。

这恰好落在地址粒度上，因此**不需要 egress 代理**：

- 集群 Pod CIDR 是 `10.244.0.0/16`，Service CIDR 也在 `10.0.0.0/8` 内。
- 一条 `ipBlock: 0.0.0.0/0` + `except` 私网段的 NetworkPolicy 规则，就等价于"允许一切公网地址、拒绝一切内部地址"。
- 用代理反而多引入一个常驻组件，还要额外防它被绕过。

> OpenSpec change 的 design 原本写的是"项目容器只能经受控 egress 代理访问公网 HTTP/HTTPS"。所有者澄清后已改为本方案，store 里的 design / proposal / spec 都已同步。

## except 清单

在 Hermes 已有的 9 条基础上补齐了调查中发现的缺口，共 13 条：

```
10.0.0.0/8        172.16.0.0/12     192.168.0.0/16    127.0.0.0/8
169.254.0.0/16    100.64.0.0/10     0.0.0.0/8         224.0.0.0/4
240.0.0.0/4       192.0.0.0/24      198.18.0.0/15     192.88.99.0/24
255.255.255.255/32
```

后四条是 Hermes 那份清单里没有的：`192.0.0.0/24`（IETF 协议保留）、`198.18.0.0/15`（基准测试）、`192.88.99.0/24`（6to4 中继，已废弃）、`255.255.255.255/32`（广播）。

`169.254.0.0/16` 挡住链路本地，其中包含云元数据地址 `169.254.169.254`。
`127.0.0.0/8` 挡住回环，同时防止以回环为跳板打 Pod 内的 localhost 服务。

## 为什么按端口不设限（项目容器）

`runner-egress` 对公网**不限制端口**，只限制目标地址段。包管理器、VCS、语言工具链各自选端口，限制端口只会制造难以排查的故障，而需求本身是"挡内网"而不是"管控出站"。

网页容器不同：它只需访问 Casdoor，因此只放行公网 443。

## 域名不受保护——这是有意为之

一条公有 DNS 名解析到内网地址时**同样被拒**，因为 NetworkPolicy 匹配的是解析后的目标地址。所以经典的 DNS rebinding 攻击（先解析到公网、再解析到内网）在这里天然无效。

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

> **更新（2026-09-19）**：传输已实现（见 [ssh-remote.md](ssh-remote.md) 第八节），**但尚未构建、未验证**。
>
> bubblewrap 现在装上了——注意装在**哪儿**：它装在 `runner` 镜像里，因为 `dsh-sandbox-ssh` 是在**远端**选本机后端的。网页镜像**仍然没有**沙箱后端，这是刻意的：一旦传输生效，网页容器就不该再执行任何 agent 命令。给它补上后端只会让错误的架构用起来更舒服。
>
> 所以上面那条判断不变：**在实测确认命令落在远端之前**（会话里跑 `hostname`，看是不是 `dsh-runner-` 前缀），当前部署仍是实验环境——不要指向真实仓库，不要在里面处理凭据。

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


