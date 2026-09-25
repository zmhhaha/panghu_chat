# Obsidian 笔记分发设计

日期：2026-09-26
状态：设计中。**实现规格以 OpenSpec change `add-obsidian-note-distribution` 为准。**

物化那一层（设备 → CouchDB → `obsidian-notes`）已经跑通，见 [README.md](README.md)。本文只回答一个问题：**物化出来的 `.md`，怎么按用途分给不同的消费方。**

## 为什么不能"一股脑全给"

笔记是私人的，但用途是分层的：

- 有些是**只给自己看的**，任何服务都不该碰；
- 有些是**给某条业务线用的**（某个系列的服务各有自己的语料）；
- 有些是**跨服务共享的**（比如给 Hermes 和 DSH 的那份"统一记忆"）。

所以需要的是"**语料分组 → 指定消费方**"，而不是"把 vault 挂给所有人"。

## 模型：三层

```text
corpus（语料分组）  →  投递方式  →  消费方
```

### ① corpus 用 Obsidian 的文件夹定义

**分组规则就是"笔记放在哪个文件夹"** —— 你在 Obsidian 里把文件拖进某个目录，分组就完成了。不需要额外配置，不需要维护清单，也不需要给笔记加标记。

```text
vault/
  memory/           ← 给 Hermes 和 DSH 的统一记忆
  guanliao/         ← 某一系列服务自己的语料
  private/          ← 只给自己，永远不外发
  欢迎.md           ← 没被任何 corpus 覆盖的，默认不外发
```

这个选择的理由：**分组动作发生在你本来就在操作的地方**（Obsidian 的文件树），而不是在 K8s 清单里。加一份语料 = 在 Obsidian 里建个目录；改归属 = 拖一下。

代价：一份笔记同时属于两个 corpus 时要靠"放两份"或"放共享目录"绕开。frontmatter tag 可以做得更灵活，但那要求笔记本身带元数据、且 tag 拼错不会报错 —— 留作后续，v1 用目录。

### ② 投递方式有两种，按消费方的用法选

| | 只读挂载 | RAG 索引 |
| --- | --- | --- |
| 做什么 | 消费方 `subPath` 挂 `obsidian-notes` 的某个 corpus 目录，只读 | CronJob 遍历 corpus，逐个 `POST /v1/ingest` |
| 适合 | 需要直接读原文的（agent 取记忆、脚本处理） | 需要检索的（问答、语义搜索） |
| 延迟 | 跟随物化节奏（当前 60s） | 跟随 CronJob 周期 |
| 额外组件 | 无 | 一个 CronJob + 一个凭据 |
| 隔离 | 靠 `subPath` 限定到目录 | 靠 rag-service 的 collection |

两种可以同时给同一个消费方 —— 例如 DSH 既挂 `memory/` 读原文，又把 `memory/` 索引进自己的 collection 做检索。

### ③ 消费方清单

每个消费方一行：**corpus 路径 + 投递方式 + 凭据**。共享的 corpus 就是多行指向同一个路径。

## RAG 那条路的具体接法

`rag-service` 是**推送式**的 —— 它不挂卷、不扫文件，语料靠调用方 `POST /v1/ingest` 送进去。所以需要一个索引作业：

```python
# 对 corpus 下每个 *.md
POST /v1/ingest  {"source_id": "<vault 相对路径>", "content": "<文件内容>"}
```

三个要点：

**（1）它很便宜，所以可以跑得很勤。** `ingest` 是内容寻址的：内容没变的 `source_id` 只花一次 ES 查询就返回 `ready`，不重新切分、不重新 embedding。见 [rag-service/app.py](../rag-service/app.py) 的 checksum 短路。

**（2）collection 由调用身份决定。** `target_collection(identity, ...)` —— 用哪个 token 推，就落到哪个 collection。所以"每服务独立 collection"这件事**不需要在索引器里写死**，给每个消费方各自的身份即可。

**（3）删除要自己记账。** ingest 只增不改：笔记在 Obsidian 里删掉后，CouchDB 里是 tombstone、物化卷里文件消失，但 **rag 索引里的 chunk 不会自己消失**。索引作业需要一份"上次见过哪些路径"的清单，对已消失的发 `DELETE /v1/ingest/{id}`。这是这条路最容易漏的一环。

## 硬约束

- **消费方一律只读。** 物化负载是 `obsidian-notes` 的唯一写者 —— `livesync-cli` 的同步是双向的，拿到写权限的下游可能把改动推回 CouchDB，污染源头。挂载必须 `readOnly: true`。
- **`private/` 永不外发。** 默认是"没被 corpus 覆盖就不外发"，而不是"默认全给"。
- **凭据不共享。** 每个消费方一个身份/token，这样 collection 才隔离得开，也才追得清是谁推的。

## 待定

- **消费方清单本身**：具体哪些服务、各要哪个 corpus、用哪种投递。你提到的"合乎周礼"那条我没对上具体是哪个服务，填清单时补上即可。
- **`memory/` 的更新节奏**：Hermes 和 DSH 用它当"统一记忆"，那它对时效的要求比其他 corpus 高（可能要缩短 CronJob 周期，或改成事件驱动）。
- **一个笔记属于多个 corpus**：v1 用目录绕开，是否值得上 frontmatter tag 待观察。
- **量级**：笔记多了以后 `POST /v1/ingest` 的并发与 embedding 配额是否需要限流。
