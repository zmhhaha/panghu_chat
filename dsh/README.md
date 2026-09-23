# DSH 私有编码工作台

ARM64 Kubernetes 中的单人 DSH（DeepSeek Harness）网页工作台。**已部署并跑通**：网页、自动登录、SSH 远程执行全部上线，**agent 的命令、文件、终端全部落在项目容器里**。

> ⚠️ **每次新建会话，工作目录必须选 `/workspace`。**
>
> 选择器列的是**网页容器**的目录，而选中的目录会成为**远端命令的 `cwd`**。选别的会让每条命令报 `spawn bash ENOENT` —— 那是 Node 在说"找不到 cwd"，却在报可执行文件的名字，所以看起来像 runner 里没有 bash。`/workspace` 是唯一在两侧含义一致的路径：**网页容器里空着不用，项目容器里就是项目卷**。详见 [docs/deployment-issues.md](docs/deployment-issues.md) 第八节。

> **边界在哪** —— **Kubernetes 项目容器就是沙箱边界**，不是 DSH 内层的沙箱。容器无 capabilities、只读根、无集群凭据、无 hostPath：**这些才是保护集群的东西**。
>
> 🔴 **更正（2026-09-20 实测）**：这一段原本还有一句"NetworkPolicy 挡住全部内网"，**实测不成立**。集群 CNI 是 `kube-flannel`（无 Calico/Cilium/kube-router），**不实现 NetworkPolicy**，`k8s/networkpolicies.yaml` 全部规则空转。从 runner 容器内探测，Kubernetes API 与 Vault 都**连通**。**网络当前不是边界的一部分。** 见 [docs/boundaries.md](docs/boundaries.md) 顶部更正与 [../../docs/network-policy-engine.md](../../docs/network-policy-engine.md)。
>
> DSH 自己的内层沙箱在这套硬件上**给不出约束**（bubblewrap 被容器 capability 集挡住；Landlock 内核根本没编译）。因此会话运行在 `danger-full-access` 下——**这不是"拆掉边界"，是"打开执行开关"**：它与 `workspace-write` 在"文件约束"上实际等价（都等于没有），差别只在 bash 能不能跑。见 [docs/ssh-remote.md](docs/ssh-remote.md) 第十、十三节。
>
> 🟡 **网络那一条（2026-09-22 状态）**：引擎与策略都已就位——集群 CNI 于 2026-09-21 换成 **Calico**，`k8s/networkpolicies.yaml` 里那条 `198.18.0.0/15` 也已删除。**但正式复验还没跑**，所以上面那条"网络不是边界的一部分"**继续有效**，直到复验输出出来为止。复验用 [`verify-network-boundary.sh`](verify-network-boundary.sh)（从真实项目容器里探测，不是新建探针 Pod）：`bash verify-network-boundary.sh --explain` 看判据，去掉 `--explain` 执行。
>
> 部署期间踩到的 **15 个坑**（其中 4 个属于"配置合法、无报错、只是不生效"的静默陷阱）完整记在 **[docs/deployment-issues.md](docs/deployment-issues.md)**。

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
| **网络边界复验** | `verify-network-boundary.sh` —— 从**真实项目容器**里探测（不是一次性探针 Pod）；判据与期望值见 `docs/boundaries.md` 末节。**2026-09-22 已就绪，尚未执行** |
| 项目容器模板 | `templates/runner.yaml`（由 `provision.sh` 渲染，**不是可直接 apply 的清单**） |
| **profile 组合（执行重定向）** | `config/cordis.patch.yml` + `auth/seed-profile.mjs` |
| **远端 provider 环境变量** | `config/ssh.env` → deploy.sh 生成的 `dsh-ssh-runtime` ConfigMap |
| **SSH 客户端别名** | `config/ssh_config` → deploy.sh 生成的 `dsh-ssh-config` ConfigMap |
| **远端 sshd 与 helper** | `runner/Dockerfile`、`runner/sshd_config`、`runner/entrypoint.sh` |
| 边界与运维说明 | `docs/boundaries.md`、`docs/operations.md`、`docs/ssh-remote.md` |
| **部署踩坑记录** | `docs/deployment-issues.md` —— 14 个问题、根因与修法 |
| Landlock 调研 | `docs/landlock.md` |

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

写入方法与路径约定见 `vault/inventory/DSH.md`。模型与 OAuth 凭据项目容器**都不挂载**——**这是真正在起作用的隔离**。（原句还有"其 NetworkPolicy 也不允许它访问这些服务的地址"，**2026-09-20 实测该条不成立**：runner 能直连这些地址。防线是"不挂载凭据"，不是"网络不通"。）

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

### 部署顺序

**Vault 必须在最前面，而且不是可选的。** `deploy.sh` 会**等四个 ExternalSecret 变成 Ready**（`dsh-model`、`dsh-oidc`、`dsh-ssh-client` 在 `dsh`；`dsh-ssh-host` 在 `dsh-runners`）；`secret/dsh/ssh` 不存在就会一直等到超时，然后整个部署失败。

| 步骤 | 动作 | 为什么是这个位置 |
|---|---|---|
| 1 | 定项目名（默认 `armbianbegin`），确认与 `config/ssh.env` 的 `DSH_SSH_HOST` 一致 | `known_hosts` 里嵌着项目名（`[dsh-runner-<project>.dsh-runners.svc.cluster.local]:2222`），必须在下一步之前定 |
| 2 | 生成传输密钥对并写入 Vault：`secret/dsh/model`、`secret/dsh/oidc`、`secret/dsh/ssh`（命令见 `vault/inventory/DSH.md`） | `deploy.sh` 会等它们 |
| 3 | `bash build.sh` | 产出两个镜像 + `rendered/helper.sha256`，`deploy.sh` 要读后者 |
| 4 | `bash deploy.sh` | 建命名空间、同步四个 Secret、生成两个 ConfigMap、起网页 |
| 5 | `bash provision.sh --apply <project>` | **必须在 4 之后**：项目容器要读 `dsh-runners` 里的 `dsh-ssh-host`，缺了起不来 |
| 6 | Cloudflare 后台手工加路由 + 给 cloudflared 打 `dsh-ingress: "true"` | 仓库里的路由 YAML 只是备份，不生效 |
| 7 | 走下面的验收清单 | 尤其第 3 条的 `hostname` 判据 |

Vault policy **不用改**：现有的 `kv-reader` 是 `path "secret/data/*"`，已经覆盖 `secret/data/dsh/*`。

**第 4 步和第 5 步之间，网页 Pod 会 `CrashLoopBackOff`——这是正常的，不是坏了。**

原因是设计使然：`dsh-ssh` 在**启动时**就要连上远端，而远端还不存在。日志里会看到：

```
[seed-profile] ready: 4 providers composed into /opt/data/.dsh/profiles/web
Error: failed to apply loader entry ssh (@deepseek-ai/dsh-ssh): SSH helper disconnected; outcome is unknown
```

这正是**失败即停**在起作用——DSH 宁可起不来，也不肯退回在网页容器里本地执行命令。跑完第 5 步后 Pod 会在下一次重试时自己恢复：

```bash
kubectl -n dsh rollout status deployment/dsh-web --timeout=120s
```

如果 `provision.sh` 之后它仍不恢复，再去看 runner 那边的日志，而不是去放宽网页侧的配置。

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

> 🔴 **2026-09-20 实测：本节描述的设计当前完全未生效。** 集群 CNI 是 `kube-flannel`，不实现 NetworkPolicy；`k8s/networkpolicies.yaml` 里所有规则空转，项目容器**可达集群内全部 Service**（实测含 Kubernetes API 与 Vault）。修复方案见 [../../docs/network-policy-engine.md](../../docs/network-policy-engine.md)。
>
> 🟡 **2026-09-22**：引擎已换成 **Calico**（2026-09-21），策略里那条 `198.18.0.0/15` 也已删除，**但正式复验尚未执行**。复验脚本：[`verify-network-boundary.sh`](verify-network-boundary.sh)（从真实项目容器里探测）。**在复验输出出来之前，上面那条结论继续有效。**

**设计意图：外网直接放行，只挡内网。** 项目容器可以直连公网拉依赖；集群内 Service、Pod/Service CIDR、节点、link-local、元数据地址全部按目标地址拒绝。实现是 NetworkPolicy 的 `ipBlock + except`（Pod CIDR `10.244.0.0/16` 与 Service CIDR 都落在 `10.0.0.0/8` 内），**不使用 egress 代理**。

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
   - 🔴 **2026-09-20 已执行，结果：不合格。** 集群 CNI 是 `kube-flannel`，不实现 NetworkPolicy。从 runner 内探测 7 个内网目标**全部连通**（含 Kubernetes API 与 Vault）。此项在本条修复前不通过——见 [../../docs/network-policy-engine.md](../../docs/network-policy-engine.md)。
   - 🟡 **2026-09-22：修好了但没复验。** 集群已迁到 Calico、策略里的 `198.18.0.0/15` 已删；**这条要等复验跑过才能勾**。执行方式：`bash verify-network-boundary.sh`（判据先看 `--explain`）。它从**真实项目容器**里探测——这是它与 `network-policy/verify.sh`、`probe-matrix.sh` 的关键差别，那两个用新建的一次性探针 Pod，证明不了真实策略挂在真实 runner 上的行为。
   - ⚠️ 只覆盖**项目容器**。网页 Pod 的 `web-egress` 与 hermes 那四条策略同样在生效，**本轮没测**。
6. **持久化**：Pod 重建后项目文件与已装依赖仍在；命令取消能终止后代进程；资源耗尽不会逃出限额。
7. **路由**：Cloudflare 侧不记录带 query 的完整 URL——launch token 会出现在 URL 里。

## 未决项

| 项 | 状态 |
|---|---|
| ~~不能执行任何命令~~ | ✅ **已解决（2026-09-19）**。走 `danger-full-access` —— 实测 `dsh-bash-sandbox` 在该模式下**直接短路**，不调用 `ctx.sandbox.confine()`。它与 `workspace-write` 在文件约束上实际等价（都等于没有），差别只在 bash 能不能跑。见 [docs/ssh-remote.md](docs/ssh-remote.md) 第十三节。 |
| ~~Landlock 切换~~ | ✅ **已撤销**。全舰队内核都没编译 Landlock，那个 boot 门禁只可能拒绝启动，部署前撤掉了。bubblewrap 也已移出镜像，`seccompProfile` 回 `RuntimeDefault`。 |
| **两个已知功能缺口** | `attachment-local` 与 `spill-local` 官方没有 `-ssh` 版本，仍在**网页容器**上操作：上传落在 agent 看不见的地方，溢出的路径远端 `read` 打不开。是**功能缺口，不是凭据泄露**。见 [docs/ssh-remote.md](docs/ssh-remote.md) 第十一节。 |
| **runner 内无 uid 分离** | sshd 与 agent 命令**同 uid（10000）**，传输密钥归该 uid → agent 可覆写自己的主机密钥。影响是**自伤式 DoS**，不是提权，也不能冒充网页 Pod。不改。 |
| **项目传输** | ✅ 已上线并验证。runner 带非 root sshd + Node + helper；网页侧经 `dsh-ssh` 连接；`config/cordis.patch.yml` 把执行重定向到远端。文件工具已确认落在项目容器（会话里读 `/etc/hostname` 得到 `dsh-runner-...`）。**重新供给项目后必须重启网页**——`dsh-ssh` 不自动重连。 |
| **web 还是 headless** | ✅ 不再是问题。执行层经 host plane 的 provider 接缝成功重定向，官方那句"面向 headless"的限制没有成为阻塞。**侧栏文件视图是否与远端一致尚未确认**，列为待观察。 |
| **DSH 自身配置** | 远程 provider 配置已完成。**仍未写**：模型绑定、工具白名单、插件静态许可清单。 |
| **自动登录与 Cookie** | ✅ 已上线。`auth/` 适配层保留原生兑换并补 `Secure`；真实 Casdoor 登录与重启恢复随本次部署通过。 |
| **远程 provider 覆盖度** | ✅ change 的 release gate（"不能只有新测试工具是远程的、而普通 Bash 仍在本地"）已满足：`subprocess` / `sandbox` / `fs-sandbox` 三个 host-plane provider 都换成了 SSH 实现，bash 与文件工具走的是同一条 `ctx.subprocess` / `ctx.fs`→远端。 |
| **IPv6** | 见上。 |
| **ResourceQuota / LimitRange** | design 要求"namespace 配额兜底"，但全仓库零先例。当前靠每个容器显式 `resources` 兜底，未引入配额对象。 |
| **节点容量** | 网页与项目容器默认都钉 `orangepi5-max-server1`，该节点同时跑 ES / PostgreSQL / Redis / embedding / Hermes。见 `docs/operations.md`。 |
| ~~本机无沙箱后端~~ | ✅ **已解决，原描述已过时**。那行写的是执行**还在网页容器**时的状态（"在持有模型密钥的容器里无沙箱执行"）——**现在执行在项目容器里**，那里没有模型密钥、没有 `DSH_HOME`、没有 `.credentials.yaml`。沙箱模式见上面两节；完整排查见 [docs/deployment-issues.md](docs/deployment-issues.md)。 |

本实现不提供模型微调、私有仓库拉取、聊天平台接入或临时测试 Job（change 的 option C 已延后）。
