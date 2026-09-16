#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
if [[ -f build.local.env ]]; then
    # Trusted operator configuration only; this file is ignored by Git.
    source build.local.env
fi
PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
# Optional registry prefix, e.g. your private Docker Hub pull-through cache.
# Empty prefix uses Docker daemon registry-mirrors configured on the server.
DOCKERHUB_MIRROR="${DOCKERHUB_MIRROR:-}"
# Resolve the selected tag once, then build exclusively from the pulled digest.
HERMES_IMAGE="${HERMES_IMAGE:-${DOCKERHUB_MIRROR:+${DOCKERHUB_MIRROR%/}/}nousresearch/hermes-agent:latest}"
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"
echo "Pulling ARM64 upstream: $HERMES_IMAGE"
docker pull --platform linux/arm64 "$HERMES_IMAGE"
arch="$(docker image inspect "$HERMES_IMAGE" --format '{{.Architecture}}')"
[[ "$arch" == arm64 ]] || { echo "Expected arm64, got $arch" >&2; exit 1; }
upstream_digest="$(docker image inspect "$HERMES_IMAGE" --format '{{index .RepoDigests 0}}')"
[[ "$upstream_digest" == *@sha256:* ]] || { echo 'Could not resolve upstream digest.' >&2; exit 1; }
HERMES_IMAGE="$upstream_digest"
IMAGE="${REGISTRY:-arm-cluster-master:5000}/hermes-intelligence:${IMAGE_TAG}"
docker build --platform linux/arm64 --build-arg "HERMES_IMAGE=$HERMES_IMAGE" \
    --build-arg "PIP_INDEX_URL=$PIP_INDEX_URL" --build-arg "NPM_REGISTRY=$NPM_REGISTRY" -t "$IMAGE" .
docker push "$IMAGE"
mkdir -p rendered
docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}' > rendered/image.txt
printf '%s\n' "$HERMES_IMAGE" > rendered/upstream-image.txt
echo 'Build complete. Deployment image:'
cat rendered/image.txt
echo 'Run bash deploy.sh to initialize or render deployment configuration.'
