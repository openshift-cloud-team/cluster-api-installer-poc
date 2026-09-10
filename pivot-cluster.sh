#!/bin/bash
#
# Pivot the guest cluster's own CAPI objects out of the kind management cluster and into itself,
# so it manages its own worker MachineDeployment.
#
# Read docs/azurestackhci-port-plan.md "Phase 2: workers and pivot" before running this. The short
# version: the pivot is mechanically supported, but a pivoted cluster cannot destroy itself, and
# destroy-cluster.sh will need the objects moved back first.

set -o pipefail

KUBECTL=${KUBECTL:-kubectl}
OC=${OC:-oc}
CLUSTERCTL=${CLUSTERCTL:-clusterctl}
NAMESPACE=${NAMESPACE:-capi-guests}

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <cluster-dir>"
    echo
    echo "KUBECONFIG must point at the MANAGEMENT (kind) cluster."
    exit 1
fi

CLUSTER_DIR=$1
guest_kubeconfig="${CLUSTER_DIR}/auth/kubeconfig"

if [ ! -f "${guest_kubeconfig}" ] || [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
    echo "Expected auth/kubeconfig and metadata.json in ${CLUSTER_DIR}"
    exit 1
fi

infra_id=$(jq -r '.infraID' "${CLUSTER_DIR}/metadata.json")

if [ -f "${CLUSTER_DIR}/azurelocal.env" ]; then
    # shellcheck disable=SC1090
    source "${CLUSTER_DIR}/azurelocal.env"
fi

#
# BEGIN: preflight
#
# clusterctl move gives poor errors for most of these, so check them here where we can say what to
# do about it.
#

fail=0

echo "== Checking every Machine has a nodeRef =="
# checkProvisioningCompleted() in cmd/clusterctl/client/cluster/mover.go aborts the whole move if
# any single Machine has status.nodeRef unset. With no Azure Local CCM nothing sets
# Node.spec.providerID on its own, so this is the check that will fail first, and it fails for the
# three control plane Machines just as readily as for the workers.
missing_noderef=$(${KUBECTL} get machines -n "${NAMESPACE}" \
    -l "cluster.x-k8s.io/cluster-name=${infra_id}" -o json \
    | jq -r '.items[] | select(.status.nodeRef == null or .status.nodeRef.name == null) | .metadata.name')

if [ -n "${missing_noderef}" ]; then
    echo "  FAIL. These Machines have no nodeRef:"
    printf '    %s\n' ${missing_noderef}
    echo
    echo "  clusterctl move will refuse to start. Approve the pending CSRs in the guest cluster,"
    echo "  then run ./link-nodes.sh ${CLUSTER_DIR} once per node to set Node.spec.providerID."
    fail=1
else
    echo "  OK."
fi

echo "== Checking the Cluster reports infrastructure provisioned =="
provisioned=$(${KUBECTL} get cluster "${infra_id}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.initialization.infrastructureProvisioned}' 2>/dev/null)
if [ "${provisioned}" != "true" ]; then
    echo "  FAIL. status.initialization.infrastructureProvisioned is '${provisioned}'."
    fail=1
else
    echo "  OK."
fi

echo "== Checking ControlPlaneInitialized =="
# The other half of checkProvisioningCompleted(). With no controlPlaneRef, CAPI derives this from
# a control plane Machine having a nodeRef -- so it clears at the same time the check above does.
cp_init=$(${KUBECTL} get cluster "${infra_id}" -n "${NAMESPACE}" \
    -o json | jq -r '.status.conditions[]? | select(.type=="ControlPlaneInitialized") | .status')
if [ "${cp_init}" != "True" ]; then
    echo "  FAIL. ControlPlaneInitialized is '${cp_init:-<absent>}'."
    fail=1
else
    echo "  OK."
fi

echo "== Checking CAPI and CAPHCI are installed in the guest cluster =="
# clusterctl move requires the target to have matching providers at a compatible contract version.
if ! ${OC} --kubeconfig "${guest_kubeconfig}" get crd azurestackhcimachines.infrastructure.cluster.x-k8s.io > /dev/null 2>&1; then
    echo "  FAIL. CAPHCI is not installed in the guest cluster."
    echo
    echo "  Install it there the same way as on the management cluster, via clusterctl:"
    echo "    KUBECONFIG=${guest_kubeconfig} clusterctl init --infrastructure azurestackhci"
    echo
    echo "  It must be clusterctl, not kubectl apply. clusterctl move discovers what to move by"
    echo "  listing CRDs labelled clusterctl.cluster.x-k8s.io, and only clusterctl applies that"
    echo "  label."
    fail=1
else
    echo "  OK."
fi

echo "== Checking the MOC login token exists in the guest cluster =="
# CAPHCI has no identity CRD -- authentication is this one global Secret, and it does not travel
# with clusterctl move because it lives outside the cluster's object graph.
if ! ${OC} --kubeconfig "${guest_kubeconfig}" get secret caphlogintoken -n default > /dev/null 2>&1; then
    echo "  FAIL. Secret default/caphlogintoken is missing in the guest cluster."
    echo
    echo "  Copy it across:"
    echo "    ${KUBECTL} get secret caphlogintoken -n default -o yaml \\"
    echo "      | ${OC} --kubeconfig ${guest_kubeconfig} apply -f -"
    echo
    echo "  Also confirm AZURESTACKHCI_CLOUDAGENT_FQDN is set on the controller Deployment there,"
    echo "  and that guest cluster pods can actually reach the cloudagent. The kind cluster's"
    echo "  network path to it says nothing about the guest cluster's."
    fail=1
else
    echo "  OK."
fi

if [ "${fail}" -ne 0 ]; then
    echo
    echo "Preflight failed. Nothing has been moved."
    exit 1
fi

#
# END: preflight
#

echo
echo "== Dry run =="
if ! ${CLUSTERCTL} move --to-kubeconfig "${guest_kubeconfig}" -n "${NAMESPACE}" --dry-run; then
    echo "Dry run failed. Nothing has been moved."
    exit 1
fi

cat <<EOF

About to move the CAPI objects for ${infra_id} from the management cluster into the guest cluster.

After this the guest cluster owns its own Cluster, Machines and MachineDeployment, and the kind
cluster owns nothing. Two consequences worth being sure about first:

  * destroy-cluster.sh will no longer work as written. Deleting the Cluster object is what removes
    the VMs, and a cluster cannot delete the VMs it is running on -- the control plane goes away
    mid-reconcile and the remaining VMs, NICs and disks leak. Move the objects back to a
    management cluster before destroying.

  * The management cluster stops being the recovery path. If the guest cluster's control plane
    breaks, the controllers that could rebuild it are inside it.

EOF
read -r -p "Continue? [y/N] " answer
case "${answer}" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
esac

echo
echo "== Moving =="
if ! ${CLUSTERCTL} move --to-kubeconfig "${guest_kubeconfig}" -n "${NAMESPACE}"; then
    echo
    echo "Move failed. clusterctl pauses the Cluster on the source before moving and unpauses on"
    echo "the target, so a partial failure can leave it paused on both sides. Check:"
    echo "  ${KUBECTL} get cluster ${infra_id} -n ${NAMESPACE} -o jsonpath='{.spec.paused}'"
    echo "  ${OC} --kubeconfig ${guest_kubeconfig} get cluster ${infra_id} -n ${NAMESPACE} -o jsonpath='{.spec.paused}'"
    exit 1
fi

echo
echo "Moved. The guest cluster now manages itself."
echo
echo "Verify:"
echo "  ${OC} --kubeconfig ${guest_kubeconfig} get cluster,machinedeployment,machines -n ${NAMESPACE}"
echo
echo "To move back before destroying, run from a management cluster context:"
echo "  ${CLUSTERCTL} move --kubeconfig ${guest_kubeconfig} -n ${NAMESPACE} --to-kubeconfig \${MGMT_KUBECONFIG}"
