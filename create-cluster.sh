#!/bin/bash

CLUSTER_DIR=$1
OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install}
SCRIPT_ROOT=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
# The management cluster is plain Kubernetes now, so kubectl rather than oc. OC is kept for the
# guest cluster, where we do want the OpenShift client.
KUBECTL=${KUBECTL:-kubectl}
OC=${OC:-oc}

NAMESPACE=capi-guests

source ${SCRIPT_ROOT}/lib/build-image.sh

# TODO:
# - Whether RHCOS on MOC reads OSProfile.CustomData at all is still unproven. We route around it
#   by baking ignition into the images; if it turns out to work, the image build could be dropped
#   in favour of one shared base image.
# - Nothing scales the guest cluster: MachineAPI is disabled and there is no Azure Local CCM or
#   CSI driver, so the worker image is built and uploaded but never consumed.
# - CAPHCI leaks the vnet it creates. See destroy-cluster.sh.

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

if [ ! -f "${CLUSTER_DIR}/azurelocal.env" ]; then
    echo "Expected azurelocal.env to exist in ${CLUSTER_DIR}"
    echo "Copy ${SCRIPT_ROOT}/azurelocal.env.example and fill it in"
    exit 1
fi

source ${CLUSTER_DIR}/azurelocal.env

#
# END: Setup of script prerequisites
#

#
# BEGIN: Preflight checks
#
# CAPHCI fails late and quietly for most of these, so check them up front and print the remedy.
#

preflight_failed=0

preflight_error() {
    echo "PREFLIGHT: $1"
    echo "           $2"
    preflight_failed=1
}

for var in RESOURCE_GROUP LOCATION VNET_NAME VNET_RESOURCE_GROUP STORAGE_CONTAINER \
           SSH_PUBLIC_KEY_B64 CONTROL_PLANE_VM_SIZE BOOTSTRAP_VM_SIZE WORKER_VM_SIZE \
           WORKER_REPLICAS API_VIP KUBERNETES_VERSION CAPI_CORE_VERSION; do
    if [ -z "${!var}" ]; then
        preflight_error "${var} is not set in ${CLUSTER_DIR}/azurelocal.env" \
                        "See ${SCRIPT_ROOT}/azurelocal.env.example"
    fi
done

# WORKER_REPLICAS is substituted straight into MachineDeployment.spec.replicas, which is an
# integer. Anything non-numeric produces a manifest that fails to parse several minutes later,
# after the images have already been built and uploaded.
if ! [[ "${WORKER_REPLICAS}" =~ ^[0-9]+$ ]]; then
    preflight_error "WORKER_REPLICAS must be a non-negative integer, got '${WORKER_REPLICAS}'" \
                    "Leave it at 0 for the install and scale up afterwards"
fi

# base64.StdEncoding.DecodeString() is applied to sshPublicKey by the reconciler.
if [ -n "${SSH_PUBLIC_KEY_B64}" ] && ! echo "${SSH_PUBLIC_KEY_B64}" | base64 -d > /dev/null 2>&1; then
    preflight_error "SSH_PUBLIC_KEY_B64 is not valid base64" \
                    "Set it with: SSH_PUBLIC_KEY_B64=\"\$(base64 -w0 < ~/.ssh/id_ed25519.pub)\""
fi

# isAvailabilityZoneSupported() string-matches spec.location against this list, and the reconciler
# then dereferences spec.availabilityZone.Enabled without a nil check. Our machines omit
# availabilityZone, so a match panics the controller.
for zone_location in centralus eastus eastus2 westus2 francecentral northeurope uksouth westeurope japaneast southeastasia; do
    if [ "${LOCATION}" == "${zone_location}" ]; then
        preflight_error "LOCATION '${LOCATION}' collides with a hardcoded availability zone location" \
                        "Rename the MOC location; this crashes the CAPHCI controller on a nil pointer"
    fi
done

# CAPHCI authenticates to the MOC cloudagent with a single global secret, created out of band with
# 'mocctl security identity create'. There is no identity CRD to fall back on.
if ! ${KUBECTL} get secret -n default caphlogintoken > /dev/null 2>&1; then
    preflight_error "Secret default/caphlogintoken is missing on the management cluster" \
                    "Create a MOC identity with 'mocctl security identity create' and load the token"
fi

if ! ${KUBECTL} get crd azurestackhciclusters.infrastructure.cluster.x-k8s.io > /dev/null 2>&1; then
    preflight_error "CAPHCI CRDs are not installed on the management cluster" \
                    "Install cluster-api-provider-azurestackhci; see README.md"
else
    storage_version=$(${KUBECTL} get crd azurestackhciclusters.infrastructure.cluster.x-k8s.io \
        -o json | jq -r '.spec.versions[] | select(.storage == true) | .name')
    if [ "${storage_version}" != "v1beta2" ]; then
        preflight_error "CAPHCI CRD storage version is '${storage_version}', expected v1beta2" \
                        "The templates are written against v1beta2, which all ten controllers import"
    fi
fi

for tool in ${CONTAINER_RUNTIME:-podman} ${QEMU_IMG:-qemu-img} ${MOCCTL:-mocctl} jq envsubst curl; do
    if ! command -v ${tool} > /dev/null 2>&1; then
        preflight_error "${tool} is not on PATH" \
                        "Required to build and upload the RHCOS gallery images"
    fi
done

if [ ${preflight_failed} -ne 0 ]; then
    echo
    echo "Preflight checks failed; fix the above and re-run."
    exit 1
fi

#
# END: Preflight checks
#

# wait_for_machine <name>
#
# Waits for an AzureStackHCIMachine's virtual machine to come up.
#
# The AWS version polled .spec.instanceID and then .status.instanceState == "running". CAPHCI has
# no instance ID on the spec, and its VMState enum is
# Creating|Updating|Succeeded|Migrating|Failed|Deleting -- there is no "Running", so Succeeded is
# the terminal healthy state.
#
# Unlike the AWS version this fails fast rather than looping forever. PathNotFound in particular
# means the gallery image is missing, which is easy to hit while iterating on the image build.
wait_for_machine() {
    local name=$1
    local json state failure

    while ! ${KUBECTL} get azurestackhcimachine --namespace ${NAMESPACE} ${name} > /dev/null 2>&1; do
        echo "Waiting for ${name} to be created"
        sleep 5
    done

    while true; do
        json=$(${KUBECTL} get azurestackhcimachine --namespace ${NAMESPACE} ${name} -o json)
        state=$(echo "${json}" | jq -r '.status.vmState // "Pending"')

        if [ "${state}" == "Succeeded" ]; then
            echo "${name} is running"
            return 0
        fi

        if [ "${state}" == "Failed" ]; then
            echo "${name} entered the Failed VM state"
            echo "${json}" | jq -r '.status.conditions[]? | select(.status == "False") | "  \(.reason): \(.message)"'
            return 1
        fi

        failure=$(echo "${json}" | jq -r '
            .status.conditions[]?
            | select(.type == "VMRunning" and .status == "False")
            | select(["VMProvisionFailed", "OutOfMemory", "OutOfCapacity", "PathNotFound", "MOCUnreachable"] | index(.reason))
            | "\(.reason): \(.message)"')
        if [ -n "${failure}" ]; then
            echo "${name} failed to provision -- ${failure}"
            case "${failure}" in
                PathNotFound*)
                    echo "  PathNotFound means the MOC gallery image was not found; check that the"
                    echo "  image referenced by spec.image.name was uploaded." ;;
                MOCUnreachable*)
                    echo "  Check AZURESTACKHCI_CLOUDAGENT_FQDN on the CAPHCI controller and the"
                    echo "  default/caphlogintoken secret." ;;
            esac
            return 1
        fi

        echo "Waiting for ${name} to be running (VM state: ${state})"
        sleep 5
    done
}

#
# BEGIN: Generate manifests and ignition
#

if [ -f "${CLUSTER_DIR}/install-config.yaml" ]; then
    ${OPENSHIFT_INSTALL} --dir ${CLUSTER_DIR} create manifests || exit 1
fi

if [ ! -f "${CLUSTER_DIR}/install-config.yaml" ] && [ -f "${CLUSTER_DIR}/.openshift_install_state.json" ] && [ ! -f "${CLUSTER_DIR}/metadata.json" ]; then
    # The AWS version of this script patched security group references into the generated Machine
    # API manifests here. On platform: baremetal with the MachineAPI capability disabled, the
    # installer generates no master Machines, no worker MachineSets, no BareMetalHosts and no
    # ControlPlaneMachineSet at all -- pkg/asset/machines/{master,worker}.go break out early on
    # !enabledCaps.Has(ClusterVersionCapabilityMachineAPI) -- so there is nothing to patch.
    #
    # If those objects do appear, the capability was not actually disabled and the rest of this
    # script is built on a false assumption.
    #
    # Check for the kinds, not for the 99_openshift-cluster-api_* filename glob. Verified against
    # openshift-install 5.0.0: with MachineAPI disabled the installer still writes
    # 99_openshift-cluster-api_{master,worker}-user-data-secret.yaml -- they are just the pointer
    # ignition Secrets in openshift-machine-api, and they are harmless. Globbing on the filename
    # rejects a correctly configured cluster.
    if grep -qE '^kind: (Machine|MachineSet|ControlPlaneMachineSet|BareMetalHost)$' \
            "${CLUSTER_DIR}"/openshift/*.yaml 2>/dev/null; then
        echo "Machine API manifests were generated, which means the MachineAPI capability is enabled."
        echo "Set the following in install-config.yaml and start from a clean directory:"
        echo "  capabilities:"
        echo "    baselineCapabilitySet: None"
        echo "    additionalEnabledCapabilities: [...]   # without MachineAPI"
        exit 1
    fi

    ${OPENSHIFT_INSTALL} --dir ${CLUSTER_DIR} create ignition-configs || exit 1
fi

infra_id=$(jq -r '.infraID' ${CLUSTER_DIR}/metadata.json)

bootstrap_image_name=${infra_id}-bootstrap
master_image_name=${infra_id}-master
worker_image_name=${infra_id}-worker

#
# END: Generate manifests and ignition
#

#
# BEGIN: Build and upload the RHCOS gallery images
#

image_dir=${CLUSTER_DIR}/images
cache_dir=${RHCOS_CACHE_DIR:-${HOME}/.cache/cluster-api-installer-poc}
mkdir -p ${image_dir}

# bootstrap.ign always carries the ironic/metal3 units on the baremetal platform, and
# master-bmh-update.service deadlocks without the BareMetalHost CRD, keeping the API VIP pinned to
# the bootstrap node. Strip them before the image is built.
strip_ironic_units ${CLUSTER_DIR}/bootstrap.ign ${image_dir}/bootstrap-stripped.ign || exit 1

base_image=$(fetch_metal_artifact ${cache_dir}) || exit 1

# With DHCP (the default) all three masters share one image. With STATIC_NETWORK_KARGS set they
# cannot, because the address and hostname are baked in per node -- five images instead of three.
if [ ${#STATIC_NETWORK_KARGS[@]} -eq 0 ]; then
    build_image ${image_dir} ${base_image} ${image_dir}/bootstrap-stripped.ign \
        ${image_dir}/${bootstrap_image_name}.vhdx || exit 1
    build_image ${image_dir} ${base_image} ${CLUSTER_DIR}/master.ign \
        ${image_dir}/${master_image_name}.vhdx || exit 1
    build_image ${image_dir} ${base_image} ${CLUSTER_DIR}/worker.ign \
        ${image_dir}/${worker_image_name}.vhdx || exit 1

    upload_gallery_image ${bootstrap_image_name} ${image_dir}/${bootstrap_image_name}.vhdx || exit 1
    upload_gallery_image ${master_image_name} ${image_dir}/${master_image_name}.vhdx || exit 1
    upload_gallery_image ${worker_image_name} ${image_dir}/${worker_image_name}.vhdx || exit 1
else
    nameserver_karg=""
    [ -n "${STATIC_NAMESERVER}" ] && nameserver_karg="nameserver=${STATIC_NAMESERVER}"

    build_image ${image_dir} ${base_image} ${image_dir}/bootstrap-stripped.ign \
        ${image_dir}/${bootstrap_image_name}.vhdx "${STATIC_NETWORK_KARGS[0]}" "${nameserver_karg}" || exit 1
    upload_gallery_image ${bootstrap_image_name} ${image_dir}/${bootstrap_image_name}.vhdx || exit 1

    for i in 0 1 2; do
        build_image ${image_dir} ${base_image} ${CLUSTER_DIR}/master.ign \
            ${image_dir}/${master_image_name}-${i}.vhdx \
            "${STATIC_NETWORK_KARGS[$((i + 1))]}" "${nameserver_karg}" || exit 1
        upload_gallery_image ${master_image_name}-${i} ${image_dir}/${master_image_name}-${i}.vhdx || exit 1
    done

    # Per-node images mean the shared ${MASTER_IMAGE_NAME} no longer applies; the master manifests
    # need patching to reference ${master_image_name}-<i>.
    echo "STATIC_NETWORK_KARGS is set: patch the master AzureStackHCIMachine manifests to use the"
    echo "per-node images ${master_image_name}-{0,1,2} before continuing."
fi

#
# END: Build and upload the RHCOS gallery images
#

#
# BEGIN: Create Cluster API manifests
#

mkdir -p ${CLUSTER_DIR}/cluster-api-manifests

substitutions='${INFRA_ID} ${LOCATION} ${RESOURCE_GROUP} ${VNET_NAME} ${VNET_RESOURCE_GROUP}'
substitutions+=' ${SSH_PUBLIC_KEY_B64} ${STORAGE_CONTAINER} ${CONTROL_PLANE_VM_SIZE}'
substitutions+=' ${BOOTSTRAP_VM_SIZE} ${API_VIP} ${KUBERNETES_VERSION} ${CAPI_CORE_VERSION}'
substitutions+=' ${BOOTSTRAP_IMAGE_NAME} ${MASTER_IMAGE_NAME} ${WORKER_IMAGE_NAME}'
substitutions+=' ${WORKER_VM_SIZE} ${WORKER_REPLICAS}'

for f in ${SCRIPT_ROOT}/templates/*.yaml; do
    INFRA_ID=${infra_id} \
    LOCATION=${LOCATION} \
    RESOURCE_GROUP=${RESOURCE_GROUP} \
    VNET_NAME=${VNET_NAME} \
    VNET_RESOURCE_GROUP=${VNET_RESOURCE_GROUP} \
    SSH_PUBLIC_KEY_B64=${SSH_PUBLIC_KEY_B64} \
    STORAGE_CONTAINER=${STORAGE_CONTAINER} \
    CONTROL_PLANE_VM_SIZE=${CONTROL_PLANE_VM_SIZE} \
    BOOTSTRAP_VM_SIZE=${BOOTSTRAP_VM_SIZE} \
    API_VIP=${API_VIP} \
    KUBERNETES_VERSION=${KUBERNETES_VERSION} \
    CAPI_CORE_VERSION=${CAPI_CORE_VERSION} \
    BOOTSTRAP_IMAGE_NAME=${bootstrap_image_name} \
    MASTER_IMAGE_NAME=${master_image_name} \
    WORKER_IMAGE_NAME=${worker_image_name} \
    WORKER_VM_SIZE=${WORKER_VM_SIZE} \
    WORKER_REPLICAS=${WORKER_REPLICAS} \
    envsubst "${substitutions}" < $f > ${CLUSTER_DIR}/cluster-api-manifests/$(basename $f)
done

# CAPI requires bootstrap data to exist before an infrastructure machine is provisioned, and
# MachineScope.GetBootstrapData() errors if the secret or its "value" key is missing. Nothing reads
# the contents: the real ignition is in the gallery image. Keeping a placeholder here rather than
# the real config also keeps the cluster root CA private key and the pull secret off the
# management cluster.
for role in {bootstrap,master,worker}; do
    ${KUBECTL} create secret generic --dry-run=client --namespace ${NAMESPACE} \
        ${infra_id}-${role}-user-data \
        --from-literal value="# placeholder: the ${role} ignition config is baked into the gallery image" \
        -o yaml > ${CLUSTER_DIR}/cluster-api-manifests/02_${role}-user-data-secret.yaml
done

# Cluster API expects a kubeconfig to be able to talk to the guest cluster.
${KUBECTL} create secret generic --dry-run=client --namespace ${NAMESPACE} \
    ${infra_id}-kubeconfig --from-file=value=${CLUSTER_DIR}/auth/kubeconfig \
    -o yaml > ${CLUSTER_DIR}/cluster-api-manifests/02_kubeconfig-secret.yaml

#
# END: Create Cluster API manifests
#

#
# BEGIN: Apply cluster manifests to cluster
#

for f in ${CLUSTER_DIR}/cluster-api-manifests/00_*.yaml; do
    if ! ${KUBECTL} get -f $f > /dev/null 2>&1 ; then
        ${KUBECTL} create -f $f
    fi
done

for f in ${CLUSTER_DIR}/cluster-api-manifests/01_*.yaml; do
    if ! ${KUBECTL} get -f $f > /dev/null 2>&1 ; then
        ${KUBECTL} create -f $f
    fi
done

# Note this is .status.initialization.provisioned, not .status.ready. AzureStackHCIClusterStatus
# dropped Ready in v1beta2 in favour of the CAPI initialization contract.
while [ "$(${KUBECTL} get azurestackhcicluster --namespace ${NAMESPACE} ${infra_id} -o json | jq -r '.status.initialization.provisioned')" != 'true' ]; do
    cluster_failure=$(${KUBECTL} get azurestackhcicluster --namespace ${NAMESPACE} ${infra_id} -o json |
        jq -r '.status.conditions[]? | select(.type == "NetworkInfrastructureReady" and .status == "False") | .message')
    if [ -n "${cluster_failure}" ]; then
        echo "AzureStackHCICluster reconciliation is failing: ${cluster_failure}"
    fi

    echo "Waiting for AzureStackHCI infrastructure cluster to be ready"
    sleep 5
done

#
# END: Apply cluster manifests to cluster
#
#
# The AWS version built an internal NLB with target groups for 6443 and 22623, registered each
# instance into it, and created Route53 records for api and api-int. None of that is ported.
#
# On platform: baremetal the machine-config-operator's onPremPlatform() path deploys keepalived,
# haproxy and coredns as static pods on the nodes themselves, and those serve the API VIP,
# api-int, MCS on 22623 and the ingress VIP from inside the cluster. That also sidesteps CAPHCI
# having no static IP support: the VIP floats onto whichever node holds it rather than us needing
# to know node addresses in advance to register them as backends.
#
# DNS for api.<cluster-domain> and *.apps.<cluster-domain> is an operator prerequisite; CAPHCI has
# no DNS integration to replace Route53 with.
#

#
# BEGIN: Create bootstrap machine
#

cluster_bootstrapped=$(${KUBECTL} get cluster -n ${NAMESPACE} ${infra_id} -o json | jq -r '.status.conditions[]? | select(.type == "ControlPlaneInitialized")| .status')

if [ "${cluster_bootstrapped}" != "True" ]; then
    for f in ${CLUSTER_DIR}/cluster-api-manifests/02_*.yaml; do
        if ! ${KUBECTL} get -f $f > /dev/null 2>&1 ; then
            ${KUBECTL} create -f $f
        fi
    done

    cluster_uid="$(${KUBECTL} get cluster -n ${NAMESPACE} ${infra_id} -o json | jq -r '.metadata.uid')"
    for role in {bootstrap,master,worker}; do
        if [ "$(${KUBECTL} get secret --namespace ${NAMESPACE} ${infra_id}-${role}-user-data -o json | jq '.metadata.ownerReferences')" == 'null' ]; then
            # Patch the Cluster as an owner so that we can delete the secrets when the cluster is deleted
            ${KUBECTL} patch secret --namespace ${NAMESPACE} ${infra_id}-${role}-user-data -p "{\"metadata\":{\"ownerReferences\":[{\"apiVersion\":\"cluster.x-k8s.io/${CAPI_CORE_VERSION}\",\"blockOwnerDeletion\":true,\"controller\":true,\"kind\":\"Cluster\",\"name\":\"${infra_id}\",\"uid\":\"${cluster_uid}\"}]}}"
        fi
    done

    wait_for_machine ${infra_id}-bootstrap || exit 1
fi

#
# END: Create bootstrap machine
#

#
# BEGIN: Create master machines
#

for f in ${CLUSTER_DIR}/cluster-api-manifests/03_*.yaml; do
    if ! ${KUBECTL} get -f $f > /dev/null 2>&1 ; then
        ${KUBECTL} create -f $f
    fi
done

for node in {master-0,master-1,master-2}; do
    wait_for_machine ${infra_id}-${node} || exit 1
done

#
# END: Create master machines
#

#
# BEGIN: Wait for bootstrap complete
#

start_bootrap=$(date +%s)
while ! KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig ${OC} get configmap -n kube-system bootstrap -o json > /dev/null 2>&1; do
    now_ts=$(date +%s)
    if [ $((${now_ts} - ${start_bootrap})) -gt 1800 ] ; then
        echo "Bootstrap failed to complete after 30 minutes"
        exit 1
    fi

    echo "Waiting for bootstrap configmap"
    sleep 30
done

while [ "$(KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig ${OC} get configmap -n kube-system bootstrap -o json | jq -r '.data["status"]')" != "complete" ]; do
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
if ${KUBECTL} get -f ${bootstrap_machine} > /dev/null 2>&1 ; then
    ${KUBECTL} delete -f ${bootstrap_machine}
fi

while ${KUBECTL} get -f ${bootstrap_machine} > /dev/null 2>&1; do
    echo "Waiting for bootstrap machine to be deleted"
    sleep 5
done

# The AWS version deleted the bootstrap security group here. CAPHCI has no security groups.

#
# END: Destroy bootstrap node
#

#
# BEGIN: Create worker MachineDeployment
#
# Applied last, and by default with replicas: 0. A worker cannot join before the masters are
# serving the machine config server on the API VIP, and the AWS version had no equivalent step at
# all -- there, workers came from Machine API MachineSets that the installer generated. Here
# MachineAPI is disabled, so this MachineDeployment is the only thing that can create workers.
#
# Read docs/azurestackhci-port-plan.md "Phase 2: workers and pivot" before scaling this up. In
# short: the VMs boot and the nodes join after their CSRs are approved by hand, but the Machines
# never reach Running, because nothing sets Node.spec.providerID. link-nodes.sh closes that gap
# one node at a time.

for f in ${CLUSTER_DIR}/cluster-api-manifests/04_*.yaml; do
    if ! ${KUBECTL} get -f $f > /dev/null 2>&1 ; then
        ${KUBECTL} create -f $f
    fi
done

#
# END: Create worker MachineDeployment
#

echo "Cluster installation complete"

if [ "${WORKER_REPLICAS}" == "0" ]; then
    cat <<EOF

The cluster has no workers. The MachineDeployment ${infra_id}-worker exists at 0 replicas; scale it
up one replica at a time:

  ${KUBECTL} scale machinedeployment ${infra_id}-worker -n ${NAMESPACE} --replicas=1

Then, for each worker, approve its two CSRs and link the Node to its Machine:

  KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig ${OC} get csr -o name | xargs \\
    KUBECONFIG=${CLUSTER_DIR}/auth/kubeconfig ${OC} adm certificate approve
  ./link-nodes.sh ${CLUSTER_DIR}

The second CSR only appears once the first is approved, so expect to run the approve twice.
EOF
fi
