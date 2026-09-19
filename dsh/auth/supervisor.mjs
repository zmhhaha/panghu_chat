import { readOwners } from './owners.mjs';
import { spawn } from 'node:child_process';
import { createAdapter } from './adapter.mjs';
import { captureLaunchOutput } from './launch-output.mjs';
// Composes the web profile with the SSH remote providers before DSH boots.
// Imported for its side effect: it runs at module evaluation, ahead of the
// spawn below, and throws rather than letting the container come up running
// commands locally.
import './seed-profile.mjs';

const authority = process.env.DSH_PUBLIC_HOST;
if (!authority || !/^[a-z0-9.-]+$/.test(authority)) throw new Error('DSH_PUBLIC_HOST must be a DNS hostname');
let token;
const server = createAdapter({ authority, getOwners: readOwners, getToken: () => token });
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
