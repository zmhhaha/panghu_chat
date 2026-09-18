import { readFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { createAdapter } from './adapter.mjs';
import { captureLaunchOutput } from './launch-output.mjs';

const authority = process.env.DSH_PUBLIC_HOST;
if (!authority || !/^[a-z0-9.-]+$/.test(authority)) throw new Error('DSH_PUBLIC_HOST must be a DNS hostname');
const owners = new Set(readFileSync('/owner/emails', 'utf8').split(/\r?\n/).map(x => x.trim().toLowerCase()).filter(x => x && !x.startsWith('#')));
if (!owners.size) throw new Error('Owner allowlist is empty');
let token;
const server = createAdapter({ authority, owners, getToken: () => token });
const child = spawn('dsh', process.argv.slice(2), { detached: true, stdio: ['ignore', 'pipe', 'pipe'] });
for (const stream of [child.stdout, child.stderr]) captureLaunchOutput(stream, value => { token = value; }, value => process.stdout.write(value));
let stopping = false;
function stop(signal = 'SIGTERM') {
  if (stopping) return;
  stopping = true;
  token = undefined;
  server.close();
  try { process.kill(-child.pid, signal); } catch { /* Child may already have exited. */ }
  setTimeout(() => {
    try { process.kill(-child.pid, 'SIGKILL'); } catch { /* Already stopped. */ }
    process.exit(1);
  }, 10000).unref();
}
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => stop(signal));
child.on('error', () => { console.error('DSH child startup failed'); stop(); process.exitCode = 1; });
child.on('exit', code => {
  token = undefined;
  try { process.kill(-child.pid, 'SIGTERM'); } catch { /* No remaining process group. */ }
  server.close();
  process.exit(stopping ? 0 : (code || 1));
});
server.on('error', () => { console.error('DSH adapter listener failed'); stop(); });
server.listen(3081, '127.0.0.1');
