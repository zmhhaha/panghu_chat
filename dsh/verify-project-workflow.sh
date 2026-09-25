#!/usr/bin/env bash
# Run inside the runner. Only the fresh audit directory is modified.
set -Eeuo pipefail
umask 077
audit=$(mktemp -d /workspace/.dsh-workflow-audit.XXXXXXXX)
trap 'printf "Audit directory retained: %s\n" "$audit"' EXIT
export GIT_TERMINAL_PROMPT=0
# The URL is load-bearing: it must be a repository that is PUBLICLY readable.
# `sindresorhus/is-number` is not, and GitHub answers 401 with a
# `WWW-Authenticate` challenge for a private *or nonexistent* repo -- so the run
# on 2026-09-23 read as "the egress path is challenging us" when the only
# problem was this line. jonschlinkert/is-number is the upstream of the npm
# package installed below, and was verified reachable 2026-09-23.
timeout 90 git -c credential.helper= clone --depth=1 https://github.com/jonschlinkert/is-number.git "$audit/project"
cd "$audit/project"
timeout 90 npm install --ignore-scripts --no-audit --no-fund --package-lock=false \
    --registry=https://registry.npmmirror.com --prefix "$audit/dependencies" is-number@7.0.0
git -c user.name=DSH-Audit -c user.email=audit@example.invalid commit \
    --allow-empty -m 'Local-only recovery acceptance'
git rev-parse HEAD > "$audit/expected-commit"
tar -czf "$audit/project.tar.gz" -C "$audit" project dependencies expected-commit
mkdir "$audit/restored"
tar -xzf "$audit/project.tar.gz" -C "$audit/restored"
test "$(git -C "$audit/restored/project" rev-parse HEAD)" = "$(cat "$audit/expected-commit")"
node -e 'const number = require(process.argv[1]); if (!number(42) || number("no")) process.exit(1)' \
    "$audit/restored/dependencies/node_modules/is-number"
git -C "$audit/restored/project" fsck --full
printf 'PASS: public clone, dependency install, local commit and directory restore.\n'
printf 'Not tested: production PVC restore, pod restart or DSH browser tool routing.\n'
