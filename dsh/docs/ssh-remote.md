# DSH 官方 SSH 远程执行 —— 调研结论

调研日期：2026-09-18。全部结论来自集群实机：`kubectl -n dsh exec dsh-web-779b77f888-brdvc` 内的 `npm view` / `curl` 探测 npm registry，以及直接解包官方 tarball 读 README。**未修改集群或容器内任何文件。**

## 结论摘要

> ✅ **已定（2026-09-19）：采用官方 SSH 方案做远程执行。** 理由与排除的替代方案见第七节。

- **官方提供了完整的 SSH 远程 provider 家族**，版本与 dsh 锁步，由官方 CI 发布、带 npm 签名，不需要写自定义插件、也不需要打补丁。
- **但必须把 dsh 从 `0.1.5-rc.2` 升到 `0.1.6-alpha.2`** —— SSH 家族只存在于 0.1.6 线，`0.1.5-rc.2` 上根本没有对应版本。
- 🚨 **官方明确写着：远程工作区面向 headless，Web 的工作区 UI 仍假设宿主机文件系统。** 这与 change 的 Phase 1（「Web + 持久项目容器 + 远程文件/终端/命令」）直接冲突，是本轮最重要的发现，需要所有者决策。
- ARM64 原生包独立版本号，升级不受影响。
- `dsh-terminal` 是基础依赖，不属于 SSH 家族。

---

## 一、官方 SSH 家族

| 包 | 版本 | 作用 | 配置字段 |
|---|---|---|---|
| `@deepseek-ai/dsh-ssh` | 0.1.6-alpha.2 | 共享 OpenSSH 连接 + 远程 POSIX helper | **有**（见第四节） |
| `@deepseek-ai/dsh-fs-ssh` | 0.1.6-alpha.2 | 远程文件系统 provider（`ctx.fs`） | 无 |
| `@deepseek-ai/dsh-subprocess-ssh` | 0.1.6-alpha.2 | 远程子进程 + **终端**（`ctx.subprocess`） | 无 |
| `@deepseek-ai/dsh-sandbox-ssh` | 0.1.6-alpha.2 | 远程沙箱 | 待读 |

- 源码位置：官方 monorepo 的 `packages/ssh/{ssh,fs-ssh,subprocess-ssh,sandbox-ssh}`
- 发布来源：packument 里 `_from: file:/home/runner/work/deepseek-harness/...`，带 npm provenance 签名
- 体积都很小（fs-ssh 15 KB、sandbox-ssh 11 KB）——是薄封装，不是玩具
- `@deepseek-ai/dsh-remote`、`dsh-lsp-ssh`、`dsh-pty-ssh`、`dsh-tool-ssh` **都不存在**（404）
- `@deepseek-ai/dsh-terminal` **存在，但它是 `dsh@0.1.5-rc.2` 的既有依赖**（连同 `dsh-terminal-bash`），不是 SSH 家族的一部分。终端走远程由 `dsh-subprocess-ssh` 提供（README：*Terminal allocation, writes, foreground inspection, signals and termination*）

### 版本约束（硬性）

```
@deepseek-ai/dsh                 latest: 0.1.5-rc.2    alpha: 0.1.6-alpha.2   <- 当前装的是 latest
@deepseek-ai/dsh-ssh             latest: 0.1.6-alpha.1  alpha: 0.1.6-alpha.2
@deepseek-ai/dsh-fs-ssh          latest: 0.1.6-alpha.1  alpha: 0.1.6-alpha.2
@deepseek-ai/dsh-subprocess-ssh  latest: 0.1.6-alpha.1  alpha: 0.1.6-alpha.2
@deepseek-ai/dsh-sandbox-ssh     latest: 0.1.6-alpha.1  alpha: 0.1.6-alpha.2
```

`dsh-ssh@0.1.6-alpha.2` 的 peerDependencies 要求 `^0.1.6-alpha.2`，而 `0.1.5-rc.2 < 0.1.6-alpha.1`，不满足 semver 范围。**升级不是可选项。**

佐证：change 的 design.md 在「Evidence and scope」里写的正是 *Inspected root version: 0.1.6-alpha.2* —— 规格本来就是照这个版本写的，只是当时误判它「not a verified published npm version」。它已发布，挂在 `alpha` tag 下。

### ARM64

- 原生包是 **`@deepseek-ai/node-addon-system-linux-arm64@0.1.2`**，**独立版本号**，不跟 dsh 版本线走
- 当前安装的就是 0.1.2
- 所以升级 dsh 不会换掉这个平台包，ARM64 支持不受影响（仍应在实际升级时确认一次）

---

## 二、profile 与插件机制（怎么把 SSH 装进去）

实机看到的目录结构：

```
/opt/data/.dsh/                      <- DSH_HOME（= $HOME/.dsh，不是 /opt/data）
├── .credentials.yaml                0600，原生会话签名密钥
├── settings.yaml                    0600，35 字节，只有 agent-presets 键
├── profiles/
│   ├── node_modules/                <- 插件装在这里，各 profile 共享（pnpm workspace）
│   └── web/                         <- 一个 profile = 一个目录
│       ├── package.json             dsh.profile.bundles + dependencies
│       ├── cordis.yml               根，恒为 []（注释说「Edit cordis.patch.yml, not this file」）
│       ├── cordis.patch.yml         用户补丁层，当前 []
│       └── pnpm-workspace.yaml      nodeLinker: hoisted, autoInstallPeers: false
├── sessions/
└── storages/
```

`web/package.json` 实际内容：

```json
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"], "patchReload": "live" } }
}
```

**配置树的组合顺序**（`cordis.yml` 里的注释）：

> each bundle in package.json's `dsh.profile.bundles`, then `cordis.patch.yml`, then any `--patch` overlays

而 `cordis.patch.yml` 的注释说明了它的格式：

> a top-level YAML array of loader patch entries (id-targeted config overrides, disables, and insert lists; `!!js` expressions allowed)

**所以接入 SSH 的机制是**（三步，都不需要改上游代码）：

1. 把四个 SSH 包装进 `profiles/node_modules`（pnpm；`dsh plugin --profile web add ...` 就是干这个的，但镜像里没有 pnpm）
2. 把它们的 bundle 名加进 `web/package.json` 的 `dsh.profile.bundles`，并把包写进 `dependencies`
3. 在 `cordis.patch.yml` 里写下 `dsh-ssh` 的配置（见下）

注意：`profiles/web/node_modules` 是空的，插件实际解析自共享的 `profiles/node_modules`——这正是 `pnpm-workspace.yaml` 的作用。

---

## 三、🚨 关键限制：远程工作区面向 headless，不是 Web

`@deepseek-ai/dsh-ssh` README 的「Known Limitations and Deferred Work」原文：

> **Web workspace UI paths still assume host filesystem access; use headless or a custom composition whose consumers honor provider paths.**

「Use this package」一节也写：

> Compose this service with fs-ssh, subprocess-ssh and sandbox-ssh in a custom `dsh` profile. The host runs the Harness, model transport and Session storage; the remote machine supplies the files and processes. **Headless profiles support this arrangement.**

`fs-ssh` README 佐证了同一件事：

> `processPath()` and `fileUrl()` name files in that same remote namespace; **they do not grant host-side access.**

也就是说：**官方的远程执行支持面向 headless profile；Web profile 的工作区 UI 路径仍然假设宿主机文件系统。**

headless 是什么？CLI help 里给的例子是：

```
dsh --profile headless "run the tests"     answer one task, print the result, and exit
```

**一次性任务，不是浏览器工作台。**

### 但 provider 接缝是干净的（2026-09-19 补充证据）

在已部署的插件树里做了静态检查，结论**比上面那段限制读起来更乐观**：

1. **消费方依赖的是抽象服务，不是本地实现。** 全树搜 `dsh-fs-local` / `dsh-subprocess-local`，代码里只命中 `-local` 包自身；`dsh-tool-fs/package.json` 里那一处位于 **`devDependencies`**，`dsh-subprocess/lib/index.js` 里那一处是 **JSDoc 注释**（原文：`The local implementation lives in @deepseek-ai/dsh-subprocess-local`）。**没有任何 `.js` 硬引用本地实现。**

   也就是说 `dsh-tool-bash` / `dsh-tool-fs` 这类消费方业务上只认 `ctx.subprocess` / `ctx.fs`，具体实现由组合决定。

2. **换实现是设计好的机制，不是打补丁。** `dsh-base/cordis.patch.yml` 的头部注释原文：

   > ... Later bundle patches and **the user's profile cordis.patch.yml address these rows by id, with the last write winning per row.**
   >
   > A patch replaces the targeted row's whole `config` rather than merging into it ...

   而 `dsh-ssh` 的 README 也正是这么教人用的：*Compose this service with fs-ssh, subprocess-ssh and sandbox-ssh in a **custom dsh profile***。

3. **两者合起来**：在 profile 的 `cordis.patch.yml` 里把 `subprocess` / `fs` / `sandbox` 三行按 id 覆盖成 SSH 实现，就是官方扩展点本身。

### 所以那条限制更可能是「显示层」而不是「执行层」

README 那句说的是 workspace **UI** paths。结合上面的接缝证据，最可能的真实情况是：

- **agent 的工具能经 SSH 路由**（执行层走接缝）
- **侧栏的工作区文件视图对不上**（显示层直接读宿主，或用了别的路径）

如果是这样，web + 远程**是可行的**，只是文件浏览侧栏不可信。

**但这仍是推断，不是结论。** README 把它列在 Known Limitations 里，说明作者知道 web 这条组合有坑；而静态检查也无法证明所有 web 侧消费方都走了接缝。**只有实测能定。**

### 这与 change 的冲突

change 的 Phase 1 原文：

> private ARM64 **Web** plus a pre-provisioned persistent project worker, remote file/terminal/command integration

而 release gate 又写：

> Do not claim release 1 complete if only a new test tool is remote but ordinary Bash remains local.

官方在这个版本上的答案是：**远程 = headless**。想要 Web + 远程，README 的说法是需要「a custom composition whose consumers honor provider paths」——那属于自定义工作，与所有者「不要打补丁、优先官方方案」的要求相悖。

**这一条需要所有者决策，见第七节。**

---

## 四、`dsh-ssh` 的配置面

| 字段 | 默认 | 含义 |
|---|---|---|
| `host` | 必填 | **既有的 OpenSSH host 别名**（ssh_config 里的 alias，不是 host:port） |
| `node` | 必填 | 远端 Node 可执行文件的**绝对路径** |
| `helper` | 必填 | 远端已安装 helper 入口的绝对路径 |
| `workspace` | 必填 | 远端默认工作区绝对路径 |
| `helperHash` | 必填 | 已安装 helper 入口的小写 SHA-256 |
| `bootstrapPath` / `bootstrapHash` | 可省 | PTC（Node 运行时）用；基础 fs/bash 不需要 |
| `requestTimeoutMs` | `30000` | 连接与管理请求超时（1 ~ 2147483647） |
| `maxFrameBytes` | `67108864` | 单条消息 JSON 上限，至多 64 MiB |
| `maxPending` | `128` | 普通未完成请求数 |
| `leaseMs` | `30000` | helper 心跳租约（3000 ~ 600000） |

`fs-ssh` 与 `subprocess-ssh` **都没有自己的配置字段**：连接身份和默认工作区属于 `dsh-ssh`，文件生效模式属于 `sandboxPolicy`。

### 安全姿态（与 change 的要求高度一致）

- 启用 **`BatchMode`** —— 没有交互式认证流程
- **强制严格 host key 检查**
- **禁用 agent forwarding**
- 每个程序流一条独立转发的 Unix socket + 独立 SSH channel；stdout 无法伪造管理回复
- 每条流用随机 **256-bit TLS PSK**，只经管理 RPC 传递，从不作为流前言发送
- socket 目录 `0700`、socket `0600`
- helper 以 **`--disable-sigusr1`** 启动，阻止同用户进程打开它的 Node 调试器
- 就绪前**校验已安装产物的摘要**
- 连接关闭 / 租约到期时由 helper 负责远端清理

### 前提条件（对部署有直接影响）

- 两端都要求 Linux 或 macOS
- **本地 `ssh` 必须支持连接复用（multiplexing）与 Unix-socket 转发**；**远端 sshd 必须允许该转发**（`AllowStreamLocalForwarding`）
- **远端要装好 helper 及其匹配的运行时依赖**，并且 **Node、helper、bootstrap 必须放在工作区和可写临时目录之外**
- helper 安装路径与摘要必须一致地写进配置

---

## 五、对当前部署意味着什么

项目容器（`templates/runner.yaml`）现在只有 `ENTRYPOINT ["/bin/sleep", "infinity"]`，没有任何监听器。要变成 SSH 远端，它至少需要：

1. **非 root sshd** 监听 2222（`k8s/networkpolicies.yaml` 与 `templates/runner.yaml` 已经预留了这个端口，且 Service port == containerPort，绕开了 DNAT 歧义）
2. **允许 Unix-socket 转发**的 sshd 配置
3. **Node 运行时**（`dsh-ssh` 的 `node` 字段指向它）
4. **`dsh-ssh` 的 helper** 安装到工作区之外，并算出 `helperHash`
5. 授权公钥：只接受来自 `dsh-web` Pod 的那一把

网页 Pod 侧需要：

1. **一个 OpenSSH host 别名**写进 `ssh_config`（部署方拥有）
2. **known_hosts 里固定项目容器的主机密钥**
3. 对应的**私钥**——正好是 `vault/inventory/DSH.md` 里预告过、当时留空的 `secret/dsh/runner` 路径
4. `dsh` 镜像里要有 **`ssh` 客户端**并支持 multiplexing + Unix-socket 转发（当前镜像装了 `openssh-client`，但从未验证过这两项能力）

---

## 六、`dsh-sandbox-ssh`：在远端选沙箱后端

`dsh-sandbox-ssh` 为 SSH 子进程提供 `ctx.sandbox`：

> The **remote host selects its installed local sandbox backend** and applies each call's policy there.

**这条对 runner 镜像有直接影响**：项目容器目前**没有可用的沙箱后端**（网页容器就是因为缺 bubblewrap / Landlock 才报 `sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host`）。同样的报错会在远端重现。

所以 runner 镜像需要**自备一个沙箱后端**（bubblewrap 或 Landlock），否则「文件生效范围的约束」在远端等于没开。

它自己的限制：

- 文件生效模式**不限制网络访问，也不限制进程可见性**；远端是 `partial` 后端就仍然是 `partial`
- **SSH 主机与已安装的 helper 属于受信基础设施** —— 摘要校验与文件约束**不构成防恶意主机的安全边界**

最后一条值得留意：DSH 把 SSH 主机当作受信的。这与本 change 的威胁模型并不矛盾（容器是受信的、它跑的代码不是），但意味着**约束能力全部来自那个容器自己的沙箱后端**——又回到上面那条。

## 七、决策：选用官方 SSH

### 已定：SSH 是唯一的远程执行通道（2026-09-19）

要满足 change 的核心要求——「命令跑在独立受限容器里」——把候选逐条排除后只剩 SSH：

| 候选方案 | 排除理由 |
|---|---|
| `kubectl exec` 到项目容器 | 需要**集群凭据**，而这正是要避免给 agent 的东西。给了就等于把集群交出去 |
| 每个命令起一个 k8s Job | 粒度上根本不成立（见附录），且 `dsh-jobs` 没有任何非本地实现（`dsh-jobs-k8s` / `-remote` / `-ssh` 全 404），要走这条得自己写 provider |
| 同 Pod 内两个容器互相 exec | k8s 不提供这个能力 |
| 只用一个容器 | 就是现状：agent 与模型密钥、`.credentials.yaml` 同容器，且无沙箱后端 |

**这不是在多个方案里挑了一个，是官方只提供了这一个。** 它同时符合「不打补丁、优先官方」的要求：`dsh-base/cordis.patch.yml` 的头部注释明确写了用户层可以按 id 覆盖配置行（*"the user's profile cordis.patch.yml address these rows by id, with the last write winning per row"*）。

### 仍未决：web 还是 headless

选定 SSH 之后还剩一个子问题——README 那句限制的确切范围。三条路：

### 选项 1：先做最小实测，再决定（推荐）

那条限制的原文说的是 workspace **UI** paths。如果 agent 的工具（bash / fs / subprocess）其实**能**经 SSH 正确路由，只有侧栏文件视图不对，那 web + 远程就是可用的，只是 UI 有瑕疵。

- **要回答的问题**：web profile 下，agent 会话的执行是否真的落到 SSH 远端
- **测试设计上的取巧**：不必先建好项目容器。`dsh-ssh` 的远端只需要「sshd + Node + helper」，可以先用一个临时目标（甚至网页 Pod 内起一个侧车 sshd）来验证路由。
- **成本**：升版本 + 装家族 + 配一个临时远端
- **收益**：一次性定下后面所有工作；避免在错误的路线上写完整实现

### 选项 2：按 headless 走（官方支持，但改定位）

- 升版本 + 装家族，用 `--profile headless` 把任务发到项目容器
- **得到**：官方支持的远程执行，满足 release gate 里「命令不在本地跑」
- **失去**：没有浏览器工作台。`dsh --profile headless "task"` 是一次性调用
- **意味着**：本 change 的定位要从「Web 工作台」改成「远程一次性任务」，或接受「Web 只做交互、执行另走 headless」的两套并存

### 选项 3：暂不做远程执行

- 保持现状（Web + 本地执行），明确它**不是** release 1，把「本地执行 + 无沙箱后端」的风险显式记录并接受
- 相当于之前讨论过的「合并容器」方案。现在有了选项 1 和 2，它从「唯一可行」降为「兜底」

### 遗留的顾虑

曾经不建议"未实测就直接写 web + 远程实现"。那条顾虑后来被第三节的接缝证据消解了：`standard` preset 的注释明确说工具在 preset、**执行服务在 host plane**，而 host plane 正是 `cordis.patch.yml` 覆盖的那一层。所以下面是按 web 路线实现的，并把"执行是否真的落到远端"留作第一件要验的事。

---

## 八、实现（2026-09-19）

代码已写，**未构建、未部署、未测试**。

### 执行重定向只覆盖三行

`config/cordis.patch.yml` 会成为 `$DSH_HOME/profiles/web/cordis.patch.yml`，按 id 覆盖 host plane 的行：

| dsh-base 原行 | 覆盖为 | 管什么 |
|---|---|---|
| `subprocess` → `dsh-subprocess-local` | `dsh-subprocess-ssh` | 所有命令执行 |
| `sandbox` → `dsh-sandbox-local` | `dsh-sandbox-ssh` | 文件生效范围（在远端选后端） |
| `fs-sandbox` → `dsh-fs-sandbox` | `dsh-fs-ssh` | agent 的文件读写 |

再 `insert` 一行 `ssh: dsh-ssh` 提供连接本身；并覆盖 `sandbox-policy.workspaceRoot`——原值是 `process.cwd()` = `/opt/data`，而 `DSH_HOME` 是 `/opt/data/.dsh`，也就是说 `workspace-write` 当时覆盖着 profile 目录和 `.credentials.yaml`。

值全部走 `!!js process.env.DSH_SSH_*`，文件保持静态可审；缺任何一个必需值都会失败，而不是退回本地执行。

### 引导失败即停

`auth/seed-profile.mjs` 在 supervisor 启动 DSH 之前跑：物化 profile（若不存在）→ 写入 patch → 从镜像内的 tarball **离线**装四个 provider → 把 SSH 密钥复制成 ssh 能接受的权限。

**任何一步抛错都让容器起不来。** 这是刻意的：一个起得来、却在本地偷偷执行命令的容器，比一个起不来的容器危险得多。

### 密钥与摘要

- 密钥对来自**同一个** Vault 路径 `secret/dsh/ssh`，拆成两个 ExternalSecret：客户端私钥只进网页 Pod，主机私钥只进项目容器，互不交叉。`authorized_keys` 是客户端公钥的重命名映射，信任关系只写一次。
- `build.sh` 从 runner 镜像里**读回** helper 摘要写进 `rendered/helper.sha256`，`deploy.sh` 再注入 ConfigMap——摘要不会被人抄错，runner 重建也不会让网页侧指向一个已不存在的值。
- 主机密钥随 Secret 每次启动重新落位到 emptyDir，所以身份跨重启稳定，而私钥不在容器可写层留痕。

---

## 附录：为什么「逐命令起 Job」不成立

（2026-09-19。起因是探讨 SSH 之外还有没有别的隔离路径。）

### 先纠正一个说法

change 里的 option C **不是**「每个命令起一个 Job」。原文是：

> Option C (**persistent development plus ephemeral test jobs**) is deferred until needed.

也就是「持久开发容器**照旧**，额外加临时测试 Job」两层——Job 是**补充**，不是替代日常执行。

### 如果真按「逐命令」设想，三种粒度都不成立

| 粒度 | 后果 |
|---|---|
| **每次工具调用一个 Job** | 每条 `ls` 都要调度 Pod、拉镜像。`cd`、环境变量、装好的依赖全部丢失 |
| **每次界面发送（一个 turn）一个 Job** | 一个 turn 内可能几十次工具调用，Job 得活满整个 turn（可能几分钟）。**turn 之间状态全丢**：第一条消息 `npm install`，第二条消息 `npm test` 时 `node_modules` 已经没了 |
| **每个会话一个 Job/容器** | 这就是 **option B**，change 选的就是它。但它是持久容器，不是 Job |

**结论：逐命令隔离与交互式开发本质矛盾。** 「一个命令」无论取哪种粒度都不可行——这也是为什么 change 的 option C 把 Job 定位成「测试用的干净房间」，而不是日常执行路径。

### 而且它现在更贵了

DSH 确实有 `dsh-jobs` 契约，`dsh-jobs-local` 实现它。但 npm 上：

```
@deepseek-ai/dsh-jobs          200  （契约）
@deepseek-ai/dsh-jobs-k8s      404
@deepseek-ai/dsh-jobs-remote   404
@deepseek-ai/dsh-jobs-ssh      404
```

**没有任何非本地实现。** 要走 k8s Job 那条路就得自己写一个 provider，与「不打补丁、优先官方」相悖。

### 顺带：官方远程家族不覆盖 jobs

远程只覆盖三个轴——`fs` / `subprocess` / `sandbox`，**没有 jobs**。所以即使走 SSH，后台任务仍是 `dsh-jobs-local`（"jobs die with the harness process and are not durable across restarts"）。

实际影响有限：web profile 在出厂层就把 `tool-jobs` 停用了，模型本来也拿不到 `job_output` / `job_list` / `job_kill`。

---

## 九、尚未验证

### 实现层面的假设（构建 + 部署一次即可证伪，任一不成立都要改）

1. **覆盖那三行是否真的把执行转到远端** —— 核心问题。判断方法：在会话里跑 `hostname`，返回 `dsh-runner-<project>-...` 就对了；返回 `dsh-web-...` 说明组合没生效，**要停下来查，不要继续用**。
2. `dsh plugin --profile web add file:...` 能否把镜像内的 tarball **离线**装进 profile。
3. `dsh --profile web --help` 是否真的会把 profile 物化出来——seed 脚本依赖这一点。
4. 镜像内的 `/etc/ssh/ssh_config` 是否带 `Include /etc/ssh/ssh_config.d/*.conf`；`dsh-ssh-config` 这个 ConfigMap 靠它生效。
5. 非 root sshd 在只读根 + `drop: [ALL]` 下能否正常启动。

### 仍未解决的问题

6. **runner 镜像的沙箱后端是否真的可用**：镜像里装了 bubblewrap，但它在那个容器（非 root、无 capabilities、只读根）里能否工作**完全未验证**。不解决的话远端的文件约束等于没开。
7. **Web profile 限制的确切范围**：README 说的是 workspace **UI** paths。执行层大概率没问题，但侧栏文件视图对不上是预期内的；需要确认到哪一步。
8. **升级到 `0.1.6-alpha.2` 后现有功能是否回归**：网页、适配层、原生 cookie 兑换、WebSocket 都没在新版本上验证过。
9. **`node-addon-system-linux-arm64@0.1.2` 在 0.1.6-alpha.2 下是否仍被安装**（版本独立，理论上没问题，但未实测）。
