#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(pwd)"

usage() {
    cat <<'EOF'
Usage: bash provision.sh [--apply|--remove] <project>

Renders templates/runner.yaml for one project and creates its persistent work
container, Service and PVC in the dsh-runners namespace.

Defaults to a dry run: nothing is sent to the cluster unless --apply is given.

  <project>    Lowercase DNS label, e.g. armbianbegin. One work container per
               project; re-running is idempotent because the result is applied
               with kubectl apply.
  --apply      Actually create or update the resources.
  --remove     Delete the Deployment and Service, keeping the PVC and its data.
               Deleting the PVC is a separate explicit action; the command to
               do it is printed instead of being run.
  --dry-run    Explicit dry run (the default).
  --help       Show this message.

Configuration comes from provision.local.env when present:
  NODE_HOSTNAME    node the work container lands on (default orangepi5-max-server1)
  WORKSPACE_SIZE   per-project workspace/dependency volume (default 20Gi)
EOF
}

if [[ -f provision.local.env ]]; then
    # Trusted operator configuration only; this file is ignored by Git.
    source provision.local.env
fi
NODE_HOSTNAME="${NODE_HOSTNAME:-orangepi5-max-server1}"
WORKSPACE_SIZE="${WORKSPACE_SIZE:-20Gi}"

MODE=dry-run
PROJECT=''
for arg in "$@"; do
    case "${arg}" in
        --apply) MODE=apply ;;
        --remove) MODE=remove ;;
        --dry-run) MODE=dry-run ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "Unknown option: ${arg}" >&2; usage >&2; exit 2 ;;
        *)
            [[ -z "${PROJECT}" ]] || { echo 'Only one project name is accepted.' >&2; exit 2; }
            PROJECT="${arg}"
            ;;
    esac
done

[[ -n "${PROJECT}" ]] || { usage >&2; exit 2; }
[[ "${PROJECT}" =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] || {
    echo "Invalid project name '${PROJECT}': use a lowercase DNS label (letters, digits, dashes)." >&2
    exit 2
}

command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
command -v sed >/dev/null || { echo 'sed is required.' >&2; exit 1; }

kubectl get namespace dsh-runners >/dev/null 2>&1 || {
    echo 'Namespace dsh-runners does not exist. Run bash deploy.sh first.' >&2
    exit 1
}

RENDERED="rendered/runner-${PROJECT}.yaml"
mkdir -p rendered

render() {
    sed -e "s/__PROJECT__/${PROJECT}/g" \
        -e "s/__NODE_HOSTNAME__/${NODE_HOSTNAME}/g" \
        -e "s/__WORKSPACE_SIZE__/${WORKSPACE_SIZE}/g" \
        "${SCRIPT_DIR}/templates/runner.yaml" > "${RENDERED}"
    if grep -q '__[A-Z_][A-Z_]*__' "${RENDERED}"; then
        echo 'Rendering left unresolved placeholders; refusing to continue.' >&2
        grep -n '__[A-Z_][A-Z_]*__' "${RENDERED}" >&2
        exit 1
    fi
}

case "${MODE}" in
    dry-run)
        render
        echo "Rendered ${RENDERED} (dry run; nothing applied)."
        echo "Project: ${PROJECT}  Node: ${NODE_HOSTNAME}  Workspace: ${WORKSPACE_SIZE}"
        echo 'Re-run with --apply to create the resources.'
        ;;
    apply)
        render
        kubectl apply -f "${RENDERED}"
        kubectl -n dsh-runners rollout status "deployment/dsh-runner-${PROJECT}" --timeout=300s
        cat <<EOF

Provisioned project '${PROJECT}'.

The web workload reaches this container over SSH as dsh-runner-${PROJECT}
(see config/ssh.env and config/ssh_config). dsh-ssh establishes that connection
when dsh boots and never re-establishes it automatically, so replacing this pod
drops the transport until the web side restarts:

  kubectl -n dsh rollout restart deployment/dsh-web

Do that after every re-provision, or the web workload keeps trying to use a
connection whose remote end no longer exists.
EOF
        ;;
    remove)
        kubectl -n dsh-runners delete deployment "dsh-runner-${PROJECT}" --ignore-not-found
        kubectl -n dsh-runners delete service "dsh-runner-${PROJECT}" --ignore-not-found
        cat <<EOF

Removed deployment and service for '${PROJECT}'.

The PVC dsh-ws-${PROJECT} and its data were NOT deleted. To remove it, run this
deliberately -- it destroys the project's files and installed dependencies:

  kubectl -n dsh-runners delete pvc dsh-ws-${PROJECT}

Before that, confirm the project is deregistered from the DSH web service so no
agent tool still points at this Service.
EOF
        ;;
esac
