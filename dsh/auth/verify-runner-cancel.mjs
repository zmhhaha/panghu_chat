// Run inside the runner; uses the same installed process provider as SSH helper.
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const require = createRequire('/opt/dsh-remote/node_modules/@deepseek-ai/dsh-ssh/lib/helper.js');
const { Context } = await import(pathToFileURL(require.resolve('@deepseek-ai/cordis')));
const { LocalSubprocessRuntime } = await import(pathToFileURL(require.resolve('@deepseek-ai/dsh-subprocess-local')));
const ctx = new Context();
const fiber = await ctx.plugin(LocalSubprocessRuntime);
const directory = await mkdtemp(join(tmpdir(), 'dsh-cancel-audit-'));
let child;
try {
  const pidFile = join(directory, 'child.pid');
  child = ctx.subprocess.spawn({
    argv: ['/bin/bash', '-c', 'sleep 60 & echo $! > "$1"; wait', 'audit', pidFile],
    cwd: directory, env: { PATH: '/usr/bin:/bin' }, graceMs: 300,
    stdio: { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' },
  });
  let pid;
  for (let i = 0; i < 50; i++) {
    try { pid = Number((await readFile(pidFile, 'utf8')).trim()); } catch {}
    if (pid) break;
    await delay(100);
  }
  assert.ok(pid > 1, 'child process must start before cancellation');
  child.terminate();
  await child.waitForExit(AbortSignal.timeout(5000));
  let alive = false;
  try {
    const stat = await readFile(`/proc/${pid}/stat`, 'utf8');
    alive = stat.slice(stat.lastIndexOf(')') + 2).split(' ')[0] !== 'Z';
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  assert.equal(alive, false, 'ordinary child must not survive cancellation');
  console.log('PASS: installed helper process provider terminates ordinary child group.');
  console.log('Not tested: browser cancellation, detached/reparented processes or SSH disconnect.');
} finally {
  child?.terminate();
  await fiber.dispose();
  await rm(directory, { recursive: true, force: true });
}
