#!/usr/bin/env bash
#
# Deploy pi-cage for panghu_chat.
#
# This directory builds nothing. pi-cage is published as a multi-arch manifest
# list and this is a deployment of it:
#
#   ghcr.io/zmhhaha/pi-cage:latest
#   index sha256:897709bdb3f6a123fd3acd5da3f02f9491a217f1c0b67ab577c61dd965b868b2
#     amd64 sha256:cbd3c1960ddc76d835d32afd22b2cb70be6b5ef071c2892aa0cf3cdd53ff6cd9
#     arm64 sha256:b0905fa77029ad7520e6433c1462298435eb318350364b401752e11aad086e19
#
# The sidecar shape it applies is the one pi-cage's own docs/auth.md recommends
# and had never been run anywhere until this deployment.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

case "${1:-}" in
    '') ;;
    --dry-run)
        echo 'Preview only; no cluster changes.'
        echo 'Apply order: namespace pi, ExternalSecrets (wait Ready: model, oidc),'
        echo 'OAuth ConfigMaps, k8s/ (storage, core, networkpolicies).'
        echo 'Then assert the cage is still bound to loopback only.'
        exit 0 ;;
    --verify-only)
        VERIFY_ONLY=1 ;;
    --help|-h)
        echo 'Usage: bash deploy.sh [--dry-run|--verify-only]'
        echo 'Deploys by default. --dry-run lists actions without contacting the cluster.'
        echo '--verify-only runs the loopback assertion against whatever is already there.'
        exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
VERIFY_ONLY="${VERIFY_ONLY:-0}"

command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }

verify_loopback() {
    # The whole argument for this deployment over pi-cage's own manifests is that
    # the cage keeps its default bind and no routable listener exists in the Pod.
    # That property is one environment variable away from disappearing, so it is
    # asserted rather than assumed.
    echo 'asserting the cage is bound to loopback only...'
    kubectl -n pi exec deploy/pi -c pi-cage -- sh -c '
        if grep -q "00000000:1E01" /proc/net/tcp; then
            echo "FAIL: 7681 is bound to 0.0.0.0 -- the sidecar shape has been broken." >&2
            echo "      Something set PI_CAGE_BIND. The proxy reaches serve over" >&2
            echo "      loopback and needs no routable port." >&2
            exit 1
        fi
        if ! grep -q "0100007F:1E01" /proc/net/tcp; then
            echo "FAIL: nothing is listening on 127.0.0.1:7681." >&2
            exit 1
        fi
        echo "ok: 7681 is loopback-only, as intended."
    '
}

if [ "$VERIFY_ONLY" = 1 ]; then
    verify_loopback
    exit 0
fi

kubectl create namespace pi --dry-run=client -o yaml | kubectl apply -f -

# Both credentials make the workbench usable, and neither is optional: without
# the model key Pi starts and reports no models, and without the OIDC pair the
# login round trip cannot complete and the terminal is unreachable. Unlike
# hermes' third secret there is nothing here that can be missing but survivable,
# so both are waited on and either failing aborts the deploy.
kubectl apply -f ../../vault/inventory/pi-externalsecret.yaml
for name in pi-model pi-oidc; do
    kubectl -n pi wait --for=condition=Ready "externalsecret/${name}" --timeout=180s
done

kubectl apply -f ../../oauth/k8s/pi-proxy-configmap.yaml
kubectl apply -f k8s/

kubectl -n pi rollout status deployment/pi --timeout=300s

verify_loopback

# Surfaces a leftover from pi-cage's own first deployment, which used its own
# namespace and the bind-0.0.0.0 shape. Two pi-cage containers against one
# cluster is one more than intended, and the older one has no authenticating
# proxy in front of it.
if kubectl get namespace pi-cage >/dev/null 2>&1; then
    echo >&2
    echo 'note: namespace pi-cage still exists and runs a second pi-cage container,' >&2
    echo 'note: with no proxy in front of it. This deployment supersedes it.' >&2
    echo 'note: confirm the login path first, then:  kubectl delete namespace pi-cage' >&2
fi

echo
echo 'Applied. Next:'
echo '  - the Casdoor app behind secret/pi/oidc must have'
echo '    https://pi.panghuer.top/oauth2/callback registered as a redirect URL'
echo '  - add users to the allow-list:  kubectl -n pi edit configmap pi-owner'
