"""Native pre-run gate: no model calls before 20:00, at most two starts/day."""
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
from zoneinfo import ZoneInfo

now = dt.datetime.now(ZoneInfo('Asia/Shanghai'))
root = Path(os.environ.get('HERMES_HOME', '/opt/data')) / 'cron'
with (root / '.intelligence-budget.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    path = root / 'intelligence-budget.json'
    state = json.loads(path.read_text()) if path.exists() else {}
    day = now.date().isoformat()
    count = state.get('count', 0) if state.get('day') == day else 0
    allowed = now.hour >= 20 and count < 2
    if allowed:
        temp = path.with_suffix('.tmp')
        temp.write_text(json.dumps({'day': day, 'count': count + 1}))
        temp.replace(path)
    print(json.dumps({'wakeAgent': allowed, 'date': day, 'timezone': 'Asia/Shanghai',
                      'reason': 'evening research' if allowed else 'outside window or daily limit'}))
