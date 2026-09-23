# Obsidian 部署设计

日期：2026-09-23

## 第一版范围

第一版只提供单用户浏览器工作台：

- 一个 `obsidian` 命名空间；
- 一个 `linuxserver/obsidian` Deployment，单副本；
- 一个保存 `/config` 和 Vault 的持久化存储方案；
- 一个只允许指定邮箱的 oauth2-proxy；
- 一个通过 Cloudflare Tunnel 对外提供的域名，例如 `obsidian.panghuer.top`。

第一版不包含 CouchDB、LiveSync、RAG 自动索引、公开发布和多人协作。

## 请求路径

```text
https://obsidian.panghuer.top
  -> Cloudflare Tunnel
  -> obsidian.obsidian.svc.cluster.local:4180
  -> linuxserver/obsidian（同一 Pod 的 HTTP 3000 端口）
```

Cloudflare Tunnel 的 Public Hostname 由 Cloudflare 后台配置，仓库中的路由文件只作为部署记录，遵循现有 Tunnel 约定。

## 认证设计

认证方式复用 DSH 和 Hermes 的模式：

- OIDC issuer 使用 `https://auth.panghuer.top`；
- oauth2-proxy 使用 `authenticated_emails_file = "/owner/emails"`；
- `obsidian-owner` ConfigMap 每行保存一个允许访问的已验证邮箱；
- 使用独立 Cookie 名称 `__Host-obsidian`；
- 不设置 cookie domain；
- 开启 `cookie_secure`、`cookie_samesite = "lax"` 和 `proxy_websockets = true`；
- oauth2-proxy 与 Obsidian UI 使用同一 Pod，Cloudflare Tunnel 只指向 oauth2-proxy 的 4180 端口，避免后端被绕过。

示意配置：

```toml
http_address = "0.0.0.0:4180"
provider = "oidc"
oidc_issuer_url = "https://auth.panghuer.top"
redirect_url = "https://obsidian.panghuer.top/oauth2/callback"
upstreams = ["http://127.0.0.1:3000/"]
authenticated_emails_file = "/owner/emails"
scope = "openid email profile"
cookie_name = "__Host-obsidian"
cookie_path = "/"
cookie_secure = true
cookie_samesite = "lax"
proxy_websockets = true
skip_provider_button = true
```

邮箱白名单放在 ConfigMap：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: obsidian-owner
  namespace: obsidian
data:
  emails: |
    zmh_haha@163.com
```

白名单为空时应默认拒绝所有用户。增加或删除邮箱后，按照 DSH/Hermes 的做法等待挂载文件刷新；删除用户不会立即断开已经建立的浏览器会话，因此 cookie 过期时间仍需保持有限。

## Secret 与知识内容的边界

HashiCorp Vault 只保存敏感配置，例如：

```text
secret/obsidian/oauth
  OAUTH2_PROXY_CLIENT_ID
  OAUTH2_PROXY_CLIENT_SECRET
  OAUTH2_PROXY_COOKIE_SECRET
```

ExternalSecret 将这些字段同步到 `obsidian` 命名空间的 Kubernetes Secret。邮箱白名单和其他非敏感参数放在 ConfigMap。

Obsidian 的 Markdown、附件、插件、`.obsidian` 配置和应用状态全部保存在 PVC 中。它们不能写入 HashiCorp Vault，也不能通过 Secret 或 ConfigMap 管理。

## 存储设计

第一版使用单副本和 `ceph-rbd` 的 `ReadWriteOnce` PVC，建议分开管理：

- `obsidian-config`：挂载到 `/config`；
- `obsidian-vault`：挂载到用户实际打开的 Vault 目录。

分开 PVC 可以让应用状态和知识内容分别备份、迁移和恢复。具体 Vault 路径需要以镜像启动后的默认用户目录和 Obsidian 启动参数为准，在清单定稿前做一次容器内验证。

第一版只允许 Obsidian UI 写入 Vault。未来其他服务读取时，优先采用只读挂载或显式导出；不要一开始就让多个服务共享写权限。

## 工作负载边界

建议：

- 禁止自动挂载 Kubernetes ServiceAccount token；
- oauth2-proxy 使用非 root 用户运行并删除 Linux capabilities；
- Obsidian 主容器保留 LinuxServer 镜像启动脚本所需的初始化权限；
- 为 `/config` 和 Vault 设置资源与临时存储限制；
- Service 使用 ClusterIP，不创建公开 LoadBalancer；
- 通过 NetworkPolicy 限制入口只来自 Cloudflare Tunnel / oauth2-proxy 路径（待集群网络策略能力验证后启用）；
- 禁止把 HashiCorp Vault、Kubernetes API 或其他平台 Secret 挂载到 Obsidian 容器。

由于远程桌面容器的终端能力较强，认证、网络边界和容器权限需要同时成立，不能只依赖邮箱白名单。LinuxServer 镜像的初始化过程需要调整应用文件和 nginx 运行目录，不能对主容器强行使用 `drop: ALL`。

## 部署顺序

1. 创建 `obsidian` namespace。
2. 创建 `obsidian-owner` 和 oauth2-proxy ConfigMap。
3. 创建 Vault 中的 OAuth 凭据和对应 ExternalSecret。
4. 创建两个 PVC。
5. 部署 Obsidian UI 与 oauth2-proxy。
6. 创建内部 Service，并配置 Cloudflare Public Hostname。
7. 使用允许的 Casdoor 账户验证登录、WebSocket、读写 Vault 和 Pod 重启后的数据持久化。
8. 备份并恢复一份测试 Vault 后，再投入真实内容。

## 验收条件

- 未在邮箱白名单中的 Casdoor 用户无法进入 Obsidian；
- 允许的用户可以完成 OIDC 登录和浏览器 GUI 连接；
- 直接访问 Obsidian ClusterIP 不会形成公网入口；
- Obsidian 重启后 Vault 内容仍然存在；
- Pod 重建后 `/config` 和 Vault 都能恢复；
- OAuth secret 不出现在 ConfigMap、日志或 Git 明文中；
- HashiCorp Vault 中不存在 Markdown、附件或 `.obsidian` 文件；
- 没有启用 CouchDB、LiveSync 或其他第二套同步机制。

## 实际部署记录（2026-09-23）

已在 `192.168.137.101` 集群完成启动验证：

- `obsidian` Pod 最终达到 `2/2 Running`；
- `obsidian` Service 获得 Pod endpoint `:4180`；
- `obsidian.panghuer.top` 经 Cloudflare Tunnel 返回 `302`，正确跳转到 Casdoor 登录；
- oauth2-proxy 日志确认上游为 `http://127.0.0.1:3000/`；
- Obsidian 容器使用 LinuxServer 镜像默认初始化权限，不能对主容器设置 `drop: ALL`，否则 nginx 无法执行所需的 `chown`；
- oauth2-proxy 仍保持非 root、禁止提权和删除 capabilities。

曾出现的启动问题已记录为部署经验：3001 是 LinuxServer 的 HTTPS 端口，未提供证书时会失败；HTTP 工作端口应使用 3000。主容器过度收紧 capabilities 会导致 `/var/lib/nginx/body` 权限初始化失败。

当前已验证到认证入口和工作负载就绪，登录后的完整桌面操作、Vault 内容恢复和备份恢复仍需单独验收。
