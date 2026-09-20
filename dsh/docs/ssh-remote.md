# DSH 官方 SSH 远程执行 —— 调研结论

调研日期：2026-09-18。全部结论来自集群实机：`kubectl -n dsh exec dsh-web-779b77f888-brdvc` 内的 `npm view` / `curl` 探测 npm registry，以及直接解包官方 tarball 读 README。**未修改集群或容器内任何文件。**

## 结论摘要

> ✅ **已跑通（2026-09-20）：官方 SSH 方案上线，agent 的命令、文件、终端全部落在项目容器里**（`hostname` 返回 `dsh-runner-<project>`、`pwd` 返回 `/workspace`）。
> ✅ **Landlock 线路已撤销**：全舰队内核都没编译 Landlock，那个 boot 门禁只可能拒绝启动，部署前撤掉了。bubblewrap 也已移出镜像、`seccompProfile` 回 `RuntimeDefault`。
> ⚠️ **每次新建会话，工作目录必须选 `/workspace`** —— 见第十一节。

- **官方提供了完整的 SSH 远程 provider 家族**，版本与 dsh 锁步，由官方 CI 发布、带 npm 签名，不需要写自定义插件、也不需要打补丁。
- **必须升到 `0.1.6-alpha.2`** —— SSH 家族只存在于 0.1.6 线，`0.1.5-rc.2` 上根本没有对应版本。**已完成。**
- **实测确认执行已转到远端**：会话里读 `/etc/hostname` 得到 `dsh-runner-armbianbegin-...`
- ❌ **bash、以及一切要起进程的路径（测试、构建、`git`、装依赖）都被沙箱检查拒绝**。原因**不是内核**——master 上同一个内核跑同一个探测是 `rc=0`。瓶颈是容器的 capability 集，而补上它（root + `CAP_SYS_ADMIN`）换来的"文件约束"实测是**假的**。见第十节。
- 早前担心的「官方限制远程工作区面向 headless」**没有成为阻塞**：经 host plane 的 provider 接缝，执行成功重定向了。侧栏文件视图是否正常尚未确认。
- ARM64 原生包独立版本号，升级不受影响；`dsh-terminal` 是基础依赖，不属于 SSH 家族。

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
4. `dsh` 镜像里要有 **`ssh` 客户端**并支持 multiplexing + Unix-socket 转发 —— **已验证可用**。但要留意**服务端那一半**：sshd 的 `AllowTcpForwarding` **不能设为 `no`**，否则 streamlocal 转发会被静默拒绝，而 `sshd -T` 仍显示 streamlocal 是允许的。见第十二节。

---

## 六、`dsh-sandbox-ssh`：在远端选沙箱后端

`dsh-sandbox-ssh` 为 SSH 子进程提供 `ctx.sandbox`：

> The **remote host selects its installed local sandbox backend** and applies each call's policy there.

**这条对 runner 镜像有直接影响**：项目容器目前**没有可用的沙箱后端**（网页容器就是因为缺 bubblewrap / Landlock 才报 `sandbox mode "workspace-write" is requested but no sandbox backend is usable on this host`）。同样的报错会在远端重现。

所以 runner 镜像需要**自备一个沙箱后端**。本次采用官方 ARM64 Landlock launcher，移除 bubblewrap，避免为 namespace 沙箱放宽 seccomp。

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

## 八、实现与部署（2026-09-19）

**已构建、已部署、已部分验证。** 结论：**文件工具确实跑到了项目容器**；bash 因远端没有可用的沙箱后端而拒绝执行（见第十节）。

### 执行重定向：停用 + 插入，不是改 `name`

`config/cordis.patch.yml` 成为 `$DSH_HOME/profiles/web/cordis.patch.yml`。做法是**停用 dsh-base 的本地行，再插入 SSH 的行**：

| dsh-base 的行 | 处置 |
|---|---|
| `subprocess` → `dsh-subprocess-local` | `disabled: true`；改由插入的 `@deepseek-ai/dsh-subprocess-ssh` 提供 |
| `sandbox` → `dsh-sandbox-local` | `disabled: true`；改由 `@deepseek-ai/dsh-sandbox-ssh` 提供 |
| `fs-sandbox` → `dsh-fs-sandbox` | `disabled: true`；改由 `@deepseek-ai/dsh-fs-ssh` 提供 |
| `sandbox-policy` | **保留原 `name`**，只覆盖 `config`（`workspaceRoot` 指向远端工作区） |
| —（base 里没有） | 插入 `@deepseek-ai/dsh-ssh`，提供连接本身 |

> ⚠️ **踩过的坑：按 id 的补丁不能改 `name`。**
>
> 最初的写法是 `- id: subprocess / name: '@deepseek-ai/dsh-subprocess-ssh'`——文件合法、YAML 合法、**没有任何报错，但静默无效**。判据是四条覆盖里唯一生效的 `sandbox-policy` 恰好是只改 `config` 的那条；而仓库里所有现成的补丁层（`dsh-base` 被 `dsh-web-app` 打的那些）**没有一条改过 `name`**。
>
> 补丁能改的是行的**行为**（`config`、`disabled`），不是它绑哪个插件。服务名（`ctx.subprocess` 等）才是消费方解析的东西，所以"停用 A、由 B 提供同样的服务"是等价的。

### 启动顺序

1. **`auth/seed-profile.mjs`**（被 supervisor 导入，先于 spawn `dsh`）：物化 profile → 写入 patch → 从镜像内 tarball **离线**装四个 provider → 把 SSH 密钥复制到 `$HOME/.ssh` 并设成 ssh 能接受的权限
2. **init 容器 `prepare-keys`（root）**：`chmod 0755 /state` → 建 `/state/keys`（0700）→ 装主机密钥与 `authorized_keys` → `chown` 给 10000
3. **runner 容器（非 root）**：校验密钥存在 → `exec sshd -D`

任何一步失败都让容器起不来——**一个起得来、却在本地偷偷执行命令的容器，比一个起不来的容器危险得多**。

### 密钥与摘要

- 密钥对来自**同一个** Vault 路径 `secret/dsh/ssh`，拆成两个 ExternalSecret：客户端私钥只进网页 Pod，主机私钥只进项目容器，互不交叉。`authorized_keys` 是客户端公钥的重命名映射，信任关系只写一次。
- `build.sh` 从 runner 镜像里**读回** helper 摘要写进 `rendered/helper.sha256`，`deploy.sh` 再注入 ConfigMap——摘要不会被人抄错，runner 重建也不会让网页侧指向一个已不存在的值。
- 主机密钥随 Secret 每次启动重新落位到 emptyDir，所以身份跨重启稳定，而私钥不在容器可写层留痕。

### 权限与路径：三个非显然的约束

- **k8s 造的所有可写卷都是 group/world-writable**（emptyDir 是 `drwxrwsrwx`，secret 卷是 `drwxrwsrwt`）。sshd 的 `StrictModes` 会对密钥路径**逐级**校验、遇到这种目录必然拒绝。所以密钥必须放在一个**由 root 创建、且卷根已被 chmod 过的 0700 目录**里——非 root 进程做不到 chmod 别人的目录，**这就是 init 容器存在的唯一理由**。
- init 容器**只加 `CHOWN` 是不够的**：root 丢掉 `DAC_OVERRIDE` 之后，进不去自己刚刚 chown 给 10000 的 0700 目录。必须同时加 `DAC_OVERRIDE`。
- **OpenSSH 的 `~` 不是 `$HOME`**，而是 passwd 里的 home（本镜像是 `/home/dsh`，而且它在只读根上）。`config/ssh_config` 必须写绝对路径 `/opt/data/.ssh/...`。

### 实测结果（2026-09-19）

- ✅ **SSH 链路通**：runner 的 sshd 日志出现 `Accepted publickey for dev from <web-pod-ip>`，指纹与客户端密钥一致
- ✅ **文件工具跑在项目容器**：会话里读 `/etc/hostname` 得到 `dsh-runner-armbianbegin-...`
- ❌ **bash 拒绝执行**：远端没有可用的沙箱后端，见第十节
- ⚠️ **runner 重建会断连，且 `dsh-ssh` 不自动重连**：重新供给项目之后必须 `kubectl -n dsh rollout restart deployment/dsh-web`

### 踩过的坑汇总

| 症状 | 真正原因 |
|---|---|
| `install: cannot change permissions of '/state'` | fsGroup 让 emptyDir 归 root，非 root 不能 chmod 别人的目录 |
| `Host key verification failed` | `~` 展开自 passwd 而非 `$HOME` |
| `Permission denied (publickey)`，而指纹完全对得上 | 卷根 group/world-writable，`StrictModes` 逐级拒绝 |
| init 容器进不去自己刚建的目录 | 只有 `CHOWN`、缺 `DAC_OVERRIDE` |
| 补丁"生效"了但配置没变 | 按 id 的补丁不能改 `name` |

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

## 九、验证状态

### 已验证（2026-09-19 实测）

1. ✅ **组合把执行转到了远端** —— 会话里读 `/etc/hostname` 得到 `dsh-runner-armbianbegin-...`；runner 的 sshd 有成功的公钥认证
2. ✅ **`dsh plugin --profile web add file:...` 能离线装包** —— 日志 `[seed-profile] providers already present`
3. ✅ **`dsh --profile web --help` 会物化 profile** —— seed 脚本依赖它且未报错
4. ✅ **镜像内有 `Include /etc/ssh/ssh_config.d/*.conf`** —— 已核对
5. ✅ **非 root sshd 能在只读根 + `drop: [ALL]` 下启动** —— 前提是 init 容器预处理密钥（见第八节）
6. ✅ **升到 `0.1.6-alpha.2` 后原功能未回归** —— 网页、适配层、原生 cookie 兑换、WebSocket 都正常

### 仍未解决

7. ❌ **远端沙箱后端不可用** —— 见第十节。**已修正**：瓶颈是容器的 capability 集，不是内核；而补上能力换来的约束是假的
8. **Web profile 限制的确切范围**：README 说的是 workspace **UI** paths。执行层已证明没问题，但侧栏文件视图对不上是预期内的；具体差到哪一步还没验
9. **`node-addon-system-linux-arm64@0.1.2` 是否仍被安装**（版本独立，理论上没问题，但没单独核对）

---

## 十、沙箱后端：两个后端，两个不同的阻塞原因

> **2026-09-19 修正。** 本节早前写的是"这个 vendor 内核不给"，**那是错的**。但也别反过来推成"内核没问题"——准确的说法必须分后端：
>
> | 后端 | 阻塞在哪 | 证据 |
> |---|---|---|
> | **bubblewrap** | **容器的 capability 集**（内核无罪） | master 上同一内核、root 身份跑同一探测 → `rc=0` |
> | **Landlock** | **内核**（根本没编译） | 全舰队三种内核均为 `CONFIG_SECURITY_LANDLOCK is not set`，syscall 返回 `ENOSYS` |
>
> 把两者混成一句"环境不行"会掩盖一个事实：**Landlock 是换节点也解决不了的**，而 bubblewrap 是换配置也解决不了的。下面先查 bubblewrap，Landlock 的结论见本节末尾。

### bubblewrap：内核没问题，是容器的 capability 集

在 master 节点上（**同一个内核** `6.1.115-vendor-rk35xx`）以 root 直接跑 DSH 的原始探测命令：

```
bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true
→ rc=0   ← 通过
```

所以 **RK 系列和这个内核对 bubblewrap 都无罪**。集群全是 RK（3×RK3399 + 2×RK3588）**不构成障碍**。

### 是容器的 capability 集

在 runner 容器里跑能力矩阵（全部 `seccompProfile: Unconfined`）：

| uid | CapEff | 结果 |
|---|---|---|
| 0 | `0` | 建 namespace 失败 |
| 0 | `a80425fb`（root 默认集，**不含** SYS_ADMIN） | 建 namespace 失败 |
| 10000 | `0` | 挂 proc 失败 |
| 10000 | `0` ← **`add: [SYS_ADMIN]` 没生效** | 挂 proc 失败 |
| **0** | **`200000`**（SYS_ADMIN） | **rc=0 通过** |

> ⚠️ 看第 4 行：非 root 用户加 `CAP_SYS_ADMIN` 时 `CapEff` 仍是 `0`，因为 `no_new_privs` 会在 exec 时把它丢掉。所以早前"加 `CAP_SYS_ADMIN` 也没用"的结论**是无效的**——那次根本没测到这个 capability。

### 但 root 方案兑不了承诺

最后一行的组合（root + `CAP_SYS_ADMIN`）确实让探测通过了。可它给不出真正的约束，有两个互相独立的原因：

**① DSH 的 bwrap profile 对 root 调用者不做约束。** 实测被 bwrap 包裹的进程：

```
inner uid:      0
inner CapEff:   0000000000200000      ← 仍持 CAP_SYS_ADMIN
写 /etc:         denied
mount -o remount,rw /:   REMOUNTED    ← 自己把只读改回可写
改完再写 /etc:    WROTE
```

profile 是 `--ro-bind / / … --unshare-pid --proc /proc`，**没有 `--unshare-user`**。这不是疏漏——它假设调用者**非特权**，`--ro-bind` 才有意义。一旦调用者持有 `CAP_SYS_ADMIN`，被约束的进程可以自己把 `/` 挂回可写，那层只读根就只剩个样子。

**② sshd 会降权，所以连"通过"都拿不到。** 容器是 root 不改变 sshd 的行为：认证 `dev` 后 setuid 到 uid 10000，capability 全丢，helper 回到矩阵第 4 行。要让探测过，就得允许 **root 登录**——而那样 ① 立刻生效。

**两条路互相堵死**：降权 → 探测失败；root → 探测成功但约束是假的。

### 结论

- **换节点、换内核都解决不了**——内核本来就没问题
- **改容器 capability 能过探测，但换不到真约束**，代价却是把 runner 变成近乎 privileged
- 所以实际只剩两条：**保持 `workspace-write`（bash 不可用）**，或**放开 `danger-full-access`（bash 可用，无文件约束）**

这两条**在"文件约束"上实际等价**——因为这套 bwrap profile 在这里本来就给不出约束。而"root + `CAP_SYS_ADMIN`"是唯一的坏选择：同时提高风险、又不兑现承诺。

> **已完成（2026-09-19）**：bubblewrap 已从 runner 镜像移除，`seccompProfile` 已改回 `RuntimeDefault`。

> 关于平台差异：这不是"容器不如本地"。DSH 在 Windows 上用的是**另一套后端**（ACL restricted token / `dsh-pwsh-sandbox`），且 `bash-sandbox` 在 win32 上本来就是禁用的——"Windows 本地装"拿到的是 PowerShell，不是 bash。两边功能集本来就不同。

---

## 十一、路径审计（2026-09-19）

design 有两条要求：**传输身份与执行身份分离**，以及**审计所有远程 file / process / terminal 路径、禁止本地回退**。这是审计结果。

### 干净的三条（有证据）

**1. `tool-jobs` 不是回退路径。** 这是最初最可疑的一条——官方远程家族**不覆盖 jobs**，而 `dsh-jobs-local` 的 README 说它「runs background jobs **inside the harness process**」。实测它的 `lib/index.js` 只 import：

```
@deepseek-ai/dsh-jobs      @deepseek-ai/dsh-scope
@deepseek-ai/dsh-timeout   @deepseek-ai/schemastery
```

**没有 `child_process` / `spawn` / `Worker` / `fork`。** 它是**内存登记表**；真正的执行由工具走 `ctx.subprocess`（已指向远端）。

**2. runner 无法冒充网页 Pod。** 客户端私钥 `id_ed25519` 只在 `dsh-ssh-client`（`dsh` 命名空间），**不在 runner**；主机私钥与 `authorized_keys` 在 `dsh-ssh-host`（`dsh-runners`）。两半互不交叉。

**3. 本地回退有三层独立保障**：组合里本地 provider 被停用；`seed-profile.mjs` 失败即停；`dsh-ssh` 装载时连不上就拒绝启动（实测过 CrashLoopBackOff）。

### 缺口一：三个 `-local` 插件官方没有 `-ssh` 对应版

它们仍在**网页容器**上操作：

| 插件 | 读什么 | 处置 |
|---|---|---|
| `file-reference-local` | `node:fs`，**零处 `ctx.fs`** | **已停用**（2026-09-19） |
| `attachment-local` | `node:fs` | 保留，记为已知限制 |
| `spill-local` | `node:fs` | 保留，记为已知限制 |

`dsh-file-reference-local` 的 README 自己就是判据：

> Choose this package when `read` uses the Harness host filesystem; **remote or virtual namespaces need matching discovery**.

`read` 已指远端，它还在做本地发现——**官方那句 "Web workspace UI paths still assume host filesystem access" 说的就是这个插件族**，不是笼统的失败。

**为什么只停用第一个：**

- `file-reference-local` 停用后**只有好处**：它列的路径 `read` 一个也打不开，而且会把 `/opt/data/.dsh/.credentials.yaml` 这样的**名字**当候选给模型。这是移除错误答案，不是移除功能。
- `attachment-local` 还负责**为模型请求归一化图片**，盲停可能打断任何带图的请求，而它并不泄露凭据。
- `spill-local` 停用会改变超大输出的处理行为，收益不明。

后两个**已经是坏的**（上传落在 agent 看不见的地方；溢出的路径远端 `read` 打不开），但那是**功能缺口，不是凭据泄露**。

### 缺口二：runner 内没有 uid 分离

```
uid=10000(dev)                       ← agent 命令的身份
dev  sshd: /usr/sbin/sshd -D ...     ← sshd 也是 dev

-rw------- dev dev ssh_host_ed25519_key    WRITABLE
-rw------- dev dev authorized_keys         WRITABLE
```

sshd 与 agent 命令**同 uid**，而传输密钥归这个 uid 所有——**agent 可以覆写自己的传输密钥**。

**影响有界**：改掉主机密钥 → 网页侧 `known_hosts` 的固定失效 → 下次连接（网页重启时）被拒 → **DSH 停摆**。这是**自伤式 DoS**，不是提权，也**不能**冒充网页 Pod。

**不做修改**：唯一干净的修法是把 sshd 与执行分离到不同 uid 或容器，但 helper 必须与工作区在一起、sshd 必须与 helper 在一起，所以"搬个 sidecar"并不自动成立——design 里那句 *"merely moving sshd to another container does not prove ... or prevent bypass"* 说的就是这个。收益仅是防住一个自伤式 DoS，不值当。

### 同一族限制的第三次现身：工作区选择器

`browse` 选择器列的是**它所在容器**的目录（网页 Pod），而**选中的目录会成为远端每次 spawn 的 `cwd`**。所以"在界面上选一个工作目录"这个动作，会把网页容器的路径当成远端的路径。

后果实测：选中 `/opt/data/github` → 远端 spawn 报 `spawn bash ENOENT`——**Node 在 `cwd` 不存在时也返回 ENOENT，却报可执行文件的名字**，所以看起来像"runner 里没有 bash"，实际 `/bin/bash` 好好地在那儿。

**处置**：网页 Pod 挂一个**空的** `/workspace`（`k8s/web.yaml`），让选择器能列出它。那边空着不用，这边就是项目卷——**唯一在两侧含义一致的路径**。

**使用约束**：工作目录**只能选 `/workspace`**。这条要写进使用说明，否则下一个人会再踩一次。

### 不是问题但该知道

`web` 工具（联网抓取）从**网页 Pod** 发出，不走 runner。这是 host-plane 的设计使然。

---

## 十二、最后一个阻塞：`AllowTcpForwarding no` 连坐 streamlocal

切到 `danger-full-access` 后沙箱错误消失，但 bash 换成了另一个报错：

```
Error: Client network socket disconnected before secure TLS connection was established
```

**这个报错极具误导性**：读起来像"连不上"，而且 **fs 工具完全正常**——只有 bash 挂。

**根因**：`dsh-ssh` 的架构是

> The OpenSSH master carries private administrative RPC. **Each program stream uses a separate forwarded Unix socket** and an independent SSH channel.

- **fs** 走 master（管理 RPC）→ 一直正常
- **bash** 走**独立转发 socket** → 一直被拒

而 `runner/sshd_config` 里写着 `AllowTcpForwarding no`。**OpenSSH 会因此拒绝 streamlocal 的远程转发请求**——尽管配置里 `AllowStreamLocalForwarding yes`、`sshd -T` 也确认是 `yes`，**只有运行期才拒**：

```
Received request from 10.244.4.123 to remote forward to path "/tmp/fwd4",
but the request was denied.
```

**修法**：`AllowTcpForwarding yes`。

**权衡（有界）**：sshd 的**预期**客户端是网页 Pod，而网页 Pod **本来就在这里有一个 shell**。所以能开的隧道不超出调用方已有的能力。

> 🔴 **更正（2026-09-20 实测）**：原文还写了"（NetworkPolicy 只放行它）"与"runner 自己的出网被 NetworkPolicy 限到公网"，**两条都不成立** —— 集群 CNI 是 `kube-flannel`，不实现 NetworkPolicy，集群内任何 Pod 都能连到这个端口。结论仍成立（不超出网页 Pod 已有的能力），但理由不是网络隔离。见 [boundaries.md](boundaries.md) 顶部更正。

**教训**：这是**纯配置陷阱**。写的时候完全合理（"转发全关"是收紧），结果关掉了这个服务存在的理由。而 `sshd -T` 只报配置、**不报实际会不会被拒**——排查转发类问题必须看运行期日志。

---

## 十三、权限模式：`danger-full-access` 不是拆边界

**它是"打开执行开关"。**

已验证 `dsh-bash-sandbox` 在 `danger-full-access` 下**直接短路**，根本不调用 `ctx.sandbox.confine()`：

```js
if (mode === "danger-full-access") return super.start(spec)
```

| | bash / 测试 / 构建 / `git` | DSH 内层文件约束 | K8s 容器边界 |
|---|---|---|---|
| `workspace-write` | ❌ 全部拒绝 | 无（本来就给不出） | 不变 |
| `danger-full-access` | ✅ | 无（不尝试给） | **不变** |

**后两列完全一样，安全差量≈0。** 这名字在这套架构下是夸大的：它去掉的只是 DSH **内层**的沙箱，而**容器那层边界**（无 capabilities、只读根、无集群凭据、NetworkPolicy 挡内网）完全不动。而且 §10 已经证明，内层那层约束**本来就是假的**。

所以这个部署里它的实际含义是：**DSH 停止尝试建一个它建不出来的沙箱，直接把命令交给那个本来就是边界的容器。**

实现方式：`DSH_PERMISSION_MODE: danger-full-access` 加进 `dsh-runtime` ConfigMap。`sandbox-policy` 和 `approval` 两行都读它，所以提权提示一起变成 `never`。

**它不改变什么**：`attachment-local` / `spill-local` 那两个缺口与沙箱模式无关，放开也不会变好。
