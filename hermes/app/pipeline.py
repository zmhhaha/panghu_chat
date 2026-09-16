"""Bounded feed collection, Hermes research, and durable Hublog delivery."""
import argparse
import datetime as dt
import fcntl
import hashlib
import html
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import signal
import socket
import sqlite3
import ssl
import subprocess
import time
from urllib.parse import urljoin, urlsplit
from zoneinfo import ZoneInfo

import feedparser
import yaml

TZ = ZoneInfo("Asia/Shanghai")
ROOT = Path(os.getenv("REPORT_HOME", "/reports"))
CONFIG = Path(os.getenv("SOURCE_CONFIG", "/opt/intelligence/config/sources.yaml"))


def utcnow():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def atomic(path, value):
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(path)


class PinnedHTTPS(http.client.HTTPSConnection):
    """Connect to the validated IP, while preserving certificate/SNI hostname."""
    def __init__(self, host, address):
        super().__init__(host, timeout=30, context=ssl.create_default_context())
        self.address = address

    def connect(self):
        raw = socket.create_connection((self.address, 443), self.timeout)
        self.sock = self._context.wrap_socket(raw, server_hostname=self.host)


def public_get(url):
    for _ in range(5):
        part = urlsplit(url)
        if part.scheme != "https" or not part.hostname or part.username or part.password or part.port not in (None, 443):
            raise ValueError("only public HTTPS sources are supported")
        addresses = {x[4][0] for x in socket.getaddrinfo(part.hostname, 443, type=socket.SOCK_STREAM)}
        if not addresses or any(not ipaddress.ip_address(x).is_global for x in addresses):
            raise ValueError("non-public source destination")
        conn = PinnedHTTPS(part.hostname, sorted(addresses)[0])
        try:
            target = part.path or "/"
            if part.query:
                target += "?" + part.query
            conn.request("GET", target, headers={"User-Agent": "HermesIntelligence/1.0", "Accept-Encoding": "identity"})
            response = conn.getresponse()
            if response.status in (301, 302, 303, 307, 308):
                url = urljoin(url, response.getheader("Location", ""))
                continue
            if response.status != 200:
                raise ValueError(f"source HTTP {response.status}")
            body = response.read(2_000_001)
            if len(body) > 2_000_000:
                raise ValueError("source exceeds 2MB")
            return body
        finally:
            conn.close()
    raise ValueError("too many redirects")


def database():
    ROOT.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(ROOT / "sources.sqlite", timeout=30)
    db.execute("CREATE TABLE IF NOT EXISTS items (id TEXT PRIMARY KEY, category TEXT, source TEXT, title TEXT, url TEXT, summary TEXT, published TEXT, collected TEXT)")
    db.execute("CREATE TABLE IF NOT EXISTS coverage (source TEXT PRIMARY KEY, category TEXT, checked TEXT, count INTEGER, error TEXT)")
    return db


def clean(text, limit):
    return html.unescape(re.sub(r"<[^>]+>", " ", str(text)))[:limit]


def collect(db):
    sources = yaml.safe_load(CONFIG.read_text(encoding="utf-8"))["sources"]
    for source in sources:
        count, error = 0, None
        try:
            feed = feedparser.parse(public_get(source["url"]))
            if not feed.entries:
                raise ValueError("empty or invalid feed")
            for entry in feed.entries[:60]:
                link = entry.get("link", "")
                parsed = urlsplit(link)
                if parsed.scheme not in ("https", "http") or not parsed.hostname:
                    continue
                key = hashlib.sha256((source["category"] + "\n" + link).encode()).hexdigest()
                published = entry.get("published", entry.get("updated", "unknown"))
                db.execute("INSERT OR IGNORE INTO items VALUES (?,?,?,?,?,?,?,?)", (
                    key, source["category"], source["name"], clean(entry.get("title", ""), 500),
                    link, clean(entry.get("summary", ""), 2500), published, utcnow()))
                count += 1
        except Exception as exc:
            # Avoid writing response bodies, URLs with credentials, or environment values.
            error = type(exc).__name__
        db.execute("INSERT OR REPLACE INTO coverage VALUES (?,?,?,?,?)", (
            source["name"], source["category"], utcnow(), count, error))
        db.commit()
    cutoff = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=60)).isoformat()
    db.execute("DELETE FROM items WHERE collected < ?", (cutoff,))
    db.commit()


def generate(db):
    now = dt.datetime.now(TZ)
    if now.hour < 20:
        raise RuntimeError("report generation allowed only after 20:00 Asia/Shanghai")
    day = now.date().isoformat()
    folder = ROOT / day
    folder.mkdir(exist_ok=True)
    if (folder / "payload.json").exists():
        return
    attempts = folder / "attempts.json"
    state = json.loads(attempts.read_text()) if attempts.exists() else {"count": 0}
    if state["count"] >= int(os.getenv("MAX_DAILY_ATTEMPTS", "2")):
        raise RuntimeError("daily model attempt budget exhausted")
    rows = []
    cutoff = (now - dt.timedelta(days=2)).astimezone(dt.timezone.utc).isoformat()
    for category in ("geopolitics", "finance", "ai", "jobs_cn", "jobs_global"):
        # Round-robin sources so one large feed cannot crowd out every other source.
        selected = db.execute("""SELECT source,title,url,summary,published,collected FROM (
            SELECT *, ROW_NUMBER() OVER (PARTITION BY source ORDER BY collected DESC) AS rank
            FROM items WHERE category=? AND collected>=?) ORDER BY rank,source LIMIT 24""", (category, cutoff)).fetchall()
        rows.extend({"category": category, "source": r[0], "title": r[1], "url": r[2],
                     "summary": r[3][:700], "published": r[4], "collected": r[5]} for r in selected)
    coverage = [dict(zip(("source", "category", "checked", "count", "error"), row))
                for row in db.execute("SELECT * FROM coverage")]
    if not rows:
        raise RuntimeError("no collected evidence; refusing to invent a report")
    evidence = {"cutoff": now.isoformat(), "items": rows, "coverage": coverage}
    atomic(folder / "evidence.json", evidence)
    instructions = (Path("/opt/intelligence/config/report-prompt.txt")).read_text(encoding="utf-8")
    query = folder / "query.txt"
    query.write_text(instructions + "\nUNTRUSTED_SOURCE_DATA\n" + json.dumps(evidence, ensure_ascii=False), encoding="utf-8")
    state["count"] += 1
    atomic(attempts, state)  # Reserve before launching: crashes also consume the budget.
    output = folder / "response.txt"
    env = dict(os.environ)
    env.pop("HUBLOG_SERVICE_TOKEN", None)
    command = ["/opt/hermes/.venv/bin/hermes", "chat", "--query-file", str(query),
               "--oneshot", "--quiet", "--toolsets", "web", "--max-turns", "6", "--run-budget", "900"]
    with output.open("w", encoding="utf-8") as stream:
        process = subprocess.Popen(command, stdout=stream, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL, env=env, start_new_session=True)
        try:
            result = process.wait(timeout=960)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise RuntimeError("Hermes report timed out") from None
    if result:
        raise RuntimeError(f"Hermes exited with code {result}; check model configuration")
    text = output.read_text(encoding="utf-8")
    start, end = "BEGIN_REPORT", "END_REPORT"
    if start not in text or end not in text:
        raise RuntimeError("missing report delimiters; nothing published")
    report = text.split(start, 1)[1].split(end, 1)[0].strip()
    if not 200 <= len(report) <= 170_000:
        raise RuntimeError("invalid report length")
    appendix = "\n\n来源采集状态（程序记录）\n" + "\n".join(
        f"{c['source']}: {c['count']} 条; {c['error'] or '正常'}; {c['checked']}" for c in coverage)
    payload = {"post_type": "article", "visibility": "public", "title": f"Hermes 信息日报 | {day}",
               "content": report + appendix, "tags": ["Hermes", "地缘局势", "国际财经", "AI论文", "程序员就业"]}
    atomic(folder / "payload.json", payload)


def publish():
    # Payloads are immutable. Retry the exact bytes and key after uncertain responses.
    endpoint = os.getenv("HUBLOG_URL", "http://hublog-api.hublog.svc.cluster.local")
    part = urlsplit(endpoint)
    if part.scheme not in ("http", "https") or part.username or part.query or part.fragment:
        raise ValueError("invalid Hublog endpoint")
    token = Path(os.getenv("HUBLOG_TOKEN_FILE", "/credentials/token")).read_text().strip()
    if not token:
        raise RuntimeError("missing Hublog token")
    pending = [p for p in sorted(ROOT.glob("????-??-??/payload.json"))
               if not (p.parent / "published.json").exists()]
    for payload_file in pending[:10]:
        receipt = payload_file.parent / "published.json"
        if receipt.exists():
            continue
        payload = payload_file.read_bytes()
        for attempt in range(3):
            cls = http.client.HTTPSConnection if part.scheme == "https" else http.client.HTTPConnection
            conn = cls(part.hostname, part.port, timeout=30)
            try:
                conn.request("POST", part.path.rstrip("/") + "/api/v1/posts", body=payload,
                             headers={"Authorization": "Bearer " + token, "Content-Type": "application/json",
                                      "Idempotency-Key": "hermes-daily:" + payload_file.parent.name + ":v1"})
                response = conn.getresponse()
                data = response.read(1_000_000)
                if response.status in (200, 201):
                    post = json.loads(data)
                    atomic(receipt, {"post_id": post["id"], "published_at": utcnow()})
                    break
                if response.status < 500 and response.status != 429:
                    raise ValueError(f"Hublog HTTP {response.status}; requires operator action")
                raise OSError(f"Hublog HTTP {response.status}")
            except (OSError, http.client.HTTPException):
                if attempt == 2:
                    raise
                time.sleep(2 ** attempt)
            finally:
                conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["collect", "report", "publish"])
    action = parser.parse_args().action
    ROOT.mkdir(parents=True, exist_ok=True)
    # File lock supplements CronJob Forbid for manually created jobs on the same PVC.
    with (ROOT / (action + ".lock")).open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if action == "publish":
            publish()
        else:
            with database() as db:
                if action == "collect":
                    collect(db)
                else:
                    generate(db)


if __name__ == "__main__":
    main()
