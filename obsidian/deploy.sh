#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
EXTERNAL_SECRET="${ROOT_DIR}/vault/inventory/obsidian-externalsecret.yaml"
COUCHDB_CONFIG="${SCRIPT_DIR}/k8s/couchdb-config.yaml"
JWT_PLACEHOLDER='REPLACE_WITH_PUBLIC_KEY_PEM'

usage() {
    cat <<'EOF'
Usage: bash deploy.sh [--dry-run]

Applies the Obsidian note-sync namespace, CouchDB configuration, PVCs,
ExternalSecrets, CouchDB StatefulSet and the materializer Deployment.

  --dry-run   Print the apply order and the remaining manual steps only.
  --help      Show this message.

Before the first deploy:
  1. Create the Vault secrets (see vault/inventory/obsidian-externalsecret.yaml).
  2. Generate the JWT key pair and paste the public key into
     k8s/couchdb-config.yaml. The deploy refuses to run while the placeholder
     is still there, because CouchDB would start with no usable key.
  3. Add the Cloudflare Public Hostname for obsidian-sync.panghuer.top.
  4. Remove the retired obsidian.panghuer.top Public Hostname in Cloudflare.
EOF
}

check_jwt_placeholder() {
    if grep -q "${JWT_PLACEHOLDER}" "${COUCHDB_CONFIG}"; then
        echo "k8s/couchdb-config.yaml still contains ${JWT_PLACEHOLDER}." >&2
        echo 'Generate the key pair and paste the public key first:' >&2
        echo '  openssl ecparam -name secp521r1 -genkey -noout | openssl pkcs8 -topk8 -inform PEM -nocrypt -out private_key.pem' >&2
        echo '  openssl ec -in private_key.pem -pubout -outform PEM -out public_key.pem' >&2
        return 1
    fi
}

case "${1:-}" in
    '') ;;
    --dry-run)
        echo 'Preview only; no cluster changes.'
        echo "  1. ${SCRIPT_DIR}/k8s/namespace.yaml"
        echo "  2. ${COUCHDB_CONFIG}"
        echo "  3. ${SCRIPT_DIR}/k8s/storage.yaml"
        echo "  4. ${EXTERNAL_SECRET}"
        echo '  5. wait for externalsecret/obsidian-couchdb and obsidian-livesync Ready'
        echo "  6. ${SCRIPT_DIR}/k8s/couchdb.yaml"
        echo "  7. ${SCRIPT_DIR}/k8s/materializer.yaml"
        echo '  8. wait for statefulset/obsidian-couchdb rollout'
        echo
        echo 'Manual, not performed by this script:'
        echo '  - Vault: secret/obsidian/couchdb and secret/obsidian/livesync'
        echo '  - Cloudflare: add obsidian-sync.panghuer.top ->'
        echo '    http://obsidian-couchdb.obsidian.svc.cluster.local:5984'
        echo '  - Cloudflare: delete the retired obsidian.panghuer.top Public Hostname'
        echo '  - Onboard each device with the Setup URI'
        if ! check_jwt_placeholder 2>/dev/null; then
            echo
            echo 'NOTE: the JWT public key placeholder is still present; a real deploy would stop here.'
        fi
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

check_jwt_placeholder || exit 1

[[ -f "${EXTERNAL_SECRET}" ]] || {
    echo "Missing ${EXTERNAL_SECRET}. Use a full armbianbegin checkout including panghu_chat." >&2
    exit 1
}

kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"
kubectl apply -f "${COUCHDB_CONFIG}"
kubectl apply -f "${SCRIPT_DIR}/k8s/storage.yaml"
kubectl apply -f "${EXTERNAL_SECRET}"

for name in obsidian-couchdb obsidian-livesync; do
    kubectl -n obsidian wait \
        --for=condition=Ready "externalsecret/${name}" \
        --timeout=180s
done

kubectl apply -f "${SCRIPT_DIR}/k8s/couchdb.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/materializer.yaml"

kubectl -n obsidian rollout status statefulset/obsidian-couchdb --timeout=300s

cat <<'EOF'
Applied.

The materializer provisions itself from the Setup URI on its first start and
then follows CouchDB's change feed continuously. Watch it with:

  kubectl -n obsidian get deploy obsidian-materializer
  kubectl -n obsidian logs deploy/obsidian-materializer

It stays in CrashLoopBackOff until obsidian-livesync exists and its
setup-uri key is populated; that is the expected state before step 1 above.

Note that :latest tags with imagePullPolicy: Always do not roll a StatefulSet
or Deployment by themselves; after a rebuild run:

  kubectl -n obsidian rollout restart statefulset/obsidian-couchdb
  kubectl -n obsidian rollout restart deploy/obsidian-materializer
EOF
