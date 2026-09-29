#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
EXTERNAL_SECRET="${ROOT_DIR}/vault/inventory/obsidian-externalsecret.yaml"
MODE=full

usage() {
    cat <<'EOF'
Usage: bash deploy.sh [--dry-run | --indexers]

Applies the Obsidian note-sync namespace, CouchDB configuration, PVCs,
ExternalSecrets, CouchDB StatefulSet, and -- once the Setup URI exists -- the
materializer Deployment. It also renders one indexer ExternalSecret + CronJob
per persona from the framework roster.

  --dry-run   Print the apply order and the remaining manual steps only.
  --indexers  Only re-render the indexer ExternalSecrets and CronJobs from the
              roster. This is the fast path after adding a persona: one entry in
              registry.yaml (plus its RAG_TOKEN_<SLUG> in Vault), then this.
  --help      Show this message.

Before the first deploy, create the Vault secrets. Commands are in
vault/inventory/obsidian-externalsecret.yaml. Nothing has to be pasted into a
version-controlled file: the JWT key material lives in Vault too.

The materializer needs secret/obsidian/livesync (the Setup URI), which can only
be produced by an already-configured device. If that secret is absent this
script still deploys CouchDB and skips the materializer, so the rollout can be
done in two stages.
EOF
}

CLOUDFLARE_NOTE='Cloudflare: repoint the existing obsidian.panghuer.top Public Hostname
    service to http://obsidian-couchdb.obsidian.svc.cluster.local:5984.
    The dashboard is the only place that takes effect: cloudflared runs in
    token mode with no ConfigMap mounted, and the operator never calls the
    Cloudflare API. tunnel-routes.yaml is a record only.'

case "${1:-}" in
    '') ;;
    --dry-run)
        echo 'Preview only; no cluster changes.'
        echo "  1. ${SCRIPT_DIR}/k8s/namespace.yaml"
        echo "  2. ${SCRIPT_DIR}/k8s/couchdb-config.yaml"
        echo "  3. ${SCRIPT_DIR}/k8s/storage.yaml"
        echo "  4. ${EXTERNAL_SECRET}"
        echo '  5. wait for externalsecret/obsidian-couchdb Ready'
        echo "  6. ${SCRIPT_DIR}/k8s/couchdb.yaml"
        echo "  7. ${SCRIPT_DIR}/k8s/materializer.yaml (only if obsidian-livesync is Ready)"
        echo '  8. wait for statefulset/obsidian-couchdb rollout'
        echo "  9. ConfigMap obsidian-indexer from ${SCRIPT_DIR}/indexer/index.py"
        echo " 10. per persona, from the roster:"
        echo "       ${ROOT_DIR}/vault/inventory/obsidian-indexer-externalsecret.yaml"
        echo "       ${SCRIPT_DIR}/k8s/indexer.yaml  (one CronJob per persona)"
        echo
        echo 'Manual, not performed by this script:'
        echo '  - Vault: secret/obsidian/couchdb and secret/obsidian/livesync'
        echo "  - ${CLOUDFLARE_NOTE}"
        echo '  - Onboard the first device by hand, then generate the Setup URI'
        exit 0
        ;;
    --indexers)
        MODE=indexers
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

# 索引作业按人格名册渲染，名册是 JSON（读它用 python3，和 indexer/index.py 同一个解释器）
command -v python3 >/dev/null || {
    echo 'python3 is required: the indexer jobs and their ExternalSecrets are rendered from the persona roster.' >&2
    exit 1
}

[[ -f "${EXTERNAL_SECRET}" ]] || {
    echo "Missing ${EXTERNAL_SECRET}. Use a full armbianbegin checkout including panghu_chat." >&2
    exit 1
}

# ---- 人格名册 -> 索引作业 -------------------------------------------------
# 「接入一个人格」在这里应当只是"名册加一条 + 跑一条命令"，而不是再抄一份 YAML。
# 所以索引作业不是手写的：下面按名册逐个人格渲染 k8s/indexer.yaml 与
# vault/inventory/obsidian-indexer-externalsecret.yaml。
#
# 名册就是框架自己那份 registry.yaml —— slug（决定身份与 collection）、display_name
# （决定 corpus 目录名）、rag_enabled（决定要不要建作业）都从那儿来，不另立一份。
# 有第二个"服务组"就往 SERVICE_GROUPS 里加一行 `目录名:名册路径`；作业名、身份键、
# corpus 路径、调度分钟都会跟着推出来。
SERVICE_GROUPS=(
    "百家争鸣:${ROOT_DIR}/panghu_agent/baijiazhengming/registry.yaml"
)
INDEXER_TEMPLATE="${SCRIPT_DIR}/k8s/indexer.yaml"
INDEXER_SECRET_TEMPLATE="${ROOT_DIR}/vault/inventory/obsidian-indexer-externalsecret.yaml"

# sed 的替换串里 & | \ 有特殊含义（& 会展开成整个匹配），人格名是中文也要挡住
sed_escape() { printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

# 名册 -> "服务组<TAB>slug<TAB>人格名"，顺序即名册顺序（决定调度分钟）
read_roster() {
    local spec group registry
    for spec in "${SERVICE_GROUPS[@]}"; do
        group="${spec%%:*}"
        registry="${spec#*:}"
        [[ -f "$registry" ]] || {
            echo "Missing roster: $registry (use a full armbianbegin checkout)" >&2
            return 1
        }
        python3 - "$group" "$registry" <<'PY'
import json, sys

# 名册里有中文（人格名），而它要经 stdout 走到 sed 的替换串里 —— 不吃 locale 的默认编码，
# 否则在非 UTF-8 locale 的机器上会把 corpus 路径写坏（同一个理由见 indexer/index.py）。
# newline 钉成 \n：环境若把行尾翻成 \r\n（Windows 签出的仓库、Git Bash），那个 CR 会被
# YAML 折成一个空格，corpus 路径就多一个字面空格 —— 这种错很难看出来。
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

group, path = sys.argv[1], sys.argv[2]
agents = json.load(open(path, encoding="utf-8"))["agents"]
for slug, spec in agents.items():
    if spec.get("rag_enabled"):
        print("\t".join((group, slug, spec["display_name"])))
PY
    done
}

apply_indexers() {
    local roster notes i=0 line group slug display minute count
    roster="$(read_roster)" || return 1

    # 脚本不在镜像里 —— 在这里变成 ConfigMap：源码只有一份，清单与 indexer/index.py
    # 不会分叉。所有作业共用这一个 ConfigMap。
    kubectl -n obsidian create configmap obsidian-indexer \
        --from-file=index.py="${SCRIPT_DIR}/indexer/index.py" \
        --dry-run=client -o yaml | kubectl apply -f -

    # 2026-09-29 拆成「一个 corpus 一个作业」时改了名（obsidian-indexer ->
    # obsidian-indexer-<slug>）。`kubectl apply` 从不删资源，留着那个旧的会和新作业对
    # 同一批文档交错上传与删除。--ignore-not-found 保证这里可重复执行。
    kubectl -n obsidian delete cronjob obsidian-indexer --ignore-not-found

    # 卷里已有的笔记：只用于下面那行提示。读不到（权限、物化负载没起）不影响部署。
    notes=""
    notes="$(kubectl -n obsidian exec deploy/obsidian-materializer -- \
        find /vault -name '*.md' -not -path '*/.*' 2>/dev/null)" || notes=""

    echo 'Indexer jobs (one per persona, from the roster):'
    while IFS=$'\t' read -r group slug display; do
        [[ -n "$slug" ]] || continue
        # 调度分钟按名册序号错开：(23 + 7i) mod 60。7 与 60 互质，所以 60 个人格以内
        # 都不会撞车；i 是全局序号，跨服务组继续往下排。
        minute=$(( (23 + 7 * i) % 60 ))
        i=$(( i + 1 ))

        # 身份：只取本 persona 那一个 Vault 键 —— 每个作业拿不到别人的令牌
        sed -e "s|__SLUG__|$(sed_escape "$slug")|g" \
            -e "s|__VAULT_TOKEN_KEY__|$(sed_escape "RAG_TOKEN_${slug^^}")|g" \
            "${INDEXER_SECRET_TEMPLATE}" | kubectl apply -f -

        sed -e "s|__SLUG__|$(sed_escape "$slug")|g" \
            -e "s|__SERVICE_GROUP__|$(sed_escape "$group")|g" \
            -e "s|__DISPLAY_NAME__|$(sed_escape "$display")|g" \
            -e "s|__MINUTE__|${minute}|g" \
            "${INDEXER_TEMPLATE}" | kubectl apply -f -

        count="$(printf '%s\n' "$notes" | grep -c "^/vault/${group}/${display}/" || true)"
        if [[ "$count" == "0" ]]; then
            printf '  %-12s %s/%s  每小时 :%02d 分   语料：还没有笔记\n' \
                "$slug" "$group" "$display" "$minute"
        else
            printf '  %-12s %s/%s  每小时 :%02d 分   语料：%s 篇\n' \
                "$slug" "$group" "$display" "$minute" "$count"
        fi
    done <<< "$roster"
}

if [[ "$MODE" == "indexers" ]]; then
    apply_indexers
    exit 0
fi

kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/couchdb-config.yaml"
kubectl apply -f "${SCRIPT_DIR}/k8s/storage.yaml"
kubectl apply -f "${EXTERNAL_SECRET}"

# Only the CouchDB secret is required for this stage. The livesync secret is
# checked separately below, because it cannot exist until a device has been
# configured -- blocking on it here would make a first-stage deploy impossible.
kubectl -n obsidian wait \
    --for=condition=Ready "externalsecret/obsidian-couchdb" \
    --timeout=180s

kubectl apply -f "${SCRIPT_DIR}/k8s/couchdb.yaml"
kubectl -n obsidian rollout status statefulset/obsidian-couchdb --timeout=300s

echo
if kubectl -n obsidian wait \
    --for=condition=Ready "externalsecret/obsidian-livesync" \
    --timeout=15s 2>/dev/null; then
    kubectl apply -f "${SCRIPT_DIR}/k8s/materializer.yaml"
    echo 'Materializer applied.'
else
    cat <<'EOF'
obsidian-livesync is not Ready, so the materializer was NOT applied.

That is expected before the first device has been configured: the Setup URI it
needs can only be generated by an already-configured device. Store it, then run
this script again:

  kubectl -n vault exec -i vault-0 -- vault kv put secret/obsidian/livesync \
    SETUP_URI='obsidian://setuplivesync?...'

  kubectl -n obsidian annotate externalsecret obsidian-livesync \
    force-sync=$(date +%s) --overwrite
EOF
fi

# -- indexer ---------------------------------------------------------------
# 作业全部由名册渲染（见上面的 apply_indexers）。加一个人格后只重跑这一段就够了：
#   bash deploy.sh --indexers
apply_indexers


cat <<'EOF'

Manual steps that this script does not perform:

  1. Cloudflare dashboard: repoint the obsidian.panghuer.top Public Hostname
     service to http://obsidian-couchdb.obsidian.svc.cluster.local:5984.
     The dashboard is the only place that takes effect.

  2. Onboard the first device by hand. The JWT settings are inside the CouchDB
     connection dialogue in the plugin, below Custom Headers -- scroll down.
     Then generate the Setup URI from that device and store it as above.

Note that :latest tags with imagePullPolicy: Always do not roll a workload by
themselves; after rebuilding an image run:

  kubectl -n obsidian rollout restart statefulset/obsidian-couchdb
  kubectl -n obsidian rollout restart deploy/obsidian-materializer
EOF
