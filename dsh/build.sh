#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
command -v docker >/dev/null || { echo 'Docker is required.' >&2; exit 1; }
if [[ -f build.local.env ]]; then
    # Trusted operator configuration only; this file is ignored by Git.
    source build.local.env
fi
REGISTRY="${REGISTRY:-arm-cluster-master:5000}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
NODE_IMAGE="${NODE_IMAGE:-arm64v8/node:22-bookworm-slim}"
: "${DSH_PACKAGE:?Set DSH_PACKAGE to an exact published version, e.g. deepseek-harness@0.1.6-alpha.2}"
IMAGE_TAG="${IMAGE_TAG:-$(date -u +%Y%m%dT%H%M%SZ)}"

echo "Pulling ARM64 base: ${NODE_IMAGE}"
docker pull --platform linux/arm64 "${NODE_IMAGE}"
arch="$(docker image inspect "${NODE_IMAGE}" --format '{{.Architecture}}')"
[[ "${arch}" == arm64 ]] || { echo "Expected arm64, got ${arch}" >&2; exit 1; }
NODE_DIGEST="$(docker image inspect "${NODE_IMAGE}" --format '{{index .RepoDigests 0}}')"
[[ "${NODE_DIGEST}" == *@sha256:* ]] || { echo 'Could not resolve base image digest.' >&2; exit 1; }

mkdir -p rendered

echo 'Building dsh-web'
WEB_IMAGE="${REGISTRY}/dsh-web:${IMAGE_TAG}"
docker build --platform linux/arm64 \
    --build-arg "NODE_IMAGE=${NODE_DIGEST}" \
    --build-arg "NPM_REGISTRY=${NPM_REGISTRY}" \
    --build-arg "DSH_PACKAGE=${DSH_PACKAGE}" \
    -t "${WEB_IMAGE}" .
docker push "${WEB_IMAGE}"

echo 'Building dsh-runner'
RUNNER_IMAGE="${REGISTRY}/dsh-runner:${IMAGE_TAG}"
docker build --platform linux/arm64 \
    --build-arg "NODE_IMAGE=${NODE_DIGEST}" \
    -t "${RUNNER_IMAGE}" ./runner
docker push "${RUNNER_IMAGE}"

# The deployment manifests use :latest with imagePullPolicy: Always, so a
# redeploy must be paired with an explicit rollout restart.
docker tag "${WEB_IMAGE}" "${REGISTRY}/dsh-web:latest"
docker push "${REGISTRY}/dsh-web:latest"
docker tag "${RUNNER_IMAGE}" "${REGISTRY}/dsh-runner:latest"
docker push "${REGISTRY}/dsh-runner:latest"

docker image inspect "${WEB_IMAGE}" --format '{{index .RepoDigests 0}}' > rendered/web-image.txt
docker image inspect "${RUNNER_IMAGE}" --format '{{index .RepoDigests 0}}' > rendered/runner-image.txt
printf '%s\n' "${NODE_DIGEST}" > rendered/base-image.txt
printf '%s\n' "${DSH_PACKAGE}" > rendered/dsh-package.txt

echo 'Build complete.'
cat rendered/web-image.txt
cat rendered/runner-image.txt
echo 'Run bash deploy.sh to apply. CronJobs do not exist for DSH; project containers are provisioned separately.'
