# Obsidian 笔记同步

本目录记录 Obsidian 笔记在集群里的落地方案。目标是：**笔记存在自有集群里，在 Windows 和手机上用原生 Obsidian 编辑，同时让集群内其他服务能读到纯 Markdown。**

## 当前结论

用 **CouchDB + Self-hosted LiveSync**：

```text
Windows / 手机  Obsidian + LiveSync 插件
      │  HTTPS（Cloudflare Tunnel，域名 obsidian.panghuer.top）
      ▼
  CouchDB（StatefulSet + RBD PVC，命名空间 obsidian）    ← 权威副本
      ▲
      │  livesync-cli daemon（mirror 扫描 + _changes 增量流）
  obsidian-materializer（Deployment）
      │
      ▼
  obsidian-notes（ceph-cephfs，ReadWriteMany）  ← 纯 .md
      │
      ▼
  下游服务（只读挂载）
```

认证用 **JWT**：插件在本地用私钥签 token，CouchDB 用公钥校验，密码不过网。代价是上游明确说明 LiveSync 的请求会被当作 `_admin`，所以设备上的私钥等同于该库的管理员权限 —— 已实测证实（见下）。补偿措施是 vault 端到端加密，库里存的是密文。

⚠️ **这里的 JWT 和平台的 Casdoor JWT 是两套互不相干的东西**，只是格式同名。Casdoor 在这条链路上完全不参与，且**改配置也统一不了**（插件没有"从外部 IdP 取 token"的能力）。详见 [deployment-design.md](deployment-design.md)。

**浏览器工作台已下线**（2026-09-24）。原方案把 Obsidian 桌面版用 Selkies 串流进浏览器，实测确认它带来的是 Selkies 远程桌面而非 Obsidian 本身。见 [runtime-state.md](runtime-state.md)。

文档：[deployment-research.md](deployment-research.md)（方案比较）、[deployment-design.md](deployment-design.md)（设计细节）、[runtime-state.md](runtime-state.md)（切换前实测）、[implementation-record.md](implementation-record.md)（实现与部署记录）、[deployment-notes.md](deployment-notes.md)（**踩坑与排查手册，出问题先看这份**）、[downstream-distribution.md](downstream-distribution.md)（下游消费方怎么按 corpus 分发）。**实现规格以 OpenSpec store 为准**，change 为 `add-obsidian-livesync-workbench`（已部署）与 `add-obsidian-note-distribution`（设计中）。

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

上游不发布 `livesync-cli` 的容器镜像，所以这里从源码构建 ARM64 镜像再推私有仓库。CouchDB 用官方 `couchdb:3` 重新打标签。

**改动镜像后必须显式重启**：清单用 `:latest` + `imagePullPolicy: Always`，`kubectl apply` 不会滚动更新：

```bash
kubectl -n obsidian rollout restart statefulset/obsidian-couchdb
kubectl -n obsidian rollout restart deploy/obsidian-materializer
```

## 部署前置

1. **Vault**：`secret/obsidian/couchdb`（`COUCHDB_USER` / `COUCHDB_PASSWORD` / `jwt_keys.ini`）与 `secret/obsidian/livesync`（`SETUP_URI`）。命令写在 [obsidian-externalsecret.yaml](../../vault/inventory/obsidian-externalsecret.yaml) 的注释里。
2. **Cloudflare 后台**：见下。
3. **Setup URI**：见"接入设备"。

## Cloudflare：只有后台生效

⚠️ **隧道是远端托管模式，仓库里的路由文件和 operator 写的 ConfigMap 都不在服务链路上。**

实测（2026-09-24）：cloudflared 进程是 `cloudflared tunnel run --token eyJ...`，Pod 里**没有挂载任何 ConfigMap**（唯一卷是 ServiceAccount token），operator 也**从不调用 Cloudflare API**（`controller.py` 只 import kopf 和 kubernetes 客户端）。所以：

- [cloudflare-tunnel/operator/tunnel-routes.yaml](../../cloudflare-tunnel/operator/tunnel-routes.yaml) 里的 `obsidian` 条目是**记录**；
- operator 写的 `default/cf-tunnel-cfg-main` 也**不被读取**；
- **真正生效的是 Cloudflare 后台的 Public Hostname。**

需要在后台配置（Zero Trust → Networks → Tunnels → `main` → Public Hostnames）：

```text
obsidian.panghuer.top  ->  http://obsidian-couchdb.obsidian.svc.cluster.local:5984
```

域名复用 `obsidian.panghuer.top`：DNS 已存在，服务下线后该名字空出来，没必要另起一个只多一条记录的 `obsidian-sync`。

## 接入设备

### 第一台设备（必须手工配）

Setup URI 只能由**已配置好的设备**生成，所以第一台要手工来：

1. 装 Obsidian，装社区插件 **Self-hosted LiveSync**。
2. 新建 vault，进入插件设置 → Remote Configuration → 点 `➕` 添加 CouchDB 连接。
3. **JWT 配置收在对话框的 `Experimental Settings` 折叠区里，需要点开。** 它不在默认展开的字段中（`Advanced Settings` 也一并看一眼）。上游把 JWT 认证归为 Beta/experimental，因此默认收起 —— 默认可见的只有 URL / 用户名 / 密码 / 数据库名称 / Use Internal API 这几项。

   展开后按此填写：

   | 设置项 | 值 |
   | --- | --- |
   | **Use JWT Authentication** | 开启 |
   | JWT Algorithm | `ES512` |
   | JWT Key | 私钥 PEM 全文（PKCS#8） |
   | JWT Key ID (kid) | `obsidian` |
   | JWT Subject (sub) | `obsidian` |

   `kid` 必须与 [k8s/couchdb-config.yaml](k8s/couchdb-config.yaml) 里 `jwt_keys` 的 key id 一致。开启 JWT 后，上面的用户名/密码留空即可。

4. 设端到端加密口令（自己定，别和别处复用）。
5. 让插件检查/创建服务端库（JWT 有 `_admin`，建库没问题）。

   ⚠️ **插件自带的"检查服务器配置"会报若干误报**，不要照单全收。它读 `_config`，把"未显式设置"一律当成"设置错误"（看不见本就正确的内置默认值），而且有几个键名停留在 CouchDB 2.x。逐条判读见 [implementation-record.md](implementation-record.md) 的"插件检查报告的判读"。
6. **生成 Setup URI**（插件设置里有复制/二维码入口），贴进 Vault：

   ```bash
   kubectl -n vault exec -i vault-0 -- vault kv put secret/obsidian/livesync SETUP_URI='obsidian://setuplivesync?...'
   ```

   ⚠️ Setup URI 里含端到端加密口令，是整个方案最敏感的值。只经 Vault 和私密渠道传递，不要贴进聊天记录或工单。

7. 部署物化负载：

   ```bash
   kubectl apply -f panghu_chat/obsidian/k8s/materializer.yaml
   ```

   它会从 Setup URI 自行完成 `init-settings` + `setup`，然后转入持续同步。

### 其余设备

导入同一个 Setup URI 即可。vault 口令与 Setup URI 口令必须不同，且不要经同一渠道传递。

## 公私钥轮换

**用"直接替换"，不要用"新旧并存"。**

两种做法都可行，取舍是明确的：

| | 直接替换（本文采用） | 新旧并存 |
| --- | --- | --- |
| 钥匙数量 | 一把、一个 kid | 两把、两个 kid |
| 迁移 | 一次性切换 | 逐台设备迁移，迁完再撤旧的 |
| 停机 | **有一小段**：切换时所有消费方都连不上 | 无 |
| 出错面 | 小 | 大 —— 每台设备的 `kid` 都要跟着改，改错就是 `Bad signature` |

我们选替换，因为消费方只有两个（设备 + 物化负载），而并存那套的 `kid` 记账**实际已经导致过一次故障**：设备换上了新私钥却仍发 `kid=obsidian`，CouchDB 拿旧公钥验新签名，一路 400。

### 步骤

关键点：**`kid` 不变，始终是 `obsidian`。** 替换的是 `ec:obsidian` 这把锁的**钥匙**，不是它的**名字**。

```bash
cd /root/obsidian-jwt

# 1. 生成新密钥对
openssl ecparam -name secp521r1 -genkey -noout | openssl pkcs8 -topk8 -inform PEM -nocrypt -out private_key.pem
openssl ec -in private_key.pem -pubout -outform PEM -out public_key.pem

# 2. 用新公钥覆盖 ec:obsidian 的值，只留这一行（删掉可能存在的 ec:obsidian2）
cp jwt_keys.ini jwt_keys.ini.before-single      # 留个回滚副本
{ echo '[jwt_keys]'
  printf 'ec:obsidian = '
  sed -e 's/$/\\n/' public_key.pem | tr -d '\n'
  echo
} > jwt_keys.ini

# 3. 写进 Vault，强制同步，重建 Pod
kubectl -n vault exec -i vault-0 -- vault kv patch secret/obsidian/couchdb jwt_keys.ini=- < jwt_keys.ini
kubectl -n obsidian annotate externalsecret obsidian-couchdb force-sync=$(date +%s) --overwrite
kubectl -n obsidian rollout restart statefulset/obsidian-couchdb

# 4. 设备：把 JWT Key 换成新私钥，kid 保持 obsidian 不动
# 5. 物化负载：设备恢复后重新生成 Setup URI，更新 secret/obsidian/livesync
#    kubectl -n vault exec -i vault-0 -- vault kv patch secret/obsidian/livesync SETUP_URI='obsidian://...'
#    kubectl -n obsidian rollout restart deploy/obsidian-materializer
```

**第 3 步之后、第 4/5 步之前，所有消费方都连不上** —— 服务端只认新公钥了。所以 3、4 要连着做。物化负载可以先 `scale --replicas=0`，免得空转刷错误日志。

第 5 步**必须在第 4 步之后**：设备不通就生成不出新的 Setup URI。

### 两条判据

- **公钥必须压成一行、换行写成字面 `\n`。** CouchDB 的 ini 解析器只取该行剩余部分；真实换行会让公钥被静默截断到第一行，文件看着正常、CouchDB 不报错、但**所有 JWT 都会验签失败**（详见 [deployment-notes.md](deployment-notes.md) 的 B6）。
- **配置由 initContainer 在 Pod 启动时拷贝**，所以改完必须重启 StatefulSet，光更新 Secret 不生效。

### 怎么确认换对了

服务端直接验，不要靠猜（`<CID>` 换成 Service 的 ClusterIP）：

```bash
# 新私钥 + kid=obsidian 应返回 200；旧私钥应返回 400 Bad signature
```

判据是响应码：**400 + `user=undefined`** 意味着"签名坏了"（kid 对不上或钥匙不匹配），而不是"没带凭据"。这条在排障时比日志里任何一行都有用。

### 收尾

全部切换完成后，服务器上删掉旧密钥对（`private_key.pem` / `public_key.pem`）和 `jwt_keys.ini.before-single`。**确认新钥匙生效之后再删。**

私钥是**设备侧**的东西：不要进 Vault、不要进 Git、分发完就该从服务器删掉。

## 下游读取

下游服务把 `obsidian-notes` PVC **只读**挂载即可，里面是直接的 `.md`。

物化负载是这块卷的**唯一写入者**。注意 `livesync-cli` 的同步是双向的 —— 只读挂载不是可选的优化，是正确性要求：拿到写权限的下游可能把自己的改动推回 CouchDB。
