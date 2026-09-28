#!/bin/sh
# Git-only SSH wrapper; never used for DSH's internal SSH transport.
set -eu
umask 077
source=/var/run/github-ssh
[ -s "$source/id_ed25519" ] && [ -s "$source/known_hosts" ] || {
    echo 'GitHub SSH Secret is missing id_ed25519 or verified known_hosts' >&2
    exit 1
}
# Secret volumes are root-owned/fsGroup-readable. OpenSSH needs a private
# user-owned copy. Keep it outside persistent workspaces and remove on exit.
temp=$(mktemp -d /tmp/github-ssh.XXXXXXXX)
trap 'rm -rf "$temp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$source/id_ed25519" "$temp/key"
chmod 600 "$temp/key"
ssh -F /dev/null -o HostName=ssh.github.com -p 443 -l git \
    -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$source/known_hosts" \
    -o GlobalKnownHostsFile=/dev/null -o ForwardAgent=no \
    -o ClearAllForwardings=yes -o ConnectTimeout=15 -i "$temp/key" "$@"
