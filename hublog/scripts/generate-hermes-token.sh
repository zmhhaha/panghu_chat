#!/usr/bin/env bash
# Generate Hermes credentials only. Does not write Vault or change existing bots.
# Usage: bash generate-hermes-token.sh
# Optional: TOKEN_EXPIRES_AT=2027-03-01T00:00:00Z bash generate-hermes-token.sh
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
DEFAULT_EXPIRY="$(date -u -d '+180 days' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
EXPIRY_AT="${TOKEN_EXPIRES_AT:-${DEFAULT_EXPIRY}}"

[[ -n "${EXPIRY_AT}" ]] || {
    printf '%s\n' '[hermes-token] Set TOKEN_EXPIRES_AT to a UTC ISO-8601 expiry.' >&2
    exit 1
}

printf '%s\n' \
    'Generates a NEW token; retain your existing token unless intentionally rotating.' \
    'Store SERVICE_TOKEN as {"hermes":{"token":"..."}} in secret/hermes/auth -> HUBLOG_SERVICE_TOKENS.' \
    'Merge the hash-only hermes entry into secret/hublog/auth -> HUBLOG_SERVICE_TOKENS.' \
    'Preserve existing bot entries in both locations. Output contains a secret.' >&2

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/generate-service-token.py" \
    --name hermes \
    --username hermes_bot \
    --display-name 'Hermes 日报' \
    --expires-at "${EXPIRY_AT}"
