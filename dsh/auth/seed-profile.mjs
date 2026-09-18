// Seed the DSH web profile with the SSH remote composition, before DSH starts.
//
// Runs once per container start, ahead of the supervisor spawning dsh. It is
// idempotent and offline: the provider packages ship inside the image as
// tarballs, so a boot never downloads anything and the pinned set cannot drift.
//
// Failure is fatal. If the profile cannot be composed for the SSH remote, the
// container must not come up running commands locally instead -- that is the
// exact state this composition exists to remove, and it would fail silently.
import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const DEP_DIR = '/opt/dsh-ssh-deps';
const PATCH_SOURCE = '/opt/dsh-config/cordis.patch.yml';
const PATCH_NAME = 'cordis.patch.yml';

// Must track the DSH release pinned in the image; the family is published only
// on the 0.1.6 line and its peers require the same version.
const PROVIDERS = [
  'dsh-ssh',
  'dsh-fs-ssh',
  'dsh-subprocess-ssh',
  'dsh-sandbox-ssh',
];

const home = process.env.DSH_HOME ?? join(process.env.HOME ?? homedir(), '.dsh');
const profile = join(home, 'profiles', 'web');

function log(message) {
  process.stdout.write(`[seed-profile] ${message}\n`);
}

function run(args) {
  return execFileSync('dsh', args, { stdio: ['ignore', 'pipe', 'pipe'] }).toString();
}

// dsh materialises $DSH_HOME/profiles/web from the shipped template on first
// boot. Booting with --help loads the profile without binding a server, which
// is the cheapest way to make that happen before we write into it.
if (!existsSync(join(profile, 'package.json'))) {
  log('profile not materialised yet; booting once to initialise it');
  run(['--profile', 'web', '--help']);
}
if (!existsSync(join(profile, 'package.json'))) {
  throw new Error(`profile was not created at ${profile}`);
}

// Write the composition. Always overwrite: this file belongs to the image, and
// a stale copy would keep redirecting execution to the wrong place.
const source = readFileSync(PATCH_SOURCE, 'utf8');
const target = join(profile, PATCH_NAME);
const previous = existsSync(target) ? readFileSync(target, 'utf8') : null;
if (previous !== source) {
  writeFileSync(target, source, 'utf8');
  log(`${previous === null ? 'wrote' : 'replaced'} ${target}`);
} else {
  log(`${target} already current`);
}

// Install the providers from the baked tarballs. `dsh plugin` forwards to pnpm
// inside the profile directory, which is the documented install path; using
// file: specifiers keeps it offline and pinned.
for (const name of PROVIDERS) {
  const tarball = join(DEP_DIR, `${name}.tgz`);
  if (!existsSync(tarball)) throw new Error(`missing bundled provider ${tarball}`);
}
const manifestPath = join(profile, 'package.json');
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
const missing = PROVIDERS.filter((name) => !(`file:${join(DEP_DIR, `${name}.tgz`)}` in (manifest.dependencies ?? {})) && !(`@deepseek-ai/${name}` in (manifest.dependencies ?? {})));
if (missing.length) {
  log(`adding providers: ${missing.join(', ')}`);
  for (const name of missing) {
    execFileSync('dsh', ['plugin', '--profile', 'web', 'add', `file:${join(DEP_DIR, `${name}.tgz`)}`],
      { stdio: ['ignore', 'pipe', 'pipe'] });
  }
} else {
  log('providers already present');
}

// The composition resolves provider names from the profile, so a silent
// resolution failure would surface much later as a broken session. Check the
// rows we depend on are actually declared before letting DSH start.
const installed = JSON.parse(readFileSync(manifestPath, 'utf8')).dependencies ?? {};
for (const name of PROVIDERS) {
  const ok = Object.keys(installed).some((key) => key === `@deepseek-ai/${name}` || key.endsWith(`/${name}`));
  if (!ok) throw new Error(`provider @deepseek-ai/${name} is not a profile dependency`);
}

// --- transport keys ---------------------------------------------------------
// A Secret volume is owned by root with its group set by fsGroup, and ssh
// refuses a private key that is group- or world-readable, so the files cannot
// be used where they are mounted. Copy them into the user's home with the
// modes ssh insists on. That home sits under the data root but outside
// DSH_HOME, and after this composition nothing the agent runs can reach it:
// agent execution happens on the remote.
const sshDir = join(process.env.HOME ?? homedir(), '.ssh');
const secretDir = process.env.DSH_SSH_SECRET_DIR ?? '/secrets/ssh';
mkdirSync(sshDir, { recursive: true, mode: 0o700 });
chmodSync(sshDir, 0o700);
for (const [name, mode] of [['id_ed25519', 0o600], ['known_hosts', 0o644]]) {
  const from = join(secretDir, name);
  if (!existsSync(from)) throw new Error(`missing ${from}`);
  const to = join(sshDir, name);
  copyFileSync(from, to);
  chmodSync(to, mode);
}
log(`transport keys materialised in ${sshDir}`);

log(`ready: ${PROVIDERS.length} providers composed into ${profile}`);
