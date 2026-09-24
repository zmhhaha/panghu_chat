# Obsidian 笔记同步设计

日期：2026-09-24
状态：设计中。**实现规格以 OpenSpec change `add-obsidian-livesync-workbench` 为准**，本文件是过程材料与理由记录，不是规格。

## 第一版范围

- `obsidian` 命名空间里一个单副本 CouchDB，保存权威副本；
- 一个物化负载（CronJob），把 CouchDB 内容落成纯 Markdown 到共享卷；
- 各设备用原生 Obsidian + Self-hosted LiveSync 插件同步；
- vault 端到端加密；
- 一个下游可只读挂载的 `ReadWriteMany` 卷。

第一版不包含浏览器入口、多用户、公开发布站点。

## 为什么不串流桌面

Obsidian 没有官方网页版。`linuxserver/obsidian` 的做法是把 Linux 桌面应用跑在一个虚拟 Wayland 桌面（`labwc`）里，再用 Selkies 把**整个桌面**串流到浏览器。

实测（[runtime-state.md](runtime-state.md)）确认代价：浏览器里看到的是 Selkies 的串流外壳而非 Obsidian，串流层会先截获 `Ctrl+Shift+M` / `Ctrl+Shift+F` 这类快捷键；同时桌面串流的资源占用和攻击面都远大于一个同步后端。

在设备上跑原生 Obsidian 直接消掉这一层，也顺带消掉了 vault 位置问题 —— 设备持有自己的本地 vault，CouchDB 只是副本，不再是一个挂载点。

## 权威副本：CouchDB

单副本、单用户。Ceph RBD 的 `ReadWriteOnce` 足够，它不需要 CephFS。

CouchDB 只在集群内可达，公网只经 Cloudflare Tunnel。上游明确不建议把 CouchDB 挂在反向代理的根目录，所以用独立主机名。

**CORS 必须配**。插件是在 Obsidian 自己的 origin 里发请求的，没有 CORS 会在认证之前就失败。

## 为什么用 CephFS 而不是 Ceph RBD

需求是"集群里其他服务能读笔记"。`ceph-rbd` 是 `ReadWriteOnce`，同一时刻只能挂到一个节点，调度到别的节点的消费者根本挂不上。集群里已有 `ceph-cephfs`，提供 `ReadWriteMany`。

这正是上一版设计自己写下的触发条件："只有在多个 Pod 或其他工作负载需要同时挂载 Vault 时，才需要评估 CephFS / ReadWriteMany"。条件现在成立了。

已于 2026-09-23 实测：`arm-cluster-master` 上的 Pod 写入文件，`orangepi5-max-server1` 上的 Pod 同时挂载同一 claim 并读到。CouchDB 自己不需要，继续用 RBD。

## 服务端物化

Self-hosted LiveSync 把笔记以插件自己的**分块文档格式**存在 CouchDB 里，别的服务读不了。所以把下游直接指向 CouchDB 不满足需求。

上游 CLI 补上了这一环：

> `mirror [vault-path]`: Bidirectional sync between the local database and a local directory (**the actual vault**).

所以物化负载先 `sync` 从远端 CouchDB 复制，再 `mirror` 把真实 `.md` 写进共享卷。

**`mirror` 是双向的**。这一点只有在"物化负载是唯一写入者、所有下游只读挂载"的前提下才成立。不要因为以为 `mirror` 是单向的，就给下游写权限。

调度上跑 CLI 的 **`daemon`** 模式（它是 CLI 的默认命令）：先做一次 mirror 扫描，之后跟随 CouchDB 的 `_changes` 流持续同步。选它而不是"CronJob 定时跑 `sync` + `mirror`"，因为它是上游的主线用法（README 自己的第一个例子就是它），并且直接消掉了轮询延迟，而不是拿延迟换调度频率。失败表现为 Pod 重启，不是卡住的调度。

已知缺口：**没有 liveness 探针**。容器里唯一的进程就是 daemon（用 `exec` 启动），所以进程死了容器就死了，kubelet 本来就会重启它。探针真正该发现的失败模式是"进程活着但卡住"，而它发现不了 —— 所以不假装有覆盖。笔记不再出现时，看 `kubectl -n obsidian logs deploy/obsidian-materializer` 和重启次数。

## 凭据与内容边界

HashiCorp Vault 只保存 CouchDB 侧凭据，以及物化解密所需的 vault 口令，即：

```text
secret/obsidian/couchdb
  COUCHDB_USER
  COUCHDB_PASSWORD
secret/obsidian/livesync
  SETUP_URI        # 含端到端加密口令
```

Vault 里**绝不**放 Markdown、附件或 `.obsidian` 状态。

端到端加密口令本身不是服务端机密：设备持有它，而物化负载为了解密也必须持有 —— 那是它在设备之外唯一存在的地方。把物化负载的那份当一等机密对待，并把它的可读范围限制到只有它自己和设备。

端到端加密是暴露 CouchDB 的补偿措施：即使数据库或备份被拿走，没有口令也读不出笔记。

## 认证：JWT

CouchDB 侧配置 `chttpd/authentication_handlers` 包含 `{chttpd_auth, jwt_authentication_handler}`、`jwt_auth/required_claims = exp`，公钥以 PEM SPKI 放在 `jwt_keys/ec:<key_id>`。插件持有 PKCS#8 私钥，本地签 token。

用 ES512（`secp521r1`）生成密钥对；上游推荐非对称算法而非 HMAC，正因为共享密钥会从设备上泄露。

**接受的限制**：上游说明 LiveSync 总会把 `_couchdb.roles` 设为 `["_admin"]`，所以持有私钥的设备对同步库有管理员权限。不要把 JWT 当作降权手段 —— 它的作用是让共享密码不再过网。限制这份管理员权限能拿到什么的，是端到端加密。

设备丢失的吊销路径是换密钥对：生成新对 → 以新 key id 加入 CouchDB → 重新接入其余设备 → 移除旧 key id。

**CouchDB 前面没有 oauth2-proxy。** 那套是浏览器 OIDC 跳转，插件的原始 HTTP 请求会被 302 掉而不是被认证。这是平台里唯一不被 Casdoor 白名单覆盖的入口，由 JWT + 端到端加密替代。

### ⚠️ 此 JWT 与平台的 Casdoor JWT 无关

两处都叫 "JWT"，但只是**格式同名**，信任链完全不同：

| | Casdoor JWT（oauth2-proxy / openspec） | 此处（Obsidian → CouchDB） |
| --- | --- | --- |
| 谁签发 | Casdoor | **设备上的插件自己签** |
| 公钥从哪来 | 动态，取 Casdoor 的 JWKS 端点 | 静态，手抄进 `jwt_keys/ec:obsidian` |
| 校验什么 | 签名 + `iss` + `aud` | 签名 + `exp`，没有 iss/aud 概念 |
| 吊销 | Casdoor 账号 / 会话 | 换密钥对 |

`openspec_service/src/auth.mjs` 用 `jose` 的 `createRemoteJWKSet` 取 Casdoor 的 JWKS 并校验 `issuer`/`audience`；oauth2-proxy 走 `oidc_issuer_url`。两者都是 Casdoor 签发的，是同一套。本节讲的是**第三套、独立的**一套。

**两者无法靠配置统一。** CouchDB 侧理论上可以指向 Casdoor 的公钥，但 LiveSync 插件没有"从外部 IdP 取 token"的模式 —— 它的 JWT 设置就是"本地私钥 + 算法 + kid + sub"，拿不到 Casdoor 签的 token。所以这条路径**在设计上就绕过了平台的统一身份**，端到端加密因此是必需而非可选的补偿控制。若将来"不得使用绕过统一身份的凭据"成为硬要求，出路是让 CouchDB 完全不暴露公网、改走 VPN，而不是把 Casdoor 接进来。

通过 Fauxton 而非配置文件配置时，公钥里的换行必须转义成 `\n`；上游把这点标为不直观的要求。

## 设备接入

用上游的 Setup URI 流程：配好第一台设备 → 由它生成 Setup URI → 其余设备导入。vault 口令与 Setup URI 口令必须不同，且不要经同一渠道传递。

## 下线浏览器工作台

删掉 Deployment、Service 和 oauth2-proxy 配置**并不够**。Cloudflare 后台那条 Public Hostname 才是真正在服务流量的东西，必须一并删除，否则废弃域名仍然可达。仓库里的路由记录只是记录。

`obsidian-config` 与 `obsidian-vault` 两块旧 PVC 会闲置。删之前先看内容 —— 前者里躺着误建的 `/config/Obsidian Vault`。

## 未验证项

以下都还没有证据，在验证之前不要基于它们下结论：

- ✅ CouchDB ARM64 镜像可用 —— 已验证（2026-09-23，`couchdb:3` 即 3.5.2.1，`arm64 linux`）。
- ✅ `ceph-cephfs` 跨节点 `ReadWriteMany` —— 已验证（2026-09-23）。
- ⏳ `livesync-cli` 的 ARM64 构建 —— **已验证（2026-09-23）**。镜像 289MB、`arm64 linux`，CLI 能启动并打印帮助。上游不发布该 CLI 的镜像，只能自建。过程中踩到两个坑，都已在 [livesync-cli/Dockerfile](livesync-cli/Dockerfile) 内处理：`deb.debian.org` 从本网络会把构建卡死（实测 30 秒零进度），改用 USTC 源，跟随 [dsh/Dockerfile](../dsh/Dockerfile) 的既有约定；上游 Dockerfile 的 `COPY --chmod` 需要 BuildKit，而集群 daemon 用的是 legacy builder，改为单独的 `RUN chmod`。
- ⏳ CouchDB 容器的安全上下文 —— entrypoint 需要 uid 0 做 chown、写 `local.d/docker.ini`，再用 `setpriv` 降权，所以既不能设 `runAsNonRoot`，也不能 `drop: ALL`。清单里补回了 `CHOWN`/`SETUID`/`SETGID`/`DAC_OVERRIDE`/`FOWNER` 五个能力，**首次部署时验证是否够用**。
- ⏳ 物化负载以非 root（uid 1000）写 CephFS 卷 —— CephFS CSI 对 fsGroup 的支持未在本集群验证过。
- ⏳ 插件与 CLI 的版本对应关系。

## 迁移

当前 vault 里只有 `欢迎.md` 和一个默认 `.obsidian` 目录，几乎没有内容要迁。第一台设备在本地建 vault 后推到 CouchDB 即可。

不要复用现有的 `.obsidian` 桌面状态：那是被串流的容器生成的，对原生安装没有参考价值。
