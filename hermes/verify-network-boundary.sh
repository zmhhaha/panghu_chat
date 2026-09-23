#!/usr/bin/env bash
# End-to-end verification of the HERMES publication path's network boundary.
#
# Three claims the design makes, none of which had ever been measured:
#
#   1. the publisher cannot reach the public Internet,
#   2. the publisher cannot reach the Hermes web workload,
#   3. only the Hermes web workload can trigger the publisher.
#
# Read ../docs/boundaries.md and panghu_chat/hermes/README.md alongside this.
#
#   Usage: bash verify-network-boundary.sh [--explain] [--no-outsider]
#
#     --explain       print the expectation table and exit; touches nothing
#     --no-outsider   skip section 3, which creates one throwaway Pod
#
# Exit code 0 means every judged target matched its expectation.
#
# ⚠️ THE PUBLIC GROUP IS INVERTED RELATIVE TO THE DSH SCRIPT.
#    `panghu_chat/dsh/verify-network-boundary.sh` expects the public Internet to
#    be REACHABLE -- project containers install dependencies. The publisher
#    expects the opposite: DENIED. Its only egress rules are DNS and
#    `hublog-api` in the in-cluster `hublog` namespace, and `role: publish` is
#    selected by `hermes/default-deny`. There is no rule granting public egress
#    at all, so "the publisher cannot reach the public Internet" holds by
#    construction rather than by an ipBlock excluding ranges. Because Hublog is
#    IN-CLUSTER -- that is the single fact the whole claim rests on. If Hublog
#    ever moves to a public address, this expectation flips.
#
# Two things are checked against the cluster rather than the repository, because
# "the file is correct" and "the cluster is correct" diverged on 2026-09-20 and
# the gap cost DSH and Hermes their public route.
#
# Caveat on any REACHABLE result for a public target, measured 2026-09-23: this
# network answers CONNECTED for ANY public address:port, unroutable TEST-NET
# ranges included, because the router transparently proxies. So a "reachable"
# public result proves the packet left the pod, not that the far end answered.
# The DENY expectations are unaffected: a policy drop happens on the node, so
# the proxy never sees the packet and cannot manufacture a success. That is why
# the publisher's inverted expectation is the strong one here.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

NS=hermes
PUB_REF=deploy/hermes-publisher
PUB_CTR=publisher
WEB_REF=deploy/hermes-web
WEB_CTR=hermes
PROBE_NS=hermes-boundary-probe
PROBE_POD=outsider
PROBE_IMAGE="${PROBE_IMAGE:-arm-cluster-master:5000/hermes-intelligence:latest}"
PY=/opt/hermes/.venv/bin/python
HUBLOG_FALLBACK=http://hublog-api.hublog.svc.cluster.local

EXPLAIN=0
OUTSIDER=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --explain) EXPLAIN=1; shift ;;
        --no-outsider) OUTSIDER=0; shift ;;
        --help|-h) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# Destinations the publisher must NOT reach. Everything internal is covered:
# `role: publish` is selected by hermes/default-deny and no policy re-admits any
# of it. hermes-web is the interesting one -- publication and research are
# deliberately separate workloads, and the publisher holds the Hublog token.
DENIED_INTERNAL=(
    hermes-web.hermes.svc.cluster.local:4180
    kubernetes.default.svc.cluster.local:443
    vault.vault.svc.cluster.local:8200
    postgres.data.svc.cluster.local:5432
    redis.data.svc.cluster.local:6379
    llm-service.llm.svc.cluster.local:80
    rag-service.data.svc.cluster.local:8080
    embedding-service.data.svc.cluster.local:8080
)

# Public destinations the publisher must NOT reach. Compare with the DSH script,
# where these same three must stay reachable.
DENIED_PUBLIC=(
    registry.npmmirror.com:443
    github.com:443
    # Resolves into 198.18.0.0/15 here (OpenClash fake-ip). For the runner that
    # range is a trap to keep OUT of an except list; for the publisher it must
    # simply be unreachable. Same address, opposite expectation.
    auth.panghuer.top:443
)

# Plus the node it runs on, and the cloud metadata address.
DENIED_EXTRA=(
    169.254.169.254:80
)

DNS_NAMES=(
    kubernetes.default.svc.cluster.local
    auth.panghuer.top
)

INFO=( 2606:4700:4700::1111:443 )   # IPv6 egress; reported, never judged

ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  ⚠️  %s\n' "$1"; }
FAIL=0

if [[ "$EXPLAIN" == 1 ]]; then
    echo "=== 期望值（--explain，未接触集群）==="
    for t in "${DENIED_INTERNAL[@]}"; do
        printf '  %-52s %s\n' "$t" "拒绝"
    done
    printf '  %-52s %s\n' '<publisher 所在节点的地址>:22' "拒绝"
    for t in "${DENIED_EXTRA[@]}"; do
        printf '  %-52s %s\n' "$t" "拒绝"
    done
    for t in "${DENIED_PUBLIC[@]}"; do
        printf '  %-52s %s\n' "$t" "拒绝（注意与 DSH 那份相反：runner 必须可达）"
    done
    printf '  %-52s %s\n' '<集群上实际配置的 HUBLOG_URL>' "可达"
    echo
    echo "  --- 从 hermes-web 容器（role: web）---"
    printf '  %-52s %s\n' 'hermes-publisher.hermes.svc.cluster.local:8090' "可达（触发链路）"
    printf '  %-52s %s\n' 'hublog-api.hublog.svc.cluster.local:80' "拒绝（凭据隔离：web 不得直连 Hublog）"
    echo
    echo "  --- 从集群内一个无策略命名空间（一次性 Pod）---"
    printf '  %-52s %s\n' 'hermes-publisher.hermes.svc.cluster.local:8090' "拒绝（只有 web 能触发）"
    printf '  %-52s %s\n' 'hermes-web.hermes.svc.cluster.local:4180' "拒绝（只放行 cloudflared）"
    exit 0
fi

command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }

# ------------------------------------------------------------------ preflight --
echo "=== 0. preflight ==="

for ref in "$PUB_REF" "$WEB_REF"; do
    kubectl -n "$NS" get "$ref" >/dev/null 2>&1 || {
        echo "  找不到 $NS/$ref。" >&2; exit 1; }
done
ok "$PUB_REF 与 $WEB_REF 都存在（ns $NS）"

NODE="$(kubectl -n "$NS" get "$PUB_REF" -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}' 2>/dev/null || true)"
if [[ -z "$NODE" ]]; then
    NODE="$(kubectl -n "$NS" get pod -l app=hermes-publisher -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
fi
[[ -n "$NODE" ]] || { echo "  取不到 publisher 所在节点。" >&2; exit 1; }
ok "publisher 固定在 $NODE"

# A policy is enforced by the node hosting the pod, so an uncovered node would
# report everything reachable and look like a boundary failure.
ENGINE=
if kubectl -n kube-system get ds calico-node >/dev/null 2>&1; then ENGINE=calico-node NS_ENG=kube-system
elif kubectl -n kube-router get ds kube-router >/dev/null 2>&1; then ENGINE=kube-router NS_ENG=kube-router
fi
if [[ -z "$ENGINE" ]]; then
    echo "  集群里没有策略引擎，所有 NetworkPolicy 空转，本脚本的判定没有意义。" >&2
    exit 1
fi
if [[ "$(kubectl -n "$NS_ENG" get pods -l "k8s-app=$ENGINE" -o jsonpath="{.items[*].spec.nodeName}" 2>/dev/null)" != *"$NODE"* ]]; then
    echo "  $ENGINE 没有覆盖 $NODE，策略在那台节点上不执行。" >&2
    exit 1
fi
ok "策略引擎 $ENGINE 覆盖 $NODE"

# The claims below only hold while the cluster's policies look like the design.
# Check the cluster, not the repository: on 2026-09-20 the file was already
# corrected while the cluster still ran the old version.
kubectl -n "$NS" get networkpolicy default-deny >/dev/null 2>&1 || {
    echo "  集群里没有 $NS/default-deny —— publisher 的出站就不是默认拒绝了。" >&2; exit 1; }
if ! grep -q Egress <<<"$(kubectl -n "$NS" get networkpolicy default-deny -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null)"; then
    echo "  $NS/default-deny 不含 Egress —— 出站没有被默认拒绝。" >&2; exit 1
fi
ok "default-deny 覆盖出站"

if ! kubectl -n "$NS" get networkpolicy hublog-publisher >/dev/null 2>&1; then
    echo "  集群里没有 $NS/hublog-publisher —— publisher 连 Hublog 都到不了。" >&2
    exit 1
fi
# The whole "publisher cannot reach the public Internet" claim rests on there
# being no ipBlock grant anywhere in its egress. If one appears, this script's
# expectation table is wrong, so say that instead of failing every row.
PUB_CIDRS="$(kubectl -n "$NS" get networkpolicy -o jsonpath='{range .items[?(@.spec.podSelector.matchLabels.role=="publish")]}{.spec.egress[*].to[*].ipBlock.cidr}{" "}{end}' 2>/dev/null || true)"
if [[ -n "${PUB_CIDRS// /}" ]]; then
    echo "  ❌ 集群上有策略给 role: publish 授予了 ipBlock：${PUB_CIDRS}" >&2
    echo "     「publisher 无法访问公网」这个前提不成立了，先确认这是不是有意的。" >&2
    exit 1
fi
ok "没有任何策略给 role: publish 授予 ipBlock（公网被拒是结构性结论）"

# Probe the endpoint the publisher is actually configured with, not a guess.
HUBLOG_URL="$(kubectl -n "$NS" exec "$PUB_REF" -c "$PUB_CTR" -- printenv HUBLOG_URL 2>/dev/null || true)"
[[ -n "$HUBLOG_URL" ]] || HUBLOG_URL="$HUBLOG_FALLBACK"
HUBLOG_HOSTPORT="$(printf '%s' "$HUBLOG_URL" | sed -E 's#^[a-z+]+://##; s#/.*$##')"
if [[ "$HUBLOG_HOSTPORT" != *:* ]]; then
    case "$HUBLOG_URL" in
        https://*) HUBLOG_HOSTPORT="${HUBLOG_HOSTPORT}:443" ;;
        *)         HUBLOG_HOSTPORT="${HUBLOG_HOSTPORT}:80" ;;
    esac
fi
ok "HUBLOG_URL = ${HUBLOG_URL} → 探测 ${HUBLOG_HOSTPORT}"

NODE_TARGET="${NODE}:22"

# ----------------------------------------------------------------- the probe --
# Python, not Node: this is the hermes image, and its own readiness probe already
# does `socket.create_connection` with /opt/hermes/.venv/bin/python.
read -r -d '' PROBE_PY <<'PY' || true
import concurrent.futures, errno, socket, sys

TIMEOUT = 5.0
TARGETS = sys.argv[1:]


def rank(exc):
    # An RST means the packet ARRIVED and something answered it -- that is
    # REACHABLE, not blocked. Scoring it blocked would turn a reachable target
    # into a pass, which is the one error this probe must not make.
    if exc is None:
        return 3, 'REACHABLE(CONNECTED)'
    if isinstance(exc, ConnectionRefusedError):
        return 2, 'REACHABLE(ECONNREFUSED)'
    if isinstance(exc, ConnectionResetError):
        return 2, 'REACHABLE(ECONNRESET)'
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return 1, 'DROPPED(timeout)'
    num = getattr(exc, 'errno', None)
    code = errno.errorcode.get(num) or f'ERRNO{num}'
    if num in (errno.ENETUNREACH, errno.EHOSTUNREACH, errno.EACCES, errno.EPERM):
        return 1, f'BLOCKED({code})'
    return 0, f'ERROR({code})'


def connect(addr, port):
    try:
        socket.create_connection((addr, port), TIMEOUT).close()
        return rank(None)
    except OSError as exc:
        return rank(exc)


def one(target):
    try:
        host, _, port = target.rpartition(':')
        port = int(port)
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        addrs = []
        for info in infos:
            if info[4][0] not in addrs:
                addrs.append(info[4][0])
        if not addrs:
            return f'{target} NORESOLVE(EMPTY) addrs=-'
        # Report the most reachable outcome across the resolved addresses: the
        # boundary is about what the workload CAN reach, so one reachable
        # address among several makes the target reachable.
        best = max((connect(a, port) for a in addrs), key=lambda v: v[0])
        return f'{target} {best[1]} addrs={",".join(addrs)}'
    except OSError as exc:
        num = getattr(exc, 'errno', None)
        return f'{target} NORESOLVE({errno.errorcode.get(num) or num}) addrs=-'
    except Exception as exc:                      # never let one target silence the run
        return f'{target} ERROR({type(exc).__name__}) addrs=-'


with concurrent.futures.ThreadPoolExecutor(max_workers=max(len(TARGETS), 1)) as pool:
    for line in sorted(pool.map(one, TARGETS)):
        print('RESULT ' + line)
PY

# $1=namespace $2=object ref $3=container; rest are targets
probe_from() {
    local ns="$1" ref="$2" ctr="$3"; shift 3
    kubectl -n "$ns" exec "$ref" -c "$ctr" -- "$PY" -c "$PROBE_PY" "$@" 2>/dev/null \
        | sed -n 's/^RESULT //p'
}

# $1=raw results $2=target -> verdict label. Must not fail the script: a target
# with no RESULT line has to be reported, not abort the run.
verdict_of() { grep -F "$2 " <<<"$1" | head -1 | awk '{print $2}' || true; }
addrs_of()   { grep -F "$2 " <<<"$1" | head -1 | awk -F'addrs=' 'NF>1{print $2}' || true; }

# $1=raw $2=target $3=deny|reach $4=note
judge() {
    local raw="$1" t="$2" expect="$3" note="${4:-}"
    local v label
    v="$(verdict_of "$raw" "$t")"
    label="${v:-<无结果>}"
    case "$expect:$v" in
        deny:DROPPED*|deny:BLOCKED*|reach:REACHABLE*)
            ok "$(printf '%-52s %-22s %s' "$t" "$label" "$note")" ;;
        deny:NORESOLVE*|reach:NORESOLVE*)
            bad "$(printf '%-52s %-22s 名字没解析，无法判断策略' "$t" "$label")" ;;
        deny:*)
            bad "$(printf '%-52s %-22s ← 本该被拒' "$t" "$label")" ;;
        reach:*)
            bad "$(printf '%-52s %-22s ← 本该可达' "$t" "$label")" ;;
    esac
}

# ------------------------------------------------------ 1. publisher 的出站 --
echo
echo "=== 1. 从 publisher 容器探测（role: publish）==="
RAW_PUB="$(probe_from "$NS" "$PUB_REF" "$PUB_CTR" \
    "${DENIED_INTERNAL[@]}" "$NODE_TARGET" "${DENIED_EXTRA[@]}" \
    "${DENIED_PUBLIC[@]}" "$HUBLOG_HOSTPORT" "${INFO[@]}")"
if [[ -z "$RAW_PUB" ]]; then
    echo "  探测没有返回任何结果——kubectl exec 失败，或容器里没有 $PY。" >&2
    exit 1
fi
ok "收到 $(wc -l <<<"$RAW_PUB") 条结果"

echo
echo "--- 1a. 内网：必须全部被拒 ---"
for t in "${DENIED_INTERNAL[@]}"; do
    judge "$RAW_PUB" "$t" deny
done
judge "$RAW_PUB" "$NODE_TARGET" deny "所在节点自身"
for t in "${DENIED_EXTRA[@]}"; do
    judge "$RAW_PUB" "$t" deny "云元数据地址"
done

echo
echo "--- 1b. 公网：必须被拒（与 DSH 那份相反）---"
for t in "${DENIED_PUBLIC[@]}"; do
    judge "$RAW_PUB" "$t" deny "$(addrs_of "$RAW_PUB" "$t")"
done

echo
echo "--- 1c. Hublog：唯一必须可达的外部依赖 ---"
judge "$RAW_PUB" "$HUBLOG_HOSTPORT" reach "配置文件里的实际地址"

echo
echo "--- 1d. DNS 放行（策略显式放行 kube-dns 53）---"
DNS_OUT="$(kubectl -n "$NS" exec "$PUB_REF" -c "$PUB_CTR" -- "$PY" -c '
import socket, sys
for name in sys.argv[1:]:
    try:
        addrs = sorted({i[4][0] for i in socket.getaddrinfo(name, None)})
        print("DNS " + name + " -> " + ",".join(addrs))
    except OSError as exc:
        print("DNS " + name + " -> FAIL(" + str(getattr(exc, "errno", "?")) + ")")
' "${DNS_NAMES[@]}" 2>/dev/null | sed -n 's/^DNS //p' || true)"
for name in "${DNS_NAMES[@]}"; do
    line="$(grep -F "$name ->" <<<"$DNS_OUT" | head -1 || true)"
    if [[ -z "$line" || "$line" == *FAIL* ]]; then
        bad "${line:-$name -> <无结果>}"
    else
        ok "$line"
    fi
done

# ------------------------------------------------- 2. web 侧的触发链路 --
echo
echo "=== 2. 从 hermes-web 容器探测（role: web）==="
RAW_WEB="$(probe_from "$NS" "$WEB_REF" "$WEB_CTR" \
    "hermes-publisher.hermes.svc.cluster.local:8090" \
    "hublog-api.hublog.svc.cluster.local:80" \
    registry.npmmirror.com:443)"
if [[ -z "$RAW_WEB" ]]; then
    echo "  web 容器探测没有返回结果——kubectl exec 失败，或容器里没有 $PY。" >&2
    exit 1
fi
judge "$RAW_WEB" "hermes-publisher.hermes.svc.cluster.local:8090" reach "触发链路：web → publisher"
judge "$RAW_WEB" "hublog-api.hublog.svc.cluster.local:80" deny "凭据隔离：web 不得直连 Hublog"
judge "$RAW_WEB" "registry.npmmirror.com:443" reach "research-egress 的公网 443"
echo "     ↑ 这一条只能证明包离开了 web 容器（见文件头的透明代理说明），不能证明真拉到了东西。"
echo "       它的价值在反向：被策略丢弃时包不出节点，代理无从应答，那时会明确显示 DROPPED。"

# ------------------------------------------- 3. 外部命名空间看到的 publisher --
if [[ "$OUTSIDER" == 1 ]]; then
    echo
    echo "=== 3. 从集群内一个无策略命名空间探测（一次性 Pod）==="
    echo "  这一节验的是入站方向：只有 web 能触发 publisher，别处不能。"
    cleanup() {
        kubectl delete ns "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    }
    trap cleanup EXIT
    kubectl delete ns "$PROBE_NS" --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
    kubectl create ns "$PROBE_NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $PROBE_POD
  namespace: $PROBE_NS
spec:
  restartPolicy: Never
  containers:
  - name: probe
    image: $PROBE_IMAGE
    command: ["$PY", "-c", "import time; time.sleep(900)"]
    securityContext:
      runAsNonRoot: true
      allowPrivilegeEscalation: false
      capabilities: {drop: ["ALL"]}
      seccompProfile: {type: RuntimeDefault}
EOF
    if kubectl -n "$PROBE_NS" wait --for=condition=Ready "pod/$PROBE_POD" --timeout=120s >/dev/null 2>&1; then
        RAW_OUT="$(probe_from "$PROBE_NS" "pod/$PROBE_POD" probe \
            hermes-publisher.hermes.svc.cluster.local:8090 \
            hermes-web.hermes.svc.cluster.local:4180 \
            hublog-api.hublog.svc.cluster.local:80)"
        judge "$RAW_OUT" "hermes-publisher.hermes.svc.cluster.local:8090" deny "只有 role: web 能触发"
        judge "$RAW_OUT" "hermes-web.hermes.svc.cluster.local:4180" deny "入站只放行 cloudflared → 4180"
        judge "$RAW_OUT" "hublog-api.hublog.svc.cluster.local:80" reach "对照：这个命名空间没有策略，出站自由"
    else
        bad "一次性探针 Pod 没起来，第 3 节未执行"
    fi
fi

# ------------------------------------------------------------------- IPv6 --
echo
echo "=== 4. IPv6（只报告，不判定）==="
POD_IPS="$(kubectl -n "$NS" get pod -l app=hermes-publisher -o jsonpath='{.items[*].status.podIPs[*].ip} ' 2>/dev/null || true)"
echo "  publisher Pod 登记的地址： ${POD_IPS:-<无>}"
if grep -q ':' <<<"$POD_IPS"; then
    warn "拿到了 IPv6 地址——ipBlock 是 IPv4-only，这一类策略对它不生效"
elif [[ -z "$POD_IPS" ]]; then
    warn "取不到 Pod 地址，这一节无从判断"
else
    echo "  publisher Pod 只有 IPv4。"
fi
for t in "${INFO[@]}"; do
    v="$(verdict_of "$RAW_PUB" "$t")"
    case "$v" in
        REACHABLE*) warn "$t $v  ← 存在 IPv6 出口，边界的 IPv6 缺口是真的" ;;
        *)          echo "  $t ${v:-<无结果>}（无 IPv6 出口，或该地址不通）" ;;
    esac
done

echo
if [[ "$FAIL" == 0 ]]; then
    echo "通过：publisher 内网与公网全部被拒、Hublog 可达、触发链路只对 web 开放。"
    echo "把本次输出记进 panghu_chat/hermes/README.md 的验收一节。"
else
    echo "有 ${FAIL} 项不符合预期。"
    exit 1
fi
