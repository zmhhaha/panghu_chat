"""Credential-isolated delivery of completed native report outputs.

Only the cron subdirectory is mounted here, read-only. Callers cannot supply a
URL, token, article body or job id. The native no-agent job triggers this service.
"""
import datetime as dt
import json
import re
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

from app import delivery

CRON = Path('/cron')
TZ = ZoneInfo('Asia/Shanghai')


def report_payload(cron=CRON):
    marker = cron / 'intelligence-install.json'
    if not marker.exists():
        return None
    job_id = json.loads(marker.read_text())['report']
    if not re.fullmatch(r'[a-f0-9]{12}', job_id):
        raise ValueError('invalid report job id')
    document = json.loads((cron / 'jobs.json').read_text())
    jobs = document['jobs'] if isinstance(document, dict) else document
    job = next((j for j in jobs if j['id'] == job_id), None)
    if not job or job.get('last_status') != 'ok':
        return None
    finished = dt.datetime.fromisoformat(job['last_run_at'])
    if finished.tzinfo is None:
        raise ValueError('report completion must have timezone')
    # Publication never adopts a new in-flight output under a prior success.
    if job.get('fire_claim') or job.get('run_claim'):
        return None
    outputs = sorted((cron / 'output' / job_id).glob('*.md'))
    if not outputs:
        return None
    latest = outputs[-1]
    if latest.is_symlink():
        raise ValueError('symlink output is not accepted')
    age = finished.timestamp() - latest.stat().st_mtime
    if not -1 <= age <= 120 or latest.stat().st_size > 1_000_000:
        raise ValueError('output does not match successful completion')
    text = latest.read_text(encoding='utf-8')
    # Split off the saved prompt, which itself mentions these markers.
    _, separator, response = text.partition('\n## Response\n')
    if not separator:
        raise ValueError('native response section missing')
    match = re.fullmatch(r'\s*BEGIN_REPORT\s*\n(.*?)\nEND_REPORT\s*', response, re.S)
    if not match or not 200 <= len(match[1]) <= 170_000:
        raise ValueError('complete report markers missing or invalid length')
    day = finished.astimezone(TZ).date().isoformat()
    return day, {'post_type': 'article', 'visibility': 'public',
                 'title': f'Hermes 信息日报 | {day}', 'content': match[1].strip(),
                 'tags': ['Hermes', '地缘局势', '国际财经', 'AI论文', '程序员就业']}


def deliver():
    if dt.datetime.now(TZ).hour < 20:
        return 'Outside publication window; no changes.'
    if not Path('/credentials/HUBLOG_SERVICE_TOKENS').is_file():
        raise ValueError('Hublog credential unavailable')
    delivery.ROOT.mkdir(parents=True, exist_ok=True)
    candidate = report_payload()
    if candidate:
        day, payload = candidate
        folder = delivery.ROOT / day
        folder.mkdir(exist_ok=True)
        target = folder / 'payload.json'
        if not target.exists():
            delivery.atomic(target, payload)
    # Reuse frozen payloads and hermes-daily:<date>:v1 keys from the old publisher.
    delivery.publish()
    return 'Publication checked; successful deliveries have persisted receipts.'


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, code, message):
        body = (message + '\n').encode()
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply(200 if self.path == '/healthz' else 404, 'publisher')

    def do_POST(self):
        if self.path != '/publish' or self.headers.get('Content-Length', '0') != '0' or self.headers.get('Transfer-Encoding'):
            self.reply(400, 'Only an empty publication trigger is accepted.')
            return
        try:
            self.reply(200, deliver())
        except Exception as exc:
            # Never expose upstream bodies, tokens or private cron contents.
            print(f'Publication failed: {type(exc).__name__}', flush=True)
            self.reply(503, 'Publication failed; check publisher configuration and receipts.')


if __name__ == '__main__':
    HTTPServer(('0.0.0.0', 8090), Handler).serve_forever()
