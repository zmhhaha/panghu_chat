# Obsidian 部署调研

日期：2026-09-23

## 目标重新界定

当前使用方式不是多台桌面或移动设备之间同步，而是：

1. Obsidian 运行在 Kubernetes 中。
2. 用户通过浏览器打开 Obsidian 界面。
3. 知识内容保存在集群存储中。
4. 后续由集群内其他服务读取这些内容。

因此，第一阶段的核心是浏览器工作台和可靠的持久化存储，不是同步后端。

## 方案比较

| 方案 | 当前判断 | 原因 |
| --- | --- | --- |
| `linuxserver/obsidian` | 第一版采用 | 提供浏览器中的 Obsidian 桌面界面，适合单用户远程工作台 |
| CouchDB + Self-hosted LiveSync | 暂缓 | 解决多设备同步，当前没有这个需求 |
| 官方 Obsidian Sync | 暂缓 | 托管同步服务，与当前 Kubernetes 工作台目标无关 |
| Obsidian Publish | 暂缓 | 面向公开发布，不是编辑工作台 |
| Quartz / MkDocs | 暂缓 | 适合静态发布，后续可从选定内容构建 |

## 浏览器版的适配性

`linuxserver/obsidian` 通过 Selkies 将 Obsidian 桌面应用串流到浏览器。它保存两类数据：

- `/config`：容器用户、桌面环境和应用状态；
- Obsidian Vault：Markdown、附件、`.obsidian` 配置和插件。

这两个目录都需要持久化。第一版单副本、单用户使用，使用 `ceph-rbd` 的 `ReadWriteOnce` PVC 即可。只有在多个 Pod 或其他工作负载需要同时挂载 Vault 时，才需要评估 CephFS / `ReadWriteMany`。

该镜像包含远程终端能力，因此不能将其 Service 直接暴露到公网。入口必须经过 Cloudflare Tunnel 和 oauth2-proxy，并且 oauth2-proxy 的邮箱白名单必须只包含明确允许的 Casdoor 账户。

部署实测补充：LinuxServer 镜像使用 HTTP 3000、HTTPS 3001。第一版不在容器内配置证书，使用 HTTP 3000，由 Cloudflare Tunnel 负责公网 HTTPS。镜像初始化需要调整应用和 nginx 目录权限，因此主容器不能套用 `drop: ALL`；oauth2-proxy sidecar 仍可使用非 root 和最小权限。

## 与现有平台的关系

当前平台已有 Cloudflare Tunnel、Casdoor、oauth2-proxy、Vault、External Secrets Operator 和 Ceph 存储，可以复用现有模式：

```text
浏览器
  -> Cloudflare Tunnel
  -> oauth2-proxy（Casdoor OIDC + 邮箱白名单）
  -> linuxserver/obsidian
  -> PVC
```

Obsidian 不需要独立实现用户系统，也不需要把知识内容写入 PostgreSQL、Redis 或 Vault。它的知识文件首先是 PVC 上的普通 Markdown 文件。

## 后续扩展

后续如果出现实际需求，可以分别增加：

- 多设备访问：CouchDB + Self-hosted LiveSync；
- Agent 读取：由指定服务只读挂载 Obsidian Vault，或增加受控导出服务；
- 检索：选择性将 Markdown 导入现有 `rag-service`；
- 公开发布：从选定内容构建 Quartz / MkDocs 站点。

这些能力不应作为第一版的隐含依赖。

## 主要风险

| 风险 | 影响 | 处理方式 |
| --- | --- | --- |
| Web UI 绕过认证暴露 | 远程终端和文件可能被滥用 | Service 只允许集群内访问，公网只经过 oauth2-proxy |
| 多个服务同时改文件 | 文件覆盖或内容冲突 | 第一版只有 Obsidian 可写，其他服务默认只读 |
| PVC 丢失 | 知识内容丢失 | 纳入后续 PVC 备份与恢复演练 |
| 误把知识内容放进 HashiCorp Vault | 密钥和业务内容边界混乱 | HashiCorp Vault 只保存 ExternalSecret 所需的敏感字段 |
| 单副本故障 | 浏览器工作台暂时不可用 | 保留本地/导出备份，后续再评估高可用 |

## 资料来源

- LinuxServer Obsidian：https://docs.linuxserver.io/images/docker-obsidian/
- Obsidian Sync：https://obsidian.md/help/Obsidian%2BSync%2FIntroduction%2Bto%2BObsidian%2BSync
- Self-hosted LiveSync：https://github.com/vrtmrz/obsidian-livesync
