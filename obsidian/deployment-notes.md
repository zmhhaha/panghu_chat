# Obsidian 笔记同步：部署踩坑与排查手册

日期：2026-09-25
适用：CouchDB 3.5.2 + `livesync-cli`（上游 1.0 线）+ Obsidian Self-hosted LiveSync 插件

本文只记**踩过的坑和排查手段**。设计与运维步骤见 [deployment-design.md](deployment-design.md) 与 [README.md](README.md)，过程记录见 [implementation-record.md](implementation-record.md)。

## 一句话

**这条链路上最贵的坑都有一个共同特征：配置/文件/参数看上去完全正确，却不生效，而且不报错。**
读配置、看文件、查文档都发现不了 —— **只有实际发请求、看行为**才能发现。全文八成的篇幅都是这个模式的变体。

## 最终可用的形态

```text
Obsidian（插件，JWT 认证）
   │  HTTPS  obsidian.panghuer.top
   ▼
CouchDB（StatefulSet，端到端密文）
   ▲
   │  livesync-cli daemon --interval 60
   │
obsidian-materializer（Deployment，initContainer 自举 + 轮询）
   ▼
obsidian-notes（ceph-cephfs RWX）→ 下游只读挂载
```

自举顺序（materializer 容器内）：

```bash
livesync-cli --settings "$settings" init-settings          # 仅在文件不存在时
livesync-cli --settings "$settings" setup "$(cat /secrets/setup-uri)" \
  < <(cat /secrets/setup-uri-passphrase; echo)
exec livesync-cli --settings "$settings" --vault /vault --interval 60
```

---

## 坑列表

### A. 镜像与构建

**A1. `COPY --chmod` 需要 BuildKit，集群 daemon 用 legacy builder。**

- **现象**：构建跑到 Step 24/27 才失败：`the --chmod option requires BuildKit`
- **根因**：上游 Dockerfile 用了 `COPY --chmod=755`
- **解决**：拆成 `COPY` + 单独的 `RUN chmod 755`，不依赖 builder 类型

**A2. `deb.debian.org` 会把构建卡死。**

- **现象**：apt 下载 30 秒零进度（实测字节数不增长）
- **解决**：Dockerfile 内换成 USTC 源，跟随 [dsh/Dockerfile](../dsh/Dockerfile) 的既有约定。改完后 apt 秒过、npm install 14 秒装完 774 个包

### B. CouchDB 配置

**B1. 只读挂载让容器静默死亡（最阴的一条）。**

- **现象**：Pod 立刻 `exit 1`，**日志一个字都没有**
- **根因**：entrypoint 在 uid 0 时执行
  ```bash
  find /opt/couchdb ! \( -user couchdb -group couchdb \) -exec chown -f couchdb:couchdb '{}' +
  ```
  ConfigMap/Secret 挂进 `/opt/couchdb` 是只读的 → chown 必然失败 → `-f` 吞掉报错 → 外面 `set -e` 直接退出
- **判据**：对照实验 —— local.d 里放一个只读文件 → 静默 exit 1；同样内容放可写目录 → 正常启动
- **解决**：加 `stage-config` initContainer，把 ConfigMap 和 Secret 拷进**可写的 emptyDir**，再用它顶掉 `local.d`。镜像自带的 `local.d` 只有一个 README，替换无损失

**B2. `drop: ALL` 会让 entrypoint 起不来。**

- **根因**：entrypoint 写完 admin 后用 `setpriv --reuid=couchdb --regid=couchdb` 降权，需要 `SETUID`/`SETGID`；chown 需要 `CHOWN`
- **解决**：补回 `CHOWN`/`SETUID`/`SETGID`/`DAC_OVERRIDE`/`FOWNER` 五个能力，并在清单里写明为什么。进程最终仍以非 root 的 couchdb 用户运行

**B3. `enable_cors` 默认关闭，整段 `[cors]` 配置空转。**

- **现象**：`_config/cors` 读回来 `origins`/`methods`/`headers`/`credentials` 四项齐全，但预检 `OPTIONS` 返回 **405** 且没有任何 `Access-Control-*` 头
- **根因**：`default.ini` 里 `enable_cors = false`，且注明这些键**已从 `[httpd]` 移到 `[chttpd]`**
- **解决**：`[chttpd] enable_cors = true`。改完预检 204

**B4. 配置写在不生效的节里 —— config API 照收，但没有东西读它。**

- **现象**：`chttpd_auth/require_valid_user_except_for_up` 读回来是 `"true"`，但 `GET /` 仍匿名 200
- **根因**：CouchDB 3.x 把 `require_valid_user*` 放在 `[chttpd]`
- **解决**：挪到 `[chttpd]`。立即生效（`GET /` → 401），用 `_except_for_up` 变体保住 kubelet 的无凭据探针

**B5. `cors.origins` 逗号后的空格让插件的检查器误报。**

- **现象**：插件报 `cors.origins 设置错误`，但三个源逐个实测**全部匹配**
- **根因**：CouchDB 解析时会 trim，所以运行正常；**插件的检查器不 trim**，按逗号切开逐项比对，` capacitor://localhost` ≠ `capacitor://localhost`
- **解决**：用上游 `setup_own_server.md` 的规范写法，逗号后不留空格

**B6. JWT 公钥被静默截断。**

- **现象**：配置 API 读回来的公钥只有 45 字节，文件看着正常，CouchDB 不报错，但**所有 JWT 都会验签失败**
- **根因**：ini 解析器只取该行剩余部分作为值；真实换行让公钥只剩第一行
- **解决**：PEM 压成一行，换行写成字面 `\n`。修好后 299 字节

### C. Obsidian 插件

**C1. JWT 配置藏在折叠区里。**

- **现象**：连接对话框只能看到 URL / 用户名 / 密码 / 数据库名称 / Use Internal API，找不到 JWT
- **根因**：上游把 JWT 认证归为 **Beta/experimental**，收在对话框的 **`Experimental Settings`** 折叠区（`Advanced Settings` 之外另一个）
- **解决**：点开折叠区。填 Algorithm `ES512`、Key 为私钥 PKCS#8、kid、sub；开了 JWT 后用户名/密码留空

**C2. 插件的"检查服务器配置"会报大量误报，不能当待办清单。**

实测 7 条里只有 1 条是真的：

| 插件报告 | 判读 |
| --- | --- |
| ⚠ 没有管理员权限 | **误报**。CouchDB 日志显示插件以 `obsidian` 身份成功读取了 admin-only 的 `_node/_local/_config/*` |
| ❗ `httpd.enable_cors` | 误报：查的是 2.x 键位置 |
| ❗ `httpd.WWW-Authenticate` | 键位置差异 |
| ❗ `chttpd_auth.require_valid_user` | 键位置差异 |
| ❗ `chttpd.max_http_request_size` 过低 | 误报：`default.ini` 默认就是 4GB |
| ❗ `cors.origins` | 误报：空格问题（见 B5） |
| ✔ 其余三项 | 正确 |

- **根因**：检查器读 `_config`，把"未显式设置"一律当成"设置错误"（看不见内置默认值），且有几个键名停留在 CouchDB 2.x
- **解决**：逐条核实。为消掉残留三条，在 `obsidian.ini` 里额外写了三个 **2.x 位置的兼容垫片**并注明"不生效、`[chttpd]` 才是权威"

**C3. 设备侧"重建服务端"会把远端锁上。**

- **现象**：CLI 所有请求都 200/201，然后一句 `Initial replication failed`
- **根因**：插件的重建/覆盖操作会**锁定远端数据库**，拒绝其他客户端连入，防止重建期间数据损坏
- **解决**：`livesync-cli ... unlock-remote`。验证输出会显示 `Remote Database: UNLOCKED` 与 `Current Device Node ID (...): ACCEPTED`
- ⚠️ 把 `unlock-remote` 写进启动脚本是不对的 —— 那会让锁失去意义。它是运维动作，出问题手动执行

### D. livesync-cli

**D1. 不要在命令里写 database-path。**

- **现象**：`Unknown command '/data'`
- **根因**：镜像的 entrypoint wrapper **会自动前置** database-path：
  ```sh
  exec node /app/dist/index.cjs "${LIVESYNC_DB_PATH:-/data}" "$@"
  ```
  再写一遍就成了 `/data /data ...`，CLI 把第二个 `/data` 当命令名
- **解决**：命令里省掉，直接 `livesync-cli --settings ... sync`

**D2. `setup` 无条件要口令，且没有 `--passphrase` 参数。**

- **现象**：`Enter setup URI passphrase:` 之后在容器里永远等不到输入
- **根因**：`setup` 的实现就是 `const passphrase = await standardIo.prompt(...)`，空输入报 `Passphrase is required`；`--help` 里**没有**任何口令相关参数
- **解决**：口令走 **stdin**。实测喂错误口令会得到 `AESCipherJob.onDone` 解密失败，证明通路可用
- 推论：**Setup URI 必须是加密的**（插件里的 "Encrypt your settings"）。未加密的 URI 在 CLI 这条路上同样走不通

**D3. stdin 到 EOF 但没有换行 → Node 静默 exit 0，什么都不做。**

- **现象**：`setup` 无报错、`rc=0`，但 settings 仍是 `"isConfigured": false`，输出里**从来没有** `[Command] setup -> ...` 那一行
- **根因**：prompt 用 `readline.question()`。stdin 到 EOF 且没有换行时这个 promise **永不 settle**，事件循环空转后 Node 以 0 退出
- **解决**：喂进去的内容**必须以换行结尾**。清单里用进程替换：
  ```bash
  < <(cat /secrets/setup-uri-passphrase; echo)
  ```
  （密文文件本身不带结尾换行，所以不能直接 `< file`）
- **判据**：看有没有 `[Command] setup -> <path>`。有才是真的执行了

**D4. 自举守卫不能只看"文件是否存在"。**

- **现象**：容器一直报 `Failed to initialise LiveSync`，而日志里**完全没有 setup 的输出**
- **根因**：一次运行创建了 `settings.json` 但没来得及应用 URI，留下"文件在、未配置"的状态；下一次启动 `if [ ! -f settings ]` 判定为已初始化，**永远跳过修复**
- **解决**：`setup` **每次启动都跑**（幂等且能自愈）。`init-settings` 仍然只在文件不存在时跑（它对已存在的文件会报错）

**D5. 只做首次同步就停了。**

- **现象**：`Initial replication complete` 之后跟着
  `Warning: liveSync and syncOnStart are both disabled in settings. No sync will occur.`
- **根因**：Setup URI 携带的是设备侧设置，`liveSync` / `syncOnStart` 都没开
- **解决**：加 `--interval 60` 进入轮询模式（也是上游给的无头模式推荐做法）。比去改被 `setup` 反复重写的 settings.json 干净

**D6. daemon 把失败原因吞掉了。**

- **现象**：只有一句 `[Daemon] Initial replication failed, cannot continue`
- **根因**：daemon 分支只判断 `outcome.status === "completed"`，非完成就打印通用消息，**不输出 reason**
- **解决**：用 `sync`（单次）或 `remote-status` 代替 —— 它们会把真实原因打出来（C3 的"远端被锁"就是这样定位到的）。`--verbose` 也能出 HTTP 级别的细节

**D7. 被删除的文件在镜像日志里显示为 skip，不是错误。**

- **现象**：卷里的文件数和 DB 里的文档数对不上（例如 DB 7 条、卷里 1 个），看着像镜像漏写
- **根因**：LiveSync 把删除记录为 tombstone。镜像扫描时对被删除的文件打印
  `SKIP newer-wins: <path> (db-only-deleted)` 并计入 `skipped` 而不是 `failed`
- **判据**：`Synchronisation completed: N files processed (x completed, y skipped, z failed)` 里 **`z failed` 为 0 就是正常的**。想看清楚就跑 `mirror --verbose`，或者用 `ls` 看本地库真正持有哪些文件
- **注意**：这条很容易误判成"镜像坏了"。我第一次就是这样 —— 卷里少了两个 `.base` 文件，实际是设备侧删掉了它们，镜像**正确地没有重建**

### E. 平台侧

**E1. Cloudflare Tunnel 的路由只有后台生效。**

- cloudflared 进程是 `run --token`（**远端托管模式**），Pod 里**没有挂载任何 ConfigMap**，operator 也**从不调用 Cloudflare API**
- 所以仓库里的 `tunnel-routes.yaml` 与 operator 写的 `cf-tunnel-cfg-main` 都**不在服务链路上**，唯一生效的是后台的 Public Hostname
- 旁证：ConfigMap 里只有 1 条 hostname，而集群有二十多条路由在正常工作

**E2. Cloudflare 按 User-Agent 拦非浏览器请求。**

- **现象**：`403 error 1010`，**与是否带 token 无关**（对照组一样）
- **判据**：换成浏览器形态的 UA 即通过
- **状态**：插件与 CLI 的 UA 目前都通过，但这是**未在真机长期验证**的一环。设备侧若报 1010，就是这里

---

## 排查方法论

1. **不要信配置，看行为。** 上面 B3/B4/B5/B6/D3 都是"配置读回来正确、实际不生效"。发一个真实请求看状态码和响应头，比读十遍配置有用。
2. **怀疑静默状态时，找"应该出现却没有出现的那一行"。** D3 就是靠 `[Command] setup -> ...` 缺失定位的。
3. **对照实验是最快的判据。** B1 的一句话结论来自"放只读文件 vs 放可写目录"两组对比。
4. **CLI 吞掉原因时，换一条命令问。** daemon 不说，`sync`/`remote-status` 说（D6）。
5. **minified bundle 读得动。** 好几个坑（D1/D2/D3）是直接 `grep`/`sed` 镜像里的 `/app/dist/index.cjs` 定的，报错信息里带的 `文件:行号` 就是入口。
6. **认证问题的判据在响应码，不在日志文本。** CouchDB 的访问日志里，`user` 列是 `undefined` 且状态码为 **400** → "签名坏了"（kid 对不上、或私钥与信任的公钥不匹配），错误体是 `{"reason":"Bad signature"}`；而 **401** 才是"没带凭据"。看到 400 就别去查网络和 CORS 了 —— 请求已经到达服务端，只是验签没过。
7. **服务端能替你验钥匙。** 私钥在服务器上时，直接签一个 token 打给 CouchDB，把"哪把私钥配哪个 kid"的组合跑一遍，比在设备 UI 上猜快得多。`Bad signature` / `Unknown kid` / `200` 三种结果直接给出答案。（跑完记得按 [README](README.md) 的收尾删掉旧密钥。）

## 安全注记

- **`remote-ls` / `remote-export` 会打印完整连接串，其中含 JWT 私钥**，而它的脱敏只覆盖 `@` 前面的部分。不要在会被记录的环境里跑这两条命令。
- **Setup URI 与它的口令必须分开保管**：URI 单独无用，口令单独也无用。两者都在 Vault 里，且都不应进入对话记录或工单。
- **口令丢失不可恢复**：端到端加密没有找回途径。
