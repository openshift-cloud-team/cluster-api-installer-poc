# POC: Deploy OpenShift 4 via Cluster API on Azure Local (Azure Stack HCI)

This repository captures a proof-of-concept for provisioning the infrastructure required to deploy
an OpenShift 4 cluster on Azure Local using Cluster API and Microsoft's
[cluster-api-provider-azurestackhci](https://github.com/microsoft/cluster-api-provider-azurestackhci)
(CAPHCI).

It is a port of the AWS/CAPA version of this PoC, which is still on the `main` branch. The point of
the port is to find out how much of a CAPI-based OpenShift install is genuinely provider-agnostic
and how much of it was AWS-shaped. The short answer is that the CAPI plumbing ports almost
unchanged and everything around it — load balancing, DNS, ignition delivery, node addressing —
does not.

**This has not been run against real hardware.** Azure Local and a MOC cloudagent were not
available while writing it. Everything here was derived from provider and installer source and is
structurally complete, but end-to-end provisioning is unverified. The known gaps are recorded in
[docs/azurestackhci-port-plan.md](docs/azurestackhci-port-plan.md), which is the design document
for the port and explains the reasoning behind every decision below.

## What does this POC do?

Based on a basic `install-config.yaml`, `create-cluster.sh` will:

* Generate manifests and ignition configs with `openshift-install`
* Build three RHCOS disk images — bootstrap, master, worker — each with its role's ignition config
  written into it, and upload them to the MOC gallery
* Apply Cluster API and CAPHCI manifests to create the virtual network and the VMs
* Wait for bootstrap to complete and then remove the bootstrap node

It does **not** create a load balancer or any DNS records. On `platform: baremetal` the
machine-config-operator runs keepalived, haproxy and coredns as static pods on the nodes, and those
serve the API VIP, `api-int`, the machine config server on 22623 and the ingress VIP from inside
the cluster. DNS for `api.` and `*.apps.` is an out-of-band prerequisite.

## Prerequisites

### Tooling

* [OpenShift CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/) (`oc`)
* [OpenShift Install CLI](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/)
* `kubectl`, `jq`, `envsubst`, `curl`
* `mocctl`, configured against the MOC cloudagent
* `podman` (or set `CONTAINER_RUNTIME`) and `qemu-img`, for the image build
* An OpenShift pull secret (`pull-secret.txt`)

The image build wants a Linux host. `coreos-installer` runs in a container so it will start on
macOS, but it writes to a loopback-mounted disk image and the qemu fallback has no acceleration
there.

### Azure Local / MOC

Created out of band, before running anything here:

* A MOC identity and login token:
  ```
  mocctl security identity create --name capi --location <location>
  ```
  loaded into the management cluster as Secret `default/caphlogintoken`, key `value`, containing
  base64 YAML with `name`, `token` and `certificate`. CAPHCI has no identity CRD — this one global
  Secret is the whole authentication story.
* A resource group and a storage container for the VMs, disks and images.
* A virtual network. CAPHCI will create one if it does not exist, but it never deletes one it
  created (see gap 9 in the design doc), so a dedicated vnet you expect to remove by hand is the
  safer choice.
* DNS A records for `api.<cluster-domain>` and `*.apps.<cluster-domain>` pointing at the API and
  ingress VIPs, and PTR records for the node names.
* DHCP on the segment — see below.

### DHCP and node naming

This is the environment prerequisite most likely to be missed, and it fails opaquely.

CAPHCI creates a MOC `Transparent` virtual network: the vNIC is bridged straight onto the physical
L2 with no subnet, gateway, DNS servers or IP pool. It also never requests an address for a NIC —
`networkinterfaces.Spec` has a `StaticIPAddress` field but the reconciler that builds the spec
never sets it, and the CRD's `IpConfigurationSpec.IpAddress` is annotated *"below fields are unused,
but adding for completeness"*. There is no path by which CAPHCI gives a node an address.

Nor can the image supply one: all three masters boot the same image, so anything baked in would be
identical on all three.

So the segment needs:

* A DHCP reservation per node, with an infinite lease.
* The hostname supplied via DHCP. Reverse lookup is the fallback but it races node startup, and the
  failure mode is nodes coming up as `localhost` or three masters claiming the same name.
* PTR records matching, which RHCOS needs for CSR generation regardless.

None of this is added by CAPHCI — `platform: baremetal` requires it anyway. Azure Local is IPv4
only, and will not provision a VM on an address that is the network's gateway or DNS server.

If the segment has no usable DHCP, set `STATIC_NETWORK_KARGS` in `azurelocal.env`. The addresses
are then baked in as kernel arguments at image-build time, which means one image per node — five
instead of three — and a correspondingly longer build.

## Setting up the management cluster

Unlike the AWS version, the management cluster is plain Kubernetes. Nothing here needs OpenShift
on the management side.

```
kind create cluster --name capi-mgmt
export KUBECONFIG=$(kind get kubeconfig-path --name capi-mgmt)

clusterctl init
```

Then install CAPHCI. It is not in the `clusterctl` provider registry, so install it from the
repository:

```
git clone https://github.com/microsoft/cluster-api-provider-azurestackhci
cd cluster-api-provider-azurestackhci
make deploy
```

Set `AZURESTACKHCI_CLOUDAGENT_FQDN` on the controller Deployment to the cloudagent's FQDN, and
create the `default/caphlogintoken` Secret described above.

Use `make deploy` rather than applying `config/crd/bases/*.yaml` by hand. In CAPI v1beta2 an
`infrastructureRef` names an `apiGroup` and no version — the version is resolved from the
`cluster.x-k8s.io/v1beta2` contract label on the referenced CRD. CAPHCI adds that label from its
kustomization, not from the CRD sources, so hand-applied CRDs come out unlabelled and every
reference in `templates/` silently fails to resolve.

Check that the CRDs landed with `v1beta2` as the storage version — that is what the controllers
reconcile against and what these templates are written for:

```
kubectl get crd azurestackhciclusters.infrastructure.cluster.x-k8s.io \
  -o jsonpath='{.spec.versions[?(@.storage)].name}'
```

`create-cluster.sh` checks this, along with the login token and the rest of the environment, in a
preflight block before it does anything expensive.

## Configuring the guest cluster

### `install-config.yaml`

Create one in the guest cluster directory. It must have:

```yaml
platform:
  baremetal:
    apiVIPs:
      - 192.168.1.10
    ingressVIPs:
      - 192.168.1.11
    provisioningNetwork: Disabled
compute:
  - name: worker
    replicas: 0
capabilities:
  baselineCapabilitySet: None
  additionalEnabledCapabilities:
    - ...      # anything you want, but NOT MachineAPI
```

Why `platform: baremetal` with MachineAPI disabled: the installer's validation gates both the
"bare metal hosts are missing" error and `ValidateHosts` on the MachineAPI capability being
enabled. Disabling it makes `platform: baremetal` legal with no `hosts[]` and no BMC credentials,
and stops the installer generating master Machines, worker MachineSets, BareMetalHosts and a
ControlPlaneMachineSet — none of which have any meaning here. What we keep is MCO's on-prem
networking stack, which is what removes the need for a load balancer.

`apiVIPs` and `ingressVIPs` are required, must be inside the machine network, and must differ from
each other. `apiVIPs[0]` must match `API_VIP` in `azurelocal.env`.

`create-cluster.sh` fails loudly if the installer generates Machine API manifests anyway — that
would mean the capability was not actually disabled and everything downstream is built on a false
assumption.

### `azurelocal.env`

The AWS version read what it needed from `metadata.json` and `aws sts get-caller-identity`.
`metadata.json` for `platform: baremetal` carries nothing Azure Local specific and MOC has no
caller-identity equivalent, so the environment is configured explicitly:

```
cp azurelocal.env.example <my-guest-cluster-dir>/azurelocal.env
$EDITOR <my-guest-cluster-dir>/azurelocal.env
```

Each variable in the example file carries a comment explaining what it is for and, where relevant,
the CAPHCI behaviour that constrains it. Two worth calling out here:

* `SSH_PUBLIC_KEY_B64` must be **base64 encoded**. The reconciler runs
  `base64.StdEncoding.DecodeString()` over it and fails the machine otherwise.
* `LOCATION` must not be one of `centralus`, `eastus`, `eastus2`, `westus2`, `francecentral`,
  `northeurope`, `uksouth`, `westeurope`, `japaneast` or `southeastasia`. CAPHCI string-matches the
  location against that list to decide whether availability zones are supported, and then
  dereferences `spec.availabilityZone.Enabled` without a nil check. Our machines omit
  `availabilityZone`, so a matching location panics the controller.

## Building the node images

`create-cluster.sh` does this for you; this section explains what it is doing and why, because it
is the largest departure from the AWS version.

CAPHCI passes bootstrap data to MOC as `OSProfile.CustomData`. The provider does not care about the
format — it contains no reference to ignition or cloud-init — but **whether RHCOS on MOC reads
CustomData at all is unproven**, and it was the biggest risk in the design. Rather than bet the
port on it, each role's ignition config is written into its own disk image, and CustomData is never
read.

For each of bootstrap, master and worker, `lib/build-image.sh`:

1. Resolves the RHCOS **metal** artifact from the release payload — not the `azurestack` one. The
   metal image carries `ignition.platform.id=metal`, which is exactly what makes on-disk ignition
   work. The download is cached in `~/.cache/cluster-api-installer-poc` (override with
   `RHCOS_CACHE_DIR`) and shared across the three roles and across runs.
2. Runs `coreos-installer install --image-file <metal.raw.gz> --ignition-file <role>.ign <role>.raw`
   in a container. `coreos-installer install` accepts a plain file as its target, so no VM has to
   be booted.
3. Converts the result to dynamic VHDX with `qemu-img`.
4. Uploads it as `<infra-id>-<role>` with `mocctl compute galleryimage create`, skipping the upload
   if the image already exists so re-runs are cheap.

Ignition then finds the config at `/boot/ignition/config.ign` on first boot — the same path RHCOS
uses for every bare-metal install. This also removes the size ceiling that ruled out the Hyper-V
KVP route: `bootstrap.ign` is hundreds of KB and simply sits on the boot partition.

Two costs worth knowing before you start:

* **The images are single-use.** They embed this cluster's certificates, so they cannot be shared
  between clusters, and they go stale with the 24-hour bootstrap certificate lifetime. Every
  install attempt means rebuilding and re-uploading three multi-GB images.
* **The bootstrap ignition is modified before it is baked in.** On `platform: baremetal` the
  installer always adds five Ironic/Metal3 units to `bootstrap.ign` — the switch is on platform
  name only, not gated on the MachineAPI capability. `master-bmh-update.service` waits forever for
  a `BareMetalHost` CRD that a MachineAPI-disabled cluster never creates, and the step *after* that
  wait is the one that shuts down the ironic containers so the API VIP can fail over to the control
  plane. Left in place, the bootstrap node keeps the VIP and the install cannot complete.
  `build-image.sh` strips those five units and their backing scripts with `jq`.

## Bootstrapping the cluster

With `KUBECONFIG` pointing at the management cluster:

```
./create-cluster.sh <my-guest-cluster-dir>
```

Override binary locations with `OC`, `KUBECTL`, `OPENSHIFT_INSTALL`, `MOCCTL`, `QEMU_IMG`,
`CONTAINER_RUNTIME` and `COREOS_INSTALLER_IMAGE` if they are not on `PATH` under those names.

The script is written to be re-entrant: re-running it after a failure skips work that is already
done, including the image build and upload.

## Destroying the guest cluster

```
./destroy-cluster.sh <my-guest-cluster-dir>
```

This deletes the CAPI `Cluster` — which cascades to the Machines, VMs, NICs and disks — and then
deletes the gallery images, which nothing else cleans up. It does **not** call
`openshift-install destroy cluster`: on this platform the installer owns no infrastructure. It
prints a list of what still needs removing by hand, which includes the DNS records and, thanks to
an inverted ownership check in CAPHCI's vnet delete path, the virtual network.

## Known gaps

The full list, with source citations, is in
[docs/azurestackhci-port-plan.md](docs/azurestackhci-port-plan.md). The ones that will bite first:

* **Nothing here has been run against hardware.** In particular, whether the RHCOS *metal* image
  boots on Hyper-V is untested. The VM must be generation 2 for UEFI boot, and the
  `hyperv_vmbus`/`hv_storvsc`/`hv_netvsc` drivers must be in the initramfs. If it will not boot,
  the `azurestack` VHD is the fallback base, but its `ignition.platform.id=azurestack` reintroduces
  the CustomData question and would need a karg override.
* **The Ironic strip is the assumption most in need of a real test.** With ironic gone there should
  be no VIP contention and keepalived's normal priority handover should apply — should.
* **No guest-cluster node lifecycle.** MachineAPI is off and there is no Azure Local CCM or CSI
  driver. Workers are static, CSRs are approved by hand, there are no dynamic PVs and no
  `Service type=LoadBalancer`. The worker image is built and uploaded but nothing in the PoC
  consumes it — scaling means writing more `03_`-style manifests by hand.
* **No static IPs, no security groups, no object storage, no DNS integration.** Four CAPA
  capabilities with no CAPHCI analogue.
* **CAPHCI's load balancer is unusable for OpenShift** and is deliberately skipped. It creates one
  TCP rule, is never reconciled after creation, needs a MOC vippool its API cannot create, and its
  replica VMs boot with empty bootstrap data — so they need a self-configuring haproxy appliance
  image that does not exist for RHCOS.

## FAQs

### Why is this not using the `openshift-install` binary to create the guest cluster?

Same reason as the AWS version: we are exploring how far Cluster API can be used to bootstrap
OpenShift clusters, and what that costs on a platform the installer has never targeted.

### Why is this not using the `openshift-install` binary to destroy the guest cluster?

On AWS the answer was about tag semantics. Here it is simpler: the installer never created
anything. On `platform: baremetal` it produces manifests and ignition configs and nothing else —
CAPHCI created every VM, NIC and disk, and deleting the CAPI `Cluster` is what removes them. There
is nothing for `openshift-install destroy cluster` to do.

### Can I use this to deploy clusters across multiple clouds?

The management cluster here is plain Kubernetes with `clusterctl`, so in principle it can host any
number of infrastructure providers at once, which is a real improvement over the AWS version's
"an AWS management cluster can only provision AWS" constraint.

In practice the guest-cluster half is deeply platform-specific — the platform in `install-config`,
the VIP arrangement, the image build — so a second platform is a second port, not a configuration
change.

### The install script crashed half way through?

Re-run it. The script is written to be re-entrant and should pick up where it left off. The
expensive parts — the base image download, the image builds and the gallery uploads — all skip
work that is already done.

### Why three images instead of one?

Because each one carries a different ignition config, and ignition is delivered in the image. If
CustomData delivery to RHCOS on MOC turns out to work, this collapses to one shared base image and
the build stage disappears; see gap 3 in the design doc for what would need proving first.
