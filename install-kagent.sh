#!/usr/bin/env bash
#
# kagent — install the Helm release
#
# Run ./setup-model.sh first. Safe to re-run: an existing release is upgraded
# rather than reinstalled.
#
# Usage:  ./install-kagent.sh
#         ./install-kagent.sh --dry-run    # render only, change nothing
#
# ORDER MATTERS. setup-model.sh must have created the Secret already, because
# the chart's bundled agents bind their ModelConfig when the release is
# created. A Secret applied afterwards is too late and surfaces as
# `secret "..." not found` on pods that were already scheduled -- which looks
# like a kagent bug and is not one.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"
VALUES="${SCRIPT_DIR}/kagent-values.yaml"
SECRET_NAME="kagent-azure-openai"
CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent"
CRD_CHART="oci://ghcr.io/kagent-dev/kagent/helm/kagent-crds"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!]\033[0m  %s\n' "$*"; }
bad()  { printf '    \033[0;31m[no]\033[0m %s\n' "$*"; }
info() { printf '    %-22s %s\n' "$1" "$2"; }

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ -f "${CONFIG}" ]] || { echo "ERROR: ${CONFIG} not found." >&2; exit 1; }
[[ -f "${VALUES}" ]] || { echo "ERROR: ${VALUES} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${CONFIG}"

NS="${KAGENT_NAMESPACE}"

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
log "Preflight"

MISSING=""
[[ -n "${AOAI_ENDPOINT:-}"    ]] || MISSING="${MISSING} endpoint"
[[ -n "${AOAI_DEPLOYMENT:-}"  ]] || MISSING="${MISSING} deployment"
[[ -n "${AOAI_MODEL:-}"       ]] || MISSING="${MISSING} model"
[[ -n "${AOAI_API_VERSION:-}" ]] || MISSING="${MISSING} api-version"

if [[ -n "${MISSING}" ]]; then
    bad "missing in config.env:${MISSING}"
    echo "    Run ./setup-model.sh first -- it fills these in AND proves the" >&2
    echo "    endpoint emits tool calls before anything is installed." >&2
    exit 1
fi

info "endpoint"    "${AOAI_ENDPOINT}"
info "deployment"  "${AOAI_DEPLOYMENT}"
info "model"       "${AOAI_MODEL}"
info "api-version" "${AOAI_API_VERSION}"
info "namespace"   "${NS}"

# An api-version older than 2023-12-01 accepts a tools array, ignores it, and
# answers in prose. Refuse to install on top of that: the agent would look
# broken for a reason no amount of kagent debugging would reveal.
if [[ "${AOAI_API_VERSION}" == "2023-05-15" ]]; then
    bad "api-version 2023-05-15 PREDATES tool calling."
    echo "    kagent will install cleanly and every agent will answer in prose." >&2
    echo "    Set AOAI_API_VERSION to a current version in config.env." >&2
    exit 1
fi

# Context guard. A wrong kubeconfig context is the difference
# between installing into an evaluation cluster and installing into someone
# else's. Cheap to check, expensive to get wrong.
CTX=$(kubectl config current-context 2>/dev/null || echo "")
info "kubectl context" "${CTX:-<none>}"
if [[ -z "${EXPECTED_CONTEXT:-}" ]]; then
    warn "EXPECTED_CONTEXT is blank in config.env -- installing into the context"
    warn "above without checking it. Set it (Step 5) to enable the guard."
elif [[ "${CTX}" != "${EXPECTED_CONTEXT}" ]]; then
    bad "context '${CTX}' does not match EXPECTED_CONTEXT '${EXPECTED_CONTEXT}'"
    echo "    Refusing to install. Either switch context, or update" >&2
    echo "    EXPECTED_CONTEXT in config.env if this is genuinely right." >&2
    exit 1
else
    ok "context matches config.env"
fi

# The Secret must already exist.
if kubectl get secret "${SECRET_NAME}" -n "${NS}" >/dev/null 2>&1; then
    ok "Secret ${SECRET_NAME} present"
else
    bad "Secret ${SECRET_NAME} not found in namespace ${NS}."
    echo "    It must exist BEFORE the release is created. Run ./setup-model.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Check the chart's own value names
# ---------------------------------------------------------------------------
# kagent's docs and its chart disagree here: the docs page shows `apiKeySecret`
# / AZURE_OPENAI_API_KEY, the chart's values.yaml shows `apiKeySecretRef` /
# AZUREOPENAI_API_KEY. A mistyped Helm key is SILENTLY IGNORED -- the install
# succeeds and every agent fails with a missing credential. Confirm against the
# chart we are about to install rather than against either document.
log "Verifying the chart's value names"

CHART_VALUES=$(helm show values "${CHART}" 2>/dev/null || true)

if [[ -z "${CHART_VALUES}" ]]; then
    warn "Could not read chart values from ghcr.io -- skipping the name check."
    warn "If this machine cannot reach ghcr.io, the cluster may not either."
elif echo "${CHART_VALUES}" | grep -q 'apiKeySecretRef'; then
    ok "chart uses 'apiKeySecretRef' -- matches kagent-values.yaml"
else
    warn "This chart version does NOT use 'apiKeySecretRef'."
    warn "Edit kagent-values.yaml to match, or the key is ignored and every"
    warn "agent fails with a missing-credential error. Chart's block:"
    echo "${CHART_VALUES}" | sed -n '/azureOpenAI:/,/^  [a-z]/p' | sed 's/^/        /'
fi

HELM_SETS=(
    --set "providers.azureOpenAI.model=${AOAI_MODEL}"
    --set "providers.azureOpenAI.config.azureEndpoint=${AOAI_ENDPOINT}"
    --set "providers.azureOpenAI.config.azureDeployment=${AOAI_DEPLOYMENT}"
    --set "providers.azureOpenAI.config.apiVersion=${AOAI_API_VERSION}"
)

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Dry run -- rendering only, nothing is applied"
    helm template kagent "${CHART}" -n "${NS}" \
        --values "${VALUES}" "${HELM_SETS[@]}" 2>&1 | head -80
    echo
    echo "  (first 80 lines shown). Nothing was installed."
    exit 0
fi

# ---------------------------------------------------------------------------
# 2. CRDs
# ---------------------------------------------------------------------------
# Separate chart, and CLUSTER-scoped. If this is where it fails, the answer is
# an RBAC role assignment, not a kagent setting.
log "kagent CRDs"

if helm status kagent-crds -n "${NS}" >/dev/null 2>&1; then
    ok "kagent-crds already installed"
else
    if helm install kagent-crds "${CRD_CHART}" --namespace "${NS}" --create-namespace --wait; then
        ok "kagent-crds installed"
    else
        bad "CRD install failed."
        echo "    If the error mentions 'forbidden' on customresourcedefinitions," >&2
        echo "    kagent installs CustomResourceDefinitions, which is a" >&2
        echo "    CLUSTER-scoped permission -- namespace admin is not enough." >&2
        echo "    Ask for cluster-admin on the cluster, or use the IAM" >&2
        echo "    principal that created it -- on EKS the creator has it." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 3. kagent
# ---------------------------------------------------------------------------
log "kagent (k8s-agent + tools only, AzureOpenAI provider)"

if helm status kagent -n "${NS}" >/dev/null 2>&1; then
    ok "existing release found -- upgrading to current values"
    VERB="upgrade"
else
    VERB="install"
fi

helm "${VERB}" kagent "${CHART}" --namespace "${NS}" \
    --values "${VALUES}" "${HELM_SETS[@]}" --wait --timeout 15m
RC=$?

if [[ "${RC}" -ne 0 ]]; then
    bad "Helm reported failure. Current state:"
    kubectl get pods -n "${NS}" | sed 's/^/    /'
    echo
    kubectl get events -n "${NS}" --sort-by=.lastTimestamp | tail -25 | sed 's/^/    /'
    exit 1
fi
ok "Helm release ${VERB}ed"

# ---------------------------------------------------------------------------
# 4. Readiness
# ---------------------------------------------------------------------------
# NOT `kubectl wait --for=condition=Ready pods --all`. That waits on every pod
# including Completed and Evicted ones, which can never become Ready, so it
# hangs. Wait on the workloads instead.
log "Waiting for deployments to become Available"

if kubectl wait --for=condition=Available deployment --all -n "${NS}" --timeout=600s; then
    ok "all deployments Available"
else
    warn "not all deployments became Available. Current state:"
    kubectl get pods -n "${NS}" | sed 's/^/    /'
    echo
    kubectl get events -n "${NS}" --sort-by=.lastTimestamp | tail -25 | sed 's/^/    /'
    warn "Pending pods on a 2-node dev cluster usually means capacity, not"
    warn "kagent. ImagePullBackOff means ghcr.io egress. CrashLoop with a"
    warn "credential error means the Secret name or key is wrong."
    exit 1
fi

# ---------------------------------------------------------------------------
# 5. Verify what actually took effect
# ---------------------------------------------------------------------------
# A mistyped Helm key is silently ignored, so assert rather than assume. And
# assert the SHAPE, not merely that a ModelConfig exists: whether the fields
# are right is what decides the outcome, not whether the object is there.
log "Verifying"

PODS=$(kubectl get pods -n "${NS}" --no-headers 2>/dev/null || true)
echo "${PODS}" | sed 's/^/    /'
POD_COUNT=$(echo "${PODS}" | grep -c . || true)
info "pods in ${NS}" "${POD_COUNT}"

if [[ "${POD_COUNT}" -gt 8 ]]; then
    warn "More pods than expected (~5). Some 'enabled: false' keys may not"
    warn "have matched this chart version. Compare with:"
    warn "    helm get values kagent -n ${NS}"
    warn "This matters for cost, not just tidiness -- every extra agent is"
    warn "another tool-schema surface being billed per turn."
fi

echo
log "ModelConfig"
MC=$(kubectl get modelconfig -n "${NS}" -o yaml 2>/dev/null || echo "")

if [[ -z "${MC}" ]]; then
    warn "no ModelConfig found -- agents will not have a model to call"
else
    check() {   # $1 = label, $2 = needle
        if echo "${MC}" | grep -q -- "$2"; then
            ok "$1"
        else
            warn "NOT CONFIRMED: $1"
            warn "  looked for: $2"
        fi
    }
    check "provider is AzureOpenAI"              "AzureOpenAI"
    check "endpoint is ${AOAI_ENDPOINT}"         "${AOAI_ENDPOINT}"
    check "deployment is ${AOAI_DEPLOYMENT}"     "${AOAI_DEPLOYMENT}"
    check "apiVersion is ${AOAI_API_VERSION}"    "${AOAI_API_VERSION}"

    if echo "${MC}" | grep -q '2023-05-15'; then
        warn "apiVersion 2023-05-15 appears somewhere in the ModelConfig."
        warn "That version PREDATES tool calling. If agents answer in prose"
        warn "and never call a tool, this is why -- not the model."
    fi
fi

echo
log "Agents"
kubectl get agent -n "${NS}" 2>/dev/null | sed 's/^/    /' || warn "no Agent resources found"

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
log "Install complete"

cat <<EOF

  Go/no-go. Ask the k8s-agent:

      "What pods are running in my cluster?"

  PASS = an answer in seconds, describing pods that really exist. If it
  answers in general prose without naming your pods, it is not calling tools
  -- re-check the api-version, and see RUNBOOK.md step 7.

  Dashboard:
      kubectl port-forward -n ${NS} svc/kagent-ui 8080:8080
      then open http://localhost:8080

  Next:
      kubectl apply -f test-broken-pod.yaml   # two pods for it to diagnose
      ./make-lean-agent.sh                    # optional: 5-tool comparison agent

EOF
