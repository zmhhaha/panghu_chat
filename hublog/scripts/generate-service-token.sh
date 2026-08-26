#!/usr/bin/env bash
# One-shot credential generation for all planned content agents. Set
# BOT_NAME=finance-news to print only the token entry for a newly added bot.
# Deployment: run manually on a trusted host; it only prints credentials and does not write them to Git.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DEFAULT_EXPIRY="$(date -u -d '+180 days' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
EXPIRY_AT="${TOKEN_EXPIRES_AT:-${DEFAULT_EXPIRY}}"

[[ -n "${EXPIRY_AT}" ]] || {
    printf '%s\n' '[hublog-token] ERROR: 当前系统不支持自动计算过期时间，请设置 TOKEN_EXPIRES_AT，例如 2027-02-20T00:00:00Z' >&2
    exit 1
}

BOT_ARGS=()
if [[ -n "${BOT_NAME:-}" ]]; then
    BOT_ARGS+=(--bot "${BOT_NAME}")
fi
exec "${PYTHON_BIN}" "${SCRIPT_DIR}/generate-service-tokens.py" --expires-at "${EXPIRY_AT}" "${BOT_ARGS[@]}"
