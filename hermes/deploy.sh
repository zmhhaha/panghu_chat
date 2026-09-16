#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
if [[ "${APPLY:-false}" != true ]]; then
    echo 'Manifests: k8s/, ../../oauth/k8s/hermes-proxy-configmap.yaml'
    echo 'Set APPLY=true to deploy. CronJobs remain suspended.'
    exit 0
fi
kubectl create namespace hermes --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f ../../vault/inventory/hermes-externalsecret.yaml
for name in hermes-model hermes-oidc hermes-hublog; do
    kubectl -n hermes wait --for=condition=Ready "externalsecret/${name}" --timeout=180s
done
kubectl apply -f ../../oauth/k8s/hermes-proxy-configmap.yaml
kubectl apply -f k8s/
kubectl -n hermes rollout restart deployment/hermes-web
echo 'Applied. Verify owner email and model settings before enabling CronJobs.'
