# DSH profile 架构（2026-09-18 实测）

来源：在已部署的 `dsh-web` Pod 内执行 `dsh --profile web --dump-config`。这份文件记录 dump 揭示的架构，以及为「把执行移到项目容器」需要继续查的问题。

## dump 是什么

`--dump-config` 打印**组合后的 profile 树**——「an ordered stack of plugin-bundle patch layers under your own overrides」。本次输出里可见两层：

- `# == @deepseek-ai/dsh-base`（出厂层）
- `# == @deepseek-ai/dsh-base, patched by @deepseek-ai/dsh-web-app`（web 应用层的覆盖）

没有出现用户覆盖层的标记，说明当时 `$DSH_HOME` 下没有自定义 profile。

## 关键发现一：web profile 停用了本地工具

`dsh-web-app` 层把一批工具显式 `disabled: true`：

| 停用项 | 含义 |
|---|---|
| `tool-bash`、`tool-pwsh`、`tool-jobs` | 命令执行 |
| `tool-fs`、`tool-fs-search` | 文件读写与搜索 |
| `agent-instructions` | 仓库指令注入 |
| `tool-skill`、`skill-filesystem` | 技能 |
| `tool-web` | 网页工具 |
| `tool-todo`、`goal` 系列、`plan-mode` | 计划与目标 |
| `tool-subagent*`、`tool-workflow`、`compaction*` | 子代理与压缩 |

**但自检里 bash / read / write / edit / glob / grep 都是可用的。** 两者矛盾，只能有一个解释：**agent 会话不是跑在 `web` profile 的工具集下**。web 应用更像是宿主机/界面，真正的 agent 在别处运行。

同时出厂层里有明确的「本地实现」插件：`dsh-subprocess-local`、`dsh-sandbox-local`、`dsh-jobs-local`、`dsh-credentials-local`、`dsh-attachment-local`、`dsh-spill-local`、`dsh-file-reference-local`。

## 关键发现二：存在 workspace / remotes 这一层

web 层里有：

- `dsh-workspace`、`dsh-util-workspace-path`、`dsh-api-workspace-files`、`dsh-api-workspace-controller`、`dsh-client-ui-workspace`
- `dsh-api-remotes`
- `dsh-host-directory-picker-auto`（目录选择器）
- `dsh-code-runtime-worker-thread`、`dsh-cordis-host-runner`

**这些名字暗示有「宿主 / 工作区」之分**，但它们的实际语义尚未确认——`remotes` 也可能指的是「对 DSH 服务端的远程连接管理」，而不是「远程计算」。

## 关键发现二之补充：安装的版本里没有远程 provider 包

`0.1.5-rc.2` 的 `@deepseek-ai/dsh` 依赖了 **240 个 `@deepseek-ai/*` 包**。按 `ssh|remote|workspace|sandbox|local|transport|connect` 过滤，结果是：

```
dsh-api-remotes                dsh-api-workspace-controller   dsh-api-workspace-files
dsh-attachment-local           dsh-bash-local                 dsh-bash-sandbox
dsh-client-connection          dsh-client-locale              dsh-client-ui-workspace
dsh-credentials-local          dsh-file-reference-local       dsh-fs-local
dsh-fs-sandbox                 dsh-jobs-local                 dsh-pwsh-local
dsh-pwsh-sandbox               dsh-sandbox                    dsh-sandbox-local
dsh-sandbox-policy             dsh-sandbox-windows-acl        dsh-spill-local
dsh-subprocess-local           dsh-util-workspace-path        dsh-workspace
```

**没有 `ssh`。所有能力实现都是 `*-local`。**

change 的 design 原本写：

> Official SSH provider family supports filesystem, subprocess, terminal and sandbox capabilities, but complete native Web integration is unverified. **Validate it first against the pinned release**; use a scoped custom provider only if necessary.

那个 `packages/ssh/README.md` 存在于**源码 monorepo**，但**没有随这个 npm 版本发布**。所以「先验证官方 SSH provider」这条路在当前版本上走不通——要么是另一个未发布的包，要么需要换版本，要么只能写自定义 provider。


## 关键发现三：几个控制项是环境变量

| 变量 | 用途 | 默认 |
|---|---|---|
| `DSH_PERMISSION_MODE` | `sandbox-policy.mode` 与 `approval.policy` | `workspace-write` |
| `DSH_TOOLS_MODE` | `dsh-tools.mode` | 未设（`undefined`） |
| `DSH_TELEMETRY_MODE` | 会话遥测模式 | `FEEDBACK_ONLY` |
| `DSH_TELEMETRY_OTLP_URL` | 遥测导出地址 | `https://harness-telemetry.deepseeksvc.com/v1/logs` |

模型侧：`agent-default-model` 是 `provider: deepseek-official` / `model: deepseek-flash`；搜索用 `web-search-deepseek`，`apiKeyEnv: DEEPSEEK_API_KEY`。**所以 `dsh-model` Secret 里必须提供 `DEEPSEEK_API_KEY`。**

## 关键发现四：沙箱根目录默认就是 DSH_HOME

```
- id: sandbox-policy
  config:
    mode: !!js process.env.DSH_PERMISSION_MODE ?? 'workspace-write'
    workspaceRoot: !!js process.cwd()
```

`sandbox-policy.workspaceRoot` 取的是 **DSH 进程的 cwd**。容器里 `WORKDIR` 是 `/opt/data`，也就是 `DSH_HOME`。所以即便补上沙箱后端，`workspace-write` 允许写的范围**就是整个 DSH_HOME**——包含 `profiles/`、`sessions/`、`storages/` 和 `.credentials.yaml`。

「workspace-write」这个名字听起来像受限，实际在这里并不受限。

## 关键发现五：默认开启遥测到厂商端点

`session-telemetry-otel` 的 exporter 默认指向 `https://harness-telemetry.deepseeksvc.com/v1/logs`，模式默认 `FEEDBACK_ONLY`。对一个「私人编码工作台」来说这是个需要显式决定的事：要么把 `DSH_TELEMETRY_MODE` 关掉，要么在 NetworkPolicy 层挡掉该域名。

注意 `FEEDBACK_ONLY` 不等于「始终上报」，但端点是配置好的、而 web Pod 的公网 443 是放行的。

## 需要更正的一条

上一版 `docs/boundaries.md` 里写了「agent 可以跑 `dsh plugin --profile web add <包>` 装插件」。实测 `dsh plugin` 当前**不可用**：

```
dsh: pnpm not found on PATH — install pnpm to manage profile plugins
```

镜像里没有 pnpm，所以这条路径暂时走不通（agent 理论上可以先自己装 pnpm，但那需要额外的网络下载步骤，不是直接就通）。**profile 目录的写权限问题仍然存在**——补丁层是文件，agent 只要有权就能改——但插件安装这条具体说法要收回。

## 尚未查清 / 已澄清

1. ✅ **`DSH_HOME` 的实际位置**：不是 `$HOME` 本身，而是 `$HOME/.dsh`（本部署为 `/opt/data/.dsh`）。profile 在 `/opt/data/.dsh/profiles/web`。之前查 `/opt/data/profiles/` 找不到，是路径错了。
2. ✅ **`disabled: true` 与实际工具集为何不一致**：`standard` preset 的头部注释给了答案——**工具在 preset 里，执行服务在 host plane**。web profile 停用的是宿主自己的工具名册；会话加入 preset 后拿到的是 preset 的工具，而那些工具消费的 `subprocess` / `sandbox` / `fs` 服务由 host 提供。这正是"覆盖 host 的三行就能重定向执行"的依据，见 [ssh-remote.md](ssh-remote.md) 第八节。
3. ❓ **`dsh-api-remotes` 的语义**：是「远程计算」还是「对 DSH 服务端的远程连接管理」？仍未确认，但已不影响方案——远程计算走的是 `dsh-ssh`，与它无关。

## 结论（2026-09-18）：默认不带远程执行，但存在可安装的 SSH 插件

自检时的工作目录 `/opt/data/github` 是**界面上让用户新建并选定的本地目录**——不是远程连接，不是配置项，就是容器内的一个路径。而 `0.1.5-rc.2` 的 240 个依赖里没有任何远程 provider，全部是 `*-local`。

**所以开箱状态下 DSH 只能在本进程所在的容器里执行命令。**

但「没有依赖」≠「不存在」。2026-09-18 在集群上直接探测 npm registry，确认**官方提供了完整的 SSH 远程 provider 家族**：

| 包 | 存在 | alpha 版本 | 说明 |
|---|---|---|---|
| `@deepseek-ai/dsh-ssh` | ✅ | `0.1.6-alpha.2` | Shared OpenSSH connection and versioned POSIX remote helper |
| `@deepseek-ai/dsh-fs-ssh` | ✅ | `0.1.6-alpha.2` | 远程文件系统 provider（15 KB） |
| `@deepseek-ai/dsh-subprocess-ssh` | ✅ | `0.1.6-alpha.2` | 远程子进程 provider |
| `@deepseek-ai/dsh-sandbox-ssh` | ✅ | `0.1.6-alpha.2` | 远程沙箱（11 KB） |
| `@deepseek-ai/dsh-terminal` | ✅ | — | 终端（是否 ssh 相关待确认） |
| `@deepseek-ai/dsh-remote` | ❌ 404 | | 不存在这个包名 |
| `@deepseek-ai/dsh-lsp-ssh`、`dsh-pty-ssh`、`dsh-tool-ssh` | ❌ 404 | | |

这些包由官方 CI 发布（packument 里 `_from: file:/home/runner/work/deepseek-harness/...`），带 npm provenance 签名，体积都只有十几 KB——是薄封装，不是玩具。

### 关键约束：SSH 家族只存在于 0.1.6 线

```
@deepseek-ai/dsh               latest: 0.1.5-rc.2   alpha: 0.1.6-alpha.2
@deepseek-ai/dsh-ssh           latest: 0.1.6-alpha.1 alpha: 0.1.6-alpha.2
@deepseek-ai/dsh-fs-ssh        latest: 0.1.6-alpha.1 alpha: 0.1.6-alpha.2
@deepseek-ai/dsh-subprocess-ssh latest: 0.1.6-alpha.1 alpha: 0.1.6-alpha.2
@deepseek-ai/dsh-sandbox-ssh   latest: 0.1.6-alpha.1 alpha: 0.1.6-alpha.2
```

**当前部署的 `0.1.5-rc.2` 上没有 SSH provider**——`@deepseek-ai/dsh-ssh` 的 peerDependencies 要求 `^0.1.6-alpha.1`，而 `0.1.5-rc.2 < 0.1.6-alpha.1`，不满足 semver 范围。

所以「走官方方案」**必须同时把 dsh 升到 `0.1.6-alpha.2`**，这不是可选动作。

值得注意：change 的 design.md 在「Evidence and scope」里写的正是 *Inspected root version: 0.1.6-alpha.2*。规格从一开始就是照着这个版本写的，只是当时误判它「not a verified published npm version」。实际上它已发布，只是挂在 `alpha` tag 下。

> 三轮前的结论曾写成「官方 SSH provider 这条路在当前版本上走不通」。那句话对了一半：在 `0.1.5-rc.2` 上确实走不通，但**升级到 `0.1.6-alpha.2` 之后官方方案就是可用的**，不需要写自定义插件，也不需要打补丁。




