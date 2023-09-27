#!/bin/bash

CLUSTER_DIR=$1
OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install}
SCRIPT_ROOT=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
OC=${OC:-oc}

if [ -z "${CLUSTER_DIR}" ]; then
    echo "Usage: ./destroy-cluster.sh <cluster-dir>"
    exit 1
fi

if [ ! -d "${CLUSTER_DIR}" ]; then
    echo "Expected cluster directory ${CLUSTER_DIR} to exist"
    exit 1
fi

if [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
    echo "metadata.json to exist in ${CLUSTER_DIR}"
    exit 1
fi

infra_id=$(jq -r '.infraID' ${CLUSTER_DIR}/metadata.json)

if [ -d "${CLUSTER_DIR}/cluster-api-manifests" ]; then
   rm -rf ${CLUSTER_DIR}/cluster-api-manifests
fi

guest_oc="${OC} --kubeconfig ${CLUSTER_DIR}/auth/kubeconfig"

if ${guest_oc} get nodes --request-timeout=5s > /dev/null 2>&1 ; then
    echo "Cluster is still running, removing worker machines"
    machines="$(${guest_oc} get machines -n openshift-machine-api -o json -l machine.openshift.io/cluster-api-machine-role=worker | jq -r '.items[].metadata.name')"
    for machine in "${machines}"; do
        ${guest_oc} annotate machine -n openshift-machine-api ${machine} machine.openshift.io/exclude-node-draining="true"
    done

    machine_sets="$(${guest_oc} get machineset -n openshift-machine-api -o json | jq -r '.items[].metadata.name')"
    for machineset in "${machine_sets}"; do
        ${OC} --kubeconfig ${CLUSTER_DIR}/auth/kubeconfig scale machineset -n openshift-machine-api ${machineset} --replicas=0
    done

    while [ "$(${OC} --kubeconfig ${CLUSTER_DIR}/auth/kubeconfig get machines -n openshift-machine-api -o json -l machine.openshift.io/cluster-api-machine-role=worker | jq -r '.items[]')" != "" ]; do
        echo "Waiting for machines to be deleted"
        sleep 5
    done
fi

# Trigger the cluster delete will delete all dependents.
${OC} delete cluster --namespace openshift-cluster-api-guests ${infra_id} --wait=false

while [ "$(${OC} get machines -n openshift-cluster-api-guests -o json -l cluster.x-k8s.io/cluster-name=${infra_id} | jq -r '.items[]')" != "" ]; do
    echo "Waiting for machines to be deleted"
    sleep 5
done

# Wait for the cluster to go away.
${OC} delete cluster --namespace openshift-cluster-api-guests ${infra_id} || true

${OPENSHIFT_INSTALL} --dir ${CLUSTER_DIR} destroy cluster
