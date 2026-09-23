#!/usr/bin/env bash
# End-to-end verification of the DSH PROJECT CONTAINER's network boundary.
#
# Why this exists as a separate script: `network-policy/verify.sh` and
# `network-policy/probe-matrix.sh` both create their own throwaway probe pod.
# That proves the policy ENGINE works, which is a different question from
# "do the real policies, applied to the real runner, do what they claim".
# Those two scripts say so themselves -- network-policy/README.md:
#
#   "verify.sh 证明的是引擎能工作，不是你的策略是对的。"
#
# So this one probes from inside `dsh-runner-<project>` itself, over the same
# SSH-reachable project container that agent-generated code runs in.
#
# Read docs/boundaries.md first: it is the design, and the IPv6 gap it flags is
# only REPORTED here, not judged.
#
#   Usage: bash verify-network-boundary.sh [--project <name>] [--explain]
#
#     --project <name>   project suffix -> deployment/dsh-runner-<name>
#                        (default: armbianbegin)
#     --explain          print the expectation table and exit; touches nothing
#
# Exit code 0 means every judged target matched its expectation.
#
# Two deliberate differences from the older probe scripts:
#
#   1. Reachability classification. probe-matrix.sh scores `ECONNREFUSED` as
#      BLOCKED. It is not: an RST means the packet ARRIVED and something
#      answered it, so the target is REACHABLE -- that is exactly what a host
#      you can reach with no listener on the port looks like. Scoring it as
#      blocked turns "reachable" into a pass. Here only a timeout or an
#      unreachable-network error counts as blocked.
#   2. The policy actually installed in the cluster is checked, not just the
#      file in this repository. They were out of sync on 2026-09-20 and the gap
#      was DSH/Hermes losing their public route -- see
#      ../docs/network-policy-engine.md section 五.
#
# Caveat on the public group, measured 2026-09-23: this network answers
# CONNECTED for ANY public address:port -- unroutable TEST-NET ranges included --
# because the router transparently proxies. So a "reachable" result here proves
# the packet left the container and the policy allowed it, NOT that the far end
# answered. It keeps its discriminating power in the other direction: a policy
# drop happens on the node, so the proxy never sees the packet and cannot
# manufacture a success.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

PROJECT=armbianbegin
NS=dsh-runners
CONTAINER=runner
EXPLAIN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project) PROJECT="${2:?}"; shift 2 ;;
        --explain) EXPLAIN=1; shift ;;
        --help|-h) sed -n '2,45p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- the matrix --
# Internal destinations the policies MUST deny. These seven are the exact list
# that failed on 2026-09-20 (infrastructure-assessment.md section 8.0, table in
# network-policy-engine.md section 一) -- kept identical on purpose so this run
# is directly comparable with that one.
INTERNAL=(
    llm-service.llm.svc.cluster.local:80
    rag-service.data.svc.cluster.local:8080
    embedding-service.data.svc.cluster.local:8080
    postgres.data.svc.cluster.local:5432
    redis.data.svc.cluster.local:6379
    kubernetes.default.svc.cluster.local:443
    vault.vault.svc.cluster.local:8200
)

# Plus the two the boundary is also stated to cover: the node's own address, and
# the cloud metadata address. Both sit inside excepted ranges (192.168.0.0/16
# and 169.254.0.0/16), so a correct policy drops them.
NODE_TARGET="{node}:22"
METADATA=169.254.169.254:80

# Public destinations that MUST stay reachable. The project container installs
# dependencies and clones repositories; denying these is what the erroneous
# `198.18.0.0/15` except entry did, and it is why this group exists.
PUBLIC=(
    registry.npmmirror.com:443
    github.com:443
    # Resolves into 198.18.0.0/15 on this network (OpenClash fake-ip), so it is
    # the regression guard for that whole class of mistake: if the except list
    # ever grows a fake-ip range again, this is the target that goes dark.
    auth.panghuer.top:443
)

# Reported, never judged.
INFO=(
    2606:4700:4700::1111:443      # IPv6 egress -- see the IPv6 gap in boundaries.md
)

DNS_NAMES=(
    kubernetes.default.svc.cluster.local
    auth.panghuer.top
)

ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }
warn() { printf '  ⚠️  %s\n' "$1"; }
FAIL=0

discover_node() {
    kubectl -n "$NS" get pod -l "app=dsh-runner-$PROJECT" \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true
}

NODE="$(discover_node)"
# In --explain mode there is no cluster to ask, so the placeholder stays.
[[ -n "$NODE" ]] && NODE_TARGET="${NODE_TARGET/\{node\}/$NODE}"

if [[ "$EXPLAIN" == 1 ]]; then
    echo "=== 期望值（--explain，未接触集群）==="
    printf '  %-58s %s\n' "目标" "期望"
    for t in "${INTERNAL[@]}" "$METADATA" "$NODE_TARGET"; do
        printf '  %-58s %s\n' "$t" "拒绝（TIMEOUT / ENETUNREACH）"
    done
    for t in "${PUBLIC[@]}"; do
        printf '  %-58s %s\n' "$t" "可达（CONNECTED；回 RST 也算可达）"
    done
    for t in "${INFO[@]}"; do
        printf '  %-58s %s\n' "$t" "只报告，不判定"
    done
    echo
    echo "  {node} 运行时替换为项目容器所在节点的地址（--explain 时不查集群，故仍是占位符）。"
    echo "  内部那 7 个目标与 2026-09-20 失败那次逐条一致，便于前后对比。"
    echo "  auth.panghuer.top 是 198.18.0.0/15 那个 fake-ip 陷阱的回归守卫。"
    exit 0
fi

command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }

# ------------------------------------------------------------------ preflight --
echo "=== 0. preflight ==="

if ! kubectl -n "$NS" get "deploy/dsh-runner-$PROJECT" >/dev/null 2>&1; then
    echo "  找不到 deployment/dsh-runner-$PROJECT（命名空间 $NS）。" >&2
    echo "  用 --project <名字> 指定其它项目。" >&2
    exit 1
fi
ok "deployment/dsh-runner-$PROJECT 存在（ns $NS，容器 $CONTAINER）"

if [[ -z "$NODE" ]]; then
    echo "  该项目容器没有 Running 的 Pod，无从探测。" >&2
    exit 1
fi
ok "调度在 $NODE"

# The policy engine has to cover THAT node: a policy is enforced by the kubelet's
# node, so a probe on an uncovered node would report everything reachable and
# look like a boundary failure when it is a coverage problem.
ENGINE=
if kubectl -n kube-system get ds calico-node >/dev/null 2>&1; then ENGINE=calico-node NS_ENG=kube-system
elif kubectl -n kube-router get ds kube-router >/dev/null 2>&1; then ENGINE=kube-router NS_ENG=kube-router
fi
if [[ -z "$ENGINE" ]]; then
    echo "  集群里没有策略引擎（calico-node / kube-router 都没有）。" >&2
    echo "  没有引擎 = 所有 NetworkPolicy 空转，本脚本的判定没有意义。" >&2
    exit 1
fi
SEL="k8s-app=$ENGINE"
if [[ "$(kubectl -n "$NS_ENG" get pods -l "$SEL" -o jsonpath="{.items[*].spec.nodeName}" 2>/dev/null)" != *"$NODE"* ]]; then
    echo "  $ENGINE 没有覆盖 $NODE，策略在那台节点上不执行。" >&2
    exit 1
fi
ok "策略引擎 $ENGINE 覆盖 $NODE"

# The cluster's policy, not the repository's copy. `kubectl apply` of the fixed
# file was never confirmed on 2026-09-20 while the file itself was already
# corrected -- "提交了 ≠ 集群上是新的".
if ! kubectl -n "$NS" get networkpolicy runner-egress >/dev/null 2>&1; then
    echo "  集群里没有 dsh-runners/runner-egress 策略。" >&2
    exit 1
fi
EXCEPTS="$(kubectl -n "$NS" get networkpolicy runner-egress \
           -o jsonpath='{.spec.egress[*].to[*].ipBlock.except[*]}' 2>/dev/null || true)"
NEXCEPT="$(wc -w <<<"$EXCEPTS")"
if grep -q '198\.18\.' <<<"$EXCEPTS"; then
    echo "  ❌ 集群上的 runner-egress 仍在 except 列表里含 198.18.0.0/15。" >&2
    echo "     本网络的 fake-ip DNS 把所有外部域名解析到那个段，这条把整个公网排除。" >&2
    echo "     先 apply 仓库里的修正版：" >&2
    echo "       kubectl apply -f k8s/networkpolicies.yaml" >&2
    echo "     再重跑本脚本（参见 ../docs/network-policy-engine.md 第五节）。" >&2
    exit 1
fi
ok "集群上的 runner-egress 不含 198.18.0.0/15（except 条目 ${NEXCEPT} 条）"

echo
echo "  从项目容器里探测的是真实策略，不是合成探针 Pod。"

# ----------------------------------------------------------------- the probe --
# Runs on the CONTAINER's node and speaks for it. Note the runner image is
# node:22 based and its rootfs is read-only -- `node -e` writes nothing.
read -r -d '' PROBE_JS <<'JS' || true
const net = require('net');
const dns = require('dns');

const targets = process.argv.slice(1);
// Per-address connect timeout. Long enough that a slow public host is not scored
// as dropped -- a false "blocked" would hide a real boundary failure. Every
// target is probed in parallel, so this is the whole run's wall clock too.
const TIMEOUT_MS = 5000;

// Only a timeout or an unreachable-network error means the packet was dropped.
// An RST (ECONNREFUSED / ECONNRESET) means it ARRIVED -- never score that as
// blocked: it is what a reachable host with no listener on the port looks like,
// and scoring it blocked manufactures a pass.
function classify(err) {
  if (!err) return { rank: 3, label: 'REACHABLE(CONNECTED)' };
  const c = err.code;
  if (c === 'ECONNREFUSED') return { rank: 2, label: 'REACHABLE(ECONNREFUSED)' };
  if (c === 'ECONNRESET')   return { rank: 2, label: 'REACHABLE(ECONNRESET)' };
  if (c === 'ETIMEDOUT')    return { rank: 1, label: 'DROPPED(timeout)' };
  if (c === 'ENETUNREACH' || c === 'EHOSTUNREACH' || c === 'EACCES' || c === 'EPERM')
    return { rank: 1, label: 'BLOCKED(' + c + ')' };
  return { rank: 0, label: 'ERROR(' + c + ')' };
}

function connect(addr, port, cb) {
  const s = net.connect(port, addr);
  let settled = false;
  const finish = v => { if (!settled) { settled = true; s.destroy(); cb(v); } };
  s.on('connect', () => finish(classify(null)));
  s.on('error', e => finish(classify(e)));
  s.setTimeout(TIMEOUT_MS, () => finish(classify({ code: 'ETIMEDOUT' })));
}

const results = [];
let pending = targets.length;
function emit(line) {
  results.push(line);
  if (--pending === 0) {
    results.sort();
    for (const l of results) console.log('RESULT ' + l);
    process.exit(0);
  }
}

for (const t of targets) {
  const i = t.lastIndexOf(':');
  const host = t.slice(0, i), port = Number(t.slice(i + 1));
  const literal = net.isIP(host) !== 0;
  const look = cb => literal ? cb(null, [host])
    : dns.lookup(host, { all: true }, (e, a) => cb(e, (a || []).map(x => x.address)));

  look((err, addrs) => {
    if (err) return emit(t + ' NORESOLVE(' + err.code + ') addrs=-');
    // A name that resolves to nothing must still emit, or this target never
    // reports and the run hangs waiting for it.
    if (!addrs.length) return emit(t + ' NORESOLVE(EMPTY) addrs=-');
    // Probe every resolved address and report the most reachable outcome: the
    // boundary is about what the container CAN reach, so one reachable address
    // among several makes the target reachable.
    let left = addrs.length, best = null;
    for (const a of addrs) {
      connect(a, port, v => {
        if (!best || v.rank > best.rank) best = v;
        if (--left === 0) emit(t + ' ' + best.label + ' addrs=' + addrs.join(','));
      });
    }
  });
}
JS

probe() {
    kubectl -n "$NS" exec "deploy/dsh-runner-$PROJECT" -c "$CONTAINER" \
        -- node -e "$PROBE_JS" "$@" 2>/dev/null | sed -n 's/^RESULT //p'
}

# These must never fail the script: a target that produced no RESULT line has to
# be reported as such, not abort the run. Without `|| true` the failing grep
# inside `$( )` trips `set -e`.
verdict_of() { grep -F "$1 " <<<"$RAW" | head -1 | awk '{print $2}' || true; }
addrs_of()   { grep -F "$1 " <<<"$RAW" | head -1 | awk -F'addrs=' 'NF>1{print $2}' || true; }

echo
echo "=== 1. 探测（在项目容器内）==="
RAW="$(probe "${INTERNAL[@]}" "$METADATA" "$NODE_TARGET" "${PUBLIC[@]}" "${INFO[@]}")"
if [[ -z "$RAW" ]]; then
    echo "  探测没有返回任何结果——kubectl exec 失败，或容器里没有 node。" >&2
    exit 1
fi
ok "收到 $(wc -l <<<"$RAW") 条探测结果"

echo
echo "=== 2. 内网：必须被拒绝 ==="
for t in "${INTERNAL[@]}" "$METADATA" "$NODE_TARGET"; do
    v="$(verdict_of "$t")"
    case "$v" in
        DROPPED*|BLOCKED*) ok "$(printf '%-56s %s' "$t" "$v")" ;;
        REACHABLE*)        bad "$(printf '%-56s %s  ← 可达，边界不成立' "$t" "$v")" ;;
        NORESOLVE*)        bad "$(printf '%-56s %s  ← 名字没解析，无法判断策略' "$t" "$v")" ;;
        *)                 bad "$(printf '%-56s %s' "$t" "${v:-<无结果>}")" ;;
    esac
done

echo
echo "=== 3. 公网：必须可达（解析到的地址一并打印）==="
echo "  注：本网络对任意公网地址:端口都会回 CONNECTED（实测 2026-09-23：192.0.2.1、"
echo "  198.51.100.7、203.0.113.55 这些不可路由的测试段全部 CONNECTED，是软路由在透明代理）。"
echo "  所以这一组「可达」证明的是包离开了容器、策略放行了它，**不证明对端真的应答了**。"
echo "  反过来它是有判别力的：被策略丢弃时包根本不出节点，那个代理也就无从应答。"
for t in "${PUBLIC[@]}"; do
    v="$(verdict_of "$t")"; a="$(addrs_of "$t")"
    case "$v" in
        REACHABLE*) ok "$(printf '%-40s %-24s %s' "$t" "$v" "$a")" ;;
        NORESOLVE*) bad "$(printf '%-40s %-24s DNS 挂了——except 列表或 kube-dns 放行规则有问题' "$t" "$v")" ;;
        *)          bad "$(printf '%-40s %-24s ← 被拦，项目容器装不了依赖' "$t" "${v:-<无结果>}")" ;;
    esac
done

echo
echo "=== 4. DNS 放行（策略显式放行 kube-dns 53）==="
DNS_OUT="$(kubectl -n "$NS" exec "deploy/dsh-runner-$PROJECT" -c "$CONTAINER" -- node -e '
  const dns = require("dns");
  const names = process.argv.slice(1);
  let n = 0;
  for (const name of names) dns.lookup(name, { all: true }, (e, a) => {
    console.log("DNS " + name + " -> " + (e ? "FAIL(" + e.code + ")" : a.map(x => x.address).join(",")));
    if (++n === names.length) process.exit(0);
  });
' "${DNS_NAMES[@]}" 2>/dev/null | sed -n 's/^DNS //p')"
for name in "${DNS_NAMES[@]}"; do
    line="$(grep -F "$name ->" <<<"$DNS_OUT" | head -1 || true)"
    if [[ -z "$line" || "$line" == *FAIL* ]]; then
        bad "${line:-$name -> <无结果>}"
    else
        ok "$line"
    fi
done

echo
echo "=== 5. IPv6（只报告，不判定）==="
POD_IPS="$(kubectl -n "$NS" get pod -l "app=dsh-runner-$PROJECT" \
           -o jsonpath='{range .items[*]}{.status.podIPs[*].ip}{" "}{end}' 2>/dev/null || true)"
echo "  Pod 登记的地址： ${POD_IPS:-<无>}"
if [[ -z "$POD_IPS" ]]; then
    warn "取不到 Pod 地址（Pod 可能不在 Running），这一节无从判断"
elif grep -q ':' <<<"$POD_IPS"; then
    warn "Pod 拿到了 IPv6 地址——ipBlock 是 IPv4-only，这套边界对它不生效"
else
    echo "  Pod 只有 IPv4。"
fi
for t in "${INFO[@]}"; do
    v="$(verdict_of "$t")"
    case "$v" in
        REACHABLE*) warn "$t $v  ← 存在 IPv6 出口，边界的 IPv6 缺口是真的" ;;
        *)          echo "  $t $v（无 IPv6 出口，或该地址不通）" ;;
    esac
done
echo "  这一节不下结论：ENETUNREACH/EAFNOSUPPORT/DROPPED 都只说明这条路不通，"
echo "  而 ipBlock 根本没有 IPv6 表达。要按 docs/boundaries.md 的 IPv6 一节逐条确认。"

echo
if [[ "$FAIL" == 0 ]]; then
    echo "通过：内网全部被拒、公网全部可达。"
    echo "把本次输出记进 docs/boundaries.md（顶部横幅与「怎么复验」一节）。"
else
    echo "有 ${FAIL} 项不符合预期。"
    exit 1
fi
