# DSH 私有编码工作台

ARM64 Kubernetes 中的单人 DSH（DeepSeek Harness）网页工作台。**代码已实现，未构建镜像、未部署、未测试**；服务器验收清单见末尾。

对应 OpenSpec change：`add-dsh-private-k8s-workbench`（项目 `armbianbegin`）。

## 组件和边界

- **`dsh-web`**：DSH 网页监听 Pod 内回环 `127.0.0.1:3080`；同 Pod 的 oauth2-proxy 暴露 4180，精确邮箱白名单。`DSH_HOME` 在独立 PVC 上。
- **`dsh-runner-<project>`**：**每个项目一个持久受限容器**（change 的 option B）。所有 agent 命令、终端、文件读写都在这里执行，**不在网页容器里**。命令不需要新建 Job。
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
| 边界与运维说明 | `docs/boundaries.md`、`docs/operations.md` |

## 构建

在 ARM64 构建机准备 Docker。先选定一个**已发布的精确版本**，核实它确实提供 `web` 子命令及其 `--host/--port/--trusted-host/--no-open` 标志、远程文件/命令/终端 provider 家族、以及关闭本地执行回退的开关，然后固定：

```bash
cd panghu_chat/dsh
cp config/build.example.env build.local.env
# 编辑 build.local.env：填 DSH_PACKAGE 为 <包名>@<精确版本>
bash build.sh
```

`build.sh` 会 pull ARM64 基础镜像、断言 `Architecture == arm64`、解析其摘要，之后一律用摘要构建；产出 `dsh-web` 与 `dsh-runner` 两个镜像，时间戳 tag 与 `:latest` 双推，并把实际摘要写进 `rendered/`。`DSH_PACKAGE` 不带精确版本会被构建拒绝。

依赖在**构建期**装好；运行期不跑 `npx`、不联网装依赖。npm 源默认 `registry.npmmirror.com`，可在 `build.local.env` 覆盖。

## 凭据与配置

| Secret | 内容 | 挂载到 |
|---|---|---|
| `dsh-model` | 模型/搜索供应商密钥对应的原生环境变量 | **仅**网页容器 |
| `dsh-oidc` | `OAUTH2_PROXY_CLIENT_ID` / `_CLIENT_SECRET` / `_COOKIE_SECRET` | **仅** OAuth 容器 |

写入方法与路径约定见 `vault/inventory/DSH.md`。项目容器**两个都不挂载**，其 NetworkPolicy 也不允许它访问这些服务的地址。

模型端点与 ID、工具白名单、插件静态许可清单等**非敏感**配置放 ConfigMap，不进 Vault。模型密钥优先用 `apiKeyEnv` 绑定，**不要通过界面写进普通 settings YAML**。

插件与宿主机同权限，因此：静态许可清单、安装目录只读、生产环境不自动更新。

## 部署

需要完整仓库目录（脚本要读 `../..` 下的 vault 与 oauth 配置），不能只复制本子目录。

```bash
bash deploy.sh --dry-run    # 只打印 apply 顺序
bash deploy.sh              # 建命名空间、同步 Secret、apply 清单、重启网页
```

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
4. **网络**：项目容器能直连公网 clone/装依赖；**不能**访问集群 Service、Pod/Service CIDR、节点地址、`169.254.169.254`；用公有 DNS 名指向内网地址同样失败。验证 CNI 实际生效，而不是只看清单存在。
5. **持久化**：Pod 重建后项目文件与已装依赖仍在；命令取消能终止后代进程；资源耗尽不会逃出限额。
6. **路由**：Cloudflare 侧不记录带 query 的完整 URL——launch token 会出现在 URL 里。

## 未决项

| 项 | 状态 |
|---|---|
| **DSH 自身配置** | 网页容器的 `args` 是 design 给的候选值，**未在固定版本上验证**；Cordis 策略覆盖、模型绑定、工具白名单、关闭本地执行的开关都还没写。需要上游文档或第一轮构建后的实测。 |
| **原生 Cookie 的 Secure** | DSH 原生 cookie 在本机场景下不带 `Secure`。上游是否有配置开关未知；若无，需要一个位于 OAuth 与 DSH 之间的极小回环适配层。见 `oauth/k8s/DSH.md`。 |
| **项目传输** | runner 镜像**还没有传输监听器**。design 要求先验证官方 SSH provider 能否覆盖，必要时才写自定义 provider；`k8s/networkpolicies.yaml` 与 `templates/runner.yaml` 里的 2222 端口是暂定值。 |
| **远程 provider 覆盖度** | change 把它列为 release gate：不能只有新测试工具是远程的、而普通 Bash 仍在本地。 |
| **IPv6** | 见上。 |
| **ResourceQuota / LimitRange** | design 要求"namespace 配额兜底"，但全仓库零先例。当前靠每个容器显式 `resources` 兜底，未引入配额对象。 |
| **节点容量** | 网页与项目容器默认都钉 `orangepi5-max-server1`，该节点同时跑 ES / PostgreSQL / Redis / embedding / Hermes。见 `docs/operations.md`。 |

本实现不提供模型微调、私有仓库拉取、聊天平台接入或临时测试 Job（change 的 option C 已延后）。
