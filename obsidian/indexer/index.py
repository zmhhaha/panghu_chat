#!/usr/bin/env python3
"""把一个 Obsidian corpus 索引进 rag-service。

设计见 ../downstream-distribution.md。**下面三条是硬性约束，改动前先读。**

1. `doc_type` 不能用 `"knowledge"`。
   服务端只在 `doc_type == "knowledge"` 时走按 H2 小节切分的路径，而那条路径带一个
   行为约束排除表（`守则/边界/原则/禁忌/篇幅/自检/开头/例子/工作步骤/工具箱`）——
   **标题命中就整节丢掉，而且不报错**。换任何别的 doc_type 走普通段落切分，完全不
   看标题。所以这个作业用一个自带的值 `obsidian-note`。

2. 删除只作用于 `--corpus` 前缀下的文档。
   同一个 collection 里还有别的东西：例如 agent 的基线 `knowledge.md` 是它自己的
   initContainer 推上去的（source_id 是 `knowledge.md`）。列表接口返回的是**整个
   collection**，所以"凡是不在我的文件列表里就删"会把基线知识删掉。**只删前缀匹配
   的那些。**

3. 只读。这个作业不写物化卷，卷的唯一写者仍是物化负载。

用法::

    index.py --corpus 百家争鸣/秉笔春秋
    index.py --corpus 百家争鸣/秉笔春秋 --dry-run --verbose

环境变量::

    RAG_URL    默认 http://rag-service.data.svc.cluster.local:8080
    RAG_TOKEN  调用身份。collection 由它决定，不在参数里给。
    VAULT_PATH 默认 /vault
    DOC_TYPE   默认 obsidian-note（见约束 1，不要改成 knowledge）
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
DOC_TYPE = os.environ.get("DOC_TYPE", "obsidian-note")

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
    if corpus == "knowledge" or DOC_TYPE == "knowledge":
        return _fail("doc_type 不能是 knowledge —— 见文件头约束 1")

    corpus_root = os.path.join(VAULT_PATH, corpus)
    if not os.path.isdir(corpus_root):
        # 目录不存在几乎总是意味着 corpus 被改名或路径写错了。静默什么都不做会让
        # 旧文档永远留在索引里，所以这里大声失败。
        return _fail(f"corpus 目录不存在: {corpus_root}（改名或路径错误？见设计文档『路径即标识』）")

    if not RAG_TOKEN and not args.dry_run:
        return _fail("RAG_TOKEN 未设置")

    files = collect_files(corpus_root)
    prefix = f"{corpus}/"
    log(args.verbose, f"corpus={corpus}  文件数={len(files)}")

    # 列表是读操作，dry-run 也要拉 —— 否则看不到"会删掉什么"。
    indexed: dict[str, dict] = {}
    if RAG_TOKEN:
        status, body = request("GET", "/v1/ingest?limit=2000")
        indexed = {doc["document_id"]: doc for doc in (body or {}).get("documents", [])}
        log(args.verbose, f"collection 里现有 {len(indexed)} 条：{sorted(indexed)}")
    else:
        print("[indexer] RAG_TOKEN 未设置 —— 只做本地扫描，不对比远端", file=sys.stderr)

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
