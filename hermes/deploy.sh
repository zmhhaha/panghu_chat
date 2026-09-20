#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
case "${1:-}" in
    '') ;;
    --dry-run)
        echo 'Preview only; no cluster changes.'
        echo 'Apply order: namespace hermes, Vault ExternalSecrets (wait Ready: model, oidc; warn only: hublog), OAuth ConfigMaps, k8s/.'
        echo 'Then restart hermes-web. CronJobs remain suspended.'
        exit 0 ;;
    --help|-h)
        echo 'Usage: bash deploy.sh [--dry-run]'
        echo 'Deploys by default. --dry-run lists actions without contacting the cluster.'
        exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
if [[ $# -gt 1 ]]; then
    echo 'Usage: bash deploy.sh [--dry-run]' >&2
    exit 2
fi
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
kubectl create namespace hermes --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ../../vault/inventory/hermes-externalsecret.yaml
# Model and OIDC credentials make the workbench usable; a missing one is a real
# deployment failure. The Hublog token is not: it only gates publication, so an
# unwritten Vault path must not abort the deploy before the workbench is applied.
for name in hermes-model hermes-oidc; do
    kubectl -n hermes wait --for=condition=Ready "externalsecret/${name}" --timeout=180s
done
if ! kubectl -n hermes wait --for=condition=Ready externalsecret/hermes-hublog --timeout=20s; then
    echo 'warn: externalsecret/hermes-hublog not Ready -- publication will be skipped.' >&2
    echo 'warn: the workbench, collection and research are unaffected.' >&2
fi
kubectl apply -f ../../oauth/k8s/hermes-proxy-configmap.yaml
kubectl apply -f k8s/
kubectl -n hermes rollout restart deployment/hermes-web
kubectl -n hermes rollout status deployment/hermes-web --timeout=300s
echo 'Applied. Verify owner email and model settings before enabling CronJobs.'
