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
  // Carry the overlay so even this initialising boot composes the same tree the
  // real launch will compose.
  run(['--profile', 'web', '--patch', PATCH_SOURCE, '--help']);
}
if (!existsSync(join(profile, 'package.json'))) {
  throw new Error(`profile was not created at ${profile}`);
}

// The profile's cordis.patch.yml is the *user* layer. DSH's own plugin manager
// writes row overrides (`disabled`) and row config into it, and UI settings land
// in the home-level patch, so this script must not own it: overwriting it on every
// start (which is what an earlier version did) silently discarded every row toggle
// and row config the plugin manager had saved.
//
// This deployment's composition therefore ships as a `--patch` overlay instead
// (see k8s/web.yaml). DSH applies overlays *after* the profile layer, so the
// redirect still wins -- and now it also cannot be lost or edited away.
const source = readFileSync(PATCH_SOURCE, 'utf8');
const target = join(profile, PATCH_NAME);
// `[]` is how a patch file disables its layer; an empty or comments-only file
// fails boot, so the empty user layer is spelled this way.
const EMPTY_USER_LAYER = '[]\n';
const previous = existsSync(target) ? readFileSync(target, 'utf8') : null;
if (previous === null) {
  writeFileSync(target, EMPTY_USER_LAYER, 'utf8');
  log(`created the empty user patch layer ${target}`);
} else if (previous === source) {
  // Migration: this file is the image's composition, written here by an earlier
  // version of this script. The same rows now arrive through --patch, so hand the
  // file back to the user layer.
  writeFileSync(target, EMPTY_USER_LAYER, 'utf8');
  log(`emptied ${target}; the composition now comes from the --patch overlay`);
} else {
  log(`${target} is a user layer; left alone`);
}

// Fail closed if the launch arguments no longer carry the overlay: without it the
// profile would come up with no redirect at all, executing commands locally.
const overlayArgs = process.argv.filter((arg) => arg === '--patch' || arg.startsWith('--patch='));
if (!overlayArgs.length) {
  throw new Error(
    `the container must launch dsh with --patch ${PATCH_SOURCE}; without it the profile has no ` +
      'composition and would run commands locally instead of in the project container',
  );
}
log(`composition overlay declared: ${overlayArgs.join(' ')}`);

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
