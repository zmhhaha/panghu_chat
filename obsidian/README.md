# Obsidian 服务设计

本目录记录 Obsidian 在当前 Kubernetes 平台中的部署调研与设计。当前目标是提供一个通过浏览器访问的个人 Obsidian 工作台，供平台内服务后续读取知识文件。

## 文档

- [部署调研](deployment-research.md)：目标、方案比较和现有平台的适配性。
- [部署设计](deployment-design.md)：第一版组件、权限、存储和后续扩展边界。

## 当前结论

第一版部署 `linuxserver/obsidian`，通过现有 Cloudflare Tunnel 和 oauth2-proxy 对外提供访问。oauth2-proxy 使用 Casdoor OIDC，并通过 `authenticated_emails_file` 只允许指定邮箱登录。

Obsidian Vault 的知识内容保存在工作负载挂载的 PVC 中。HashiCorp Vault 只用于保存 OIDC client secret、cookie secret 等敏感配置，不保存 Markdown、附件或 Obsidian 配置文件。

第一版暂不部署 CouchDB、Self-hosted LiveSync、RAG 同步器和公开发布站点。

## 清单

应用清单位于 `k8s/`，ExternalSecret 统一位于主仓库的 [vault/inventory/obsidian-externalsecret.yaml](../../vault/inventory/obsidian-externalsecret.yaml)。部署需要完整的 `armbianbegin` 检出（含 `panghu_chat` 子模块），按以下顺序应用：

```text
namespace.yaml
../../oauth/k8s/obsidian-proxy-configmap.yaml
storage.yaml
../../vault/inventory/obsidian-externalsecret.yaml
deployment.yaml
service.yaml
```

OAuth 配置与邮箱白名单统一放在 [oauth/k8s/obsidian-proxy-configmap.yaml](../../oauth/k8s/obsidian-proxy-configmap.yaml)，资源仍属于 `obsidian` 命名空间，代理仍为应用 Pod 内的 sidecar。

Cloudflare 路由记录放在 [cloudflare-tunnel/operator/tunnel-routes.yaml](../../cloudflare-tunnel/operator/tunnel-routes.yaml)。Obsidian 条目是待配置记录，不代表公网已开通；按 [Tunnel 说明](../../cloudflare-tunnel/README.md)，需在后台设置 Public Hostname 指向 `http://obsidian.obsidian.svc.cluster.local:4180`。部署脚本不会应用整份共享路由文件。

构建并发布 ARM64 镜像：

```bash
bash build.sh
```

预览部署顺序或实际部署：

```bash
bash deploy.sh --dry-run
bash deploy.sh
```

脚本默认使用 `arm-cluster-master:5000` 私有仓库，也可以在未提交的 `build.local.env` 中设置 `REGISTRY` 和 `UPSTREAM_IMAGE`。

部署前需要先准备：

- 私有镜像仓库中的 `arm-cluster-master:5000/linuxserver/obsidian:latest`；
- HashiCorp Vault 中的 `secret/obsidian/oidc`；
- Cloudflare 后台的 `obsidian.panghuer.top` Public Hostname，指向 `obsidian.obsidian.svc.cluster.local:4180`。

当前清单使用单副本和 `Recreate` 策略，适合 RWO PVC。容器内使用 LinuxServer 的 HTTP 3000 端口，由 Cloudflare Tunnel 提供公网 HTTPS；`deployment.yaml` 中的 Vault 挂载位置是 `/config/obsidian-vault`，首次启动后需要在 Obsidian 界面中选择该目录作为 Vault。
