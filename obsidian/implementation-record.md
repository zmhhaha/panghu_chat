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
