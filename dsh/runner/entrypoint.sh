#!/usr/bin/env bash
# DSH remote helper endpoint: non-root sshd on 2222.
#
# Runs as uid 10000 with a read-only root and no privileges, so this script does
# almost nothing: the keys were placed by the prepare-keys init container (see
# templates/runner.yaml), and this script only verifies them before handing over.
#
# It must fail closed. A runner that starts without a usable transport is worse
# than one that does not start, because the web side would then be free to fall
# back to local execution.
#
# There is deliberately NO sandbox-backend gate here. An earlier revision made
# the ARM64 Landlock launcher's `--probe` a startup requirement. Correct in
# intent, wrong in fact: no node in this cluster has Landlock compiled in
# (`CONFIG_SECURITY_LANDLOCK is not set`; the syscall returns ENOSYS), so the
# gate could only ever refuse to start -- it would have taken the whole
# deployment down without buying anything. Whether DSH executes a command is
# decided by its own sandbox policy, not by this script.
set -Eeuo pipefail

KEYS_DIR="${SSH_KEYS_DIR:-/state/keys}"

log() { printf 'dsh-runner: %s\n' "$*"; }
fail() { printf 'dsh-runner: %s\n' "$*" >&2; exit 1; }

# Placed by the init container. Checked here too so a rendering change that
# drops the init container fails loudly instead of serving an unusable sshd.
[[ -s "${KEYS_DIR}/ssh_host_ed25519_key" ]] || fail "missing ${KEYS_DIR}/ssh_host_ed25519_key (did prepare-keys run?)"
[[ -s "${KEYS_DIR}/authorized_keys" ]] || fail "missing ${KEYS_DIR}/authorized_keys"

# Recorded for diagnosis only, never enforced. Both Linux sandbox backends are
# unusable on this cluster: bubblewrap cannot mount procfs inside the container
# (refused even with CAP_SYS_ADMIN), and Landlock is not in the kernel. DSH
# therefore refuses to execute anything under `workspace-write`. That is a
# property of the cluster, not of the runner -- see docs/ssh-remote.md §10.
log 'no usable sandbox backend on this cluster; DSH will refuse to execute commands'

# sshd wants /run/sshd when it can have it. The root filesystem is read-only, so
# this only succeeds when a writable /run is mounted; non-root sshd works
# without it, so a failure here is not fatal.
mkdir -p /run/sshd 2>/dev/null || log 'no writable /run; continuing without it'

# `sshd -D` stays in the foreground so the container's lifecycle is the server's.
# Any configuration error exits non-zero and the pod restarts rather than
# serving a half-configured transport.
log 'starting sshd on 2222'
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
