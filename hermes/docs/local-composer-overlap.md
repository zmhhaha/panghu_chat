# 本地消息编辑器与 Copy 按钮重叠

记录日期：2026-09-17。

## 现象与原因

部署本地消息编辑器后，终端右下角原有的 Copy 按钮覆盖编辑器的 Terminal / Send 操作栏。

原注入脚本将 `LocalMessageComposer` 放在 `hostRef` 对应的 xterm 节点之后，
但仍位于 `termWrapRef` 对应的相对定位容器内部。Copy 按钮在该容器右下角绝对定位，
不占普通文档流空间，因此与新增编辑器的底部操作栏重叠。

## 修复方式

`scripts/apply-web-overlay.py` 为终端和编辑器增加共同的纵向布局容器：

```text
聊天主区域（横向排列）
  左侧列
    终端容器：xterm、Copy 按钮及原有终端浮层
    本地消息编辑器：文本框、Terminal / Send 操作栏
  右侧栏：模型、会话
```

编辑器与终端容器成为兄弟节点。Copy 按钮继续相对终端定位，不能覆盖编辑器。
注入脚本使用 `termWrapRef` 和桌面侧栏条件表达式作为边界，
以 `data-hermes-local-composer-column` 标记避免重复包裹，并移除旧位置的编辑器挂载。
上游结构不匹配时停止构建，需重新适配锚点。

`web-overlay/LocalMessageComposer.tsx` 同时调整：

- 编辑器不参与纵向压缩，宽度允许随父容器缩小。
- 文本框设置默认高度及最小、最大高度，避免无限拖高挤占终端。
- 操作栏允许换行，按钮组不压缩，状态文字可换行。

## 生效步骤与验证状态

在服务器同步代码后执行：

```bash
cd panghu_chat/hermes
bash build.sh
bash deploy.sh
```

必须重新构建镜像：Docker 构建时应用补丁并执行 `npm run build --workspace web`，
dashboard 实际提供的是编译后的 `web_dist`；仅修改源码或重启旧镜像不会生效。

记录时已完成代码修改，尚未构建、部署或验证本次布局修复。
部署后需检查桌面和窄屏中 Copy 与操作栏互不重叠，以及拖动文本框高度、
展开/收起侧栏、断线提示出现时的布局。布局检查无需发送消息调用模型。

## 交互可靠性补充

本地编辑器会按聊天 channel 保存草稿到浏览器 `localStorage`，断线时不清空内容。
提交分为 bracketed paste 和回车两个步骤；第二步发送前会再次检查 WebSocket 状态。
连接在两步之间关闭时，编辑器保留草稿并提示先检查终端，避免自动重发造成重复执行。
发送成功后只显示 `Submitted`，不把它误报为模型已完成处理。
