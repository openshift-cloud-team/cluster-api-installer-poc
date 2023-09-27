# POC: Deploy OpenShift 4 via Cluster API on OpenStack

This repository aims to capture a proof-of-concept for provisioning the infrastructure required to deploy an OpenShift 4 cluster on OpenStack using Cluster API.

## What does this POC do?

This POC will deploy an OpenShift 4 cluster on OpenStack using Cluster API.

Based on a basic `install-config.yaml`, it will create the OpenStack infrastrutcure required to run an OpenShift 4 cluster, and then use Cluster API to deploy the cluster.
Note that it does not support customisation of the infrastructure and is not intended to be used for anything other than a POC.

The `create-cluster.sh` script forms the basis of this install, combined with a number of [templates][./templates] for the Cluster API resources.

The script will:
* Take an `install-config.yaml`, generate manifests and ignition from it and adjust the Machine API related resources to use the modified infrastructure toplogy
* (TODO) Create the internal load balancer and manage attachement of control plane instances to this load balancer
* (TODO) Create a bootstrap node security group (and remove it when no longer required)
* Leverage Cluster API resources to create remanining infrastructure and bootstrap the cluster

## Prerequisites

* [OpenStackClient](https://docs.openstack.org/python-openstackclient/latest/)
* [OpenShift CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)
* [OpenShift Install CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)
* OpenStack credentials
* An openshift pull secret (`pull-secret.txt`)
* An OpenShift 4 cluster:
    * With the `TechPreviewNoUpgrade` feature set enabled
    * TODO: Add support for OpenStack and build https://github.com/openshift/cluster-capi-operator/pull/127

## Setting up the management/bootstrap cluster

This cluster will be used to provision the infrastructure and bootstrap the OpenShift cluster.
This cluster is created using regular IPI workflows, though, it is expected that in the future we will leverage a local Kubernetes like control plane as the CAPI management cluster.

### Getting an OpenShift installer

Using cluster bot, build a release image containing the required PRs:

```
build 4.15,openshift/cluster-capi-operator#127
```

Once the image is built, extract the `openshift-install` binary from the image generated:

```
oc adm release extract --command openshift-install --from registry.build05.ci.openshift.org/ci-ln-<rand>/release:latest -a pull-secret.txt
```

### Installing the management cluster

Use the freshly extracted `openshift-install` binary to generate an install config:

```
./openshift-install create install-config --dir=<my-cluster-dir>
```

Configure the `install-config.yaml` to use the TechPreviewNoUpgrade feature set:

```
echo "featureSet: TechPreviewNoUpgrade" >> <my-cluster-dir>/install-config.yaml
```

Execute the cluster install:
```
./openshift-install create cluster --dir=<my-cluster-dir>
```

Once the installation is complete, you are ready to bootstrap the guest cluster.

## Bootstrapping an OpenShift cluster via Cluster API

Once the management cluster is up and running, you can use the `create-cluster.sh` script to bootstrap the guest cluster.

First, make sure that the `oc`, `openstack` and `openshift-install` binaries are in your path, or use the `OC`, `OPENSTACK` and `OPENSHIFT_INSTALL` environment variables to point to the binaries.

Make sure your `KUBECONFIG` env is pointing to the management cluster kubeconfig.

```
export KUBECONFIG=<my-cluster-dir>/auth/kubeconfig
```

Create an install config for the guest cluster:

```
./openshift-install create install-config --dir=<my-guest-cluster-dir>
```

Then, run the `create-cluster.sh` script:

```
./create-cluster.sh <my-guest-cluster-dir>
```

## Destroying the guest cluster

At present, a few manual steps are required to destroy the guest cluster.
These have been encoded into a `desotry-clustser.sh` script.

In the future it is expected that this will all be handled by additional OpenShift controllers and/or the `openshift-install` binary depending on the cluster topology.

To destroy the guest cluster, run the `destroy-cluster.sh` script:

```
./destroy-cluster.sh <my-guest-cluster-dir>
```

## FAQs

### Why is this not using the `openshift-install` binary to create the guest cluster?

We are exploring avenues to leverage Cluster API to bootstrap OpenShift clusters.
This POC is intended to explore the options available to us and to help us understand the challenges we will face.
By exploring this avenue we can determine whether it is a viable option for us to pursue as an alternative to the current OpenShift IPI workflow.

### Why is this not using the `openshift-install` binary to destroy the guest cluster?

Currently, the `openshift-install` binary reliase on the well known `kubernetes.io/cluster/<id>` tag to identify resources to delete.
Cluster API does not tag all resources with this will known tag, but rather uses its own tag.

If we were to use the `openshift-install` binary to destroy the guest cluster, we would need to ensure that all resources are tagged with the well known tag.
However, Cluster API by default provisions multiple security groups. This would mean that we would need to tag all security groups with the well known tag.
The AWS Cloud Controller Manager expects at most one security group attached to an instance to contain the well known tag, and as such, we cannot do this.

Further to this, deleting the resources outside of the Cluster API controllers, would remove the IAM roles created for the CAPI controllers to provision the cluster.
This would prevent them from detecting that the cluster resources have been removed and would block the removal of the Cluster API resources from the management cluster.

In a future world where the clusters are joined, this is not important and the `openshift-install` binary will be used to destroy the single standalone cluster.
For multi cluster use cases, we need to ensure that the Cluster API controllers are responsible for destroying the cluster.

### Can I use this to deploy clusters across multiple clouds?

At present, the OpenShift technology preview of Cluster API supports AWS and GCP.
However, it only configures the correct provider for the infrastructure of the management cluster.
That is, an AWS management cluster only supports provisioning AWS infrastructure, and a GCP management cluster only supports provisioning GCP infrastructure.

So for the purposes of this POC, you can only use this to deploy clusters on AWS, from an AWS management cluster.

In the future it should be possible for OpenShift to act as a management cluster for multiple platforms, though the particulars of this still need to be worked out.

### The install script crashed half way through?

Just re-run it! The script was written in an attempt to be re-entrant and should pick up where it left off.
