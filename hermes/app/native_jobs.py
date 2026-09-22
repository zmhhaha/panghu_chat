"""Install native jobs once; the dashboard owns subsequent edits and deletion."""
import fcntl
import json
import os
from pathlib import Path
import shutil


def install():
    from cron.jobs import create_job, list_jobs

    home = Path(os.environ.get('HERMES_HOME', '/opt/data'))
    cron = home / 'cron'
    cron.mkdir(parents=True, exist_ok=True)
    scripts = home / 'scripts'
    scripts.mkdir(exist_ok=True)
    for name in ('intelligence_gate.py', 'intelligence_publish.py'):
        shutil.copyfile(Path('/opt/intelligence/scripts') / name, scripts / name)
    with (cron / '.intelligence-install.lock').open('w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        marker = cron / 'intelligence-install.json'
        if marker.exists():
            print('Native intelligence jobs already installed; dashboard settings preserved.')
            return
        # Recover a partial installation by exact names instead of duplicating jobs.
        jobs = {j['name']: j for j in list_jobs(include_disabled=True)}
        definitions = [
            dict(name='Intelligence daily report', schedule='0 20 * * *',
                 prompt=Path('/opt/intelligence/config/native-report-prompt.txt').read_text(),
                 script='intelligence_gate.py', enabled_toolsets=['web'], deliver='local'),
            dict(name='Intelligence Hublog publication', schedule='*/10 20-23 * * *',
                 prompt='', script='intelligence_publish.py', no_agent=True, deliver='local'),
        ]
        ids = {}
        for key, definition in zip(('report', 'publish'), definitions):
            job = jobs.get(definition['name']) or create_job(**definition)
            ids[key] = job['id']
            print(f"Native job {key}: {job['id']}")
        temp = marker.with_suffix('.tmp')
        temp.write_text(json.dumps(ids) + '\n')
        temp.replace(marker)


if __name__ == '__main__':
    install()
