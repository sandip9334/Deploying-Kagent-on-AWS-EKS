#!/usr/bin/env bash
#
# kagent — teardown
#
# Usage:  ./uninstall.sh            # remove kagent, keep the CRDs
#         ./uninstall.sh --all      # also remove CRDs and the demo namespace
#
# THIS SCRIPT IS DELIBERATELY TIMID.
#
# Deleting namespaces or pruning images cluster-wide is reasonable on a
# throwaway cluster and a bad afternoon on a shared one, and the blast radius is
# not obvious from the command name. So:
#
#   * it refuses to run unless the active context matches config.env
#   * it names every resource it is about to delete, and waits for you to type
#     the cluster name back
#   * it never touches anything outside the kagent namespace, the kagent Helm
#     releases, and (with --all) the demo namespace -- any other workloads on
#     the cluster are never in scope
#   * there is no cluster-wide anything

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!]\033[0m  %s\n' "$*"; }
bad()  { printf '    \033[0;31m[no]\033[0m %s\n' "$*"; }

ALL=0
case "${1:-}" in
    --all) ALL=1 ;;
    "") ;;
    *) echo "ERROR: unknown argument '${1}'. Usage: ./uninstall.sh [--all]" >&2; exit 1 ;;
esac

[[ -f "${CONFIG}" ]] || { echo "ERROR: ${CONFIG} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${CONFIG}"

NS="${KAGENT_NAMESPACE}"
DEMO_NS="kagent-demo"

# ---------------------------------------------------------------------------
# 1. Guard — which cluster is this actually pointed at?
# ---------------------------------------------------------------------------
log "Target"

printf '    %-22s %s\n' "cluster"  "${CLUSTER_NAME}"
printf '    %-22s %s\n' "region"   "${AWS_REGION}"

CTX=$(kubectl config current-context 2>/dev/null || echo "")
printf '    %-22s %s\n' "kubectl context" "${CTX:-<none>}"

if [[ -z "${EXPECTED_CONTEXT:-}" ]]; then
    bad "EXPECTED_CONTEXT is not set in config.env."
    echo "    This guard is the only thing preventing a destructive run" >&2
    echo "    against the wrong cluster. Set it and re-run." >&2
    exit 1
fi

if [[ "${CTX}" != "${EXPECTED_CONTEXT}" ]]; then
    bad "Refusing to run."
    echo "    active context : ${CTX}" >&2
    echo "    expected       : ${EXPECTED_CONTEXT}" >&2
    echo >&2
    echo "  Switch context, or correct EXPECTED_CONTEXT in config.env if" >&2
    echo "  this really is the intended cluster." >&2
    exit 1
fi
ok "context matches config.env"

# ---------------------------------------------------------------------------
# 2. Show exactly what will go
# ---------------------------------------------------------------------------
log "What will be deleted"

echo "    Helm releases in namespace ${NS}:"
helm list -n "${NS}" 2>/dev/null | sed 's/^/        /' || echo "        (none)"

echo
echo "    Resources in namespace ${NS}:"
kubectl get all -n "${NS}" 2>/dev/null | sed 's/^/        /' || echo "        (none)"

echo
echo "    Namespace ${NS}                    will be DELETED"
if [[ "${ALL}" -eq 1 ]]; then
    echo "    Namespace ${DEMO_NS}               will be DELETED"
    echo "    kagent CRDs (cluster-scoped)          will be DELETED"
else
    echo "    Namespace ${DEMO_NS}               kept (pass --all to remove)"
    echo "    kagent CRDs                           kept (pass --all to remove)"
fi

echo
warn "Nothing outside those namespaces is touched. Any other workloads on"
warn "this cluster are not affected by anything below."

echo
printf '    Type the cluster name (%s) to proceed: ' "${CLUSTER_NAME}"
read -r CONFIRM
if [[ "${CONFIRM}" != "${CLUSTER_NAME}" ]]; then
    echo
    ok "Aborted. Nothing was changed."
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Helm releases
# ---------------------------------------------------------------------------
log "Removing Helm releases"

if helm status kagent -n "${NS}" >/dev/null 2>&1; then
    helm uninstall kagent -n "${NS}" --wait --timeout 5m >/dev/null 2>&1 \
        && ok "removed kagent" \
        || warn "uninstall of kagent reported an error -- continuing"
else
    ok "kagent not installed"
fi

if [[ "${ALL}" -eq 1 ]]; then
    if helm status kagent-crds -n "${NS}" >/dev/null 2>&1; then
        helm uninstall kagent-crds -n "${NS}" --wait --timeout 5m >/dev/null 2>&1 \
            && ok "removed kagent-crds" \
            || warn "uninstall of kagent-crds reported an error -- continuing"
    else
        ok "kagent-crds not installed"
    fi
else
    ok "keeping kagent-crds (reinstalls are faster with them in place)"
fi

# ---------------------------------------------------------------------------
# 4. Namespaces — only ours, by name, never by selector
# ---------------------------------------------------------------------------
log "Removing namespaces"

if kubectl get namespace "${NS}" >/dev/null 2>&1; then
    kubectl delete namespace "${NS}" --timeout=5m >/dev/null 2>&1 \
        && ok "deleted namespace ${NS}" \
        || warn "namespace ${NS} delete timed out -- it may still be terminating"
else
    ok "namespace ${NS} not present"
fi

if [[ "${ALL}" -eq 1 ]]; then
    if kubectl get namespace "${DEMO_NS}" >/dev/null 2>&1; then
        kubectl delete namespace "${DEMO_NS}" --timeout=3m >/dev/null 2>&1 \
            && ok "deleted namespace ${DEMO_NS}" \
            || warn "namespace ${DEMO_NS} delete timed out"
    else
        ok "namespace ${DEMO_NS} not present"
    fi
fi

# ---------------------------------------------------------------------------
log "Teardown complete"
cat <<EOF

  The Azure OpenAI resource, its deployment and its key are untouched -- this
  script only removes what was installed INTO the cluster.

  To reinstall:
      ./setup-model.sh && ./install-kagent.sh

  (setup-model.sh must run again: the Secret lived in the namespace that was
  just deleted.)

EOF
