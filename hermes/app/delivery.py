"""Frozen, idempotent Hublog delivery for the native Hermes publisher."""
import http.client
import json
import os
from pathlib import Path
import time
from urllib.parse import urlsplit


ROOT = Path(os.getenv("REPORT_HOME", "/reports"))


def atomic(path, value):
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    temp.replace(path)


def publish():
    pending = [p for p in sorted(ROOT.glob("????-??-??/payload.json"))
               if not (p.parent / "published.json").exists()]
    token_file = Path("/credentials/HUBLOG_SERVICE_TOKENS")
    if not token_file.exists():
        for payload_file in pending:
            atomic(payload_file.parent / "publish-skipped.json",
                   {"at": time.time(), "reason": "missing Hublog token; publication disabled"})
        print("publish skipped: no Hublog token")
        return
    document = json.loads(token_file.read_text())
    entry = document.get("hermes") if isinstance(document, dict) else None
    token = entry.strip() if isinstance(entry, str) else ""
    if isinstance(entry, dict):
        for key in ("token", "raw_token", "service_token"):
            value = entry.get(key)
            if isinstance(value, str) and value.strip():
                token = value.strip()
                break
    if not token:
        raise RuntimeError("missing Hublog token")
    endpoint = os.getenv("HUBLOG_URL", "http://hublog-api.hublog.svc.cluster.local")
    part = urlsplit(endpoint)
    if part.scheme not in ("http", "https") or part.username or part.query or part.fragment:
        raise ValueError("invalid Hublog endpoint")
    for payload_file in pending[:10]:
        payload = payload_file.read_bytes()
        for attempt in range(3):
            cls = http.client.HTTPSConnection if part.scheme == "https" else http.client.HTTPConnection
            conn = cls(part.hostname, part.port, timeout=30)
            try:
                conn.request("POST", part.path.rstrip("/") + "/api/v1/posts", body=payload,
                             headers={"Authorization": "Bearer " + token,
                                      "Content-Type": "application/json",
                                      "Idempotency-Key": "hermes-daily:" + payload_file.parent.name + ":v1"})
                response = conn.getresponse()
                data = response.read(1_000_000)
                if response.status in (200, 201):
                    post = json.loads(data)
                    atomic(payload_file.parent / "published.json",
                           {"post_id": post["id"], "published_at": time.time()})
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
