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
for name in dsh-model dsh-oidc; do
    kubectl -n dsh wait --for=condition=Ready "externalsecret/${name}" --timeout=180s
done
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
