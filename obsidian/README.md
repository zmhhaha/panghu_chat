# Obsidian 笔记同步

本目录记录 Obsidian 笔记在集群里的落地方案。目标是：**笔记存在自有集群里，在 Windows 和手机上用原生 Obsidian 编辑，同时让集群内其他服务能读到纯 Markdown。**

## 当前结论

用 **CouchDB + Self-hosted LiveSync**：

```text
Windows / 手机  Obsidian + LiveSync 插件
      │  HTTPS（Cloudflare Tunnel）
      ▼
  CouchDB（StatefulSet + RBD PVC，命名空间 obsidian）    ← 权威副本
      ▲
      │  livesync-cli sync + mirror
  obsidian-materializer（Deployment，跑 CLI 的 daemon 模式）
      │
      ▼
  obsidian-notes（ceph-cephfs，ReadWriteMany）  ← 纯 .md
      │
      ▼
  下游服务（只读挂载）
```

认证用 **JWT**：插件在本地用私钥签 token，CouchDB 用公钥校验，密码不过网。代价是上游明确说明 LiveSync 的请求会被当作 `_admin`，所以设备上的私钥等同于该库的管理员权限 —— 补偿措施是 vault 端到端加密，库里存的是密文。

**浏览器工作台已废弃。** 原方案是把 Obsidian 桌面版用 Selkies 串流进浏览器，实测确认它带来的是 Selkies 远程桌面而非 Obsidian 本身，且 Vault 落错了 PVC。详见[运行时现状核对](runtime-state.md)。

文档见 [deployment-research.md](deployment-research.md)（方案比较）、[deployment-design.md](deployment-design.md)（设计细节）、[runtime-state.md](runtime-state.md)（切换前的实测证据）和 [implementation-record.md](implementation-record.md)（本次实现记录：已完成什么、验证证据、未完成项）。**实现规格以 OpenSpec store 为准**，change 为 `add-obsidian-livesync-workbench`。

## 清单

应用清单位于 `k8s/`，ExternalSecret 位于主仓库的 [vault/inventory/obsidian-externalsecret.yaml](../../vault/inventory/obsidian-externalsecret.yaml)。部署需要完整的 `armbianbegin` 检出（含 `panghu_chat` 子模块）：

```text
namespace.yaml
couchdb-config.yaml
storage.yaml
../../vault/inventory/obsidian-externalsecret.yaml
couchdb.yaml
materializer.yaml
```

Cloudflare 路由记录放在 [cloudflare-tunnel/operator/tunnel-routes.yaml](../../cloudflare-tunnel/operator/tunnel-routes.yaml)，条目是待配置记录，不代表公网已开通。

## 构建与部署

```bash
bash build.sh
bash deploy.sh --dry-run
bash deploy.sh
```

`build.sh` 需要 `LIVESYNC_REF` —— 上游的完整 commit SHA，放在未提交的 `build.local.env` 里：

```bash
LIVESYNC_REF=$(git ls-remote https://github.com/vrtmrz/obsidian-livesync.git refs/heads/main | cut -f1)
```

上游不发布 `livesync-cli` 的容器镜像，所以这里从源码在集群外构建 ARM64 镜像再推私有仓库。CouchDB 用官方 `couchdb:3` 重新打标签。

## 部署前必须准备

1. **Vault 密钥**（脚本不会代做）：
   - `secret/obsidian/couchdb` → `COUCHDB_USER`、`COUCHDB_PASSWORD`
   - `secret/obsidian/livesync` → `SETUP_URI`（见下）
   具体命令写在 [obsidian-externalsecret.yaml](../../vault/inventory/obsidian-externalsecret.yaml) 的注释里。
2. **JWT 密钥对**，公钥填进 [k8s/couchdb-config.yaml](k8s/couchdb-config.yaml) 替换 `REPLACE_WITH_PUBLIC_KEY_PEM`。`deploy.sh` 会检查这个占位符，没换会直接拒绝部署。私钥给每台设备的插件，绝不入库。
3. **Cloudflare**：新增 `obsidian-sync.panghuer.top` → `http://obsidian-couchdb.obsidian.svc.cluster.local:5984`，并**删除**已废弃的 `obsidian.panghuer.top`。

## 接入设备

在第一台设备上装 LiveSync 插件、配好连接和端到端加密口令，然后由它生成 **Setup URI**。把该 URI 放进 `secret/obsidian/livesync` 的 `SETUP_URI`，物化负载首次运行时会自动用它配置自己；其余设备导入同一个 URI 即可。

⚠️ Setup URI 里含端到端加密口令，是整个方案里最敏感的值。它只存在于 Vault、设备，以及物化 Pod 的挂载文件里；不要走环境变量（会出现在进程列表），不要贴进聊天记录。

## 下游读取

下游服务把 `obsidian-notes` PVC **只读**挂载即可，里面是直接的 `.md`。

物化负载是这块卷的**唯一写入者**。注意 `livesync-cli mirror` 是双向的 —— 只读挂载不是可选的优化，是正确性要求。
