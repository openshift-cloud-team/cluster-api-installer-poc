#!/bin/bash

CLUSTER_DIR=$1
OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install}
SCRIPT_ROOT=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
OC=${OC:-oc}
OPENSTACK=${OPENSTACK:-openstack}
OPENSTACK_EXTERNAL_NETWORK_NAME=${OPENSTACK_EXTERNAL_NETWORK_NAME:-"external"}

# TODO: 
# - Installer should delete resources created by CAPI tags (not all will have cluster tag - ref SG issue)

#
# BEGIN: Setup of script prerequisites
#

if [ -z "${CLUSTER_DIR}" ]; then
    echo "Usage: ./create-cluster.sh <cluster-dir>"
    exit 1
fi

if [ ! -d "${CLUSTER_DIR}" ]; then
    echo "Expected cluster directory ${CLUSTER_DIR} to exist"
    exit 1
fi

if [ ! -f "${CLUSTER_DIR}/install-config.yaml" ] && [ ! -f "${CLUSTER_DIR}/.openshift_install_state.json" ] && [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
    echo "Expected install-config.yaml, .openshift_install_state.json or metadata.json to exist in ${CLUSTER_DIR}"
    exit 1
fi

os_cloud=$(jq -r '.openstack.cloud' ${CLUSTER_DIR}/metadata.json)
export OS_CLOUD=${os_cloud}

if [ -z "${os_cloud}" ]; then
    echo "Expected openstack.cloud to be set in ${CLUSTER_DIR}/metadata.json"
    exit 1
fi

openstack_external_network_id=$(${OPENSTACK} network show ${OPENSTACK_EXTERNAL_NETWORK_NAME} -f value -c id)

if [ -f "${CLUSTER_DIR}/install-config.yaml" ]; then
    ${OPENSHIFT_INSTALL} --dir ${CLUSTER_DIR} create manifests
fi

if [ ! -f "${CLUSTER_DIR}/install-config.yaml" ] && [ -f "${CLUSTER_DIR}/.openshift_install_state.json" ] && [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
    infra_id=$(jq -r '."*installconfig.ClusterID".InfraID' ${CLUSTER_DIR}/.openshift_install_state.json)
    # At this point we have run create manifests but not yet create ignition-configs

    # Update the security groups in the worker machinesets
    for i in {"0","1","2"}; do
        sed -i .bak "s/${infra_id}-worker-sg/${infra_id}-node\n          - filters:\n            - name: tag:Name\n              values:\n              - ${infra_id}-lb/" ${CLUSTER_DIR}/openshift/99_openshift-cluster-api_worker-machineset-${i}.yaml
        rm ${CLUSTER_DIR}/openshift/99_openshift-cluster-api_worker-machineset-${i}.yaml.bak
    done

    # Update the security groups in the master machines
    for i in {"0","1","2"}; do
        sed -i .bak "s/${infra_id}-master-sg/${infra_id}-node\n      - filters:\n        - name: tag:Name\n          values:\n          - ${infra_id}-lb\n      - filters:\n        - name: tag:Name\n          values:\n          - ${infra_id}-controlplane/" ${CLUSTER_DIR}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml
        rm ${CLUSTER_DIR}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml.bak
    done

    # Update the security group in the control plane machine set
    sed -i .bak "s/${infra_id}-master-sg/${infra_id}-node\n            - filters:\n              - name: tag:Name\n                values:\n                - ${infra_id}-lb\n            - filters:\n              - name: tag:Name\n                values:\n                - ${infra_id}-controlplane/" ${CLUSTER_DIR}/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml
    rm ${CLUSTER_DIR}/openshift/99_openshift-machine-api_master-control-plane-machine-set.yaml.bak

    ${OPENSHIFT_INSTALL} --dir ${CLUSTER_DIR} create ignition-configs
fi

#
# END: Setup of script prerequisites
#

#
# BEGIN: Create Cluster API manifests
#

infra_id=$(jq -r '.infraID' ${CLUSTER_DIR}/metadata.json)

mkdir -p ${CLUSTER_DIR}/cluster-api-manifests

for f in ${SCRIPT_ROOT}/templates/*.yaml; do
    INFRA_ID=${infra_id} OS_CLOUD=${os_cloud} OPENSTACK_EXTERNAL_NETWORK_ID=${openstack_external_network_id} envsubst ${INFRA_ID} ${OS_CLOUD} ${OPENSTACK_EXTERNAL_NETWORK_ID} < $f > ${CLUSTER_DIR}/cluster-api-manifests/$(basename $f)
done

for role in {bootstrap,master,worker}; do
    # Note: when applied to the clustser, we add an owner reference to these secrets to link them to the Cluster object
    ${OC} create secret generic --dry-run=client --namespace openshift-cluster-api-guests ${infra_id}-${role}-user-data  --from-literal format=ignition --from-file=value=${CLUSTER_DIR}/${role}.ign -o yaml > ${CLUSTER_DIR}/cluster-api-manifests/02_${role}-user-data-secret.yaml 
done

# Cluster API expects a kubeconfig to be able to talk to the guest cluster
${OC} create secret generic --dry-run=client --namespace openshift-cluster-api-guests ${infra_id}-kubeconfig --from-file=value=${CLUSTER_DIR}/auth/kubeconfig -o yaml > ${CLUSTER_DIR}/cluster-api-manifests/02_kubeconfig-secret.yaml

#
# END: Create Cluster API manifests
#

#
# BEGIN: Apply cluster manifests to cluster
#

for f in ${CLUSTER_DIR}/cluster-api-manifests/00_*.yaml; do
    if ! ${OC} get -f $f > /dev/null 2>&1 ; then
        ${OC} create -f $f
    fi
done

for f in ${CLUSTER_DIR}/cluster-api-manifests/01_*.yaml; do
    if ! ${OC} get -f $f > /dev/null 2>&1 ; then
        ${OC} create -f $f
    fi
done

while [ "$(${OC} get openstackcluster --namespace openshift-cluster-api-guests ${infra_id} -o json | jq .status.ready)" != 'true' ]; do
    echo "Waiting for OpenStack infrastructure cluster to be ready"
    sleep 5
done

#
# END: Apply cluster manifests to cluster
#

#
# BEGIN: Create internal load balancer
#

# Figure out LB stuff
# We might have nothing to do if we use CAPO loadbalancer service (Octavia) or an external LB (a pre-existing HAproxy for example).

#
# END: Create internal load balancer
#

#
# BEGIN: Create required security groups and rules
#

# Figure out security group stuff for the bootstrap machine

#
# END: Create required security group rules
#

#
# BEGIN: Create bootstrap machine
#

cluster_bootstrapped=$(${OC} get cluster -n openshift-cluster-api-guests ${infra_id} -o json | jq -r '.status.conditions[] | select(.type == "ControlPlaneInitialized")| .status')

if [ "${cluster_bootstrapped}" != "True" ]; then
    for f in ${CLUSTER_DIR}/cluster-api-manifests/02_*.yaml; do
        if ! ${OC} get -f $f > /dev/null 2>&1 ; then
            ${OC} create -f $f
        fi
    done

    cluster_uid="$(${OC} get cluster -n openshift-cluster-api-guests ${infra_id} -o json | jq -r '.metadata.uid')"
    for role in {bootstrap,master,worker}; do
        if [ "$(${OC} get secret --namespace openshift-cluster-api-guests ${infra_id}-${role}-user-data -o json | jq '.metadata.ownerReferences')" == 'null' ]; then
            # Patch the Cluster as an owner so that we can delete the secrets when the cluster is deleted
            ${OC} patch secret --namespace openshift-cluster-api-guests ${infra_id}-${role}-user-data -p "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"cluster.x-k8s.io/v1beta1\",\"blockOwnerDeletion\":true,\"controller\":true,\"kind\":\"Cluster\",\"name\":\"${infra_id}\",\"uid\":\"${cluster_uid}\"}]}}"
        fi
    done


    while ! ${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-bootstrap 2>&1 > /dev/null; do
        echo "Waiting for bootstrap machine to be created"
        sleep 5
    done

    while [ $(${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-bootstrap -o json | jq -r '.spec.instanceID') == "null" ]; do
        echo "Waiting for bootstrap node to be provisioned"
        sleep 5
    done

    while [ $(${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-bootstrap -o json | jq -r '.status.instanceState') != "running" ]; do
        echo "Waiting for bootstrap node to be running"
        sleep 5
    done

    bootstrap_id=$(${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-bootstrap -o json | jq -r '.spec.instanceID')
fi

#
# END: Create bootstrap machine
#

#
# BEGIN: Create master machines
#

for f in ${CLUSTER_DIR}/cluster-api-manifests/03_*.yaml; do
    if ! ${OC} get -f $f > /dev/null 2>&1 ; then
        ${OC} create -f $f
    fi
done

for node in {master-0,master-1,master-2}; do
    while [ "$(${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-${node} -o json | jq -r '.spec.instanceID')" == 'null' ]; do
        echo "Waiting for ${node} node to be provisioned"
        sleep 5
    done
done

for node in {master-0,master-1,master-2}; do
    while [ "$(${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-${node} -o json | jq -r '.status.instanceState')" != 'running' ]; do
        echo "Waiting for ${node} node to be running"
        sleep 5
    done
done

master_0_id=$(${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-master-0 -o json | jq -r '.spec.instanceID')
master_1_id=$(${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-master-1 -o json | jq -r '.spec.instanceID')
master_2_id=$(${OC} get openstackmachine --namespace openshift-cluster-api-guests ${infra_id}-master-2 -o json | jq -r '.spec.instanceID')

#
# END: Create master machines
#

#
# BEGIN: Wait for bootstrap complete
#

start_bootrap=$(date +%s)
while ! KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig ${OC} get configmap -n kube-system bootstrap -o json 2>&1 > /dev/null; do
    now_ts=$(date +%s)
    if [ $((${now_ts} - ${start_bootrap})) -gt 1800 ] ; then
        echo "Bootstrap failed to complete after 30 minutes"
        exit 1
    fi

    echo "Waiting for bootstrap configmap"
    sleep 30
done
    
    
while [ $(KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig ${OC} get configmap -n kube-system bootstrap -o json | jq -r '.data["status"]') != "complete" ]; do
    now_ts=$(date +%s)
    if [ $((${now_ts} - ${start_bootrap})) -gt 1800 ] ; then
        echo "Bootstrap failed to complete after 30 minutes"
        exit 1
    fi

    echo "Waiting for bootstrap to complete"
    sleep 30
done

#
# END: Wait for bootstrap complete
#

#
# BEGIN: Destroy bootstrap node
#

bootstrap_machine="${CLUSTER_DIR}/cluster-api-manifests/02_bootstrap-machine.yaml"
if ${OC} get -f ${bootstrap_machine} > /dev/null 2>&1 ; then
    ${OC} delete -f ${bootstrap_machine}
fi

while [ ${OC} get -f ${bootstrap_machine} > /dev/null 2>&1 ]; do
    echo "Waiting for bootstrap machine to be deleted"
    sleep 5
done

# TODO: destroy the bootstrap security group

#
# END: Destroy bootstrap node
#

echo "Cluster installation complete"
