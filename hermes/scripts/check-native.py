"""No-model compatibility and publication checks, using an isolated temp home."""
import datetime as dt
import json
import os
from pathlib import Path
import tempfile

with tempfile.TemporaryDirectory(prefix='hermes-native-check-') as temp:
    os.environ['HERMES_HOME'] = temp
    os.environ['TZ'] = 'Asia/Shanghai'
    from app.native_jobs import install
    from app.native_publisher import report_payload
    from cron.jobs import list_jobs, update_job
    from cron.scheduler_script import _resolve_script_path

    install()
    jobs = list_jobs(include_disabled=True)
    assert len(jobs) == 2
    ids = json.loads((Path(temp) / 'cron/intelligence-install.json').read_text())
    report = next(j for j in jobs if j['id'] == ids['report'])
    assert report['enabled_toolsets'] == ['web']
    for job in jobs:
        path, error = _resolve_script_path(job['script'])
        assert error is None and path.is_file(), error
    update_job(report['id'], {'prompt': 'Owner-edited prompt'})
    install()
    assert len(list_jobs(True)) == 2
    assert next(j for j in list_jobs(True) if j['id'] == report['id'])['prompt'] == 'Owner-edited prompt'

    # The publishing contract refuses prompt markers, failed and in-flight runs.
    cron = Path(temp) / 'fixture'
    out = cron / 'output' / ids['report']
    out.mkdir(parents=True)
    (cron / 'intelligence-install.json').write_text(json.dumps(ids))
    result = out / '2026-09-22_20-01-00.md'
    result.write_text('Prompt: BEGIN_REPORT fake END_REPORT\n\n## Response\n\nBEGIN_REPORT\n' + 'Public report. ' * 30 + '\nEND_REPORT\n')
    stamp = dt.datetime.fromtimestamp(result.stat().st_mtime, dt.timezone.utc).isoformat()
    fixture = {'id': ids['report'], 'last_status': 'ok', 'last_run_at': stamp}
    def save():
        (cron / 'jobs.json').write_text(json.dumps({'jobs': [fixture]}))
    save()
    assert report_payload(cron)[1]['content'].startswith('Public report.')
    fixture['last_status'] = 'error'
    save()
    assert report_payload(cron) is None
    fixture['last_status'] = 'ok'
    fixture['fire_claim'] = {'by': 'test'}
    save()
    assert report_payload(cron) is None
    fixture.pop('fire_claim')
    save()
    result.write_text('Prompt BEGIN_REPORT fake END_REPORT\n\n## Response\nNo valid report')
    try:
        report_payload(cron)
        raise AssertionError('invalid report accepted')
    except ValueError:
        pass
    print('PASS: native API, idempotent installation, user edits, script paths, publication guards')
