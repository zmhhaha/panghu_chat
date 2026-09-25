# Obsidian 笔记同步：实现记录

日期：2026-09-24
范围：从 Selkies 浏览器工作台切换到 CouchDB + Self-hosted LiveSync 的**代码与清单**。
状态：**仓库侧完成，未部署**。下面每条"已完成"都指仓库内容已写好并通过本地校验，不代表集群里已经跑起来。

设计与规格见 [deployment-design.md](deployment-design.md) 与 OpenSpec change `add-obsidian-livesync-workbench`。本次改动的起因见 [runtime-state.md](runtime-state.md)。

## 已完成

| 内容 | 位置 |
| --- | --- |
| CouchDB 配置（CORS、JWT 认证处理器、`jwt_keys`） | [k8s/couchdb-config.yaml](k8s/couchdb-config.yaml) |
| CouchDB StatefulSet + ClusterIP Service | [k8s/couchdb.yaml](k8s/couchdb.yaml) |
| 物化负载（CLI `daemon` 模式的 Deployment） | [k8s/materializer.yaml](k8s/materializer.yaml) |
| 三块 PVC：CouchDB（RBD）、物化输出（CephFS RWX）、同步缓存（RBD） | [k8s/storage.yaml](k8s/storage.yaml) |
| 两个 ExternalSecret：CouchDB 凭据、Setup URI | [../../vault/inventory/obsidian-externalsecret.yaml](../../vault/inventory/obsidian-externalsecret.yaml) |
| `livesync-cli` 的 ARM64 Dockerfile | [livesync-cli/Dockerfile](livesync-cli/Dockerfile) |
| 构建脚本（含 `LIVESYNC_REF` 强制为完整 SHA 的校验） | [build.sh](build.sh) |
| 部署脚本（含 JWT 公钥占位符的硬性拒绝） | [deploy.sh](deploy.sh) |
| Cloudflare 路由改为 `obsidian-sync.panghuer.top` → CouchDB | [../../cloudflare-tunnel/operator/tunnel-routes.yaml](../../cloudflare-tunnel/operator/tunnel-routes.yaml) |
| 文档改写：README、设计、调研更正 | 本目录 |
| 删除：Selkies Deployment / Service、oauth2-proxy ConfigMap | — |

全部清单通过 `kubectl apply --dry-run=client`（逐份校验，2026-09-23）。

## 验证证据

三项前置验证全部在本集群实测通过，**没有在集群里留下任何资源**（验证用的临时命名空间已删除）。

**1. CouchDB 的 ARM64 镜像** —— 通过

```text
docker pull --platform linux/arm64 couchdb:3
docker image inspect couchdb:3  →  arm64 linux   (COUCHDB_VERSION=3.5.2.1)
manifest digest: sha256:8cf5f8442585c346d2717ff0ad95605731d2f19f67b8367840baa8d3b24ebc31
```

**2. `ceph-cephfs` 跨节点 `ReadWriteMany`** —— 通过

临时命名空间里两个 Pod 同时挂载同一 claim：`rwx-a` 在 `arm-cluster-master` 写 `from-a.txt`，`rwx-b` 在 `orangepi5-max-server1` 读回 `hello-from-a`。

**3. `livesync-cli` 的 ARM64 构建** —— 通过

镜像 289MB、`arm64 linux`，`docker run --rm livesync-cli:test --help` 正常输出命令表。上游不发布该 CLI 的容器镜像，只能自建。

## 构建期发现并修正的问题

**（1）`deb.debian.org` 会把构建卡死。** 上游 Dockerfile 直接用默认 Debian 源，实测 apt 下载在 30 秒内零进度。改用 USTC 源后 apt 秒过、`npm install` 14 秒装完 774 个包。跟随 [dsh/Dockerfile](../dsh/Dockerfile) 的既有约定，已写进 Dockerfile。

**（2）`COPY --chmod` 需要 BuildKit，而集群 daemon 用 legacy builder。** 构建跑到 Step 24/27 才失败。改为 `COPY` + 单独的 `RUN chmod 755`，不依赖 builder 类型。

**（3）CouchDB entrypoint 的两个陷阱**（读 `couchdb:3` 的 `docker-entrypoint.sh` 确认）：

- 它在 uid 0 时把 `COUCHDB_USER` / `COUCHDB_PASSWORD` 追加写入 `/opt/couchdb/etc/local.d/docker.ini`。**把 ConfigMap 整目录挂到 `local.d/` 会让这个写入失败**，随后它在 ini 里找不到 admin 就直接退出。清单改用 subPath 只挂单个文件，目录本身保持可写。
- 它写完 admin 后用 `setpriv --reuid=couchdb --regid=couchdb` 降权。**`drop: ALL` 会让 `setpriv` 失败**（需要 `SETUID`/`SETGID`）。清单补回了 `CHOWN`、`SETUID`、`SETGID`、`DAC_OVERRIDE`、`FOWNER` 五个能力，并在 manifest 里写明了为什么。

这一条与之前 Selkies 那次"权限收太紧导致镜像起不来"是同一类问题，这次在写清单前就从镜像源码里查出来了。

## 设计修正：物化负载改用 CLI 的 `daemon`

验证 CLI 时发现 **`daemon` 是它的默认命令**：先做一次 mirror 扫描，之后跟随 CouchDB 的 `_changes` 流持续同步。

原计划是 CronJob 定时跑 `sync` + `mirror`。`daemon` 更贴合，是上游主线用法（README 的第一个例子就是它），且直接消掉轮询延迟。因此改为跑 daemon 的 Deployment，`Recreate` 策略（缓存卷是 RWO）。

代价已记入设计：**没有 liveness 探针能发现"进程活着但卡住"** —— 容器里唯一进程就是 daemon（`exec` 启动），进程死容器就死，kubelet 本来就会重启。不假装探针覆盖了这个失败模式。

## 未完成

**部署**（按分工由所有者执行）：所有 `tasks.md` 里未勾的项，从"准备 Vault 两个 secret 与 JWT 密钥对"开始。

**尚存未知**，部署时才会暴露：

- 物化负载以非 root（uid 1000）能否写入 CephFS 卷 —— CephFS CSI 对 fsGroup 的支持在本集群未验证过。
- subPath 挂载下，entrypoint 写 `local.d/docker.ini` 的路径能否正常工作。
- 插件与 CLI 的版本对应关系（`build.sh` 已强制 `LIVESYNC_REF` 为完整 commit SHA）。

## 遗留物

集群 master 上留了一个 `livesync-cli:test` 镜像（289MB）作为构建成功的证据，`docker rmi livesync-cli:test` 即可删除。构建用的源码 checkout 与日志已清理。

---

# 部署记录（2026-09-24）

在 `192.168.137.101` 上执行。**CouchDB 已跑起来并通过端到端 JWT 验证**；物化负载**未部署**（缺 Setup URI）。

## 已就绪

| 项 | 状态 |
| --- | --- |
| Vault `secret/obsidian/couchdb` | `COUCHDB_USER`、`COUCHDB_PASSWORD`（40 位随机）、`jwt_keys.ini` |
| JWT 密钥对 | 生成在 master 的 `/root/obsidian-jwt/`，`private_key.pem` 权限 600 |
| PVC ×3 | 全部 Bound，含 `obsidian-notes`（ceph-cephfs RWX） |
| CouchDB StatefulSet | `1/1 Running`，0 重启 |
| TunnelRoute `obsidian-sync` | 已创建，operator 已同步进 cloudflared 并完成滚动 |

## JWT 端到端验证（用私钥签真 token）

```text
带正确签名 token   /_session  -> 200  {"userCtx":{"name":"obsidian","roles":["_admin"]},
                                       "authentication_handlers":["jwt","cookie","default"],
                                       "authenticated":"jwt"}
带正确签名 token   /_all_dbs  -> 200
不带 token         /_all_dbs  -> 401
```

公钥与私钥、`kid`（`ec:obsidian` ↔ `kid: obsidian`）、认证处理器链全部对得上，且未认证请求失败关闭。**`_admin` 角色确实被授予** —— 印证了"设备私钥等同管理员"这条已接受的限制。

## 部署时踩的三个坑（都已修）

**（1）只读配置挂载会让容器静默死亡。** 第一次部署 Pod 立刻 `exit 1`，**日志一个字都没有**。

根因在 entrypoint：

```bash
find /opt/couchdb ! \( -user couchdb -group couchdb \) -exec chown -f couchdb:couchdb '{}' +
```

ConfigMap / Secret 挂进 `/opt/couchdb` 是只读的，这条 chown 必然失败；`-f` 把错误信息吞了，外面的 `set -e` 就直接退出 —— 所以既没有日志也没有 exit 之外的线索。

实测对照（couchdb:3，3.5.2.1）：local.d 里放一个只读文件 → 静默 exit 1；同样的配置放进可写目录 → CouchDB 正常启动。

修法：加一个 `stage-config` initContainer，把 ConfigMap 和 Secret **拷进可写的 emptyDir**，再用该 emptyDir 顶掉 `local.d`。镜像自带的 `local.d` 里只有一个 README，替换无损失。

**（2）JWT 公钥被静默截断。** 第一版生成的 `jwt_keys.ini` 里是**真实换行**，而 CouchDB 的 ini 解析器只取该行剩余部分作为值 —— 于是公钥只剩 `-----BEGIN PUBLIC KEY-----` 一行，后续全部丢弃。配置 API 读回来只有 45 字节。

这个坑很隐蔽：文件在、格式看着对、CouchDB 也不报错，只是**所有 JWT 都会验签失败**。

修法：PEM 压成一行，换行写成两个字符 `\n`。修好后配置 API 读回 299 字节、内容完整。

**（3）CORS 处理器默认关闭，`[cors]` 配置整段空转。** 打通公网后测预检请求，`OPTIONS /` 返回 **405** 且**没有任何 `Access-Control-*` 响应头** —— 尽管 `_config/cors` 读回来 `origins` / `methods` / `headers` / `credentials` 四项都是齐的。

根因在 `default.ini`：`enable_cors` 默认 `false`，且文件里明确注明这些键**已从 `[httpd]` 移到 `[chttpd]`**。我们只设了 `[chttpd] authentication_handlers`，没开 `enable_cors`，所以下面那段 `[cors]` 根本不参与。

修法：`[chttpd] enable_cors = true`。修好后预检返回 **204**，并带回 `access-control-allow-origin: app://obsidian.md`、`allow-credentials: true`、`allow-methods`、`max-age: 600`。

这个坑的形态和（2）一样：**配置项写得对、读回来也对，但开关没开，于是完全不生效且不报错。**

**（4）配置写进了正确的键名、却是不生效的节（section）。** 插件报 `chttpd_auth.require_valid_user 设置错误`。我先按插件指的位置写进 `[chttpd_auth]`，CouchDB 的 config API **照单全收**（`_config/chttpd_auth/require_valid_user_except_for_up` 读回来就是 `"true"`），但 `GET /` 依旧匿名返回 200 —— **因为那个键在 CouchDB 3.x 属于 `[chttpd]`，写在 `[chttpd_auth]` 里没有任何东西会去读它**（`default.ini` 里 `require_valid_user` 就列在 `[chttpd]` 之下）。

挪到 `[chttpd]` 后立即生效：`GET /` → 401，而 `GET /_up` 仍 200（用的是 `_except_for_up` 变体，否则 kubelet 的无凭据探针会把 Pod 打到永不就绪）。

顺带发现：**插件查的 `chttpd_auth.require_valid_user` 本身就是 2.x 的旧位置**，在 3.x 上它永远会报这一条。与 `httpd.enable_cors` 是同一类问题。

### 一个反复出现的模式

「**配置写得对，但完全不生效，且不报错**」在本次部署里出现了三次：

| | 表面 | 实际 |
| --- | --- | --- |
| （2）JWT 公钥 | 文件在、格式对、CouchDB 不报错 | 换行是真实换行 → 被截断到首行 → 所有 JWT 验签失败 |
| （3）CORS | `_config/cors` 四项齐全 | `enable_cors` 开关默认 false → 整段空转，预检 405 |
| （4）`require_valid_user` | config API 读回 `"true"` | 写在了不被读取的节 → 匿名访问照旧 |

三次都只能靠**实际发请求观察行为**发现，读配置、看文件、查文档都发现不了。

## 插件"检查服务器配置"报告的判读

插件报了 5 条，实测只有 1 条是真的：

| 插件报告 | 判读 |
| --- | --- |
| ⚠ 没有管理员权限 | **误报**。CouchDB 日志显示插件以 `obsidian` 身份成功读取了 admin-only 的 `_node/_local/_config/*`（200 ok） |
| ❗ `chttpd_auth.require_valid_user` | **真**。已修（见上） |
| ❗ `httpd.WWW-Authenticate` | 确实未设；但插件查的是 2.x 位置，3.x 应写在 `[chttpd]`。已显式写出 |
| ❗ `httpd.enable_cors` | **误报**。同样是 2.x 键名；3.x 的 `chttpd/enable_cors` 已设且生效 |
| ❗ `chttpd.max_http_request_size` 过低 | **误报**。`default.ini` 默认就是 `4294967296`（4GB），只是未显式写出 |
| ✔ `couchdb.max_document_size` / `cors.credentials` / CORS 源 | 正确。三个源逐个实测均返回匹配的 `access-control-allow-origin` |

**规律**：这个检查器读 `_config`，把「未显式设置」一律当成「设置错误」，因此看不见本就正确的内置默认值；同时它有几个键名停留在 CouchDB 2.x。**它列出的项不能直接当待办清单用，要逐条核实。**

### 兼容垫片：把报告清干净

核实完之后，仍有三条会一直报，因为插件查的是 2.x 的键位置：

| 插件查 | 3.x 实际位置 |
| --- | --- |
| `httpd/enable_cors` | `chttpd/enable_cors` |
| `httpd/WWW-Authenticate` | `chttpd/WWW-Authenticate` |
| `chttpd_auth/require_valid_user` | `chttpd/require_valid_user_except_for_up` |

**功能上这三条早就全部成立**，只是插件在旧位置找不到。因此在 `obsidian.ini` 里额外写了这三个旧位置键，并在清单里明确标注为垫片、`[chttpd]` 才是权威配置。

代价与风险已核实：

- 三个垫片键**都不生效**，纯粹是让检查器闭嘴；
- 其中 `chttpd_auth/require_valid_user = true` 有"万一真生效就会打断 `/_up` 探针"的风险，所以改完立刻验证：Pod 仍是 `1/1 Running`、0 重启，`GET /_up` 仍 200，`GET /` 仍 401 —— 确认它确实是空转的。

**读配置时不要以垫片为准**，`[chttpd]` 那一段才是真正在起作用的。

### `cors.origins`：空格导致的误报

垫片之后只剩一条：`cors.origins 设置错误`。我们原本写的是

```ini
origins = app://obsidian.md, capacitor://localhost, http://localhost
```

逗号后**带空格**。CouchDB 解析时会 trim，所以三个源逐个实测全部返回匹配的 `access-control-allow-origin`，功能完全正常 —— 但**插件的检查器不做 trim**，它把字符串按逗号切开逐项比较，` capacitor://localhost` 自然不等于 `capacitor://localhost`，于是报错。

改成上游 `setup_own_server.md` 里的规范写法（无空格）：

```ini
origins = app://obsidian.md,capacitor://localhost,http://localhost
```

改完 Pod 仍 `1/1 Running`，三个源仍全部匹配。

**又是一个"行为正确、检查器报错"的例子** —— 这次的成因是空白字符，而不是键位置。判据始终是同一条：**以实际请求的行为为准，不以检查器的报告为准。**

## 公网链路验证结果

`https://obsidian.panghuer.top`（Cloudflare 后台已把 service 改指 CouchDB）：

```text
带私钥签的 token   /_session  -> 200  {"userCtx":{"name":"obsidian","roles":["_admin"]},
                                       "authentication_handlers":["jwt","cookie","default"],
                                       "authenticated":"jwt"}
带私钥签的 token   /_all_dbs  -> 200
不带 token         /_all_dbs  -> 401
CORS 预检 OPTIONS  /          -> 204  access-control-allow-origin: app://obsidian.md
```

**一个要留意的点**：Cloudflare 会按 User-Agent 拦非浏览器请求（Python-urllib 得到 `403 error 1010`，与是否带 token 无关）。换成浏览器形态的 UA 后正常。插件的 UA 是 Obsidian 的（Mozilla 开头），预计能过，但这是未在真机验证过的一环 —— 如果设备侧报 1010，就是这里。

## 未完成（都需要你）

1. **Cloudflare 加 `obsidian-sync.panghuer.top` 的 DNS 记录**。实测：旧域名 `302`、`openspec` `401`、新域名 `000` —— 隧道配置已就绪，只缺 DNS。
2. **Setup URI** → `secret/obsidian/livesync`，然后 `kubectl apply -f k8s/materializer.yaml`。物化负载**现在没有部署**，正是因为它首次启动就需要这个值。
3. 把 `private_key.pem` 分发到各设备，之后建议从服务器删除。
4. 下线浏览器工作台（含 Cloudflare 后台删 `obsidian.panghuer.top`）。

## 注意：仓库状态

部署过程中改动的文件（`k8s/couchdb.yaml`、`k8s/couchdb-config.yaml`、`vault/inventory/obsidian-externalsecret.yaml`、`cloudflare-tunnel/operator/tunnel-routes.yaml`、本目录 README）**直接覆盖到了 master 的检出点**，尚未提交。需要本地 commit + push，并把 master 的检出点拉齐。

## 收尾：域名与下线（同日）

**域名复用 `obsidian.panghuer.top`，不再另起 `obsidian-sync`。** 理由：上游"不要把 CouchDB 挂在反代根目录"说的是 URL 路径而非域名，复用旧名字满足"独立子域"的要求；而且 DNS 已存在，另起一个只是多一条记录。集群侧已把 `obsidian` 路由的后端改为 CouchDB:5984，`obsidian-sync` 路由删除。

**浏览器工作台已下线。** 删除 `deployment/obsidian`、`service/obsidian`；旧 PVC `obsidian-config` 与 `obsidian-vault` 已删除（删前确认过：两块盘里唯一的 `.md` 是 Obsidian 自动生成的 `欢迎.md`，没有真实内容）。

## ⚠️ 路由只有后台生效（已记录事实的实测确认）

排查公网路径时确认了一件事。**这不是新发现** —— [docs/obsidian-deployment-research.md](../../docs/obsidian-deployment-research.md) 在 2026-09-21 就写过"`TunnelRoute` 只是后台配置备份，实际生效路由仍要去 Cloudflare 后台 Public Hostname 配置"。本次是把它从"文档声明"提升为"实测结论"，并发现实际情况比原文更彻底：

- cloudflared 进程实际是 `cloudflared tunnel --loglevel info run --token eyJ...` —— **token 模式 = 远端托管配置**；
- 该 Pod 里**没有挂载任何 ConfigMap**，唯一的卷是 ServiceAccount token；
- `controller.py` **从不调用 Cloudflare API**（只 import kopf 与 kubernetes 客户端），它做的只是"写 ConfigMap + 重启 Deployment"。

旁证：`cf-tunnel-cfg-main` 里只有 1 条 hostname，而集群里有二十多条路由在正常工作。

**结论**：`tunnel-routes.yaml` 是记录（保留作为记录是合理的），`cf-tunnel-cfg-main` 是空转的，**唯一生效的是 Cloudflare 后台的 Public Hostname**。

这也解释了切换域名后的 `502`：后台那条 `obsidian.panghuer.top` 仍指向已被删除的 `obsidian.obsidian.svc.cluster.local:4180`。

## 插件侧：JWT 配置在连接对话框里

客户端反馈"能填 URL 但没有 JWT 配置"。查上游 `docs/settings.md` 得知 CouchDB 那整组设置都在**同一个连接对话框**里，但**默认只展开 URL / 用户名 / 密码 / 数据库名称 / Use Internal API**，其余收在两个折叠区 `Advanced Settings` 与 `Experimental Settings` 中。

**JWT 那一组在 `Experimental Settings` 里**，因为上游把 JWT 认证归为 **Beta/experimental，默认不参与最小可用配置**。点开折叠区即可看到 `Use JWT Authentication` 及其后的 Algorithm / Expiration / Key / Key ID / Subject。

（我最初写的"往下滚就行"是错的：字段不是折叠在滚动区，而是在默认收起的折叠区里。已按实际对话框文案更正。）

完整的接入步骤与密钥轮换办法已写进 [README.md](README.md) 的"接入设备"与"公私钥轮换"两节。


