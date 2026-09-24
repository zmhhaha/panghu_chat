# Obsidian 运行时现状核对

日期：2026-09-23
集群：`192.168.137.101`（`arm-cluster-master`）
方式：SSH 到 master 执行 `kubectl`，全部结论来自容器内实测输出，不是清单推断。

## 结论先行

1. 服务本身是健康的：Pod `2/2 Running`，Obsidian 进程在跑，公网入口 `302` 跳 Casdoor 正常。
2. 浏览器里看到的"功能面板"是 **Selkies 串流客户端自己的侧边栏**，不是 Obsidian 的插件，也不是故障。这是 `linuxserver/obsidian` 这种"桌面应用串流进浏览器"形态的固有组成部分。
3. **有一处与设计不符**：Vault 落在 `obsidian-config`（10Gi）上，而设计指定的 `obsidian-vault`（20Gi）是空的。见第三节。

## 一、运行状态

```text
POD       obsidian-9798b9fc7-hwjdv   2/2 Running   0 restarts   node=arm-cluster-master
SERVICE   obsidian   ClusterIP   10.110.129.252   4180/TCP
PVC       obsidian-config   10Gi  Bound  ceph-rbd
          obsidian-vault    20Gi  Bound  ceph-rbd
SECRET    obsidian-oidc     Opaque  3 keys
EXTSECRET obsidian-oidc     SecretSynced  READY=True
```

- 容器内进程：`s6-supervise svc-selkies`、`svc-pulseaudio`、`selkies --addr=localhost --mode=websockets`、`/opt/obsidian/obsidian --no-sandbox`（含 zygote / gpu-process / network service 子进程）。
- 桌面是 **labwc**（Wayland）。`/config/.config/labwc/rc.xml` 的 windowRule 对所有窗口 `action name="Maximize"`，`<titlebar><layout>icon:iconify,max,close</layout>`，主题 `Clearlooks`。autostart 里**没有**任何任务栏 / 面板程序，所以桌面上只有铺满的 Obsidian 窗口。
- 线上 Deployment 的镜像与 env 与仓库 [k8s/deployment.yaml](k8s/deployment.yaml) **完全一致**（`linuxserver/obsidian:latest` + `oauth2-proxy:v7.8.0`；`TZ` / `PUID=1000` / `PGID=1000` / `CUSTOM_PORT=3000` / `TITLE=Obsidian`），没有手工漂移。

## 二、Selkies 侧边栏

界面上那块带 video / screen / audio / stats / clipboard / files / apps / sharing / gamepads / fullscreen / gaming mode / trackpad / 屏幕键盘 等区块的面板，是 Selkies Web 客户端渲染的，与 Obsidian 无关。它左上角的标题取自 `ui_title`，默认值就是字面量 `Selkies`，旁边是一个指向 `github.com/selkies-project/selkies` 的链接——这是把它和 Obsidian 界面区分开的最直接特征。

实测自容器内 `/usr/share/selkies/web/assets/index-DX1Td-pq.js`：

| 操作 | 快捷键 | 源码判据 |
| --- | --- | --- |
| 开合侧边栏 | `Ctrl+Shift+M` | `s.code==="KeyM"&&s.ctrlKey&&s.shiftKey&&document.fullscreenElement===null` → `onmenuhotkey` |
| 切换全屏 | `Ctrl+Shift+F` | `s.code==="KeyF"&&s.ctrlKey&&s.shiftKey&&document.fullscreenElement===null` → `onfullscreenhotkey` |

两个热键都带 `document.fullscreenElement===null` 前置条件：**只有不在浏览器全屏时才会被 Selkies 截获**，全屏状态下按了会被转发进桌面。

侧边栏初始状态是**收起**的（`const[u,s]=ge.useState(!1)`，类名为 `` `sidebar ${u?"is-open":""}` ``），所以它是被打开后才停留在那里的。

可配置项来自 `/lsiopy/lib/python3.13/site-packages/selkies/settings.py`，命名规则为 `SELKIES_` + 大写设置名（见该文件头部注释）：

- `ui_show_sidebar`（默认 `True`）→ `SELKIES_UI_SHOW_SIDEBAR`
- `ui_sidebar_show_*` 逐区块开关（`video_settings` / `screen_settings` / `audio_settings` / `stats` / `clipboard` / `files` / `apps` / `sharing` / `gamepads` / `fullscreen` / `gaming_mode` / `trackpad` / `keyboard_button` / `soft_buttons`）
- `ui_title` / `ui_show_logo` / `ui_show_core_buttons`

本次未做任何改动，仅记录可用杠杆。

## 三、Vault 位置与设计的偏差

| 项 | 设计（[deployment-design.md](deployment-design.md)） | 实际 |
| --- | --- | --- |
| Vault 路径 | `/config/obsidian-vault` | `/config/Obsidian Vault` |
| 承载 PVC | `obsidian-vault`（20Gi） | `obsidian-config`（10Gi） |

容器内 `mount` 确认了两块盘各自的位置：

```text
/dev/rbd2 on /config               type ext4 (rw,relatime,stripe=16)   # obsidian-config
/dev/rbd1 on /config/obsidian-vault type ext4 (rw,relatime,stripe=16)   # obsidian-vault
```

`/config/obsidian-vault/` 内容是空的（只有 `lost+found`，即一个刚格式化的卷）。真实内容在 `/config/Obsidian Vault/`：`欢迎.md` 与 `.obsidian/{graph,app,appearance,core-plugins,workspace}.json`。

`/config/.config/obsidian/obsidian.json` 原文：

```json
{"vaults":{"d1bee7f2acc01600":{"path":"/config/Obsidian Vault","ts":1790170257515,"open":true}},"language":"zh"}
```

**根因**：镜像的 autostart `/config/.config/labwc/autostart` 结尾就是裸跑 `obsidian`（`/defaults/autostart_wayland` 同理），**不传 vault 参数**；容器内 `env` 中也没有任何可用于预设 vault 的变量。因此每次启动都会走 Obsidian 的 vault 选择器，其默认项是家目录下的 `~/Obsidian Vault`，也就是 `/config/Obsidian Vault`。设计文档中"首次启动后需要在 Obsidian 界面中选择 `/config/obsidian-vault`"这一步依赖人工，实际落在了默认项上。

`/usr/bin/obsidian` 包装脚本会把 `"$@"` 透传给 `/opt/obsidian/obsidian`，所以从启动参数或 `obsidian.json` 预置 vault 在技术上是可行的——但本次未做任何改动。

## 四、未覆盖的验收项

[deployment-design.md](deployment-design.md) 的验收条件里，以下几项**本次没有验证**，仍是空白：

- 非白名单邮箱账号是否确实被拒（只验证了未登录时 `302` 跳 Casdoor）；
- 登录后的完整桌面操作与 WebSocket 长连接稳定性；
- Vault 内容的备份与恢复演练；
- PVC 重建后的数据恢复；
- NetworkPolicy 的实际生效情况——注意集群策略引擎虽已换成 Calico，但按 [docs/README.md](../../docs/README.md) 顶部横幅，端到端复验尚未执行。

## 五、本次未做的事

没有修改 `k8s/` 下任何清单，没有改 Deployment，没有动 PVC 数据，没有重启工作负载。上面第二节的 Selkies 开关与第三节的 Vault 迁移都只是记录下可用手段，未执行。
