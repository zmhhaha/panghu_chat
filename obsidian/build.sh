#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
command -v git >/dev/null || { echo 'git is required.' >&2; exit 1; }

if [[ -f build.local.env ]]; then
    # Trusted operator configuration only; this file is ignored by Git.
    source build.local.env
fi

REGISTRY="${REGISTRY:-arm-cluster-master:5000}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
NODE_IMAGE="${NODE_IMAGE:-arm64v8/node:22-bookworm-slim}"
COUCHDB_UPSTREAM="${COUCHDB_UPSTREAM:-docker.io/library/couchdb:3}"
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"

# The CLI and the Obsidian plugin have to agree on the vault schema, and the
# CLI has no published container image, so its source is built from an exact
# commit. A branch name would silently change what the materializer runs the
# next time someone rebuilds.
: "${LIVESYNC_REF:?Set LIVESYNC_REF to an exact upstream commit SHA in build.local.env.}"
if [[ ! "${LIVESYNC_REF}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "LIVESYNC_REF must be a full 40-character commit SHA, got: ${LIVESYNC_REF}" >&2
    echo 'Resolve one with:' >&2
    echo '  git ls-remote https://github.com/vrtmrz/obsidian-livesync.git refs/heads/main' >&2
    exit 1
fi

echo "Pulling ARM64 Node base: ${NODE_IMAGE}"
docker pull --platform linux/arm64 "${NODE_IMAGE}"
node_arch="$(docker image inspect "${NODE_IMAGE}" --format '{{.Architecture}}')"
[[ "${node_arch}" == arm64 ]] || { echo "Expected arm64 base, got ${node_arch}." >&2; exit 1; }
NODE_DIGEST="$(docker image inspect "${NODE_IMAGE}" --format '{{index .RepoDigests 0}}')"
[[ "${NODE_DIGEST}" == *@sha256:* ]] || { echo 'Could not resolve the base image digest.' >&2; exit 1; }

mkdir -p rendered

echo "Fetching obsidian-livesync at ${LIVESYNC_REF}"
rm -rf upstream
mkdir -p upstream
git -C upstream init -q
git -C upstream remote add origin https://github.com/vrtmrz/obsidian-livesync.git
git -C upstream fetch -q --depth 1 origin "${LIVESYNC_REF}"
git -C upstream checkout -q FETCH_HEAD
resolved="$(git -C upstream rev-parse HEAD)"
[[ "${resolved}" == "${LIVESYNC_REF}" ]] || {
    echo "Checked out ${resolved}, expected ${LIVESYNC_REF}." >&2
    exit 1
}

# The Dockerfile references src/apps/cli paths relative to the build context,
# so it is copied into the checkout rather than passed by -f from outside.
cp livesync-cli/Dockerfile upstream/Dockerfile.livesync

CLI_IMAGE="${REGISTRY}/livesync-cli:${IMAGE_TAG}"
echo "Building ${CLI_IMAGE}"
docker build --platform linux/arm64 \
    --build-arg "NODE_IMAGE=${NODE_DIGEST}" \
    --build-arg "NPM_REGISTRY=${NPM_REGISTRY}" \
    -f upstream/Dockerfile.livesync \
    -t "${CLI_IMAGE}" upstream
docker push "${CLI_IMAGE}"

# Fail loudly here rather than at 03:00 inside a CronJob. `couchdb:3` is a
# multi-architecture tag; the cluster is arm64-only, so a silent amd64 pull
# would produce a manifest that never starts.
echo "Pulling ARM64 ${COUCHDB_UPSTREAM}"
docker pull --platform linux/arm64 "${COUCHDB_UPSTREAM}"
couch_arch="$(docker image inspect "${COUCHDB_UPSTREAM}" --format '{{.Architecture}}')"
[[ "${couch_arch}" == arm64 ]] || { echo "Expected arm64 CouchDB, got ${couch_arch}." >&2; exit 1; }
COUCHDB_DIGEST="$(docker image inspect "${COUCHDB_UPSTREAM}" --format '{{index .RepoDigests 0}}')"
COUCHDB_TAG="${COUCHDB_UPSTREAM##*:}"
COUCHDB_IMAGE="${REGISTRY}/couchdb:${COUCHDB_TAG}"
docker tag "${COUCHDB_UPSTREAM}" "${COUCHDB_IMAGE}"
docker push "${COUCHDB_IMAGE}"

# The manifests use :latest with imagePullPolicy: Always. A redeploy therefore
# has to be paired with an explicit rollout restart, as noted in deploy.sh.
docker tag "${CLI_IMAGE}" "${REGISTRY}/livesync-cli:latest"
docker push "${REGISTRY}/livesync-cli:latest"
docker tag "${COUCHDB_IMAGE}" "${REGISTRY}/couchdb:latest"
docker push "${REGISTRY}/couchdb:latest"

printf '%s\n' "${NODE_DIGEST}" > rendered/base-image.txt
printf '%s\n' "${LIVESYNC_REF}" > rendered/livesync-ref.txt
printf '%s\n' "${COUCHDB_DIGEST}" > rendered/couchdb-image.txt
docker image inspect "${CLI_IMAGE}" --format '{{index .RepoDigests 0}}' > rendered/livesync-cli-image.txt

echo 'Build complete.'
cat rendered/livesync-cli-image.txt
cat rendered/couchdb-image.txt
echo 'Run bash deploy.sh to apply the Kubernetes resources.'
