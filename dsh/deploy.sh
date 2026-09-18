#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

usage() {
    cat <<'EOF'
Usage: bash deploy.sh [--dry-run]

Applies namespaces, Vault ExternalSecrets, OAuth ConfigMaps and k8s/ manifests,
then restarts dsh-web. Project work containers are NOT created here; use
provision.sh for those.

  --dry-run   Print the apply order without contacting the cluster.
  --help      Show this message.
EOF
}

case "${1:-}" in
    '')
        ;;
    --dry-run)
        echo 'Preview only; no cluster changes.'
        echo 'Apply order:'
        echo "  1. ${SCRIPT_DIR}/k8s/namespaces.yaml   (dsh, dsh-runners)"
        echo "  2. ${ROOT_DIR}/vault/inventory/dsh-externalsecret.yaml   (wait Ready)"
        echo "  3. ${ROOT_DIR}/oauth/k8s/dsh-proxy-configmap.yaml"
        echo "  4. ${SCRIPT_DIR}/k8s/"
        echo '  5. rollout restart deployment/dsh-web'
        echo 'Project containers are separate: bash provision.sh <project>'
        exit 0
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        echo "Unknown argument: $1" >&2
        usage >&2
        exit 2
        ;;
esac
if [[ $# -gt 1 ]]; then
    usage >&2
    exit 2
fi

command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
[[ -d "${ROOT_DIR}/vault/inventory" ]] || {
    echo "Run this from a full repository checkout; ${ROOT_DIR} has no vault/inventory." >&2
    exit 1
}

# Guard: the project work container is a sed template, not a manifest. It must
# never be applied with its placeholders intact.
# Kept as a BRE-friendly pattern so the guard cannot silently match nothing.
if grep -rIl '__[A-Z_][A-Z_]*__' "${SCRIPT_DIR}/k8s" >/dev/null 2>&1; then
    echo 'k8s/ contains unresolved __PLACEHOLDER__ values; refusing to apply.' >&2
    grep -rIl '__[A-Z_][A-Z_]*__' "${SCRIPT_DIR}/k8s" >&2
    exit 1
fi

kubectl apply -f "${SCRIPT_DIR}/k8s/namespaces.yaml"
kubectl apply -f "${ROOT_DIR}/vault/inventory/dsh-externalsecret.yaml"
for name in dsh-model dsh-oidc dsh-ssh-client; do
    kubectl -n dsh wait --for=condition=Ready "externalsecret/${name}" --timeout=180s
done
# The host half of the transport keypair lives beside the project containers.
kubectl -n dsh-runners wait --for=condition=Ready externalsecret/dsh-ssh-host --timeout=180s

# Provider configuration for the web pod.
#
# DSH_SSH_HELPER_HASH is the digest of the helper installed in the runner image,
# so it is taken from the build rather than committed: dsh-ssh verifies the
# installed helper against it before it will use the connection, and a stale
# value fails closed at session start rather than silently.
helper_hash="${SCRIPT_DIR}/rendered/helper.sha256"
if [[ ! -s "${helper_hash}" ]]; then
    echo "Missing ${helper_hash}. Run bash build.sh (it builds both images) first." >&2
    exit 1
fi
ssh_env="$(mktemp)"
trap 'rm -f "${ssh_env}"' EXIT
cat "${SCRIPT_DIR}/config/ssh.env" > "${ssh_env}"
printf 'DSH_SSH_HELPER_HASH=%s\n' "$(cat "${helper_hash}")" >> "${ssh_env}"
kubectl -n dsh create configmap dsh-ssh-runtime \
    --from-env-file="${ssh_env}" --dry-run=client -o yaml | kubectl apply -f -

# The dsh-runner-* aliases. Generated from config/ssh_config so the source of
# truth stays a reviewable file rather than an inline manifest string.
kubectl -n dsh create configmap dsh-ssh-config \
    --from-file=dsh.conf="${SCRIPT_DIR}/config/ssh_config" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "${ROOT_DIR}/oauth/k8s/dsh-proxy-configmap.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/"
kubectl -n dsh rollout restart deployment/dsh-web
kubectl -n dsh rollout status deployment/dsh-web --timeout=300s

cat <<'EOF'
Applied. CronJobs do not exist for DSH.

Before opening DSH to agent execution, complete the server checklist in
README.md. Two items in particular are still open in the code:
  - the dsh container args are a candidate set, not yet validated upstream
  - the project transport listener does not exist in the runner image yet
EOF
