#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

command -v docker >/dev/null || {
    echo 'Docker is required.' >&2
    exit 1
}

if [[ -f build.local.env ]]; then
    # Trusted operator configuration only; this file is ignored by Git.
    source build.local.env
fi

REGISTRY="${REGISTRY:-arm-cluster-master:5000}"
UPSTREAM_IMAGE="${UPSTREAM_IMAGE:-lscr.io/linuxserver/obsidian:latest}"
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"
IMAGE="${REGISTRY}/linuxserver/obsidian:${IMAGE_TAG}"
DEPLOY_IMAGE="${REGISTRY}/linuxserver/obsidian:latest"

echo "Pulling ARM64 image: ${UPSTREAM_IMAGE}"
docker pull --platform linux/arm64 "${UPSTREAM_IMAGE}"
architecture="$(docker image inspect "${UPSTREAM_IMAGE}" --format '{{.Architecture}}')"
[[ "${architecture}" == arm64 ]] || {
    echo "Expected ARM64 image, got ${architecture}." >&2
    exit 1
}

upstream_digest="$(docker image inspect "${UPSTREAM_IMAGE}" --format '{{index .RepoDigests 0}}')"
[[ "${upstream_digest}" == *@sha256:* ]] || {
    echo 'Could not resolve the upstream image digest.' >&2
    exit 1
}

docker tag "${UPSTREAM_IMAGE}" "${IMAGE}"
docker push "${IMAGE}"
docker tag "${IMAGE}" "${DEPLOY_IMAGE}"
docker push "${DEPLOY_IMAGE}"

mkdir -p rendered
printf '%s\n' "${upstream_digest}" > rendered/upstream-image.txt
printf '%s\n' "${IMAGE}" > rendered/image.txt

echo 'Build complete.'
echo "Deployment image: ${DEPLOY_IMAGE}"
echo "Upstream digest: ${upstream_digest}"
echo 'Run bash deploy.sh to apply the Kubernetes resources.'
