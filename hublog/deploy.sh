#!/usr/bin/env bash
# ============================================================
# Hublog 后端部署脚本
#
# 默认执行：构建镜像、初始化数据库/Vault、迁移、API/Worker、SSO、TunnelRoute。
# 用法：
#   bash deploy.sh
#   bash deploy.sh --skip-build
#   IMAGE_TAG=v0.1.0 bash deploy.sh
#   HUBLOG_DB_PASSWORD='<existing-or-new-password>' bash deploy.sh
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
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/super-admin.conf}"
export KUBECONFIG

NAMESPACE="hublog"
DB_NAME="${HUBLOG_DB_NAME:-hublog}"
DB_USER="${HUBLOG_DB_USER:-hublog}"
POSTGRES_ADMIN_USER="${POSTGRES_ADMIN_USER:-appuser}"
POSTGRES_ADMIN_DB="${POSTGRES_ADMIN_DB:-appdb}"

K8S_DIR="${SCRIPT_DIR}/k8s"
VAULT_MANIFEST="${ROOT_DIR}/vault/inventory/hublog-externalsecret.yaml"
OAUTH_DEPLOY="${ROOT_DIR}/oauth/k8s/deploy-hublog-proxy.sh"
TUNNEL_MANIFEST="${ROOT_DIR}/cloudflare-tunnel/operator/tunnel-routes.yaml"

SKIP_BUILD=false
SKIP_SSO=false
SKIP_TUNNEL=false

fail() {
    printf '[hublog] ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '2,12p' "$0"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=true ;;
        --skip-sso) SKIP_SSO=true ;;
        --skip-tunnel) SKIP_TUNNEL=true ;;
        --help|-h) usage; exit 0 ;;
        *) fail "未知参数: $1" ;;
    esac
    shift
done

for command_name in kubectl openssl python3 base64; do
    command -v "${command_name}" >/dev/null 2>&1 || fail "缺少 ${command_name}"
done
[[ -f "${KUBECONFIG}" ]] || fail "找不到 kubeconfig: ${KUBECONFIG}"
[[ -f "${VAULT_MANIFEST}" ]] || fail "找不到 Vault 清单: ${VAULT_MANIFEST}"
[[ -f "${OAUTH_DEPLOY}" ]] || fail "找不到 SSO 部署脚本: ${OAUTH_DEPLOY}"
[[ -f "${TUNNEL_MANIFEST}" ]] || fail "找不到 TunnelRoute 清单: ${TUNNEL_MANIFEST}"
[[ "${DB_NAME}" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "HUBLOG_DB_NAME 只能包含小写字母、数字和下划线"
[[ "${DB_USER}" =~ ^[a-z_][a-z0-9_]*$ ]] || fail "HUBLOG_DB_USER 只能包含小写字母、数字和下划线"

kubectl version --request-timeout=10s >/dev/null || fail "无法连接 Kubernetes API"

printf '%s\n' '=== 1. Namespace and prerequisites ==='
kubectl apply -f "${K8S_DIR}/namespace.yaml"
kubectl -n data get pod postgres-0 >/dev/null || fail "PostgreSQL Pod 不存在"
kubectl -n data get pod redis-0 >/dev/null || fail "Redis Pod 不存在"
kubectl -n vault get pod vault-0 >/dev/null || fail "Vault Pod 不存在"
kubectl get clustersecretstore vault-backend >/dev/null || fail "ClusterSecretStore vault-backend 不存在"
vault_status_json="$(kubectl -n vault exec vault-0 -- vault status -format=json 2>/dev/null || true)"
[[ -n "${vault_status_json}" ]] || fail "无法读取 Vault 状态"
if ! vault_sealed="$(printf '%s' "${vault_status_json}" | python3 -c 'import json, sys; print(str(json.load(sys.stdin)["sealed"]).lower())')"; then
    fail "无法解析 Vault 状态"
fi
[[ "${vault_sealed}" == "false" ]] || fail "Vault 当前已 sealed；请先执行: cd ${ROOT_DIR}/vault && bash scripts/unseal.sh --interactive"
kubectl -n vault exec vault-0 -- vault token lookup >/dev/null 2>&1 || \
    fail "Vault CLI 未登录；请先执行: cd ${ROOT_DIR}/vault && bash scripts/login.sh"

if [[ "${SKIP_BUILD}" == false ]]; then
    IMAGE_TAG="${IMAGE_TAG}" REGISTRY="${REGISTRY}" bash "${SCRIPT_DIR}/build.sh"
fi

postgres_admin_password="$(kubectl -n data get secret postgres-secret -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)"
redis_password="$(kubectl -n data get secret redis-secret -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)"
[[ -n "${postgres_admin_password}" ]] || fail "postgres-secret 中没有 POSTGRES_PASSWORD"
[[ -n "${redis_password}" ]] || fail "redis-secret 中没有 REDIS_PASSWORD"

existing_database_url="$(kubectl -n vault exec vault-0 -- vault kv get -field=DATABASE_URL secret/hublog/database 2>/dev/null || true)"
if [[ -z "${HUBLOG_DB_PASSWORD:-}" && -n "${existing_database_url}" ]]; then
    HUBLOG_DB_PASSWORD="$(printf '%s' "${existing_database_url}" | python3 -c 'import sys; from urllib.parse import unquote, urlsplit; print(unquote(urlsplit(sys.stdin.read()).password or ""))')"
fi
HUBLOG_DB_PASSWORD="${HUBLOG_DB_PASSWORD:-$(openssl rand -hex 24)}"
[[ -n "${HUBLOG_DB_PASSWORD}" ]] || fail "无法生成 Hublog 数据库密码"

run_admin_psql() {
    kubectl -n data exec -i postgres-0 -- \
        env PGPASSWORD="${postgres_admin_password}" \
        psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 \
        -U "${POSTGRES_ADMIN_USER}" -d "${POSTGRES_ADMIN_DB}" "$@"
}

printf '%s\n' '=== 2. PostgreSQL database and role ==='
printf '%s\n' \
    "SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', '${DB_USER}', :'hublog_password') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${DB_USER}') \\gexec" \
    "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD :'hublog_password';" \
    "SELECT format('CREATE DATABASE %I OWNER %I', '${DB_NAME}', '${DB_USER}') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}') \\gexec" \
    | run_admin_psql --set="hublog_password=${HUBLOG_DB_PASSWORD}"

kubectl -n data exec postgres-0 -- \
    env PGPASSWORD="${postgres_admin_password}" \
    psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 \
    -U "${POSTGRES_ADMIN_USER}" -d "${DB_NAME}" \
    -c "ALTER SCHEMA public OWNER TO ${DB_USER}; GRANT ALL ON SCHEMA public TO ${DB_USER};" >/dev/null

urlencode() {
    printf '%s' "$1" | python3 -c 'import sys; from urllib.parse import quote; print(quote(sys.stdin.read(), safe=""))'
}

database_password_encoded="$(urlencode "${HUBLOG_DB_PASSWORD}")"
redis_password_encoded="$(urlencode "${redis_password}")"
database_url="postgresql+asyncpg://${DB_USER}:${database_password_encoded}@postgres.data.svc.cluster.local:5432/${DB_NAME}"
redis_url="redis://:${redis_password_encoded}@redis.data.svc.cluster.local:6379/0"

printf '%s\n' '=== 3. Vault and ExternalSecret ==='
kubectl -n vault exec vault-0 -- vault kv put secret/hublog/database "DATABASE_URL=${database_url}" >/dev/null
kubectl -n vault exec vault-0 -- vault kv put secret/hublog/redis "REDIS_URL=${redis_url}" >/dev/null
kubectl apply -f "${VAULT_MANIFEST}"
if ! kubectl -n "${NAMESPACE}" wait --for=condition=Ready externalsecret/hublog-config --timeout=120s; then
    kubectl -n "${NAMESPACE}" describe externalsecret hublog-config >&2 || true
    fail "hublog-config ExternalSecret 未就绪"
fi

render_and_apply() {
    sed "s|arm-cluster-master:5000/hublog:latest|${IMAGE}|g" "$1" | kubectl apply -f -
}

printf '%s\n' '=== 4. Database migration ==='
if kubectl -n "${NAMESPACE}" get job hublog-migrate >/dev/null 2>&1; then
    active="$(kubectl -n "${NAMESPACE}" get job hublog-migrate -o jsonpath='{.status.active}')"
    [[ -z "${active}" || "${active}" == "0" ]] || fail "hublog-migrate Job 正在运行，请稍后重试"
    kubectl -n "${NAMESPACE}" delete job hublog-migrate --wait=true
fi
render_and_apply "${K8S_DIR}/migration-job.yaml"
if ! kubectl -n "${NAMESPACE}" wait --for=condition=complete job/hublog-migrate --timeout=300s; then
    kubectl -n "${NAMESPACE}" describe job hublog-migrate >&2 || true
    kubectl -n "${NAMESPACE}" logs job/hublog-migrate --all-containers=true >&2 || true
    fail "数据库迁移失败"
fi

printf '%s\n' '=== 5. API and Worker ==='
render_and_apply "${K8S_DIR}/api-deployment.yaml"
render_and_apply "${K8S_DIR}/worker-deployment.yaml"
# 默认使用 latest 标签时 Pod 模板不会变化，显式滚动以重新拉取新镜像。
kubectl -n "${NAMESPACE}" rollout restart deployment/hublog-api deployment/hublog-worker
kubectl -n "${NAMESPACE}" rollout status deployment/hublog-api --timeout=300s
kubectl -n "${NAMESPACE}" rollout status deployment/hublog-worker --timeout=300s

printf '%s\n' '=== 6. Internal readiness ==='
kubectl -n "${NAMESPACE}" exec deployment/hublog-api -- \
    python -c 'import json, urllib.request; print(json.load(urllib.request.urlopen("http://127.0.0.1:8080/health/ready", timeout=10)))'

if [[ "${SKIP_SSO}" == false ]]; then
    printf '%s\n' '=== 7. SSO proxy ==='
    bash "${OAUTH_DEPLOY}"
fi

if [[ "${SKIP_TUNNEL}" == false ]]; then
    printf '%s\n' '=== 8. Cloudflare TunnelRoute ==='
    kubectl apply -f "${TUNNEL_MANIFEST}"
fi

printf '%s\n' '=== Hublog deployment status ==='
kubectl -n "${NAMESPACE}" get deployment,pod,service,job,externalsecret -o wide
if [[ "${SKIP_SSO}" == false ]]; then
    kubectl -n oauth get deployment,service -l app=oauth2-proxy-hublog
fi

printf '%s\n' 'Hublog backend deployment complete.'
printf '%s\n' 'URL: https://hublog.panghuer.top'
printf '%s\n' 'Casdoor callback required: https://hublog.panghuer.top/oauth2/callback'
