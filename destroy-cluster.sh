#!/bin/bash

CLUSTER_DIR=$1
SCRIPT_ROOT=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
KUBECTL=${KUBECTL:-kubectl}
MOCCTL=${MOCCTL:-mocctl}

NAMESPACE=capi-guests

source ${SCRIPT_ROOT}/lib/build-image.sh

if [ -z "${CLUSTER_DIR}" ]; then
    echo "Usage: ./destroy-cluster.sh <cluster-dir>"
    exit 1
fi

if [ ! -d "${CLUSTER_DIR}" ]; then
    echo "Expected cluster directory ${CLUSTER_DIR} to exist"
    exit 1
fi

if [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
    echo "Expected metadata.json to exist in ${CLUSTER_DIR}"
    exit 1
fi

if [ -f "${CLUSTER_DIR}/azurelocal.env" ]; then
    source ${CLUSTER_DIR}/azurelocal.env
fi

infra_id=$(jq -r '.infraID' ${CLUSTER_DIR}/metadata.json)

# The AWS version scaled the guest cluster's worker MachineSets to zero first. There are none
# here: MachineAPI is disabled, so the guest cluster has no Machine API to scale.

# Deleting the Cluster cascades to the Machines, AzureStackHCIMachines, AzureStackHCIVirtualMachines
# and the user-data secrets we owner-referenced to it.
${KUBECTL} delete cluster --namespace ${NAMESPACE} ${infra_id} --wait=false

while [ "$(${KUBECTL} get machines -n ${NAMESPACE} -o json -l cluster.x-k8s.io/cluster-name=${infra_id} | jq -r '.items[]')" != "" ]; do
    echo "Waiting for machines to be deleted"
    sleep 5
done

# Wait for the cluster object itself to go away.
${KUBECTL} delete cluster --namespace ${NAMESPACE} ${infra_id} || true

# The AWS version deleted load balancers and security groups here. CAPHCI creates neither.

#
# BEGIN: Delete the per-cluster gallery images
#
# Nothing else cleans these up. They are single-use -- they embed this cluster's certificates --
# and at several GB each they will quietly fill the storage container across repeated runs.
#

for role in {bootstrap,master,worker}; do
    delete_gallery_image ${infra_id}-${role}
done

# Per-node master images, if the install used STATIC_NETWORK_KARGS.
for i in 0 1 2; do
    delete_gallery_image ${infra_id}-master-${i}
done

if [ -d "${CLUSTER_DIR}/images" ]; then
    rm -rf ${CLUSTER_DIR}/images
fi

#
# END: Delete the per-cluster gallery images
#

if [ -d "${CLUSTER_DIR}/cluster-api-manifests" ]; then
    rm -rf ${CLUSTER_DIR}/cluster-api-manifests
fi

# 'openshift-install destroy cluster' is deliberately not called. On platform: baremetal the
# installer owns no infrastructure -- CAPHCI created every VM, NIC and disk -- so there is nothing
# for it to tear down.

cat <<EOF

Cluster ${infra_id} deleted.

Manual cleanup still required:

  * DNS records for api.<cluster-domain> and *.apps.<cluster-domain>. CAPHCI has no DNS
    integration, so these were created by hand and must be removed by hand.

  * The virtual network, if CAPHCI created it. The ownership check in
    cloud/services/virtualnetworks/virtualnetworks.go is inverted relative to its own comment: it
    skips deletion when the OWNER tag is absent, nil, *or* equal to "CAPH". A vnet CAPHCI created
    is tagged CAPH and is therefore never cleaned up. Remove it with:
      ${MOCCTL} network vnet delete --name ${VNET_NAME:-<vnet>} --group ${VNET_RESOURCE_GROUP:-<group>}

  * Anything left behind in the resource group. Check for orphans with:
      ${MOCCTL} compute vm list --group ${RESOURCE_GROUP:-<group>}
      ${MOCCTL} network nic list --group ${RESOURCE_GROUP:-<group>}
      ${MOCCTL} storage virtualharddisk list --group ${RESOURCE_GROUP:-<group>}
EOF
