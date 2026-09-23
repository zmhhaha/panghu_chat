#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
EXTERNAL_SECRET="${ROOT_DIR}/vault/inventory/obsidian-externalsecret.yaml"
OAUTH_CONFIG="${ROOT_DIR}/oauth/k8s/obsidian-proxy-configmap.yaml"

usage() {
    cat <<'EOF'
Usage: bash deploy.sh [--dry-run]

Applies the Obsidian namespace, ConfigMaps, PVCs, ExternalSecret, Deployment
and ClusterIP Service. Prepare the Vault secret before deployment.
Configure the Cloudflare Public Hostname separately for public access.

  --dry-run   Print the apply order without contacting the cluster.
  --help      Show this message.
EOF
}

case "${1:-}" in
    '') ;;
    --dry-run)
        echo 'Preview only; no cluster changes.'
        echo "  1. ${SCRIPT_DIR}/k8s/namespace.yaml"
        echo "  2. ${OAUTH_CONFIG}"
        echo "  3. ${SCRIPT_DIR}/k8s/storage.yaml"
        echo "  4. ${EXTERNAL_SECRET}"
        echo '  5. wait for externalsecret/obsidian-oidc Ready'
        echo "  6. ${SCRIPT_DIR}/k8s/deployment.yaml"
        echo "  7. ${SCRIPT_DIR}/k8s/service.yaml"
        echo '  Manual: Cloudflare Public Hostname -> http://obsidian.obsidian.svc.cluster.local:4180'
        echo "  Route record: ${ROOT_DIR}/cloudflare-tunnel/operator/tunnel-routes.yaml (not applied)"
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

for manifest in "${EXTERNAL_SECRET}" "${OAUTH_CONFIG}"; do
    [[ -f "${manifest}" ]] || {
        echo "Missing ${manifest}. Use a full armbianbegin checkout including panghu_chat." >&2
        exit 1
    }
done

kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"
kubectl apply -f "${OAUTH_CONFIG}"
kubectl apply -f "${SCRIPT_DIR}/k8s/storage.yaml"
kubectl apply -f "${EXTERNAL_SECRET}"

kubectl -n obsidian wait \
    --for=condition=Ready externalsecret/obsidian-oidc \
    --timeout=180s

kubectl apply -f "${SCRIPT_DIR}/k8s/deployment.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/service.yaml"

kubectl -n obsidian rollout restart deployment/obsidian
kubectl -n obsidian rollout status deployment/obsidian --timeout=300s

cat <<'EOF'
Applied.

Next steps:
  1. Configure Cloudflare Public Hostname obsidian.panghuer.top
     -> http://obsidian.obsidian.svc.cluster.local:4180.
     The entry in cloudflare-tunnel/operator/tunnel-routes.yaml is a record,
     not an automatically activated route.
  2. Open the site with an email present in obsidian-owner.
  3. Select /config/obsidian-vault as the Obsidian Vault directory.
EOF
