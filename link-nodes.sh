#!/bin/bash
#
# Link guest cluster Nodes to their CAPI Machines by setting Node.spec.providerID.
#
# Why this is needed
# ------------------
# CAPI resolves Machine -> Node exclusively by provider ID. getNode() in
# internal/controllers/machine/machine_controller_noderef.go lists Nodes matching
# Node.spec.providerID against Machine.spec.providerID; there is no hostname fallback. CAPHCI sets
# Machine.spec.providerID to "moc://<machine-name>", but nothing ever sets it on the Node:
#
#   * There is no Azure Local cloud controller manager to do node initialisation.
#   * MachineAPI is disabled, so nothing writes it from that side either.
#   * The kubelet's --provider-id cannot be set from a shared MachineConfig, because the value is
#     per-node and the node's hostname (from DHCP) has no relationship to the CAPI machine name.
#
# So Node.spec.providerID stays empty, Machine.status.nodeRef stays nil, and:
#
#   * MachineDeployment availableReplicas never advances past 0.
#   * Machine deletion skips drain (errNilNodeRef), so workloads are killed abruptly and the Node
#     object is orphaned.
#   * `clusterctl move` refuses to run at all -- checkProvisioningCompleted() in
#     cmd/clusterctl/client/cluster/mover.go fails with "cannot start the move operation while
#     ... is still provisioning the node" for every Machine without a nodeRef.
#
# That last one is why this script exists rather than being a nice-to-have: the pivot is blocked
# until every Machine, masters included, has a nodeRef.
#
# How the matching works
# ----------------------
# It does not guess. CAPHCI exposes neither the VM's IP address nor its MAC -- status.addresses is
# declared on both AzureStackHCIMachine and AzureStackHCIVirtualMachine but never written, the NIC
# reconciler never sets Spec.MacAddress, and SDKToVM() discards everything MOC returns except ID
# and Name. There is therefore no attribute shared between a CAPI Machine and a Node to join on.
#
# The one case that is unambiguous is exactly one unmatched Machine and exactly one unmatched
# Node. This script handles that case and refuses every other one. Scale workers up one at a time
# and it always applies.
#
# The real fix is roughly forty lines in CAPHCI: read the NIC back with the existing
# networkinterfaces Get(), pull IPConfigurations[0].PrivateIPAddress, and write it to
# status.addresses. CAPI's machine_controller_phases.go already copies infra status.addresses onto
# the Machine, and matching by IP would then be exact and automatic.

set -o pipefail

KUBECTL=${KUBECTL:-kubectl}
OC=${OC:-oc}
NAMESPACE=${NAMESPACE:-capi-guests}

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <cluster-dir>"
    echo
    echo "KUBECONFIG must point at the MANAGEMENT cluster. The guest cluster is reached through"
    echo "<cluster-dir>/auth/kubeconfig."
    exit 1
fi

CLUSTER_DIR=$1

if [ ! -f "${CLUSTER_DIR}/auth/kubeconfig" ]; then
    echo "No kubeconfig at ${CLUSTER_DIR}/auth/kubeconfig"
    exit 1
fi

if [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
    echo "No metadata.json in ${CLUSTER_DIR}"
    exit 1
fi

infra_id=$(jq -r '.infraID' "${CLUSTER_DIR}/metadata.json")
guest_kubeconfig="${CLUSTER_DIR}/auth/kubeconfig"

# Read a newline-separated stream into an array. `mapfile` would be the obvious tool, but this is
# expected to be run from a laptop and macOS ships bash 3.2, which does not have it.
read_lines_into() {
    local __name=$1
    local __line
    eval "${__name}=()"
    while IFS= read -r __line; do
        [ -n "${__line}" ] || continue
        eval "${__name}+=(\"\${__line}\")"
    done
}

# Machines that have a providerID but no nodeRef yet. A Machine with no providerID at all has not
# been provisioned by CAPHCI yet and is not our problem.
read_lines_into unmatched_machines < <(
    ${KUBECTL} get machines -n "${NAMESPACE}" \
        -l "cluster.x-k8s.io/cluster-name=${infra_id}" \
        -o json 2>/dev/null \
    | jq -r '.items[]
             | select(.spec.providerID != null and .spec.providerID != "")
             | select(.status.nodeRef == null or .status.nodeRef.name == null)
             | "\(.metadata.name)\t\(.spec.providerID)"'
)

# Nodes with no providerID set. Anything already linked is left alone.
read_lines_into unmatched_nodes < <(
    ${OC} --kubeconfig "${guest_kubeconfig}" get nodes -o json 2>/dev/null \
    | jq -r '.items[]
             | select(.spec.providerID == null or .spec.providerID == "")
             | .metadata.name'
)

echo "Unmatched Machines (providerID set, nodeRef nil): ${#unmatched_machines[@]}"
for m in ${unmatched_machines[@]+"${unmatched_machines[@]}"}; do
    printf '  %s\n' "${m}"
done
echo "Unmatched Nodes (providerID empty): ${#unmatched_nodes[@]}"
for n in ${unmatched_nodes[@]+"${unmatched_nodes[@]}"}; do
    printf '  %s\n' "${n}"
done
echo

if [ "${#unmatched_machines[@]}" -eq 0 ]; then
    echo "Nothing to link. Every provisioned Machine already has a nodeRef."
    exit 0
fi

if [ "${#unmatched_nodes[@]}" -eq 0 ]; then
    echo "There are unmatched Machines but no Node is waiting to be linked."
    echo
    echo "The node has probably not joined yet. Check for pending CSRs:"
    echo "  ${OC} --kubeconfig ${guest_kubeconfig} get csr | grep Pending"
    echo "  ${OC} --kubeconfig ${guest_kubeconfig} get csr -o name | xargs ${OC} --kubeconfig ${guest_kubeconfig} adm certificate approve"
    echo
    echo "Two CSRs are needed per node: the kubelet client cert, then the serving cert. The second"
    echo "only appears after the first is approved, so expect to run that twice."
    exit 1
fi

if [ "${#unmatched_machines[@]}" -ne 1 ] || [ "${#unmatched_nodes[@]}" -ne 1 ]; then
    cat <<EOF
Refusing to guess.

There are ${#unmatched_machines[@]} unmatched Machines and ${#unmatched_nodes[@]} unmatched Nodes.
A safe automatic match needs exactly one of each.

CAPHCI publishes nothing that identifies which VM became which Node -- no IP in status.addresses,
no MAC on the NIC spec, and the VM name is CAPI-generated while the hostname comes from DHCP. So
there is no attribute to join on and picking arbitrarily would mis-link the pair.

Resolve it one of two ways:

  1. Scale the MachineDeployment back down, then up one replica at a time, running this script
     between each. That keeps the match unambiguous.

  2. Match by hand. Identify which MOC VM corresponds to which Node -- 'mocctl compute vm list'
     plus the node's IP is usually enough -- and patch it directly:

       ${OC} --kubeconfig ${guest_kubeconfig} patch node <node> --type=merge \\
         -p '{"spec":{"providerID":"moc://<machine-name>"}}'
EOF
    exit 1
fi

machine_name=$(printf '%s' "${unmatched_machines[0]}" | cut -f1)
provider_id=$(printf '%s' "${unmatched_machines[0]}" | cut -f2)
node_name="${unmatched_nodes[0]}"

echo "Linking Node ${node_name} -> Machine ${machine_name} (${provider_id})"

# providerID is immutable once non-empty, so this only ever succeeds on a genuinely unlinked node.
if ! ${OC} --kubeconfig "${guest_kubeconfig}" patch node "${node_name}" --type=merge \
        -p "{\"spec\":{\"providerID\":\"${provider_id}\"}}"; then
    echo "Failed to patch ${node_name}."
    exit 1
fi

echo
echo "Waiting for CAPI to pick up the nodeRef..."
for _ in $(seq 1 30); do
    node_ref=$(${KUBECTL} get machine "${machine_name}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.nodeRef.name}' 2>/dev/null)
    if [ -n "${node_ref}" ]; then
        echo "Machine ${machine_name} nodeRef is now ${node_ref}"
        exit 0
    fi
    sleep 5
done

echo "Machine ${machine_name} still has no nodeRef after 150s."
echo "Check the capi-controller-manager logs; the Node providerID patch itself succeeded."
exit 1
