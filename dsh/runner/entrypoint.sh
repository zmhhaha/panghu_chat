#!/usr/bin/env bash
# DSH remote helper endpoint: non-root sshd on 2222.
#
# Runs as uid 10000. The container has a read-only root and no privileges, so
# this script's job is narrow: materialise the deployment-owned keys into a
# writable location with the modes sshd insists on, verify they exist, and hand
# over. It must fail closed -- a runner that starts without a usable transport
# is worse than one that does not start, because the web side would then be
# free to fall back to local execution.
set -Eeuo pipefail

SECRET_DIR="${SSH_SECRET_DIR:-/secrets/ssh}"
STATE_DIR="${SSH_STATE_DIR:-/state}"

log() { printf 'dsh-runner: %s\n' "$*"; }
fail() { printf 'dsh-runner: %s\n' "$*" >&2; exit 1; }

# --- keys -------------------------------------------------------------------
# Copy rather than mount: secret volumes are owned by root with the group set
# by fsGroup, and sshd refuses a host key whose mode or owner it dislikes. The
# copy gives us exact control, and the source stays read-only.
install -d -m 0700 "$STATE_DIR"

install_key() {
  local name="$1" mode="$2"
  [[ -s "${SECRET_DIR}/${name}" ]] || fail "missing ${SECRET_DIR}/${name}"
  install -m "$mode" "${SECRET_DIR}/${name}" "${STATE_DIR}/${name}"
}

install_key ssh_host_ed25519_key 0600
install_key authorized_keys 0600

# The public half is only needed if something downstream asks for it; keep it
# out of the way rather than making it part of the contract.
if [[ -s "${SECRET_DIR}/ssh_host_ed25519_key.pub" ]]; then
  install -m 0644 "${SECRET_DIR}/ssh_host_ed25519_key.pub" "${STATE_DIR}/ssh_host_ed25519_key.pub"
fi

chmod 0700 "$STATE_DIR"

# --- runtime dir ------------------------------------------------------------
# sshd wants /run/sshd when it can have it. The root filesystem is read-only,
# so this only succeeds when a writable /run is mounted; non-root sshd works
# without it, so a failure here is not fatal.
mkdir -p /run/sshd 2>/dev/null || log 'no writable /run; continuing without it'

# --- listener ---------------------------------------------------------------
# `sshd -D` stays in the foreground so the container's lifecycle is the
# server's. Any configuration error exits non-zero and the pod restarts rather
# than serving a half-configured transport.
log 'starting sshd on 2222'
exec /usr/sbin/sshd -D -e -f /etc/ssh/sshd_config
