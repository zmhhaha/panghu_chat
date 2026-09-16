#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
: "${HERMES_IMAGE:?Set upstream Hermes image with @sha256 digest}"
: "${IMAGE_TAG:?Set an immutable local image tag}"
[[ "$HERMES_IMAGE" == *@sha256:* ]] || { echo 'HERMES_IMAGE must use a digest' >&2; exit 1; }
IMAGE="${REGISTRY:-arm-cluster-master:5000}/hermes-intelligence:${IMAGE_TAG}"
docker build --platform linux/arm64 --build-arg "HERMES_IMAGE=$HERMES_IMAGE" -t "$IMAGE" .
docker push "$IMAGE"
docker image inspect "$IMAGE" --format '{{json .RepoDigests}}'
