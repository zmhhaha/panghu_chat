#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
CONFIG="${1:-deployment.local.yaml}"
if [[ ! -f "$CONFIG" ]]; then
    mkdir -p -- "$(dirname -- "$CONFIG")"
    cp config/deployment.example.yaml "$CONFIG"
    echo "Created $CONFIG. Fill owner_email, oidc_issuer, storage_class and node_hostname."
    echo 'Set oauth_image to an ARM64 oauth2-proxy digest.'
    echo 'The Hermes image is read from rendered/image.txt after a successful build.'
    echo "Then rerun: bash deploy.sh '$CONFIG'"
    exit 1
fi
mkdir -p rendered
python3 scripts/render.py "$CONFIG" > rendered/hermes.yaml.tmp
mv rendered/hermes.yaml.tmp rendered/hermes.yaml
if [[ "${APPLY:-false}" != true ]]; then
    echo 'Rendered rendered/hermes.yaml. Set APPLY=true to apply; CronJobs remain suspended.'
    exit 0
fi
kubectl create namespace hermes --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ../../vault/inventory/hermes-externalsecret.yaml
for name in hermes-model hermes-oidc hermes-hublog hermes-research-config; do
    kubectl -n hermes wait --for=condition=Ready "externalsecret/${name}" --timeout=180s
    kubectl -n hermes get secret "$name" >/dev/null
done
kubectl apply -f rendered/hermes.yaml
echo 'Resources applied. CronJobs are suspended. Complete the server checklist before enabling.'
