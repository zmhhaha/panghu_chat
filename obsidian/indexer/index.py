#!/usr/bin/env python3
"""把一个 Obsidian corpus 索引进 rag-service。

设计见 ../downstream-distribution.md。**下面三条是硬性约束，改动前先读。**

1. `doc_type` 必须是 `"text"`（服务端只接受 `text` | `knowledge` 两个值）。
   服务端只在 `doc_type == "knowledge"` 时走按 H2 小节切分的路径，而那条路径带一个
   行为约束排除表（`守则/边界/原则/禁忌/篇幅/自检/开头/例子/工作步骤/工具箱`）——
   **标题命中就整节丢掉，而且不报错**。`"text"` 走普通段落切分，完全不看标题。
   脚本会在发出任何请求之前先校验这个值。

2. 删除只作用于 `--corpus` 前缀下的文档。
   同一个 collection 里还有别的东西：例如 agent 的基线 `knowledge.md` 是它自己的
   initContainer 推上去的（source_id 是 `knowledge.md`）。列表接口返回的是**整个
   collection**，所以"凡是不在我的文件列表里就删"会把基线知识删掉。**只删前缀匹配
   的那些。**

3. 只读。这个作业不写物化卷，卷的唯一写者仍是物化负载。

4. `--corpus` 目录不存在**不等于失败**。
   每个"服务组/人格"从第一天起就有一个作业（见 ../k8s/indexer.yaml），而大多数 corpus
   还没有内容 —— 空目录不参与同步，没有笔记就没有目录。所以：目录不存在、且 collection
   里本 corpus 前缀下一条文档都没有 → 正常空跑，退出 0；只要还有文档就大声失败（改名、
   误删、挂载不对，都是需要人看一眼的情况）。

用法::

    index.py --corpus 百家争鸣/秉笔春秋
    index.py --corpus 百家争鸣/秉笔春秋 --dry-run --verbose

环境变量::

    RAG_URL    默认 http://rag-service.data.svc.cluster.local:8080
    RAG_TOKEN  调用身份。collection 由它决定，不在参数里给。
    VAULT_PATH 默认 /vault
    DOC_TYPE   默认 text（见约束 1，不要改成 knowledge）
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

RAG_URL = os.environ.get("RAG_URL", "http://rag-service.data.svc.cluster.local:8080").rstrip("/")
RAG_TOKEN = os.environ.get("RAG_TOKEN", "")
VAULT_PATH = os.environ.get("VAULT_PATH", "/vault")
# 服务端的 doc_type 是 Literal["text", "knowledge"]，只接受这两个值。
# 必须是 "text"：见文件头约束 1。
DOC_TYPE = os.environ.get("DOC_TYPE", "text")

# 容器里不设 locale 时 stdout 可能是 ASCII，打印中文会直接抛 UnicodeEncodeError。
# 这个作业的输出里有中文路径，所以显式钉住编码，不依赖运行环境的 locale。
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8")

# 只索引 Markdown。附件（图片、PDF）不进检索语料。
SUFFIXES = (".md",)


def log(verbose: bool, msg: str) -> None:
    if verbose:
        print(msg, file=sys.stderr)


def request(method: str, path: str, payload: dict | None = None, timeout: int = 60):
    url = f"{RAG_URL}{path}"
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {RAG_TOKEN}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode()
            return resp.status, (json.loads(raw) if raw.strip() else None)
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode()[:300]
        raise SystemExit(f"{method} {path} -> {exc.code} {raw}") from None


def collect_files(corpus_root: str) -> dict[str, str]:
    """返回 {source_id: content}，source_id 是 vault 相对路径。"""
    files: dict[str, str] = {}
    for dirpath, dirnames, filenames in os.walk(corpus_root):
        dirnames.sort()
        for name in sorted(filenames):
            if not name.endswith(SUFFIXES):
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, VAULT_PATH).replace(os.sep, "/")
            with open(full, encoding="utf-8") as handle:
                files[rel] = handle.read()
    return files


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", required=True, help="vault 相对目录，如 百家争鸣/秉笔春秋")
    parser.add_argument("--dry-run", action="store_true", help="只打印将要做什么，不调用接口")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    corpus = args.corpus.strip("/")
    if DOC_TYPE != "text":
        # 服务端只接受 "text" | "knowledge"，而 "knowledge" 会走带行为约束排除表的
        # 分块路径（见文件头约束 1）。所以除了 "text" 之外的一切都是错的，包括
        # 自造的值 —— 服务端会用 422 拒绝它，这里提前失败，报错更直接。
        return _fail(f'doc_type 必须是 "text"，当前是 {DOC_TYPE!r} —— 见文件头约束 1')

    prefix = f"{corpus}/"

    # 列表是读操作，dry-run 也要拉 —— 否则看不到"会删掉什么"。它还必须排在对
    # corpus 目录的检查**之前**：一个还没有内容的 corpus 和一个被改名/删掉的 corpus，
    # 在文件系统上长得一模一样（空目录不参与同步，见设计文档『已知的静默行为』），
    # 只能靠 collection 里的现状把这两种情况分开。
    indexed: dict[str, dict] = {}
    if RAG_TOKEN:
        status, body = request("GET", "/v1/ingest?limit=2000")
        indexed = {doc["document_id"]: doc for doc in (body or {}).get("documents", [])}
        log(args.verbose, f"collection 里现有 {len(indexed)} 条：{sorted(indexed)}")
    else:
        print("[indexer] RAG_TOKEN 未设置 —— 只做本地扫描，不对比远端", file=sys.stderr)

    corpus_root = os.path.join(VAULT_PATH, corpus)
    if not os.path.isdir(corpus_root):
        mine = sorted(doc_id for doc_id in indexed if doc_id.startswith(prefix))
        if mine or not RAG_TOKEN:
            # 目录没了、文档却还在被召回 —— 这是危险的那种情况（改名、误删、挂载不对），
            # 必须让人看一眼；静默什么都不做会让旧文档永远留在索引里。
            extra = (f"，但 collection 里还有 {len(mine)} 条本 corpus 的文档（改名、误删，还是挂载不对？）"
                     if mine else "（改名或路径错误？见设计文档『路径即标识』）")
            return _fail(f"corpus 目录不存在: {corpus_root}{extra}")
        # 目录不存在、且本 corpus 一条文档都没有 = 这个 corpus 还没有内容。
        # **八个人格从第一天起就各有一个作业**（见 k8s/indexer.yaml），所以这是常态，
        # 不是错误：空目录不参与同步，往 corpus 里放第一篇笔记，目录就会出现。
        print(f"corpus={corpus} 文件=0 上传=0 未变=0 删除=0 "
              f"（corpus 目录还不存在 —— 还没有内容，正常空跑）")
        return 0

    if not RAG_TOKEN and not args.dry_run:
        return _fail("RAG_TOKEN 未设置")

    files = collect_files(corpus_root)
    log(args.verbose, f"corpus={corpus}  文件数={len(files)}")

    # ---- 上传：内容没变就跳过（本地比一次 checksum，连内容都不用发出去）----
    uploaded = skipped = 0
    for source_id, content in sorted(files.items()):
        digest = "sha256:" + hashlib.sha256(content.encode()).hexdigest()
        current = indexed.get(source_id)
        if current and current.get("checksum") == digest and current.get("status") == "ready":
            skipped += 1
            log(args.verbose, f"  不变  {source_id}")
            continue
        if args.dry_run:
            print(f"  [dry-run] 上传 {source_id}")
            uploaded += 1
            continue
        request("POST", "/v1/ingest", {
            "source_id": source_id,
            "content": content,
            "checksum": digest,
            "doc_type": DOC_TYPE,          # 约束 1
        })
        uploaded += 1
        log(args.verbose, f"  上传  {source_id}")

    # ---- 删除：只动本 corpus 前缀下的（约束 2）----
    stale = [doc_id for doc_id in indexed
             if doc_id.startswith(prefix) and doc_id not in files]
    deleted = 0
    for doc_id in sorted(stale):
        if args.dry_run:
            print(f"  [dry-run] 删除 {doc_id}")
            deleted += 1
            continue
        request("DELETE", "/v1/ingest/" + urllib.parse.quote(doc_id, safe=""))
        deleted += 1
        log(args.verbose, f"  删除  {doc_id}")

    untouched = [doc_id for doc_id in indexed if not doc_id.startswith(prefix)]
    print(f"corpus={corpus} 文件={len(files)} 上传={uploaded} 未变={skipped} 删除={deleted} "
          f"未触碰（不属于本 corpus）={len(untouched)}")
    if untouched:
        log(args.verbose, f"未触碰：{sorted(untouched)}")
    return 0


def _fail(message: str) -> int:
    print(f"[indexer] {message}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
