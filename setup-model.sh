#!/usr/bin/env bash
#
# kagent on Amazon EKS: wire up Azure OpenAI
#
# Proves the endpoint works BEFORE any Kubernetes is involved, then stores the
# key as a Kubernetes Secret.
#
# Usage:
#     ./setup-model.sh                # values from config.env
#     ./setup-model.sh --verify-only  # smoke tests only, no Secret created
#
# WHY THE CURL TESTS COME FIRST
#
# An endpoint, a key, a deployment name and an api-version can each be wrong,
# and through kagent all four fail the same indistinguishable way -- an agent
# that "doesn't work". Two curls settle all four in ten seconds.
#
# The SECOND test is the one that matters. It sends a `tools` array and checks
# for `tool_calls` in the reply. An api-version that is too old accepts the
# request, ignores the tools, and answers in prose. kagent is useless without
# tool calling, and that failure looks exactly like a weak model -- it is the
# single most expensive wrong turn available on this integration.
#
# KEY HANDLING
#
# The key is read with `read -rs`, never passed as a command-line argument
# (argv is world-readable via `ps`), and never placed in a Helm value or in
# config.env (both of which end up in `helm get values` output in clear). It
# reaches the cluster only as a Kubernetes Secret.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"
SECRET_NAME="kagent-azure-openai"
SECRET_KEY="AZUREOPENAI_API_KEY"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!]\033[0m  %s\n' "$*"; }
bad()  { printf '    \033[0;31m[no]\033[0m %s\n' "$*"; }
info() { printf '    %-18s %s\n' "$1" "$2"; }

[[ -f "${CONFIG}" ]] || { echo "ERROR: ${CONFIG} not found. It ships with this folder -- restore it." >&2; exit 1; }
# shellcheck source=/dev/null
source "${CONFIG}"

VERIFY_ONLY=0

case "${1:-}" in
    --verify-only) VERIFY_ONLY=1 ;;
    "") ;;
    *)
        echo "ERROR: unknown argument '${1}'" >&2
        echo "Usage: ./setup-model.sh [--verify-only]" >&2
        exit 1
        ;;
esac

# ---------------------------------------------------------------------------
# 1. Gather connection details
# ---------------------------------------------------------------------------
log "Azure OpenAI connection details"

ENDPOINT="${AOAI_ENDPOINT:-}"
DEPLOYMENT="${AOAI_DEPLOYMENT:-}"
MODEL="${AOAI_MODEL:-}"
API_VERSION="${AOAI_API_VERSION:-2024-12-01-preview}"
KEY=""

# config.env ships with placeholders so the expected shape is visible. Treat
# them as "not filled in" -- otherwise they sail through as if they were real
# values and the first sign of trouble is a confusing 404 from curl.
is_placeholder() {
    case "$1" in
        ""|*YOUR-RESOURCE*|your-deployment-name|your-model-name) return 0 ;;
        *) return 1 ;;
    esac
}

is_placeholder "${ENDPOINT}"   && ENDPOINT=""
is_placeholder "${DEPLOYMENT}" && DEPLOYMENT=""
is_placeholder "${MODEL}"      && MODEL=""

if [[ -z "${ENDPOINT}" || -z "${DEPLOYMENT}" || -z "${MODEL}" ]]; then
    echo "    Some values are not set in config.env. Enter them here -- they"
    echo "    are written back to config.env afterwards, so this is a one-off."
    echo
fi

if [[ -z "${ENDPOINT}" ]]; then
    echo "    Endpoint looks like:  https://<name>.openai.azure.com/"
    read -r -p "    Endpoint        : " ENDPOINT
fi
[[ -n "${DEPLOYMENT}" ]] || read -r -p "    Deployment name : " DEPLOYMENT
[[ -n "${MODEL}"      ]] || read -r -p "    Model name      : " MODEL
# -s so the key never appears on screen, in a screen-share, or in history.
read -rs -p "    API key         : " KEY
echo

MODEL="${MODEL:-${DEPLOYMENT}}"

# ---------------------------------------------------------------------------
# 2. Validate before using
# ---------------------------------------------------------------------------
log "Validating"

[[ -n "${ENDPOINT}"   ]] || { bad "Endpoint is empty";   exit 1; }
[[ -n "${DEPLOYMENT}" ]] || { bad "Deployment is empty"; exit 1; }
[[ -n "${KEY}"        ]] || { bad "Key is empty";        exit 1; }

ENDPOINT="${ENDPOINT%/}/"

if [[ ! "${ENDPOINT}" =~ ^https://[a-zA-Z0-9._-]+/$ ]]; then
    bad "Endpoint is not a bare https URL: '${ENDPOINT}'"
    echo "    Expected:  https://<name>.openai.azure.com/" >&2
    echo >&2
    echo "  If it looks almost right but has a stray newline or spaces in it," >&2
    echo "  that is paste corruption, not a wrong value. Re-enter it." >&2
    exit 1
fi

# A key corrupted on paste produces a 401 that looks exactly like a wrong key.
# Check the shape here, where the message can say what actually happened.
if [[ "${KEY}" =~ [[:space:]] ]]; then
    bad "The API key contains whitespace."
    echo "    That is almost certainly paste corruption. Re-run and paste again." >&2
    exit 1
fi
if [[ "${#KEY}" -lt 20 ]]; then
    bad "The API key is only ${#KEY} characters -- too short to be real."
    echo "    Likely truncated on paste. Re-run and paste again." >&2
    exit 1
fi

if [[ "${ENDPOINT}" == *"cognitiveservices.azure.com"* ]]; then
    warn "Endpoint is the *.cognitiveservices.azure.com form, which happens"
    warn "when an account was created without --custom-domain. kagent's"
    warn "AzureOpenAI provider expects *.openai.azure.com. Continuing, but if"
    warn "the smoke test 404s this is the first suspect."
fi

info "endpoint"    "${ENDPOINT}"
info "deployment"  "${DEPLOYMENT}"
info "model"       "${MODEL}"
info "api-version" "${API_VERSION}"
info "key"         "${#KEY} chars, not shown"

CHAT_URL="${ENDPOINT}openai/deployments/${DEPLOYMENT}/chat/completions?api-version=${API_VERSION}"

RESP=$(mktemp)
trap 'rm -f "${RESP}"' EXIT

# ---------------------------------------------------------------------------
# 3. Smoke test 1 — can we talk to it at all?
# ---------------------------------------------------------------------------
log "Smoke test 1/2: plain completion"

# No "max_tokens" in either request body, deliberately. The gpt-5 family and
# the o-series reject it and require "max_completion_tokens", so sending it
# would fail a perfectly healthy deployment and look like a broken endpoint.
# Both prompts here are a handful of tokens. Do not "helpfully" add one back.
HTTP=$(curl -sS -o "${RESP}" -w '%{http_code}' --max-time 60 "${CHAT_URL}" \
    -H "api-key: ${KEY}" \
    -H 'Content-Type: application/json' \
    -d '{"messages":[{"role":"user","content":"Reply with the single word: ok"}]}' \
    2>/dev/null || echo "000")

info "HTTP" "${HTTP}"

if [[ "${HTTP}" != "200" ]]; then
    bad "Endpoint did not answer 200."
    echo "    Response body:" >&2
    head -c 800 "${RESP}" >&2; echo >&2
    cat <<'EOF' >&2

  Read the body above rather than guessing. The usual causes:
    401  key wrong, or belongs to a different account
    404  deployment name wrong, or endpoint is the wrong domain form
    429  no quota / capacity on the deployment
    000  no egress from THIS machine to the endpoint

  Note that 000 here says nothing about whether the CLUSTER can reach it --
  that is a separate network path. Test it from inside the cluster with:
    kubectl run probe --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
      -n kagent -- -sS -o /dev/null -w '%{http_code}' <your-endpoint>

EOF
    exit 1
fi
ok "endpoint, key and deployment name all good"

# ---------------------------------------------------------------------------
# 4. Smoke test 2 — does it emit tool calls? (the decisive one)
# ---------------------------------------------------------------------------
log "Smoke test 2/2: tool calling on api-version ${API_VERSION}"

HTTP=$(curl -sS -o "${RESP}" -w '%{http_code}' --max-time 60 "${CHAT_URL}" \
    -H "api-key: ${KEY}" \
    -H 'Content-Type: application/json' \
    -d '{
      "messages":[{"role":"user","content":"List the pods in the default namespace."}],
      "tools":[{"type":"function","function":{
        "name":"k8s_get_resources",
        "description":"List Kubernetes resources of a given kind in a namespace.",
        "parameters":{"type":"object",
          "properties":{"kind":{"type":"string"},"namespace":{"type":"string"}},
          "required":["kind"]}}}],
      "tool_choice":"auto"}' \
    2>/dev/null || echo "000")

info "HTTP" "${HTTP}"

if [[ "${HTTP}" != "200" ]]; then
    bad "Tool-calling request failed with HTTP ${HTTP}."
    head -c 800 "${RESP}" >&2; echo >&2
    warn "If this is a 400 mentioning 'tools', the api-version is too old."
    warn "Try: AOAI_API_VERSION=\"2025-03-01-preview\" in config.env"
    exit 1
fi

if grep -q '"tool_calls"' "${RESP}"; then
    CALLED=$(grep -o '"name": *"[^"]*"' "${RESP}" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
    ok "model emitted a tool call -> ${CALLED:-unknown}"
else
    bad "HTTP 200 but NO tool_calls -- it answered in prose."
    echo "    Response body:" >&2
    head -c 800 "${RESP}" >&2; echo >&2
    cat <<EOF >&2

  STOP HERE. Do not install kagent on top of this. The agent will look broken
  and the cause is in this config, not in kagent.

  In order of likelihood:
    1. api-version too old. ${API_VERSION} should be fine; 2023-05-15 is not.
       Try AOAI_API_VERSION="2025-03-01-preview" in config.env.
    2. The deployed model does not support function calling. Deploy a current
       chat model that does -- kagent is useless without it.

EOF
    exit 1
fi

# Free datapoint: how many prompt tokens ONE tool schema costs. A 22-tool agent
# has been measured at around 2,250 prompt tokens per turn, and the schemas are
# re-sent every turn -- so this number is the basis of the cost case.
PT=$(grep -o '"prompt_tokens": *[0-9]*' "${RESP}" | head -1 | grep -oE '[0-9]+' || true)
CT=$(grep -o '"completion_tokens": *[0-9]*' "${RESP}" | head -1 | grep -oE '[0-9]+' || true)
[[ -n "${PT}" ]] && info "prompt_tokens" "${PT} (1 tool schema + a short question)"
[[ -n "${CT}" ]] && info "completion_tokens" "${CT}"

if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
    log "Verify-only: both smoke tests passed, no Secret created"
    exit 0
fi

# ---------------------------------------------------------------------------
# 5. Kubernetes Secret
# ---------------------------------------------------------------------------
# Created BEFORE the Helm release exists. The chart's bundled agents bind their
# ModelConfig at release-creation time, so a Secret applied afterwards is too
# late and shows up as `secret not found` on already-scheduled pods.
log "Creating Secret ${SECRET_NAME} in ${KAGENT_NAMESPACE}"

B64=$(printf '%s' "${KEY}" | base64 | tr -d '\n')

MANIFEST=$(mktemp)
chmod 600 "${MANIFEST}"
trap 'rm -f "${RESP}" "${MANIFEST}"' EXIT

{
    echo "apiVersion: v1"
    echo "kind: Secret"
    echo "metadata:"
    echo "  name: ${SECRET_NAME}"
    echo "  namespace: ${KAGENT_NAMESPACE}"
    echo "type: Opaque"
    echo "data:"
    echo "  ${SECRET_KEY}: ${B64}"
} > "${MANIFEST}"

kubectl get namespace "${KAGENT_NAMESPACE}" >/dev/null 2>&1 || \
    kubectl create namespace "${KAGENT_NAMESPACE}" >/dev/null
kubectl apply -f "${MANIFEST}" >/dev/null
ok "Secret applied (key ${SECRET_KEY})"

# ---------------------------------------------------------------------------
# 6. Record the NON-SECRET values back into config.env
# ---------------------------------------------------------------------------
log "Updating config.env"

# NOT `sed -i`. GNU sed takes no argument after -i, BSD sed (macOS) requires
# one, and the portable-looking `sed -i ''` then breaks on Linux. Writing to a
# temp file and copying it back needs no platform branch and no guessing which
# sed is on the box.
#
# `cat > "${CONFIG}"` rather than `mv`, deliberately: mv would replace the file
# with the temp file's own 0600 mode and inode, silently changing the
# permissions of a file the user owns. Truncating in place keeps both.
put() {   # $1 = key, $2 = value
    local k="$1" v="$2" tmp
    [[ -z "${v}" ]] && return 0
    if grep -q "^${k}=" "${CONFIG}"; then
        tmp=$(mktemp "${CONFIG}.tmp.XXXXXX") || return 1
        if sed "s|^${k}=.*|${k}=\"${v}\"|" "${CONFIG}" > "${tmp}"; then
            cat "${tmp}" > "${CONFIG}"
        fi
        rm -f "${tmp}"
    else
        echo "${k}=\"${v}\"" >> "${CONFIG}"
    fi
}

put AOAI_ENDPOINT     "${ENDPOINT}"
put AOAI_DEPLOYMENT   "${DEPLOYMENT}"
put AOAI_MODEL        "${MODEL}"
put AOAI_API_VERSION  "${API_VERSION}"

ok "endpoint / deployment / model / api-version recorded"
warn "The API KEY is deliberately NOT in config.env. It exists only in the"
warn "Kubernetes Secret. If the cluster is recreated, re-run this script."

log "Model connected"
cat <<EOF

  Both smoke tests passed: the endpoint answers, and it emits tool calls on
  api-version ${API_VERSION}.

  Next:
      ./install-kagent.sh

EOF
