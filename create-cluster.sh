#!/bin/bash

CLUSTER_DIR=$1
OPENSHIFT_INSTALL=${OPENSHIFT_INSTALL:-openshift-install}
SCRIPT_ROOT=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
OC=${OC:-oc}
AWS=${AWS:-aws}

# Fixed:
# - Install updated CRDs from PR
# - Add assume role permissions to the IAM role for CAPA
# - Cannot delete cluster
# - Load balancer name for CAPI is not the same as MAPI
# - When does the installer shut down the bootstrap node
# - Invalid secret backend for CAPA
# - Instance profiles profiles should be called profiles
# - Security group name for MAPI is not the same as CAPI
#   - SG names in machinesets/machines/controlplanemachineset need updates
# - No SSH to bootstrap node by default
# - Address bootstrap ignition feature gate issue
# - See if https://github.com/kubernetes-sigs/cluster-api-provider-aws/pull/4359 will help with control plane SG rules
# - Security group rules created by installer are not the same as created by CAPI
#   - This is largely fixed now, but still not identical, needs a thorough review
# - On delete, destroy LB first
# - Should be able to determine if API is available not just bootstrap API, to allow reentrant bootstrap
# - Should create kubeconfig in cluster to allow access to bootstrap API

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
region=$(jq -r '.aws.region' ${CLUSTER_DIR}/metadata.json)
aws_account_id=$(${AWS} sts get-caller-identity --query Account --output text)

mkdir -p ${CLUSTER_DIR}/cluster-api-manifests

for f in ${SCRIPT_ROOT}/templates/*.yaml; do
    REGION=${region} INFRA_ID=${infra_id} AWS_ACCOUNT_ID=${aws_account_id} envsubst '${REGION} ${INFRA_ID} ${AWS_ACCOUNT_ID}'  < $f > ${CLUSTER_DIR}/cluster-api-manifests/$(basename $f)
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
# BEGIN: Create IAM roles
#

iam_role_name=${infra_id}-capa-installer

if ! ${AWS} iam get-role --role-name "${iam_role_name}" 2>&1 > /dev/null ; then
    echo "Creating IAM role ${iam_role_name}"
    ${AWS} iam create-role --role-name ${iam_role_name} --assume-role-policy-document "$(AWS_ACCOUNT_ID=${aws_account_id} envsubst '${AWS_ACCOUNT_ID}' < ${SCRIPT_ROOT}/capa-installer-role-iam-trust-policy.json)" --tags Key=kubernetes.io/cluster/${infra_id},Value=owned
fi

if ! ${AWS} iam get-role-policy --role-name "${iam_role_name}" --policy-name "${iam_role_name}" 2>&1 > /dev/null ; then
    echo "Creating IAM role policy ${iam_role_name}"
    ${AWS} iam put-role-policy --role-name ${iam_role_name} --policy-name ${iam_role_name} --policy-document "$(cat ${SCRIPT_ROOT}/capa-installer-role-iam-policy.json)"
fi

for role in {master,worker}; do
    iam_machine_role_name=${infra_id}-${role}-role
    iam_machine_profile_name=${infra_id}-${role}-profile

    if ! ${AWS} iam get-role --role-name "${iam_machine_role_name}" 2>&1 > /dev/null ; then
        echo "Creating IAM role ${iam_machine_role_name}"
        ${AWS} iam create-role --role-name ${iam_machine_role_name} --assume-role-policy-document "$(cat ${SCRIPT_ROOT}/machine-role-iam-trust-policy.json)" --tags Key=kubernetes.io/cluster/${infra_id},Value=owned
    fi

    if ! ${AWS} iam get-role-policy --role-name "${iam_machine_role_name}" --policy-name "${iam_machine_role_name}" 2>&1 > /dev/null ; then
        echo "Creating IAM role policy ${iam_machine_role_name}"
        ${AWS} iam put-role-policy --role-name ${iam_machine_role_name} --policy-name ${iam_machine_role_name} --policy-document "$(cat ${SCRIPT_ROOT}/${role}-role-iam-policy.json)"
    fi

    if ! ${AWS} iam get-instance-profile --instance-profile-name "${iam_machine_profile_name}" 2>&1 > /dev/null ; then
        echo "Creating IAM instance profile ${iam_machine_profile_name}"
        ${AWS} iam create-instance-profile --instance-profile-name ${iam_machine_profile_name} --tags Key=kubernetes.io/cluster/${infra_id},Value=owned
    fi

    instance_profile_roles=$(${AWS} iam get-instance-profile --instance-profile-name "${iam_machine_profile_name}" | jq -r '.InstanceProfile.Roles[]')

    if [ -z "${instance_profile_roles}" ] ; then
        echo "Adding IAM role ${iam_machine_role_name} to instance profile ${iam_machine_profile_name}"
        ${AWS} iam add-role-to-instance-profile --instance-profile-name ${iam_machine_profile_name} --role-name ${iam_machine_role_name}
    fi
done

#
# END: Create IAM roles
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

while [ "$(${OC} get awscluster --namespace openshift-cluster-api-guests ${infra_id} -o json | jq .status.ready)" != 'true' ]; do
    echo "Waiting for AWS infrastructure cluster to be ready"
    sleep 5
done

#
# END: Apply cluster manifests to cluster
#

#
# BEGIN: Create internal load balancer
#

subnet_ids=$(${OC} get awscluster -n openshift-cluster-api-guests ${infra_id} -o json | jq -r '.spec.network.subnets[]| select(.isPublic == false) | .resourceID' | xargs)
vpc_id=$(${OC} get awscluster -n openshift-cluster-api-guests ${infra_id} -o json | jq -r '.spec.network.vpc.id')

internal_lb_name=${infra_id}-int
internal_lb_arn=$(${AWS} elbv2 describe-load-balancers --region ${region} --names ${internal_lb_name} | jq -r '.LoadBalancers[0].LoadBalancerArn')

if [ -z ${internal_lb_arn} ] ; then
    echo "Creating internal load balancer ${internal_lb_name}"
    ${AWS} elbv2 create-load-balancer --region ${region} --name ${internal_lb_name} --subnets ${subnet_ids} --type network --scheme internal --tags Key=kubernetes.io/cluster/${infra_id},Value=owned
    internal_lb_arn=$(${AWS} elbv2 describe-load-balancers --region ${region} --names ${internal_lb_name} | jq -r '.LoadBalancers[0].LoadBalancerArn')
fi

api_target_name=${infra_id}-aint
api_target_arn=$(${AWS} elbv2 describe-target-groups --region ${region} --name ${api_target_name} | jq -r '.TargetGroups[0].TargetGroupArn')

if [ -z ${api_target_arn} ] ; then
    echo "Creating target group ${api_target_name}"
    ${AWS} elbv2 create-target-group --region ${region} --name ${api_target_name} --protocol TCP --port 6443 --vpc-id ${vpc_id} --target-type instance --tags Key=kubernetes.io/cluster/${infra_id},Value=owned --health-check-port 6443 --health-check-path /readyz --health-check-protocol HTTPS
    api_target_arn=$(${AWS} elbv2 describe-target-groups --region ${region} --name ${api_target_name} | jq -r '.TargetGroups[0].TargetGroupArn')
fi

mcs_target_name=${infra_id}-sint
mcs_target_arn=$(${AWS} elbv2 describe-target-groups --region ${region} --name ${mcs_target_name} | jq -r '.TargetGroups[0].TargetGroupArn')

if [ -z ${mcs_target_arn} ] ; then
    echo "Creating target group ${mcs_target_name}"
    ${AWS} elbv2 create-target-group --region ${region} --name ${mcs_target_name} --protocol TCP --port 22623 --vpc-id ${vpc_id} --target-type instance --tags Key=kubernetes.io/cluster/${infra_id},Value=owned --health-check-port 22623 --health-check-path /healthz --health-check-protocol HTTPS
    mcs_target_arn=$(${AWS} elbv2 describe-target-groups --region ${region} --name ${mcs_target_name} | jq -r '.TargetGroups[0].TargetGroupArn')
fi

listeners=$(${AWS} elbv2 describe-listeners --region ${region} --load-balancer-arn ${internal_lb_arn} | jq -r '.Listeners[]')

if [ -z "$(echo ${listeners} | jq 'select(.Port == 6443)')" ]; then
    echo "Creating listener for port 6443"
    ${AWS} elbv2 create-listener --region ${region} --load-balancer-arn ${internal_lb_arn} --protocol TCP --port 6443 --default-actions Type=forward,TargetGroupArn=${api_target_arn} --tags Key=kubernetes.io/cluster/${infra_id},Value=owned
fi

if [ -z "$(echo ${listeners} | jq 'select(.Port == 22623)')" ]; then
    echo "Creating listener for port 22623"
    ${AWS} elbv2 create-listener --region ${region} --load-balancer-arn ${internal_lb_arn} --protocol TCP --port 22623 --default-actions Type=forward,TargetGroupArn=${mcs_target_arn} --tags Key=kubernetes.io/cluster/${infra_id},Value=owned
fi

#
# END: Create internal load balancer
#

#
# BEGIN: Create DNS entries for external and internal load balancers
#

api_server_public_lb_name=$(${OC} get awscluster -n openshift-cluster-api-guests ${infra_id} -o json | jq -r '.spec.controlPlaneLoadBalancer.name')
api_server_public_lb_arn=$(${AWS} elbv2 describe-load-balancers --region ${region} --names ${api_server_public_lb_name} | jq -r '.LoadBalancers[0]')
api_server_public_lb_dns_name=$(${AWS} elbv2 describe-load-balancers --region ${region} --names ${api_server_public_lb_name} | jq -r '.LoadBalancers[0].DNSName')
api_server_public_lb_zone_id=$(${AWS} elbv2 describe-load-balancers --region ${region} --names ${api_server_public_lb_name} | jq -r '.LoadBalancers[0].CanonicalHostedZoneId')

cluster_domain=$(jq -r '.aws.clusterDomain' ${CLUSTER_DIR}/metadata.json)
base_domain=$(echo ${cluster_domain} | cut -d . -f 2-)

public_hosted_zone_id=$(${AWS} route53 list-hosted-zones-by-name --region ${region} --dns-name ${base_domain} | jq -r ".HostedZones[] | select(.Name == \"${base_domain}.\") | .Id")
existing_public_records=$(${AWS} route53 list-resource-record-sets --hosted-zone-id ${public_hosted_zone_id} --query "ResourceRecordSets[?Name == 'api.${cluster_domain}.']")

if [ "${existing_public_records}" == "[]" ] ; then 
    echo "Creating DNS entry for api.${cluster_domain}"
    insert_public_records=$(cat << EOF
{
    "Comment": "Insert public records for ${infra_id}",
    "Changes": [
        {
            "Action": "CREATE",
            "ResourceRecordSet": {
                "Name": "api.${cluster_domain}",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "${api_server_public_lb_zone_id}",
                    "DNSName": "${api_server_public_lb_dns_name}",
                    "EvaluateTargetHealth": false
                }
            }
        }
    ]
}
EOF
)
    ${AWS} route53 change-resource-record-sets --hosted-zone-id ${public_hosted_zone_id} --change-batch "${insert_public_records}"
fi

api_server_internal_lb_dns_name=$(${AWS} elbv2 describe-load-balancers --region ${region} --names ${internal_lb_name} | jq -r '.LoadBalancers[0].DNSName')
api_server_internal_lb_zone_id=$(${AWS} elbv2 describe-load-balancers --region ${region} --names ${internal_lb_name} | jq -r '.LoadBalancers[0].CanonicalHostedZoneId')

internal_hosted_zone_id=$(${AWS} route53 list-hosted-zones-by-name --region ${region} --dns-name ${cluster_domain} | jq -r ".HostedZones[] | select(.Name == \"${cluster_domain}.\") | .Id")

if [ -z ${internal_hosted_zone_id} ]; then
    echo "Creating hosted zone for ${cluster_domain}"
    ${AWS} route53 create-hosted-zone --region ${region} --name ${cluster_domain} --caller-reference $(date +%s) --hosted-zone-config Comment="Hosted zone for ${cluster_domain}",PrivateZone=true --vpc VPCRegion=${region},VPCId=${vpc_id}
    internal_hosted_zone_id=$(${AWS} route53 list-hosted-zones-by-name --region ${region} --dns-name ${cluster_domain} | jq -r ".HostedZones[] | select(.Name == \"${cluster_domain}.\") | .Id")

    ${AWS} route53 change-tags-for-resource --resource-type hostedzone --resource-id $(echo ${internal_hosted_zone_id} | cut -d/ -f 3) --add-tags Key=kubernetes.io/cluster/${infra_id},Value=owned Key=Name,Value=${infra_id}-int
fi

existing_internal_records=$(${AWS} route53 list-resource-record-sets --hosted-zone-id ${internal_hosted_zone_id} --query "ResourceRecordSets[?Name == 'api.${cluster_domain}.']")
if [ "${existing_internal_records}" == "[]" ] ; then 
    echo "Creating internal DNS entry for api.${cluster_domain} and api-int.${cluster_domain}"
    insert_internal_records=$(cat << EOF
{
    "Comment": "Insert internal records for ${infra_id}",
    "Changes": [
        {
            "Action": "CREATE",
            "ResourceRecordSet": {
                "Name": "api.${cluster_domain}",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "${api_server_internal_lb_zone_id}",
                    "DNSName": "${api_server_internal_lb_dns_name}",
                    "EvaluateTargetHealth": false
                }
            }
        },
        {
            "Action": "CREATE",
            "ResourceRecordSet": {
                "Name": "api-int.${cluster_domain}",
                "Type": "A",
                "AliasTarget": {
                    "HostedZoneId": "${api_server_internal_lb_zone_id}",
                    "DNSName": "${api_server_internal_lb_dns_name}",
                    "EvaluateTargetHealth": false
                }
            }
        }
    ]
}
EOF
)
    ${AWS} route53 change-resource-record-sets --hosted-zone-id ${internal_hosted_zone_id} --change-batch "${insert_internal_records}"
fi

#
# END: Create DNS entries for external and internal load balancers
#

#
# BEGIN: Create required security groups and rules
#

if [ "$(${AWS} ec2 describe-security-groups --region ${region} --filter Name=\"group-name\",Values=\"${infra_id}-ocp-bootstrap\" | jq -r '.SecurityGroups[]')" == "" ] ; then
    echo "Creating security group ${infra_id}-ocp-bootstrap"
    ${AWS} ec2 create-security-group --region ${region} --group-name ${infra_id}-ocp-bootstrap --description "Security group for ${infra_id} bootstrap" --vpc-id ${vpc_id} --tag-specification "ResourceType=security-group,Tags=[{Key=\"Name\",Value=\"${infra_id}-ocp-bootstrap\"},{Key=\"sigs.k8s.io/cluster-api-provider-aws/cluster/${infra_id}\",Value=\"owned\"}]"
fi

bootstrap_sg_id=$(${AWS} ec2 describe-security-groups --region ${region} --filter Name="group-name",Values="${infra_id}-ocp-bootstrap" | jq -r '.SecurityGroups[0].GroupId')
bootstrap_sg_rules=$(${AWS} ec2 describe-security-group-rules --region ${region} --filter Name="group-id",Values="${bootstrap_sg_id}" | jq -r '.SecurityGroupRules[]')

if [ -z "$(echo ${bootstrap_sg_rules} | jq 'select(.IpProtocol == "tcp")| select(.FromPort == 22) | select(.ToPort == 22) | select(.CidrIpv4 == "0.0.0.0/0")')" ]; then
    echo "Creating bootstrap security group rule for port 22"
    ${AWS} ec2 authorize-security-group-ingress --region ${region} --group-id ${bootstrap_sg_id} --protocol tcp --port 22 --cidr 0.0.0.0/0
fi

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

    while ! ${OC} get openshiftbootstrapconfig --namespace openshift-cluster-api-guests ${infra_id}-bootstrap 2>&1 > /dev/null; do
        echo "Waiting for bootstrap bootstrapconfig to be created"
        sleep 5
    done

    ${OC} patch openshiftbootstrapconfig --namespace openshift-cluster-api-guests ${infra_id}-bootstrap --subresource status --type merge -p '{"status":{"ready":true,"dataSecretName":"'${infra_id}-bootstrap-user-data'"}}'

    while ! ${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-bootstrap 2>&1 > /dev/null; do
        echo "Waiting for bootstrap machine to be created"
        sleep 5
    done

    while [ $(${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-bootstrap -o json | jq -r '.spec.instanceID') == "null" ]; do
        echo "Waiting for bootstrap node to be provisioned"
        sleep 5
    done

    while [ $(${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-bootstrap -o json | jq -r '.status.instanceState') != "running" ]; do
        echo "Waiting for bootstrap node to be running"
        sleep 5
    done

    bootstrap_id=$(${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-bootstrap -o json | jq -r '.spec.instanceID')

    int_api_boostrap_target_health=$(${AWS} elbv2 describe-target-health --region ${region} --target-group-arn ${api_target_arn} --targets "Id=${bootstrap_id}" | jq -r '.TargetHealthDescriptions[0].TargetHealth.State')
    if [ "${int_api_boostrap_target_health}" == "unused" ]  ; then
        echo "Registering bootstrap node to internal load balancer (API)"
        ${AWS} elbv2 register-targets --region ${region} --target-group-arn ${api_target_arn} --targets "Id=${bootstrap_id}"
    fi

    int_mcs_boostrap_target_health=$(${AWS} elbv2 describe-target-health --region ${region} --target-group-arn ${mcs_target_arn} --targets "Id=${bootstrap_id}" | jq -r '.TargetHealthDescriptions[0].TargetHealth.State')
    if [ "${int_mcs_boostrap_target_health}" == "unused" ]  ; then
        echo "Registering bootstrap node to internal load balancer (MCS)"
        ${AWS} elbv2 register-targets --region ${region} --target-group-arn ${mcs_target_arn} --targets "Id=${bootstrap_id}"
    fi

    while [ "$(${AWS} elbv2 describe-target-health --region ${region} --target-group-arn ${api_target_arn} | jq -r '.TargetHealthDescriptions[].TargetHealth.State | select(. == "healthy")' | uniq)" != "healthy" ]; do
        echo "Waiting for bootstrap API to be ready"
        sleep 5
    done

    while [ "$(${AWS} elbv2 describe-target-health --region ${region} --target-group-arn ${mcs_target_arn} | jq -r '.TargetHealthDescriptions[].TargetHealth.State | select(. == "healthy")' | uniq)" != "healthy" ]; do
        echo "Waiting for bootstrap MCS to be ready"
        sleep 5
    done
fi

#
# END: Create bootstrap machine
#

#
# BEGIN: Create master machines
#

for node in {master-0,master-1,master-2}; do
 while ! ${OC} get openshiftbootstrapconfig --namespace openshift-cluster-api-guests ${infra_id}-${node} 2>&1 > /dev/null; do
        echo "Waiting for ${node} bootstrapconfig to be created"
        sleep 5
    done

    ${OC} patch openshiftbootstrapconfig --namespace openshift-cluster-api-guests ${infra_id}-${node} --subresource status --type merge -p '{"status":{"ready":true,"dataSecretName":"'${infra_id}-master-user-data'"}}'
done

for node in {master-0,master-1,master-2}; do
    while [ "$(${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-${node} -o json | jq -r '.spec.instanceID')" == 'null' ]; do
        echo "Waiting for ${node} node to be provisioned"
        sleep 5
    done
done

for node in {master-0,master-1,master-2}; do
    while [ "$(${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-${node} -o json | jq -r '.status.instanceState')" != 'running' ]; do
        echo "Waiting for ${node} node to be running"
        sleep 5
    done
done

master_0_id=$(${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-master-0 -o json | jq -r '.spec.instanceID')
master_1_id=$(${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-master-1 -o json | jq -r '.spec.instanceID')
master_2_id=$(${OC} get awsmachine --namespace openshift-cluster-api-guests ${infra_id}-master-2 -o json | jq -r '.spec.instanceID')

for id in {"${master_0_id}","${master_1_id}","${master_2_id}"}; do
    int_api_target_health=$(${AWS} elbv2 describe-target-health --region ${region} --target-group-arn ${api_target_arn} --targets "Id=${id}" | jq -r '.TargetHealthDescriptions[0].TargetHealth.State')
    if [ "${int_api_target_health}" == "unused" ] ; then
        echo "Registering node ${id} to internal load balancer (API)"
        ${AWS} elbv2 register-targets --region ${region} --target-group-arn ${api_target_arn} --targets "Id=${id}"
    fi

    int_mcs_target_health=$(${AWS} elbv2 describe-target-health --region ${region} --target-group-arn ${mcs_target_arn} --targets "Id=${id}" | jq -r '.TargetHealthDescriptions[0].TargetHealth.State')
    if [ "${int_mcs_target_health}" == "unused" ] ; then
        echo "Registering node ${id} to internal load balancer (MCS)"
        ${AWS} elbv2 register-targets --region ${region} --target-group-arn ${mcs_target_arn} --targets "Id=${id}"
    fi
done

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

while [ ${OC} get -f ${bootstrap_machine} > /dev/null 2>&1 ]; do
    echo "Waiting for bootstrap machine to be deleted"
    sleep 5
done

if ${AWS} ec2 describe-security-groups --region ${region} --filter Name="group-name",Values="${infra_id}-ocp-bootstrap" 2>&1 > /dev/null ; then
    echo "Deleting security group ${infra_id}-ocp-bootstrap"
    ${AWS} ec2 delete-security-group --region ${region} --group-id ${bootstrap_sg_id}
fi

#
# END: Destroy bootstrap node
#

echo "Cluster installation complete"
