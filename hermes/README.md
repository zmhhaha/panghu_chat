# Hermes 私人研究助手

## 当前架构

Kubernetes 负责运行和隔离服务；**Hermes 原生调度器负责定时任务**。
同一容器中，s6 分别管理 Dashboard 和官方 `hermes gateway run`。
gateway 不需要 Telegram 等聊天平台，也不会启用 Desktop 模式。
两者共享 `HERMES_HOME=/opt/data`，原生任务、执行历史和网页编辑都落在同一 PVC。

Hermes 独立使用原生 web 工具研究，不读取 content_agents 的采集结果。
旧 RSS 采集、CLI 日报、发布三个 Kubernetes CronJob 不再是调度入口。

首次启动通过官方 `cron.jobs.create_job` 注册两个原生任务：

| 名称 | 时间（Asia/Shanghai） | 内容 |
|---|---|---|
| Intelligence daily report | 每天 20:00 | 地缘局势、国际财经、AI 论文、中国及海外就业趋势 |
| Intelligence Hublog publication | 20:00–23:50 每十分钟 | 无模型脚本触发发布；失败重试冻结的正文 |

之后在 Hermes 网页管理任务。安装标记 `cron/intelligence-install.json`
防止重启重复创建；不会覆盖你的提示词、时间或暂停状态，删除任务也不会自动重建。
默认模型继承网页所在 profile 的配置，具体快照遵循当前 Hermes 原生任务语义；
更改模型后检查原生任务的模型设置。搜索工具须单独验证。

日报预执行脚本限定北京时间 20:00 后、每日最多两次研究启动。
`HERMES_CRON_TIMEOUT=600` 是空闲超时，不是总时长或金额上限。
提示词的工具调用限制是软约束；供应商金额上限仍需在账户侧设置。
修改研究任务的 script 会改变上述预执行保护，网页编辑时应保留。

## 发布与权限

`hermes-publisher` 是被原生任务调用的内部发布服务，没有自己的调度器。
它只读挂载网页 PVC 的 cron 子目录，单独挂载报告 PVC 和 Vault Hublog Token；
研究进程没有这个 Token，publisher 没有模型凭据。
请求不能传入文章、目标 URL 或任意 job id，只能触发安装时登记的日报任务。

仅处理原生成功完成的报告、正文区内的 BEGIN_REPORT/END_REPORT，
拒绝执行中的任务和无效输出。冻结为公开文章后使用
`hermes-daily:<date>:v1` 幂等键，成功保存 `published.json`。
同一天重复生成不会覆盖已经冻结的正文。旧版待发 payload 保留并沿用同一幂等键。
公众号/消息应用推送不在范围内；报告直接公开发布到 Hublog。

两个 Deployment 固定同一 ARM64 节点，以共享 Ceph RBD RWO 卷。
只有发布服务允许访问 Hublog，网页只额外允许访问发布服务的 8090。
主机初始化仍使用上游所需的有限 root 能力，不声称整个 Web Pod 满足 restricted。
无 Kubernetes 服务账号 token、hostPath 或 Docker socket。

## 配置归属

| 配置 | 文件 |
|---|---|
| Web、PVC、运行配置和基础网络策略 | `k8s/core.yaml` |
| 内部发布服务及访问策略 | `k8s/native-publisher.yaml` |
| 初始日报提示词 | `config/native-report-prompt.txt` |
| OAuth、个人邮箱白名单 | `../../oauth/k8s/hermes-proxy-configmap.yaml` |
| 模型、OIDC、Hublog 凭据 | `../../vault/inventory/hermes-externalsecret.yaml` |

旧 `app/pipeline.py` 保留用于复用幂等发布逻辑和历史回退；其采集与生成函数
不再被现行部署调用。`config/sources.yaml` 同样只是历史实现，不是原生研究来源限制。
不要对 Fake-IP 问题简单删除公网/内网访问保护；须针对原生搜索工具验证 DNS、
代理和重定向行为。就业新闻不等于具有代表性的岗位统计。

## 部署与迁移

```bash
cd panghu_chat/hermes
bash build.sh
bash deploy.sh
```

正常构建保留国内软件源，固定上游镜像摘要，并包含原生调度服务。
`scripts/Dockerfile.native-upgrade` 用于首次迁移时继承现有完整镜像的准确摘要，
避免同时升级上游或重新修改网页；后续使用正常 Dockerfile。

部署脚本先暂停旧 CronJob，有活动 Job 时停止迁移，避免重复执行。
旧 CronJob 暂不删除，已移出新清单；原生任务验收通过后可删除：
```bash
kubectl -n hermes delete cronjob hermes-collect hermes-report hermes-publish
```
不要恢复旧 CronJob 与原生任务同时运行。回退旧镜像前先暂停原生任务。
首次迁移会短暂重启网页，保留现有 OIDC/白名单，勿用仓库旧名单覆盖线上修改。

## 验证与恢复

```bash
kubectl -n hermes exec deployment/hermes-web -c hermes -- /opt/hermes/.venv/bin/hermes cron list
kubectl -n hermes exec deployment/hermes-web -c hermes -- /opt/hermes/.venv/bin/hermes cron status
kubectl -n hermes logs deployment/hermes-publisher
```

无模型兼容性检查：`PYTHONPATH=/opt/hermes:/opt/intelligence /opt/hermes/.venv/bin/python /opt/intelligence/scripts/check-native.py`。
检查使用临时 home，不触发生产任务，也不向 Hublog 发文。
完整验收还包括实际研究质量、Hublog 幂等重试、MFA、撤权、网络边界和备份恢复。

备份前暂停原生任务、等待执行结束并停写；同时备份 hermes-web 和 hermes-reports，
包括任务、安装标记、预算状态、冻结 payload 及发布回执。保留已暂停的旧任务和原镜像
直到迁移验收结束。不要只恢复文章而丢失回执，否则会依赖 Hublog 服务端幂等保护。
