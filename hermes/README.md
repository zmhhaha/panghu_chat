# Hermes 私人信息助手

使用仓库统一的原生 Kubernetes YAML，不再使用 deployment.local.yaml 或 render.py。
私人网页与公开 Hublog 日报分开；此次未运行测试或部署。

## 配置归属

| 内容 | 文件 |
|---|---|
| Deployment、PVC、Service、CronJob、网络策略及运行/来源 ConfigMap | `k8s/core.yaml` |
| 非敏感 Hermes 原生研究配置 | `k8s/research-configmap.yaml` |
| OAuth 参数、个人邮箱白名单 | `../../oauth/k8s/hermes-proxy-configmap.yaml` |
| 模型密钥、OAuth 凭据、Hublog Token | `../../vault/inventory/hermes-externalsecret.yaml` |
| Cloudflare 路由备份 | `../../cloudflare-tunnel/operator/hermes-route.yaml` |

已复用内网仓库 `arm-cluster-master:5000`、OAuth 镜像 `oauth2-proxy:v7.8.0`、
Casdoor `https://auth.panghuer.top`、Ceph RBD `ceph-rbd` 和 Hublog 内网地址。
RWO 工作负载固定在 ARM64 工作节点 `orangepi5-max-server1`，避免控制节点 NoSchedule 污点；如需迁移直接修改 YAML。
采集、研究、发布共用 RWO 卷，保持在同一工作节点。不为 memory.guard 污点添加容忍。
Hermes 镜像使用 `hermes-intelligence:latest`，Always 拉取，构建同时保留时间戳标签用于回退。

运行 ConfigMap 包括时区、来源路径、每日尝试次数、报告目录和 Hublog URL。
OAuth ConfigMap 包括 issuer、域名、Cookie 策略、白名单。邮箱没有可靠现成值，初始为空，拒绝所有用户。
研究 ConfigMap 初始 `{}`，请按实际 Hermes 版本填写模型/provider 等非敏感选项；密钥不得写入其中。
来源以 core.yaml 内 `hermes-sources` 为部署权威；镜像中 config/sources.yaml 仅供独立运行默认使用。

## 部署

```bash
cd panghu_chat/hermes
bash build.sh
bash deploy.sh              # 部署并等待网页就绪
bash deploy.sh --dry-run    # 仅预览操作，不连接集群
```

构建默认 Python 清华源、npm npmmirror；Docker 使用主机镜像加速器。
需要专用代理时可复制 `config/build.example.env` 为 `build.local.env` 填写 DOCKERHUB_MIRROR，
或指定完整 HERMES_IMAGE 指向已同步内网镜像。镜像会检查 ARM64 并固定上游摘要构建。
不修改主机 Docker 配置，不保证任意公共代理可用。

部署前按 Vault 文档写入三个路径，设置 OAuth 白名单和 Casdoor MFA。
脚本应用 ExternalSecret，**只对 `hermes-model` 与 `hermes-oidc` 等待 Ready**：缺模型或 OIDC 凭据是真实的部署失败。
**`hermes-hublog` 不等，只告警。** 它只影响发布这一步，Vault 路径没写不应让部署在中间中止、连工作台都起不来。
模型凭据通过环境变量传入，更新后重启网页；新研究任务会读取新值。
旧版 hermes-research-config ExternalSecret 不再使用：如已部署，确认配置迁移后由管理员移除旧对象；脚本不自动删除凭据。

Cloudflare 后台添加 `hermes.panghuer.top` → `http://hermes-web.hermes.svc.cluster.local:4180`。
参考 cloudflare-tunnel/operator/HERMES.md 给 cloudflared Pod 模板增加入口标签。
路由 YAML 仅备份，不会自动配置 Cloudflare。

## 调度与输出

CronJob 默认暂停，每次部署亦会恢复暂停状态，服务器验证通过后启用：

```bash
kubectl -n hermes create job --from=cronjob/hermes-collect hermes-collect-first
kubectl -n hermes patch cronjob hermes-collect --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n hermes patch cronjob hermes-report --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n hermes patch cronjob hermes-publish --type=merge -p '{"spec":{"suspend":false}}'
```

Kubernetes 1.27+：采集每三小时运行，不调用模型；日报北京时间 20:00 开始；20 点至 23 点每十分钟补发。
Hermes CLI 研究最多六轮、15 分钟、每日两次尝试，独立于私人聊天。供应商账户另设金额限制。
日报保存证据、正文及发布回执，Hublog 使用独立机器人和固定幂等键，失败仅重试冻结正文。
只发布公开文章，不自动生成匿名分享链接或手机推送。历史待发文章会补发。
**缺 Hublog token 时发布跳过而不是失败**：`token` 卷是 `optional`，`publish` 在待发日期目录里写一条 `publish-skipped.json`（含时间与原因）后正常退出，工作台、采集、研究都不受影响。
注意区分两种缺失：**卷里没有凭据文件** = 可选能力缺席，跳过；**凭据文件在但取不出可用 token** = 配错了，仍然报错。
就业来源是新闻发现，不代表招聘统计；来源失败和时间不明必须披露。正文支持人工审阅后再启用发布。

## 服务器验证与维护

尚未验证上游 dashboard/CLI 兼容性、ARM64 镜像实际运行、MFA、Host/Origin、WebSocket 和撤销会话。
**NetworkPolicy 已有结论（2026-09-20 实测）：在本集群不生效。** 集群 CNI 是 `kube-flannel`，不实现 NetworkPolicy，`k8s/core.yaml` 里的 `default-deny` / `research-egress` / `hublog-publisher` / `tunnel-ingress` 全部空转——工作台、采集、研究、发布四个角色之间当前没有网络隔离。修复路径与启用前必须修的三处见 [../../docs/network-policy-engine.md](../../docs/network-policy-engine.md)。（其中 `hublog-publisher` 原本只放行 8080 而实际连 80，即代码评审的 H1；已在仓库同时放行两者。）
上游网页入口使用 root 初始化后降权，不声称满足 restricted Pod Security；Job 使用 UID 10000。
无 Kubernetes token、hostPath 或 Docker socket。仅 publisher 挂载 Hublog 凭据。
核对 DNS 标签和 Service DNAT；公网地址的集群节点/API 需加入出口排除规则。
非敏感 ConfigMap 更改后重启网页；日报下一次运行读取新配置。
聊天及侧边栏使用 WebSocket。若握手返回 400 且正文包含 `line too long`，检查请求头长度。
Casdoor 登录后的 Cookie 头可能超过 WebSocket 库默认的 8 KiB；`hermes-dashboard-auth` 中
`WEBSOCKETS_MAX_LINE_LENGTH=32768` 将单行上限设为 32 KiB，重启网页后生效，不关闭认证或 Origin 校验。
聊天页还包含构建时注入的本地消息编辑器：输入和中文组合在浏览器完成，点击发送后通过
PTY 的 bracketed-paste 协议一次性提交，保留 Terminal 按钮处理确认框和快捷键。该补丁位于
`web-overlay/LocalMessageComposer.tsx`，由 `scripts/apply-web-overlay.py` 在 Docker 构建时应用；
它依赖上游 `ChatPage.tsx` 的终端容器、侧栏边界、`wsRef` 和 `ptyState` 结构，上游大幅改版时构建会失败并要求重新适配。
本地编辑器与 Copy 按钮重叠的原因、布局修复和部署检查见 [问题记录](docs/local-composer-overlap.md)。
Docker 随后执行 `npm run build --workspace web`，因为 dashboard 实际服务的是编译后的 `web_dist`，仅修改 `web/src` 不会改变已运行网页。
编辑器会保留未提交草稿，并在 bracketed paste 与回车之间复查 WebSocket；连接中断时不会自动重发。
备份时暂停调度、等待 Job 结束、网页缩容，离线快照两个 PVC，保存到 Agent 无写权限的位置。
来源保留 60 天，报告长期保留，需监控磁盘并归档；恢复必须同时恢复报告和发布回执以保持幂等。
