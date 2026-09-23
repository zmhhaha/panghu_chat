#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(pwd)"

usage() {
    cat <<'EOF'
Usage: bash deploy.sh [--dry-run]

Applies the Obsidian namespace, ConfigMaps, PVCs, ExternalSecret, Deployment
and ClusterIP Service. The Vault secret and Cloudflare Public Hostname must
exist before the deployment can become Ready.

  --dry-run   Print the apply order without contacting the cluster.
  --help      Show this message.
EOF
}

case "${1:-}" in
    '') ;;
    --dry-run)
        echo 'Preview only; no cluster changes.'
        echo "  1. ${SCRIPT_DIR}/k8s/namespace.yaml"
        echo "  2. ${SCRIPT_DIR}/k8s/config.yaml"
        echo "  3. ${SCRIPT_DIR}/k8s/storage.yaml"
        echo "  4. ${SCRIPT_DIR}/k8s/external-secret.yaml"
        echo '  5. wait for externalsecret/obsidian-oidc Ready'
        echo "  6. ${SCRIPT_DIR}/k8s/deployment.yaml"
        echo "  7. ${SCRIPT_DIR}/k8s/service.yaml"
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

command -v kubectl >/dev/null || {
    echo 'kubectl is required.' >&2
    exit 1
}

kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/config.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/storage.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/external-secret.yaml"

kubectl -n obsidian wait \
    --for=condition=Ready externalsecret/obsidian-oidc \
    --timeout=180s

kubectl apply -f "${SCRIPT_DIR}/k8s/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/service.yaml"

kubectl -n obsidian rollout status deployment/obsidian --timeout=300s

cat <<'EOF'
Applied.

Next steps:
  1. Configure Cloudflare Public Hostname obsidian.panghuer.top.
  2. Open the site with an email present in obsidian-owner.
  3. Select /config/obsidian-vault as the Obsidian Vault directory.
EOF
