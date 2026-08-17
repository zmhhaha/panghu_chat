#!/usr/bin/env bash
# ============================================================
# Hublog ARM64 镜像构建脚本
#
# 用法：
#   bash build.sh                 # 构建并推送 latest
#   IMAGE_TAG=v0.1.0 bash build.sh
#   bash build.sh --no-push       # 仅构建，不推送
# ============================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
if [[ -f "${ROOT_DIR}/cluster_config.sh" ]]; then
    # shellcheck disable=SC1091
    source "${ROOT_DIR}/cluster_config.sh"
fi

REGISTRY="${REGISTRY:-arm-cluster-master:5000}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="${REGISTRY}/hublog:${IMAGE_TAG}"
PUSH=true

fail() {
    printf '[hublog-build] ERROR: %s\n' "$*" >&2
    exit 1
}

case "${1:-}" in
    "") ;;
    --no-push) PUSH=false ;;
    --help|-h)
        sed -n '2,10p' "$0"
        exit 0
        ;;
    *) fail "未知参数: $1" ;;
esac

command -v docker >/dev/null 2>&1 || fail "缺少 docker"
docker info >/dev/null 2>&1 || fail "Docker daemon 不可用"

docker_arch="$(docker info --format '{{.Architecture}}')"
case "${docker_arch}" in
    arm64|aarch64) ;;
    *) fail "当前 Docker 架构为 ${docker_arch}；请在 ARM64 主节点构建，避免推送错误架构镜像" ;;
esac

printf '[hublog-build] Building %s\n' "${IMAGE}"
docker build --pull -t "${IMAGE}" "${SCRIPT_DIR}"

if [[ "${PUSH}" == true ]]; then
    printf '[hublog-build] Pushing %s\n' "${IMAGE}"
    docker push "${IMAGE}"
fi

printf '[hublog-build] Complete: %s\n' "${IMAGE}"
