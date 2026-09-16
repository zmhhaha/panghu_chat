# Hermes 私人信息助手

ARM64 Kubernetes 中的私人 Hermes 网页，配套公开 Hublog 日报。代码已实现，**未运行测试、构建镜像或部署**；服务器验收清单见末尾。

## 组件和边界

- `hermes-web`：上游 dashboard，监听 Pod 内 `127.0.0.1:9119`；同 Pod oauth2-proxy 暴露 4180，精确邮箱白名单。私人会话保存在独立 PVC。
- `hermes-collect`：每三小时采集公开 HTTPS RSS/Atom，保存去重摘要、原始时间、采集时间和失败覆盖。连接固定到验证过的公网 IP，每次重定向重新检查地址；每源最多 2 MB/60 条，资料保留 60 天。
- `hermes-report`：北京时间 20:00 调用真正的 Hermes CLI（不是替代 Agent），最多 6 轮、15 分钟；仅开启 web 工具。每领域最多 24 条摘要，来源轮转选取。每天最多启动模型两次，失败不由 Job 自动重试。
- `hermes-publish`：20:00–23:50 每十分钟检查待发布报告。独立挂载 Hublog Token，研究任务和私人网页不挂载此凭据。Hublog 固定日键幂等，保存文章 ID，网络失败重试原正文。

五条采集线：地缘、财经、AI、大陆就业、国际就业。就业默认来源是**新闻发现，不是真实职位统计**；报告必须标明样本局限。当前只采集摘要，深入核实交给 Hermes web 工具，其搜索供应商需配置。部分来源在国内可能不可达，失败在报告里披露。

不启用 Hermes gateway 和内建日报 cron，Kubernetes CronJob 是唯一自动调度来源。用户可以在网页手动研究；手动交互不受晚间限制。自动日报仅在 20 点以后调用模型，白天采集不调用模型。

## 构建

在 ARM64 构建机准备 Docker、Python 3 和 PyYAML。先选择包含 `dashboard`、`chat --query-file --oneshot --run-budget` 的上游版本，检查其 ARM64 manifest，然后固定摘要：

```bash
cd panghu_chat/hermes
HERMES_IMAGE='nousresearch/hermes-agent@sha256:<实际摘要>' IMAGE_TAG=20260916-1 bash build.sh
cp config/deployment.example.yaml deployment.local.yaml
```

将输出的本地仓库镜像摘要写入 `deployment.local.yaml`；同样固定 oauth2-proxy 镜像摘要。填写存储类、ARM64 节点 hostname、个人邮箱、OIDC issuer 和域名。不要使用占位符部署。

上游 s6 启动阶段需要 root 调整目录权限，之后降权运行。网页容器保留这条启动路径并限制 capabilities，**当前不声称满足 Pod Security restricted**。研究、采集和发布 Job 直接以 UID 10000 启动。若 namespace 强制 restricted，网页需要先适配上游入口，不应直接改成 privileged。

## 凭据和模型

以下 Secret 统一由 `vault/inventory/hermes-externalsecret.yaml` 管理；不要把真实配置提交 Git。具体字段与写入方法见 `vault/inventory/HERMES.md`：

| Secret | 内容 |
|---|---|
| `hermes-model` | Hermes 原生模型/搜索供应商环境变量，如 `OPENAI_API_KEY` 或对应供应商变量；按固定版本官方配置填写 |
| `hermes-oidc` | `OAUTH2_PROXY_CLIENT_ID`、`OAUTH2_PROXY_CLIENT_SECRET`、`OAUTH2_PROXY_COOKIE_SECRET` |
| `hermes-research-config` | 键 `config.yaml`，经过该 Hermes 版本支持的原生配置，显式设置模型、provider、最大输出 token；不要启用 MCP、本地执行或自动任务 |
| `hermes-hublog` | 键 `token`，Hermes 专属 Hublog 机器人明文 Token |

先在 Vault 写入 `secret/hermes/model`、`secret/hermes/oidc`、`secret/hermes/research` 和 `secret/hermes/hublog`。
部署脚本会创建 namespace、应用 ExternalSecret，并等待四个 Secret Ready；不再手动创建与 ESO 竞争管理的同名 Secret。

Hublog 机器人用 `../hublog/scripts/generate-service-token.py` 生成独立 `service:hermes` 身份，按 Hublog 文档合并哈希映射到 Vault；**不能覆盖已有机器人映射**。Token 不是只写权限，发布进程不得暴露给 Agent 工具。

Hermes 独立使用自己的模型接入，不连接仓库 llm-service。模型配置语法随上游演进，研究配置由操作者提供，避免编造不支持的字段。私人网页首次通过受保护入口配置模型；研究配置与私人历史隔离。Token 轮数限制不等于金额硬上限，供应商账户应另设每日费用额度；核对低价时区和模型适用范围。

## 部署和入口

平台配置按仓库目录归属维护：
- `oauth/k8s/hermes-proxy-container.yaml`：OAuth 容器模板，render.py 直接读取，不能单独 apply。
- `oauth/k8s/HERMES.md`：Casdoor、邮箱白名单、Cookie 与轮换说明。
- `vault/inventory/hermes-externalsecret.yaml` 和 `HERMES.md`：四个 Secret 的 Vault 映射与接入。
- `cloudflare-tunnel/operator/hermes-route.yaml` 和 `HERMES.md`：待上线的路由备份与实际后台操作。

运行部署脚本需要完整仓库目录，不能只复制 hermes 子目录。Cloudflare 路由不会被部署脚本自动写入。

```bash
bash deploy.sh                         # 仅生成清单
APPLY=true bash deploy.sh              # 明确执行时才部署
```

CronJob 初始全部暂停，每次重部署也会暂停。单节点约束用于保证两个 RWO PVC 可挂载，容量和可用性由所选节点决定。网页与日报总计可能需要数 GiB 内存，请勿选择已耗尽资源的小节点。

1. 在 Casdoor 建独立 OIDC 应用，回调 `https://hermes.panghuer.top/oauth2/callback`，启用 MFA，并验证邮箱声明可信。
2. 给现有 cloudflared **Pod 模板**添加 `hermes-ingress: "true"` 标签；NetworkPolicy 只允许该标签 Pod 访问代理 4180。
3. 在 Cloudflare Tunnel 控制台添加 Published application：`hermes.panghuer.top` → `http://hermes-web.hermes.svc.cluster.local:4180`。现有 TunnelRoute CR 不是实际路由权威来源。
4. 可叠加 Cloudflare Access 个人白名单；当前代码仍以 oauth2-proxy 为入口认证，不因漏配 Access 就裸露 dashboard。

网络默认禁止所有入站/出站，按角色允许 DNS、公网 HTTPS、发布器到 Hublog。请核对 CNI 对 Service DNAT 的处理、CoreDNS 标签，以及集群是否使用 NodeLocal DNS。若集群 API/节点使用公网地址，必须额外加入公网出口排除段。当前仅放行 IPv4，IPv6 默认不放行。OIDC 若使用内部地址，必须精确添加对应目标规则，不可全放内网。

## 启用日报

在服务器完成验证后手动采集第一批资料，再启用调度：

```bash
kubectl -n hermes create job --from=cronjob/hermes-collect hermes-collect-first
# 完成采集、网页和凭据验证后：
kubectl -n hermes patch cronjob hermes-collect --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n hermes patch cronjob hermes-report --type=merge -p '{"spec":{"suspend":false}}'
kubectl -n hermes patch cronjob hermes-publish --type=merge -p '{"spec":{"suspend":false}}'
```

调度要求 Kubernetes 支持 `CronJob.spec.timeZone`（1.27+ 稳定）。20:00 开始生成，20:10 起发布器可拾取结果。日报若失败，当晚可手动创建一次 report Job；第三次会被预算拒绝。publish 会补发历史未交付报告。生成后正文冻结，同日更正目前需人工处理并设计新版本键，不能编辑正文后重用旧键（Hublog 返回 409）。

日期目录包含 `evidence.json`、`response.txt`、`payload.json`、`published.json`。不要把完整原始输出写入公共日志。发布正文包含来源覆盖，不包括私人对话。报告默认公开 `article`，普通 Hublog 页面仍登录，匿名分享需另行创建分享链接。

## 备份、维护与验收（本次未执行）

- 备份前暂停 CronJob 并等待正在运行的 Job 完成，网页缩容为 0；对两个 PVC 做存储快照/离线备份到 Agent 无写权限的位置。恢复使用兼容镜像版本、恢复两个卷、重新注入凭据后再启动。
- 资料库自动删除 60 天前条目，但 SQLite 文件不自动缩小；报告长期保留，需监控 PVC 容量并离线归档，不能认为磁盘无限。
- 验证 ARM64 镜像启动、网页聊天、dashboard 自身 Host/Origin/会话检查和 WebSocket 代理；不得为方便关闭上游认证检查。
- 验证本人可登录、其他账号被拒绝、注销/撤销后连接行为；NetworkPolicy 实际阻断内网、元数据和集群 API。
- 验证官方 `web` toolset 不启用本地执行，检查网页可用工具；凭据只能由可信管理员配置，网页内容不构成授权。
- 验证模型、搜索供应商与配置文件兼容，低价时间符合预期；验证没有资料时拒绝生成、源失败可见。
- 验证报告引用、重复事件、海外/国内就业边界；公开发布前先人工审阅第一份 `payload.json`。
- 验证 Hublog Token、相同正文重复提交只产生一篇文章、401/409 不会重新生成；重启后不重复计费。

未经这些验证不能视为已完成上线。此实现不提供模型微调、真实招聘网站全量爬取、聊天平台接入、浏览器推送或测试容器集群。
