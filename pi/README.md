# pi-cage —— 部署，不是构建

当前模型接入方案为直连 `custom-llm`：首次写入 `/home/pi/.pi/agent/models.json`，
随后在网页终端 `/model` 选择。配置步骤及待确认状态见 [三个 Agent 的 custom-llm 接入记录](../docs/agents-custom-llm.md)。

`k8s/llm-egress.yaml` 为本目录部署的 `pi/app=pi` 开放到 llm-service 的精确网络例外，
配合网关 `llm-agent-clients` 入站策略即时生效。已核对 `pi.panghuer.top` 指向本部署；
旧 `pi-cage` namespace 的部署及数据已删除。网关是保留的可选路径，采用它时才配置网关令牌和 `pi-trusted`，
见 [接入说明](../../llm-service/design/agent-routing-integration.md)。

`pi` 编码代理，以 [pi-cage](https://github.com/zmhhaha/pi-cage) 的形式部署给虎博使用。

**这个目录不构建任何东西。** pi-cage 已经以多架构 manifest list 发布，这里只是它的一个部署：

```
ghcr.io/zmhhaha/pi-cage:latest
  index  sha256:897709bdb3f6a123fd3acd5da3f02f9491a217f1c0b67ab577c61dd965b868b2
  amd64  sha256:cbd3c1960ddc76d835d32afd22b2cb70be6b5ef071c2892aa0cf3cdd53ff6cd9
  arm64  sha256:b0905fa77029ad7520e6433c1462298435eb318350364b401752e11aad086e19
```

所以这里没有 `build.sh` —— 镜像由上游项目发布，这个目录消费它。

## 形态：边车，cage 保持只绑回环

```
        frpc 隧道（pi.panghuer.top）
                 │ 4180
                 ▼
   ┌──────────── Pod（同一网络命名空间）────────────┐
   │  oauth2-proxy      pi-cage                     │
   │  0.0.0.0:4180  ──▶  127.0.0.1:7681             │
   │  （Casdoor OIDC）    （serve，永不绑定可路由地址）│
   └────────────────────────────────────────────────┘
```

**同 Pod 边车是这个部署的核心论点。** oauth2-proxy 与 cage 共享网络命名空间，通过回环访问它 —— 所以 **cage 保留默认绑定 `127.0.0.1`，Pod 里不存在任何可路由的监听端口。**

这不只是好看：

- pi-cage 对外宣称的属性是"边界是容器，且没有可路由的入口"，这里**逐字成立**，没有需要加星号的例外
- **"哪些来源能访问 cage"这个问题直接消失了** —— 所以 `networkpolicies.yaml` 里没有任何针对 7681 的入站规则，也就少一条能写错的规则
- 代价是多一个容器，以及共享故障域

pi-cage 自带的 `deploy/k8s/core.yaml` 走的是**另一种**形态：绑定 `0.0.0.0`，再用 NetworkPolicy 只放行带标签的来源。那条路也实测过、也可行，但它是**用回环属性换策略属性**。这里不需要换。

**调试时要知道的后果**：cage 的端口从**任何地方**都不可达，包括同命名空间的其他 Pod。唯一直接跟 `serve` 说话的方式是 `kubectl exec` 进 Pod。这是设计，不是故障。

## 文件

| 文件 | 作用 |
|---|---|
| [`deploy.sh`](deploy.sh) | 命名空间 → ExternalSecrets → oauth 配置 → `k8s/` → 滚动 → **断言只绑回环** |
| [`k8s/storage.yaml`](k8s/storage.yaml) | 两个 PVC：`pi-home`（会话与凭据）、`pi-workspace`（代码） |
| [`k8s/core.yaml`](k8s/core.yaml) | Deployment（两个容器）+ Service（指向 4180） |
| [`k8s/networkpolicies.yaml`](k8s/networkpolicies.yaml) | default-deny + 出站（DNS、ingress-nginx、公网 443） |
| [`k8s/frpc-ingress.yaml`](k8s/frpc-ingress.yaml) | 放行 frpc → 4180 |
| [`../../oauth/k8s/pi-proxy-configmap.yaml`](../../oauth/k8s/pi-proxy-configmap.yaml) | oauth2-proxy 配置 + 邮箱白名单 |
| [`../../vault/inventory/pi-externalsecret.yaml`](../../vault/inventory/pi-externalsecret.yaml) | `pi-model`、`pi-oidc` |

## 部署

```bash
bash deploy.sh --dry-run      # 只看会做什么
bash deploy.sh                # 部署
bash deploy.sh --verify-only  # 只跑「只绑回环」的断言
```

## 还需要手工做的四件事

`deploy.sh` **会在凭据缺失时失败**：目前仍等待 `pi-model` 和 `pi-oidc` 两个 ExternalSecret Ready。
下面的 DeepSeek key 是原部署的预置模型凭据；自行配置的 `custom-llm` 使用自己的中转站密钥，
不依赖 DeepSeek key 发起请求，但这不改变现有部署脚本对 `pi-model` 的等待要求。
OIDC 凭据负责网页登录，缺失时登录流程无法完成。

**1. 写入 Vault 的两条路径**（命令写在 `vault/inventory/pi-externalsecret.yaml` 的注释里）：

```
secret/pi/model   →  DEEPSEEK_API_KEY
secret/pi/oidc    →  OAUTH2_PROXY_CLIENT_ID / _CLIENT_SECRET / _COOKIE_SECRET
```

`DEEPSEEK_API_KEY` 这个名字是从**镜像里 Pi 自己的 `docs/providers.md` 核对来的**，不是照抄本仓库的命名习惯。

**2. Casdoor 建一个应用**，回调地址填 `https://pi.panghuer.top/oauth2/callback`。不建的话 OIDC 往返在 IdP 那侧就断了。

**3. frpc 路由**：在 `frpc` 命名空间的 Secret `frpc-config` 里加一条（路由配置在 Secret 里，token 不进 git）：

```toml
[[proxies]]
name = "pi-web"
type = "http"
customDomains = ["pi.panghuer.top"]
localIP = "pi-web.pi.svc.cluster.local"
localPort = 4180
```

**4. Cloudflare 加一条 `pi.panghuer.top` 的 DNS。**

前两条是必须的，后两条只影响外部访问。`frpc` 命名空间的出站策略**已经放行了 4180**（`vps/k8s/frpc.yaml` 第 109 行），所以那侧不用改。

## 白名单

```bash
kubectl -n pi edit configmap pi-owner    # data.emails，一行一个已验证邮箱
```

**改 live 的 ConfigMap 之外也要改 `oauth/k8s/pi-proxy-configmap.yaml`**，否则下次部署会覆盖掉线上修改。

## 这个目录替换了什么

原先这里有两份文档，都已删除：

- **`README.md`（46KB）** —— 一套自建的 `pi-workbench` 部署设计：独立命名空间 `pi`、`/opt/pi`、oauth2-proxy 边车、自建镜像。**pi-cage 发布之后这套设计整体作废**，本文件取代它。
- **`server-project-research.md`（38KB）** —— 立项调研。它**把 `jmfederico/pi-web`（873★）当成了赛道在位者，漏掉了 `agegr/pi-web`（7,315★，真正的在位者），并且说"没有人做加固容器"——实际有十几个**。

那份调研的错误不是细节，是方法：它用 `sort=stars&per_page=25` 取前 25 条就当成全景，第 26 名之后的东西等于不存在。**更正后的地景、按层拆解的对照、以及"从谁身上抄什么"，现在都在 [`pi-cage/docs/prior-art.md`](https://github.com/zmhhaha/pi-cage/blob/main/docs/prior-art.md)**，并且那里顶部就记着这次更正。

不要再在这里维护第二份调研 —— **它必然与上游漂移，而上一次漂移的方式是变成假话。**
