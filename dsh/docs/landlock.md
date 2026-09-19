# Landlock migration status

2026-09-19: implementation prepared, deployment blocked by the target runtime.

The existing ARM64 runner already contains the official launcher at
`/opt/dsh-remote/node_modules/@deepseek-ai/node-addon-system-linux-arm64/bin/landlock-run`.
Installing another npm launcher does not enable missing kernel support.

Read-only probes on the actual runner (kernel `6.1.115-vendor-rk35xx`):

- `landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION)` returned
  `-1`, errno `38` (`ENOSYS`).
- Official `landlock-run --probe` exited `125` with
  `landlock is not enforced by this kernel (ABI unsupported or disabled)`.

The repository now omits bubblewrap from the next runner image, verifies the
official launcher exists, probes it before starting SSH, and uses
`RuntimeDefault` in the runner template. No live deployment was changed.
Do not deploy this image on the current node: the startup gate will reject it.

---

## Resolved 2026-09-19 → 20

**The gate was removed before deploying**, because on this fleet it could only ever refuse to start. What actually shipped:

- The runner image still omits bubblewrap and still ships the official Landlock launcher, but **neither is a startup requirement**. `runner/entrypoint.sh` logs one diagnostic line about the missing backend and starts sshd.
- The runner template is back on `RuntimeDefault` — it had been relaxed to `Unconfined` only to let bubblewrap create namespaces, and bubblewrap is gone.
- The session runs `danger-full-access`, and **the boundary is the Kubernetes container**, not an inner sandbox.

**Landlock remains unavailable on every kernel in this fleet.** Verified on all three builds present:

| nodes | kernel | result |
|---|---|---|
| master, orangepi5-max-server1 (RK3588) | `6.1.115-vendor-rk35xx` | `CONFIG_SECURITY_LANDLOCK is not set`; syscall `ENOSYS` |
| nanopct4-server1/3 (RK3399) | `6.18.35-current-rockchip64` | same |

Note the RK3399 nodes run a **completely different, much newer** kernel and still lack it — this is a build option, not a version. Reviving this line would need a **rebuilt kernel**, not a configuration change. See [ssh-remote.md](ssh-remote.md) 第十节.

Next prerequisite: inspect the actual runner node's kernel configuration,
active LSM list and syscall filtering. Select a kernel/node with Landlock
enabled, then verify the official functional probe as UID 10000 with dropped
capabilities, no-new-privileges and RuntimeDefault before replacing the runner.
Kernel upgrades and node reboots affect other services and require a separate
maintenance plan. Do not add SYS_ADMIN, privileged or Unconfined as a workaround.

Important scope correction: the official DSH Landlock profile grants read-only
access to `/`, and write access to the workspace and `/tmp` in workspace-write
mode. It does NOT hide `/state` or `/secrets`. Achieving credential read isolation
requires additional policy/integration work or separating transport credentials
from the execution identity. File tools must be audited separately from subprocess
confinement. Neither switching backends nor a successful launcher probe proves
the full project boundary is satisfied.

Acceptance still required: denied writes on a writable directory outside the
workspace (not merely an already read-only `/etc`), child inheritance, symlink
escape, credential reads, remote Bash/PTY/files, cancellation and network limits.
