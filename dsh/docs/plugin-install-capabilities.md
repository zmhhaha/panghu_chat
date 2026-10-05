# k8s 部署下的 DSH 插件安装能力

> 记录时间：2026-10-06。
> 环境：DSH `0.1.6-alpha.2`（镜像 `dsh-web:20261005T161238Z`）、pnpm `10.34.5`、
> `HOME=/opt/data` → `DSH_HOME=/opt/data/.dsh`、profile `web`。
>
> **标记约定**：**实测** = 在运行中的容器里验证过，命令与输出都给出；**文档** = 该版本自带 README 的规定。
> 换版本时先复核标着"实测"的几行。
>
> 相关：[profile-architecture.md](profile-architecture.md)、[boundaries.md](boundaries.md)、
> [ssh-remote.md](ssh-remote.md)、[operations.md](operations.md)。

## 1. 谁可以装（三个入口）

| 入口 | 能力 | 依据 |
|---|---|---|
| **Web UI 的 Plugins 面板** | ✅ 装/卸组合包、启停组合包与组合包里的行、查看 pnpm 输出、取消、选择安装源、授权构建脚本 | 组合里 `ui-plugin-manager` 行已启用（**实测** `--dump-config`） |
| **容器内 CLI** | ✅ `dsh plugin --profile web <pnpm 参数>` —— **转发给 profile 目录里的 pnpm，即完整 pnpm 命令面**（`add` / `install` / `remove` / `update` / `link` / `audit` / `ls` …） | **实测**：打印 `Version 10.34.5` + pnpm 全套用法 |
| **会话里的 agent（工具）** | ❌ **默认没有** | **实测**：`- id: tool-plugin-manager` 在 base 层就是 `disabled: true`，dump 里没有任何后续层把它打开 |

第三行是刻意的：它与 [boundaries.md](boundaries.md) 引用的上游要求一致——
"Disable agent access to plugin installation / policy mutation where supported"。
要放开就得在 agent preset 里显式启用那一行，属于单独的决策。

## 2. 能装什么

**面板接受的安装源**：包名（可带版本）· **Git 仓库地址** · **压缩包 URL** · **本地绝对路径**。
安装前 Host 会先 `pluginManager.inspect` 读出 spec 指向什么（**文档**）。

**只管理"组合包"**：没有 `dsh.bundle.patch` 的普通包**在安装前就被拒绝**；普通插件模块不算可安装项，
加载它仍是文件操作（**文档**）。

**registry（实测）**

```
pnpm 自身 registry : https://registry.npmmirror.com
另有配置           : @jsr:registry=https://npm.jsr.io/
出网（容器内 node fetch）：registry.npmmirror.com 200 ✅  registry.npmjs.org 200 ✅
                          github.com 200 ✅              codeload.github.com 200 ✅
```

面板还会并发探测 npmjs 与 npmmirror（各 1500 ms，结果缓存 5 分钟），选最快的一个作为初始安装源；
用户手选后记在**本浏览器**的 `localStorage`（**文档**）。

## 3. 装到哪 / 什么会活过重启

| 内容 | 位置 | 重启后 |
|---|---|---|
| 包本体与依赖 | `profiles/web/package.json`、`pnpm-lock.yaml`、`node_modules`（pnpm workspace，`nodeLinker: hoisted`）、`pnpm-workspace.yaml` | ✅ |
| 组合包启用/停用 | `package.json` 的 `dsh.profile.bundles` | ✅ |
| **行开关（`disabled`）与行配置** | `profiles/web/cordis.patch.yml`（用户层） | ✅（2026-10-06 修复，见下） |
| 界面设置（主题、语言等） | home 级 `$DSH_HOME/cordis.patch.yml` | ✅ |
| 版本兼容豁免 | `profiles/web/compatibility.json`（目前不存在，按需创建） | ✅ |

**2026-10-06 修复的那件事**：`seed-profile.mjs` 原先每次容器启动都**整份覆盖** profile 的
`cordis.patch.yml`，而插件管理器把行开关与行配置**写在同一份文件里** —— 于是面板里存的东西
**重启即丢**。现在本部署的组合改由启动参数 `--patch /opt/dsh-config/cordis.patch.yml` 提供
（overlay 应用在 profile 层**之后**，优先级更高；文件在镜像内、root 所有，容器 uid 改不动），
profile 的 `cordis.patch.yml` 归还给用户层。实测：按面板的写入格式写一条，重启后仍在。
详见 [profile-architecture.md](profile-architecture.md)。

## 4. 面板里的运行期能力（**文档**）

- 启停组合包；逐行开关（`disabled`）；带配置页的插件在自己的页面里编辑（**只有点保存才写入**）
- 查看 pnpm 输出，且**每次运行都标注所用的安装源**
- 取消：准备与下载阶段可取消；**加载组合包的阶段不可取消**
- 失败按归因给一句话：所有源都连不上（并列出问过哪些）、GitHub 地址或压缩包链接自身的主机连不上
  （换源无济于事）、包不存在、磁盘已满、profile 不可写、pnpm 拦下构建脚本
- pnpm 拦下依赖的安装脚本时，提供「允许这些脚本并重试」，授权写进 profile 的 `pnpm-workspace.yaml`
- 失败时 Host 会把 manifest 与 lockfile **放回原样**

## 5. 明确不支持 / 限制（**文档**）

- **无版本选择器、无自动更新**：升级＝卸载后重装；随 DSH 提供的插件随 DSH 升级
- **一次只跑一个安装**：第二个 spec 要等前一个结束
- **只管理组合包**（见 §2）
- **安装成功 ≠ 模块一定能够激活**：激活由组合决定
- **GitHub 源不能靠国内镜像替代**：镜像提供 registry 里的包，不代替 GitHub 仓库下载
- **刷新浏览器会丢跟踪的请求与输出**：同页重连可恢复活动请求；Host 不保留已完成的结果
- 与 DSH 运行时版本不匹配的插件需要显式**豁免**（`compatibility.json`，写入不改变依赖与组合包选择）

## 6. 权限与沙箱

插件管理器跑在 **host plane —— 就是 `dsh` 容器本身**，**不受**"agent 执行被 SSH 重定向到项目容器"
的影响，也不经过 agent 沙箱。本部署的 `DSH_PERMISSION_MODE=danger-full-access`，因此面板与 CLI
操作**没有审批弹窗**（换成更严的模式时，`plugin_manager` 类操作会要求审批）。

## 7. 出问题怎么恢复

- `dsh rescue --from-default-profile web`：从随附模板创建 rescue profile 并启动（**实测** `--help` 里有）
- sanitize 流程会把 profile 的 patch 重命名为同目录 `.bak-<timestamp>` 备份，并保留已安装包与其他 manifest 字段
- 安装失败：manifest 与 lockfile 自动还原（**文档**）

## 8. 现状备注

`.plugin-manager/logs/` 里那 4 条记录是**开机播种**（`seed-profile.mjs` 装四个 SSH provider）留下的、
内容为空 —— 说明**面板至今没有被真正用过**（不是失败过）。

## 9. 如何复核

```bash
POD=$(kubectl -n dsh get pod -l app=dsh-web -o jsonpath='{.items[0].metadata.name}')

# 工具链与版本
kubectl -n dsh exec $POD -c dsh -- sh -c 'node -v; pnpm --version; dsh --version'

# CLI 入口把参数转发给 pnpm
kubectl -n dsh exec $POD -c dsh -- sh -c 'dsh plugin --profile web --help | head -3'

# agent 侧工具行是否被禁用（当前：disabled: true）
kubectl -n dsh exec $POD -c dsh -- sh -c 'dsh web --patch /opt/dsh-config/cordis.patch.yml --dump-config | sed -n "1,6p"'

# 用户层现在是什么（迁移后应为 []，非空即面板写入的内容）
kubectl -n dsh exec $POD -c dsh -- sh -c 'cat /opt/data/.dsh/profiles/web/cordis.patch.yml'

# 真实安装测试（装在 /tmp，不碰 profile）
kubectl -n dsh exec $POD -c dsh -- sh -c 'rm -rf /tmp/probe && mkdir /tmp/probe && cd /tmp/probe \
  && printf "{\"name\":\"probe\",\"private\":true}\n" > package.json && pnpm add is-odd'
```
