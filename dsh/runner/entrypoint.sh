#!/usr/bin/env bash
# DSH remote helper endpoint: non-root sshd on 2222.
#
# Runs as uid 10000 with a read-only root and no privileges, so this script
# does almost nothing: the keys were placed by the prepare-keys init container
# (see templates/runner.yaml), which is the only step that can, and this script
# only verifies them before handing over.
#
# It must fail closed. A runner that starts without a usable transport is worse
# than one that does not start, because the web side would then be free to fall
# back to local execution.
set -Eeuo pipefail

KEYS_DIR="${SSH_KEYS_DIR:-/state/keys}"

log() { printf 'dsh-runner: %s\n' "$*"; }
fail() { printf 'dsh-runner: %s\n' "$*" >&2; exit 1; }

# Placed by the init container. Checked here as well so a rendering change that
# drops the init container fails loudly instead of serving an unusable sshd.
[[ -s "${KEYS_DIR}/ssh_host_ed25519_key" ]] || fail "missing ${KEYS_DIR}/ssh_host_ed25519_key (did prepare-keys run?)"
[[ -s "${KEYS_DIR}/authorized_keys" ]] || fail "missing ${KEYS_DIR}/authorized_keys"

# sshd wants /run/sshd when it can have it. The root filesystem is read-only,
# so this only succeeds when a writable /run is mounted; non-root sshd works
# without it, so a failure here is not fatal.
mkdir -p /run/sshd 2>/dev/null || log 'no writable /run; continuing without it'

# `sshd -D` stays in the foreground so the container's lifecycle is the
# server's. Any configuration error exits non-zero and the pod restarts rather
# than serving a half-configured transport.
log 'starting sshd on 2222'
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
