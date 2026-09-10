#!/usr/bin/env bash
#
# kagent — build a trimmed-down agent (OPTIONAL)
#
# WHY THIS EXISTS
#
# The built-in k8s-agent carries 22 tools, whose schemas cost ~2250 prompt
# tokens. Cut to the five a diagnostic agent actually needs, that falls to
# ~670. Those schemas are re-sent on EVERY turn and charged every time, so a
# narrow toolset is a cost control, not just a tidiness exercise. Very small
# models also stop calling tools altogether once the schema list gets long.
#
# So: a second agent restricted to the five tools a diagnostic agent actually
# needs. The built-in k8s-agent is left ALONE, deliberately -- both on the same
# cluster with the same model means the comparison is controlled rather than a
# before/after with the ground shifting underneath.
#
# HOW IT BUILDS THE MANIFEST
#
# From the LIVE resource, never from documentation. Published docs drift from
# what a given chart version actually installs; `kubectl get agent -o json` is
# ground truth for the version in front of you.
#
# Usage:  ./make-lean-agent.sh              # build and apply
#         ./make-lean-agent.sh --dry-run    # build and show, apply nothing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/config.env"
SOURCE_AGENT="k8s-agent"
LEAN_AGENT="k8s-lean"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!]\033[0m  %s\n' "$*"; }
bad()  { printf '    \033[0;31m[no]\033[0m %s\n' "$*"; }

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

[[ -f "${CONFIG}" ]] || { echo "ERROR: ${CONFIG} not found." >&2; exit 1; }
# shellcheck source=/dev/null
source "${CONFIG}"

NS="${KAGENT_NAMESPACE}"

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
log "Preflight"

command -v python3 >/dev/null 2>&1 || { bad "python3 not found"; exit 1; }
ok "python3 present"

if ! kubectl get agent "${SOURCE_AGENT}" -n "${NS}" >/dev/null 2>&1; then
    bad "agent '${SOURCE_AGENT}' not found in ${NS}"
    echo "    Agents present:" >&2
    kubectl get agent -n "${NS}" >&2 || true
    exit 1
fi
ok "source agent ${SOURCE_AGENT} found"

# ---------------------------------------------------------------------------
# 1. Dump the live resource — ground truth for the manifest shape
# ---------------------------------------------------------------------------
log "Dumping ${SOURCE_AGENT}"

DUMP="${SCRIPT_DIR}/k8s-agent-live.json"
kubectl get agent "${SOURCE_AGENT}" -n "${NS}" -o json > "${DUMP}"

if ! python3 -c "import json,sys;json.load(open(sys.argv[1]))" "${DUMP}" 2>/dev/null; then
    bad "the dump is not valid JSON"
    echo "    First 200 bytes of what was captured:" >&2
    head -c 200 "${DUMP}" >&2; echo >&2
    exit 1
fi
ok "saved ${DUMP} ($(wc -c < "${DUMP}") bytes, valid JSON)"

# ---------------------------------------------------------------------------
# 2. Build the trimmed agent
# ---------------------------------------------------------------------------
log "Building ${LEAN_AGENT}"

export LA_DUMP="${DUMP}"
export LA_NAME="${LEAN_AGENT}"
export LA_OUT="${SCRIPT_DIR}/k8s-lean-agent.json"

python3 - <<'PY'
import json, os, sys, difflib

dump = json.load(open(os.environ["LA_DUMP"]))
new_name = os.environ["LA_NAME"]

# The five a diagnostic agent needs. k8s_get_pod_logs is non-negotiable: the
# CrashLoopBackOff in test-broken-pod.yaml can ONLY be diagnosed from container
# logs, so an agent without it cannot diagnose it however fast it is.
WANTED = [
    "k8s_get_resources",
    "k8s_describe_resource",
    "k8s_get_pod_logs",
    "k8s_get_events",
    "k8s_get_available_api_resources",
]
REQUIRED = "k8s_get_pod_logs"

meta = dump.get("metadata", {})
for k in ("resourceVersion", "uid", "creationTimestamp", "generation",
          "managedFields", "selfLink", "ownerReferences", "annotations"):
    meta.pop(k, None)
meta["name"] = new_name
dump.pop("status", None)
dump["metadata"] = meta

# Do not assume the nesting. Find the tools list, and if the shape is not what
# we expect, print what IS there rather than writing a manifest built on a
# guess.
spec = dump.get("spec", {})
container = spec.get("declarative") if isinstance(spec.get("declarative"), dict) else spec
tools = container.get("tools")

if not isinstance(tools, list) or not tools:
    print("ERROR: could not find a 'tools' list in the live agent.", file=sys.stderr)
    print("spec keys: %s" % list(spec.keys()), file=sys.stderr)
    if isinstance(spec.get("declarative"), dict):
        print("spec.declarative keys: %s" % list(spec["declarative"].keys()), file=sys.stderr)
    print("\nFull spec for inspection:\n", file=sys.stderr)
    print(json.dumps(spec, indent=2)[:4000], file=sys.stderr)
    sys.exit(1)

available = []
for entry in tools:
    mcp = entry.get("mcpServer") or {}
    names = mcp.get("toolNames")
    if not isinstance(names, list):
        continue
    available.extend(names)
    mcp["toolNames"] = [n for n in WANTED if n in names]

print("  live agent exposed %d tools across %d tool server(s)" % (len(available), len(tools)))

# A name that does not exist upstream must fail LOUDLY. Silently applying it
# would leave the agent short a tool, and the diagnosis would then fail for a
# reason that looks like model quality.
missing = [n for n in WANTED if n not in available]
if missing:
    print(file=sys.stderr)
    print("  ERROR: these requested tools do not exist on the live agent:", file=sys.stderr)
    for n in missing:
        # Rank by similarity, not list order: a substring match can bury the
        # right candidate below the cut-off, which defeats the point of a hint.
        close = difflib.get_close_matches(n, available, n=3, cutoff=0.5)
        hint = ("  did you mean: %s" % ", ".join(close)) if close else ""
        print("    - %s%s" % (n, hint), file=sys.stderr)
    print(file=sys.stderr)
    print("  Tools actually available:", file=sys.stderr)
    for a in sorted(available):
        print("    %s" % a, file=sys.stderr)
    print(file=sys.stderr)
    print("  Fix WANTED in make-lean-agent.sh to match, then re-run.", file=sys.stderr)
    sys.exit(1)

final = []
for entry in tools:
    mcp = entry.get("mcpServer") or {}
    if isinstance(mcp.get("toolNames"), list):
        final.extend(mcp["toolNames"])

# Assert the result rather than assuming it.
assert all(isinstance(n, str) for n in final), "toolNames must be a list of strings"
assert len(final) == len(WANTED), "expected %d tools, produced %d" % (len(WANTED), len(final))
assert REQUIRED in final, "%s missing -- log diagnosis needs it" % REQUIRED

print("  trimmed to %d tools: %s" % (len(final), ", ".join(final)))
print("  reduction: %d -> %d schemas re-sent, and billed, PER TURN" % (len(available), len(final)))

with open(os.environ["LA_OUT"], "w") as f:
    json.dump(dump, f, indent=2)
print("  wrote %s" % os.environ["LA_OUT"])
PY

[[ $? -eq 0 ]] || { bad "manifest build failed -- see above"; exit 1; }

# ---------------------------------------------------------------------------
# 3. Apply
# ---------------------------------------------------------------------------
MANIFEST="${SCRIPT_DIR}/k8s-lean-agent.json"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    log "Dry run -- not applying"
    echo "  Manifest at ${MANIFEST}. Re-run without --dry-run to apply."
    exit 0
fi

log "Applying"

# Server-side dry run first: catches a schema rejection before anything is
# created, and prints the API server's own complaint rather than ours.
if ! kubectl apply -f "${MANIFEST}" -n "${NS}" --dry-run=server; then
    bad "the API server rejected the manifest."
    echo "    Generated file: ${MANIFEST}" >&2
    echo "    Compare against ${DUMP}, which it was derived from." >&2
    exit 1
fi
kubectl apply -f "${MANIFEST}" -n "${NS}"
ok "applied"

log "Agents now present"
kubectl get agent -n "${NS}" | sed 's/^/    /'

cat <<EOF

  Two agents, same cluster, same model, one variable:

      ${SOURCE_AGENT}   22 tools  (the built-in, untouched)
      ${LEAN_AGENT}      5 tools  (trimmed)

  Ask both the same question, and compare wall clock, turns and correctness.

EOF
