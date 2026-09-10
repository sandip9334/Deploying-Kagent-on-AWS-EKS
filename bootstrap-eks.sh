#!/usr/bin/env bash
#
# kagent — create the EKS cluster
#
# Creates the EKS cluster that everything else in this folder installs onto.
# Run this first. It is the only script here that touches AWS.
#
# Usage:
#     ./bootstrap-eks.sh --probe     # read-only recon; creates NOTHING
#     ./bootstrap-eks.sh             # recon, then create the cluster
#
# ONE THING TO DO AFTERWARDS
#
# This script prints an EXPECTED_CONTEXT value at the end. Copy it into
# config.env. That value is what uninstall.sh checks before deleting anything,
# and it is the only edit you need to make.
#
# THE EKS-SPECIFIC TRAP, BUILT IN RATHER THAN DISCOVERED
#
# EKS has NO WORKING DEFAULT STORAGECLASS. It ships `gp2` marked default, but
# that points at the in-tree `kubernetes.io/aws-ebs` provisioner which was
# REMOVED in Kubernetes 1.23+. The chart's bundled PostgreSQL asks for a 500Mi
# PVC, so without the EBS CSI driver the PVC sits Pending forever and the whole
# install looks like a kagent bug. The driver needs IRSA, which needs IAM --
# and IAM is what training sandboxes restrict hardest. Section 4 handles it and
# says so loudly if it cannot.
#
# WHY --probe EXISTS
#
# Training sandboxes restrict things in ways that only surface when you try to
# create a resource, 15 minutes into a CloudFormation stack that then rolls
# back. The recon runs first, separately, is read-only, and is allowed to stop
# the run before anything is provisioned.

set -uo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-kagent-rehearsal}"
NODE_COUNT="${NODE_COUNT:-2}"
# t3.medium = 2 vCPU / 4 GiB. t3.small's 2 GiB is not enough for ~5 kagent pods
# plus PostgreSQL once kubelet and the CNI have taken their share.
NODE_TYPE="${NODE_TYPE:-t3.medium}"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!]\033[0m  %s\n' "$*"; }
bad()  { printf '    \033[0;31m[no]\033[0m %s\n' "$*"; }
info() { printf '    %-26s %s\n' "$1" "$2"; }

PROBE_ONLY=0
case "${1:-}" in
    --probe) PROBE_ONLY=1 ;;
    "") ;;
    *) echo "ERROR: unknown argument '${1}'. Usage: ./bootstrap-eks.sh [--probe]" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 0. Tooling
# ---------------------------------------------------------------------------
log "Tooling"

for tool in aws eksctl kubectl helm; do
    if command -v "${tool}" >/dev/null 2>&1; then
        ok "${tool} present"
    else
        bad "${tool} is not installed."
        echo "       brew install awscli eksctl kubectl helm" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# 1. Identity and region
# ---------------------------------------------------------------------------
log "Identity"

CALLER=$(aws sts get-caller-identity --output json 2>&1)
if ! printf '%s' "${CALLER}" | grep -q '"Account"'; then
    bad "Not authenticated to AWS."
    printf '%s\n' "${CALLER}" | head -3 >&2
    echo >&2
    echo "       Configure the sandbox credentials:" >&2
    echo "           aws configure" >&2
    echo "       (access key id, secret access key, region, output=json)" >&2
    exit 1
fi

ACCOUNT=$(printf '%s' "${CALLER}" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Account",""))')
ARN=$(printf '%s' "${CALLER}"     | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Arn",""))')
info "account" "${ACCOUNT}"
info "identity" "${ARN}"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region 2>/dev/null)}}"
if [[ -z "${REGION}" ]]; then
    bad "No region set."
    echo "       Sandboxes pin the region -- use the one the sandbox gives you:" >&2
    echo "           export AWS_REGION=us-east-1" >&2
    exit 1
fi
info "region" "${REGION}"

# ---------------------------------------------------------------------------
# 2. Recon -- the things that actually block a sandbox
# ---------------------------------------------------------------------------
log "Recon (read-only)"

VETO=0
SKIPPED=0

# EKS API reachable at all. If eks:ListClusters is denied, nothing else matters.
CLUSTERS=$(aws eks list-clusters --region "${REGION}" --output json 2>&1)
if printf '%s' "${CLUSTERS}" | grep -q '"clusters"'; then
    CLUSTER_COUNT=$(printf '%s' "${CLUSTERS}" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("clusters",[])))')
    ok "eks:ListClusters permitted (${CLUSTER_COUNT} existing)"
else
    bad "Cannot call the EKS API."
    printf '%s\n' "${CLUSTERS}" | head -3 | sed 's/^/        /' >&2
    warn "If this is AccessDenied, EKS is not available to this identity."
    VETO=1
fi

# THE likely blocker. eksctl builds the cluster with CloudFormation, and that
# stack CREATES IAM ROLES -- for the control plane, the node group, and (in
# section 4) the EBS CSI driver. Training sandboxes restrict IAM harder than
# anything else, so establish it here rather than 15 minutes into a stack that
# then rolls back.
IAM_PROBE=$(aws iam list-roles --max-items 1 --output json 2>&1)
if printf '%s' "${IAM_PROBE}" | grep -q '"Roles"'; then
    ok "iam:ListRoles permitted"
    warn "NOTE: listing roles is not creating them. eksctl needs iam:CreateRole,"
    warn "which cannot be tested read-only without iam:SimulatePrincipalPolicy."
    SKIPPED=$((SKIPPED + 1))
else
    bad "IAM is restricted for this identity."
    printf '%s\n' "${IAM_PROBE}" | head -2 | sed 's/^/        /' >&2
    warn "eksctl creates IAM roles via CloudFormation and will fail without it."
    VETO=1
fi

# CloudFormation is how eksctl does everything.
if aws cloudformation list-stacks --region "${REGION}" --output json >/dev/null 2>&1; then
    ok "cloudformation permitted"
else
    bad "cloudformation:ListStacks denied -- eksctl cannot work here."
    VETO=1
fi

# Is the node type actually offered in this region? This one is answerable
# read-only, so there is no reason to find out by failing a create.
OFFERED=$(aws ec2 describe-instance-type-offerings --region "${REGION}" \
    --filters "Name=instance-type,Values=${NODE_TYPE}" \
    --query "InstanceTypeOfferings[0].InstanceType" --output text 2>/dev/null)
if [[ "${OFFERED}" == "${NODE_TYPE}" ]]; then
    ok "instance type offered in ${REGION}: ${NODE_TYPE}"
else
    warn "Could not confirm ${NODE_TYPE} is offered in ${REGION}."
    SKIPPED=$((SKIPPED + 1))
fi

if [[ "${VETO}" -ne 0 ]]; then
    echo >&2
    bad "Recon found a blocker. NOT creating anything."
    cat >&2 <<'EOF'

  Better to find this in a read-only call than in a failed stack. If IAM or EKS
  is denied outright for this account, no amount of parameter-tuning will fix
  it -- you need a sandbox or an account with those permissions.

EOF
    exit 1
fi

if [[ "${SKIPPED}" -gt 0 ]]; then
    warn "Recon found no blockers, but ${SKIPPED} check(s) could not be made."
    warn "That is not the same as passing."
else
    ok "Recon found no blockers in the checks performed"
fi

if [[ "${PROBE_ONLY}" -eq 1 ]]; then
    log "Probe complete -- nothing was created"
    cat <<EOF

  Ready to build. When you are:

      ./bootstrap-eks.sh

  It will create EKS '${CLUSTER_NAME}' in ${REGION},
  ${NODE_COUNT} x ${NODE_TYPE}, with OIDC and the EBS CSI driver.

  Expect 15-20 minutes -- EKS control planes are slow. That is normal.

EOF
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Create the cluster
# ---------------------------------------------------------------------------
log "Creating EKS '${CLUSTER_NAME}' -- 15-20 minutes, this is normal"

if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
    ok "cluster already exists -- reusing it"
else
    # --with-oidc is not optional. The EBS CSI driver authenticates via IRSA,
    # which requires an OIDC provider associated with the cluster, and adding
    # one afterwards means a second CloudFormation round trip.
    #
    # --managed node group rather than unmanaged: AWS handles the AMI and the
    # lifecycle, and it is the current default people actually run.
    if ! eksctl create cluster \
            --name "${CLUSTER_NAME}" \
            --region "${REGION}" \
            --nodegroup-name ng-1 \
            --node-type "${NODE_TYPE}" \
            --nodes "${NODE_COUNT}" \
            --managed \
            --with-oidc; then
        echo >&2
        bad "eksctl create cluster failed."
        cat >&2 <<'EOF'

  Read the CloudFormation error above. The usual causes, in order:
    * IAM -- the stack creates roles; sandboxes restrict this hardest
    * service quota on VPCs, EIPs or NAT gateways (eksctl makes a VPC)
    * the instance type not available in the chosen AZs
    * the sandbox expiring mid-create

  A partially created stack is left behind. Clean it up with:
      eksctl delete cluster --name CLUSTER --region REGION

EOF
        exit 1
    fi
    ok "cluster created"
fi

# ---------------------------------------------------------------------------
# 4. Storage -- the part that silently breaks kagent
# ---------------------------------------------------------------------------
# See the header. EKS's default `gp2` StorageClass names a provisioner that no
# longer exists, so a PVC bound to it never provisions. The chart's PostgreSQL
# wants 500Mi. Install the CSI driver and prove a working default exists.
log "EBS CSI driver (required for the PostgreSQL PVC)"

if kubectl get deployment ebs-csi-controller -n kube-system >/dev/null 2>&1; then
    ok "EBS CSI driver already installed"
else
    warn "Creating the IRSA role for the driver"
    eksctl create iamserviceaccount \
        --name ebs-csi-controller-sa \
        --namespace kube-system \
        --cluster "${CLUSTER_NAME}" \
        --region "${REGION}" \
        --role-name "AmazonEKS_EBS_CSI_DriverRole_${CLUSTER_NAME}" \
        --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
        --approve --role-only >/dev/null 2>&1

    if eksctl create addon --name aws-ebs-csi-driver \
            --cluster "${CLUSTER_NAME}" --region "${REGION}" \
            --service-account-role-arn "arn:aws:iam::${ACCOUNT}:role/AmazonEKS_EBS_CSI_DriverRole_${CLUSTER_NAME}" \
            --force >/dev/null 2>&1; then
        ok "EBS CSI driver installed"
    else
        warn "Could not install the EBS CSI driver -- almost certainly IAM."
        warn "The bundled PostgreSQL PVC will stay Pending and kagent will not"
        warn "come up. This is a cluster problem, not a kagent one."
    fi
fi

# gp2 is marked default but its provisioner is gone. Create a gp3 class backed
# by the CSI driver and make it THE default, demoting gp2 -- otherwise the PVC
# binds to the broken one.
log "Default StorageClass"

if kubectl get storageclass gp3-csi >/dev/null 2>&1; then
    ok "gp3-csi already present"
else
    kubectl apply -f - >/dev/null 2>&1 <<'YAML'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-csi
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
parameters:
  type: gp3
YAML
    kubectl patch storageclass gp2 \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
        >/dev/null 2>&1
    ok "gp3-csi created and set default (gp2 demoted)"
fi

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
log "Cluster checks"

aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1
CTX=$(kubectl config current-context 2>/dev/null || echo unknown)
ok "kubectl context: ${CTX}"

for _ in $(seq 1 60); do
    kubectl get nodes 2>/dev/null | grep -q ' Ready ' && break
    sleep 5
done
kubectl get nodes

if kubectl get storageclass 2>/dev/null | grep -q '(default)'; then
    ok "default StorageClass present"
else
    warn "No default StorageClass -- the PostgreSQL PVC will stay Pending."
fi

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
log "Cluster ready"

cat <<EOF

  cluster         ${CLUSTER_NAME}
  region          ${REGION}
  nodes           ${NODE_COUNT} x ${NODE_TYPE}
  context         ${CTX}

  Put this in config.env -- it is the ONLY change needed here:

      EXPECTED_CONTEXT="${CTX}"

  Leave the Azure OpenAI block alone. The model is reached over the internet
  with a key and does not care which cloud the cluster is in.

  Next -- see RUNBOOK.md steps 5-7:
      ./setup-model.sh --verify-only    # prove the model answers
      ./setup-model.sh                  # then store the key
      ./install-kagent.sh

  Teardown -- do this, an EKS control plane bills by the hour:
      eksctl delete cluster --name ${CLUSTER_NAME} --region ${REGION}

EOF
