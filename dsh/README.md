# DSH 私有编码工作台

ARM64 Kubernetes 中的单人 DSH（DeepSeek Harness）网页工作台。基础网页与自动登录适配层已部署；**SSH 远程执行已实现，尚未构建与验证**。服务器验收清单见末尾。

对应 OpenSpec change：`add-dsh-private-k8s-workbench`（项目 `armbianbegin`）。

## 组件和边界

- **`dsh-web`**：DSH 网页监听 Pod 内回环 `127.0.0.1:3080`；oauth2-proxy 暴露 4180，精确邮箱白名单，转发到回环认证适配层 3081。适配层自动兑换原生 Cookie，无需手工获取启动链接。`DSH_HOME` 在独立 PVC 上。
- **`dsh-runner-<project>`**：**每个项目一个持久受限容器**（change 的 option B）。非 root sshd 监听 2222，网页侧的 `dsh-ssh` 经此连接，**所有 agent 命令、终端、文件读写都应在那里执行**。命令不需要新建 Job。
- **传输的开关是 [config/cordis.patch.yml](config/cordis.patch.yml)**：它按 id 覆盖 host plane 的 `subprocess` / `sandbox` / `fs-sandbox` 三行，把执行从网页容器转到远端。**这是官方扩展点，不是补丁** —— dsh-base 自己的注释写明 profile 的 `cordis.patch.yml` 就是"按 id 覆盖配置行、后层覆盖前层"的用户层。工具留在 preset 里，但它们执行的宿主服务在 host plane，所以覆盖这三行就够了。
- **引导是失败即停的**：[auth/seed-profile.mjs](auth/seed-profile.mjs) 在 DSH 启动前组合 profile 并落位密钥，任何一步失败都让容器起不来，**不会退回本地执行**。
- 两者分属 `dsh` 与 `dsh-runners` 两个命名空间，与 Hermes 完全隔离。**没有任何一方持有 Kubernetes 权限**：没有 kubeconfig、没有 RBAC、没有 hostPath / hostNetwork / Docker socket，`automountServiceAccountToken: false`。
- **只处理公开仓库**：HTTPS clone、本地提交；**推送由所有者在本仓库外完成**。不注入 Git 写凭据、SSH agent 或个人凭据助手。

## 配置归属

平台配置按仓库目录归属维护，不集中在本目录：

| 关注点 | 文件 |
|---|---|
| OAuth 代理与邮箱白名单 | `oauth/k8s/dsh-proxy-configmap.yaml` + `oauth/k8s/DSH.md` |
| Vault → Secret 映射 | `vault/inventory/dsh-externalsecret.yaml` + `vault/inventory/DSH.md` |
| 公网路由（备份） | `cloudflare-tunnel/operator/dsh-route.yaml` + `cloudflare-tunnel/operator/DSH.md` |
| 命名空间、存储、网页负载 | `k8s/namespaces.yaml`、`k8s/storage.yaml`、`k8s/web.yaml` |
| 网络边界 | `k8s/networkpolicies.yaml` + `docs/boundaries.md` |
| 项目容器模板 | `templates/runner.yaml`（由 `provision.sh` 渲染，**不是可直接 apply 的清单**） |
| **profile 组合（执行重定向）** | `config/cordis.patch.yml` + `auth/seed-profile.mjs` |
| **远端 provider 环境变量** | `config/ssh.env` → deploy.sh 生成的 `dsh-ssh-runtime` ConfigMap |
| **SSH 客户端别名** | `config/ssh_config` → deploy.sh 生成的 `dsh-ssh-config` ConfigMap |
| **远端 sshd 与 helper** | `runner/Dockerfile`、`runner/sshd_config`、`runner/entrypoint.sh` |
| 边界与运维说明 | `docs/boundaries.md`、`docs/operations.md`、`docs/ssh-remote.md` |

## 构建

在 ARM64 构建机准备 Docker。两个镜像一起构建：

```bash
cd panghu_chat/dsh
cp config/build.example.env build.local.env
# 编辑 build.local.env：DSH_PACKAGE 与 DSH_SSH_VERSION 都填 0.1.6-alpha.2
bash build.sh
```

`build.sh` 会 pull ARM64 基础镜像、断言 `Architecture == arm64`、解析其摘要，之后一律用摘要构建；产出 `dsh-web` 与 `dsh-runner` 两个镜像，时间戳 tag 与 `:latest` 双推，并把实际摘要写进 `rendered/`。

**两个版本是锁死的。** `DSH_PACKAGE` 必须等于 `@deepseek-ai/dsh@${DSH_SSH_VERSION}`，否则构建直接拒绝。官方 SSH provider 家族只发布在 0.1.6 线，且它的 peerDependencies 要求同一版本——CLI 与 provider 分开钉会装配出一个装得上却组不起来的树。

构建 web 镜像时会把四个 provider 打成 tarball 放进 `/opt/dsh-ssh-deps/`；构建 runner 镜像后会从镜像里**读回** helper 摘要写进 `rendered/helper.sha256`。`deploy.sh` 需要这个文件，缺了会拒绝部署——摘要写错会让 `dsh-ssh` 在会话开始时失败，而不是静默用错版本。

依赖在**构建期**装好；运行期不跑 `npx`、不联网装依赖（profile 组合用的是镜像内已打好的 tarball）。npm 源默认 `registry.npmmirror.com`，可在 `build.local.env` 覆盖。

### 版本沿革（2026-09-18 → 09-19）

- 旧示例 `deepseek-harness@0.1.6-alpha.2` 会报 `No matching version found`：`deepseek-harness` 不是官方可运行包，`@deepseek-ai/dsh` 才是；源码树版本也不能直接当作已发布版本。不要改装 `deepseek-harness@0.0.1`，那只是占位包。
- 09-18 固定到 `@deepseek-ai/dsh@0.1.5-rc.2`（当时的 `latest`）。
- 09-19 **必须升到 `0.1.6-alpha.2`**：它挂在 `alpha` tag 下，而 SSH provider 家族只有 0.1.6 线有发布。`build.local.env` 是本地文件，更新示例不会覆盖它，需手工改。
- 稳定的 apt 安装与非交互 debconf 提示都不是构建失败原因，不需要升级 npm 或更换 apt 源。

## 凭据与配置

| Secret | 内容 | 挂载到 |
|---|---|---|
| `dsh-model` | 模型/搜索供应商密钥对应的原生环境变量 | **仅**网页容器 |
| `dsh-oidc` | `OAUTH2_PROXY_CLIENT_ID` / `_CLIENT_SECRET` / `_COOKIE_SECRET` | **仅** OAuth 容器 |
| `dsh-ssh-client` | 传输私钥 `id_ed25519`、固定主机密钥的 `known_hosts` | **仅**网页容器 |
| `dsh-ssh-host` | 主机私钥、主机公钥、`authorized_keys`（即客户端公钥） | **仅**项目容器 |

密钥对的两半来自**同一个** Vault 路径 `secret/dsh/ssh`，由两个 ExternalSecret 按"哪一侧可以持有"拆分：项目容器只拿主机私钥，网页容器只拿客户端私钥，互不交叉。`authorized_keys` 是客户端公钥的重命名映射，信任关系在 Vault 里只写一次，两边不会漂移。

写入方法与路径约定见 `vault/inventory/DSH.md`。模型与 OAuth 凭据项目容器**都不挂载**，其 NetworkPolicy 也不允许它访问这些服务的地址。

模型端点与 ID、工具白名单、插件静态许可清单等**非敏感**配置放 ConfigMap，不进 Vault。模型密钥优先用 `apiKeyEnv` 绑定，**不要通过界面写进普通 settings YAML**。

插件与宿主机同权限，因此：静态许可清单、安装目录只读、生产环境不自动更新。

## 部署

需要完整仓库目录（脚本要读 `../..` 下的 vault 与 oauth 配置），不能只复制本子目录。**必须先跑过 `build.sh`**：`deploy.sh` 要读 `rendered/helper.sha256`，缺了会直接拒绝。

```bash
bash deploy.sh --dry-run    # 只打印 apply 顺序
bash deploy.sh              # 建命名空间、同步 Secret、apply 清单、重启网页
```

`deploy.sh` 除了 apply 清单，还会生成两个 ConfigMap：

- `dsh-ssh-config` ← 由 `config/ssh_config` 生成（`dsh-runner-*` 别名），文件才是唯一真源
- `dsh-ssh-runtime` ← 由 `config/ssh.env` 生成，再追加从 `rendered/helper.sha256` 读到的 `DSH_SSH_HELPER_HASH`

顺序是先 `deploy.sh`（它在 `dsh-runners` 里建好 `dsh-ssh-host` ExternalSecret），再 `provision.sh`。反过来项目容器会因为拿不到主机密钥而起不来。

`deploy.sh` 会拒绝 apply 含未替换 `__PLACEHOLDER__` 的文件——项目容器是模板，不是清单。

公网路由不会被自动写入：要在 Cloudflare 后台手工加 `dsh.panghuer.top`，并给 cloudflared 的 Pod 模板加 `dsh-ingress: "true"` 标签。步骤见 `cloudflare-tunnel/operator/DSH.md`。

## 项目供给

由所有者手工执行，**没有 runtime controller**——DSH 和项目容器都不管理 Kubernetes 资源。

```bash
cp config/provision.example.env provision.local.env
bash provision.sh armbianbegin             # 默认 dry run，只渲染
bash provision.sh --apply armbianbegin     # 创建 PVC / Deployment / Service
bash provision.sh --remove armbianbegin    # 只删 Deployment 与 Service
```

`--remove` **不删 PVC**，会打印删除命令让你显式执行——项目文件与已装依赖不能被顺手毁掉。

## 网络边界

**外网直接放行，只挡内网。** 项目容器可以直连公网拉依赖；集群内 Service、Pod/Service CIDR、节点、link-local、元数据地址全部按目标地址拒绝。实现是 NetworkPolicy 的 `ipBlock + except`（Pod CIDR `10.244.0.0/16` 与 Service CIDR 都落在 `10.0.0.0/8` 内），**不使用 egress 代理**。

一个公有 DNS 名解析或重定向到内网地址同样被拒，因为规则匹配的是解析后的目标地址而不是域名。

⚠️ **IPv6 未覆盖**：`ipBlock` 只有 IPv4，而本仓库全仓没有 IPv6 处理。集群是纯 IPv4（`POD_CIDR 10.244.0.0/16`），但仍需在服务器上确认节点没有 IPv6 出口。详见 `docs/boundaries.md`。

## 服务器验收清单

**未完成以下验证前不要放开 agent 执行。**

1. **镜像与启动**：ARM64 原生模块加载正常；网页容器以非 root 启动（`readOnlyRootFilesystem: true`，如上游需要额外可写路径，加显式 emptyDir 而**不是**关掉只读根）。
2. **认证**：本人可登录；其他 Casdoor 账号被拒；错误 Host/Origin 被拒；注销与撤销后的连接行为符合预期；WebSocket 升级与重连正常。**注意验证外层 OAuth 与 DSH 原生 launch token 叠加后的实际 `Set-Cookie` 行为。**
3. **执行隔离**：所有 agent 执行路径（Git、终端、构建、测试、包安装）都落在项目容器，**没有网页容器内的回退**；文件工具无法穿越到 `DSH_HOME`、凭据路径或其他项目。
   - **怎么判断落在哪边**：在会话里跑 `hostname`。返回 `dsh-runner-<project>-...` 就对了；返回 `dsh-web-...` 说明组合没生效，必须停下来查，不要继续用。
   - 再确认 `dsh-web` 容器里**没有** agent 产生的文件，而项目卷 `/workspace` 上**有**。
4. **传输本身**：错误 host key 被拒；`helperHash` 不匹配时连接失败而**不是降级**；项目容器拒绝 2222 以外的转发；`dsh-web` 里只应有客户端私钥，没有主机私钥。
5. **网络**：项目容器能直连公网 clone/装依赖；**不能**访问集群 Service、Pod/Service CIDR、节点地址、`169.254.169.254`；用公有 DNS 名指向内网地址同样失败。验证 CNI 实际生效，而不是只看清单存在。
6. **持久化**：Pod 重建后项目文件与已装依赖仍在；命令取消能终止后代进程；资源耗尽不会逃出限额。
7. **路由**：Cloudflare 侧不记录带 query 的完整 URL——launch token 会出现在 URL 里。

## 未决项

| 项 | 状态 |
|---|---|
| **DSH 自身配置** | 远程 provider 配置**已写**（`config/cordis.patch.yml` 覆盖 host plane 的三行 + 插入 `dsh-ssh`）。`args` 已按 `dsh --help` 核对。**仍未写**：模型绑定、工具白名单、插件静态许可清单。 |
| **自动登录与 Cookie** | 已实现 `auth/` 适配层，保留原生兑换并补充 `Secure`，本地测试通过；需重建镜像后验证真实 Casdoor 登录、原生 Cookie 和重启恢复。见 `oauth/k8s/DSH.md`。 |
| **项目传输** | 已实现：runner 镜像带非 root sshd + Node + helper + bubblewrap，网页侧经 `dsh-ssh` 连接，`config/cordis.patch.yml` 把执行重定向到远端。**尚未构建、未部署、未测试。** 见 [docs/ssh-remote.md](docs/ssh-remote.md)。 |
| **⚠️ 本次实现的未验证假设** | 下面五条只有构建+部署一次才能证伪，任一条不成立都要改：① `dsh plugin --profile web add file:...` 能否离线装入 profile；② `dsh --profile web --help` 是否真的物化 profile；③ **覆盖那三行是否真的把执行转到远端**（核心）；④ 镜像内 `/etc/ssh/ssh_config` 是否有 `Include /etc/ssh/ssh_config.d/*.conf`；⑤ 非 root sshd 在只读根 + 无 capabilities 下能否起来。 |
| **web 还是 headless** | 早前认为这是阻断项，**证据已转向支持 web**：`standard` preset 的头部注释明确说工具在 preset 里、而"沙箱与审批栈""其执行器 `bash-sandbox`/`pwsh-sandbox`""`fs` 服务与策略"都在 **host plane**——正是 `cordis.patch.yml` 能覆盖的那一层。README 那句限制更可能只影响侧栏文件视图。**由第 ③ 条实测定论。** |
| **远程 provider 覆盖度** | change 把它列为 release gate：不能只有新测试工具是远程的、而普通 Bash 仍在本地。 |
| **IPv6** | 见上。 |
| **ResourceQuota / LimitRange** | design 要求"namespace 配额兜底"，但全仓库零先例。当前靠每个容器显式 `resources` 兜底，未引入配额对象。 |
| **节点容量** | 网页与项目容器默认都钉 `orangepi5-max-server1`，该节点同时跑 ES / PostgreSQL / Redis / embedding / Hermes。见 `docs/operations.md`。 |
| **本机无沙箱后端** | 部署后自检：镜像内缺 bubblewrap / Landlock，`workspace-write` 模式下 bash 一律被拒，只有 `danger-full-access` 能执行。叠加上一条，当前状态是「在持有模型密钥的网页容器里、无沙箱执行」，且 agent 的工作目录就在 `DSH_HOME` 内，`.credentials.yaml` 对它可读可写。**不要靠给镜像装 bubblewrap 来缓解**——要修的是传输。见 `docs/boundaries.md`。 |

本实现不提供模型微调、私有仓库拉取、聊天平台接入或临时测试 Job（change 的 option C 已延后）。
