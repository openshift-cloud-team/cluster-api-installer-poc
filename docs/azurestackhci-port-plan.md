# Port the CAPI installer PoC from AWS/CAPA to Azure Stack HCI / CAPHCI

> This is the design document for the port carried out on this branch. It records the decisions,
> the constraints that were verified against provider and installer source, and the gaps that
> remain. `README.md` is the user-facing guide; this file is the reasoning behind it.
>
> Source citations refer to `github.com/microsoft/cluster-api-provider-azurestackhci` at `master`
> (2026-08-20), `openshift/installer` (2024-08-12) and `openshift/machine-config-operator`
> (2025-04-23).

## Context

`cluster-api-installer-poc` currently demonstrates provisioning an OpenShift 4 cluster on AWS
using Cluster API: `create-cluster.sh` drives `openshift-install`, patches the generated
Machine API manifests, creates IAM roles, applies CAPA manifests, hand-builds an internal NLB
and Route53 records, and babysits the bootstrap node until `bootstrap-complete`.

We want the same concept expressed against Microsoft's
[cluster-api-provider-azurestackhci](https://github.com/microsoft/cluster-api-provider-azurestackhci)
(CAPHCI) so we can see how much of the CAPI-based install flow is genuinely provider-agnostic
and where the OpenShift assumptions are actually AWS assumptions. The result should be an honest
PoC: everything that can work, working; everything that can't, documented as a gap.

Work happens on a new branch off `main`. The AWS content is **replaced**, not kept alongside —
it stays reachable on `main`.

## Decisions taken

| Question | Decision |
|---|---|
| Base branch | `main` |
| AWS content | Replaced entirely |
| Scope | Structural port, gaps flagged rather than hidden |
| install-config platform | `baremetal`, with the MachineAPI capability disabled |
| Control plane endpoint | Skip CAPHCI's load balancer; operator supplies the VIPs |
| Ignition delivery | **Three custom per-cluster VHDs** — bootstrap, control plane, worker — each with its role's ignition baked in. No reliance on CustomData |
| Management cluster | Plain kind/vanilla Kubernetes + `clusterctl` |

## Verified constraints that shape the design

Each of these was checked against source, not assumed. Two contradicted what an initial survey
suggested, so the citations matter.

**`platform: baremetal` without bare metal.** `pkg/types/baremetal/validation/platform.go:436-449`
gates both the "bare metal hosts are missing" error and `ValidateHosts` on
`!agentBasedInstallation && enabledCaps.Has(ClusterVersionCapabilityMachineAPI)`. Disabling the
MachineAPI capability makes `platform: baremetal` legal with **no `hosts[]` and no BMC
credentials**. `pkg/asset/machines/master.go:399` and `worker.go:509` are gated the same way, so
no master Machines, no worker MachineSets, no BareMetalHosts and no ControlPlaneMachineSet are
generated at all — the AWS PoC's whole `sed`-the-manifests section disappears with nothing to
replace it and nothing to `rm`.

**This is why `baremetal` is the right platform, and it is worth being explicit about how much it
buys.** MCO's `onPremPlatform()` (`pkg/controller/template/render.go:620`) includes
`BareMetalPlatformType`, so the cluster gets the on-prem keepalived + haproxy + coredns static
pods. Those serve the API VIP, `api-int`, **MCS on 22623** and the ingress VIP from inside the
cluster. Consequences:

- The internal load balancer, the target-group registration and the Route53 records in
  `create-cluster.sh` are deleted rather than ported.
- CAPHCI has no static IP support (`IpConfigurationSpec.IpAddress` exists in the CRD but is never
  plumbed through to `networkinterfaces.Spec.StaticIPAddress`), so node IPs are unpredictable.
  Under an external-LB design that would force a manual backend-registration step; keepalived
  makes the problem moot, because the VIP floats onto the nodes themselves.
- `apiVIPs` and `ingressVIPs` become required install-config fields
  (`pkg/types/validation/installconfig.go:768+`), must sit inside the machine network, and must
  differ from each other.

**Use `v1beta2`, not `v1beta1`.** All ten controllers import
`infrav1 ".../api/v1beta2`, and every kind carries `+kubebuilder:storageversion` in `api/v1beta2/`.
v1beta1 is still served but is not what the controllers reconcile against. This also changes
readiness: in v1beta2 `AzureStackHCIClusterStatus.Ready` does not exist — it was replaced by
`Status.Initialization.Provisioned`.

**Readiness fields differ from CAPA.** `AzureStackHCICluster` readiness is
`.status.initialization.provisioned` — *not* `.status.ready`. `AzureStackHCIMachine` and
`AzureStackHCIVirtualMachine` expose `.status.ready`, `.status.vmState` and `.status.addresses`.
The `VMState` enum (`api/v1beta2/types.go`) is
`Creating|Updating|Succeeded|Migrating|Failed|Deleting` — **there is no `Running`**, so the AWS
PoC's `.status.instanceState == "running"` becomes `.status.vmState == "Succeeded"`, and there is
no `.spec.instanceID` to wait on first.

**CAPHCI has no identity CRD.** Authentication is a single global Secret `caphlogintoken` in
namespace `default`, key `value`, holding base64 YAML with `name`/`token`/`certificate` for the
MOC cloudagent (`pkg/auth/auth.go`), created out of band with `mocctl security identity create`.
Both identity templates and all four IAM JSON files are deleted with no replacement — they become
a README prerequisite plus a preflight check.

**Skipping CAPHCI's load balancer is explicitly supported.**
`controllers/azurestackhcicluster_controller.go:359-362`: when `spec.azureStackHCILoadBalancer` is
nil the controller logs "Skipping load balancer reconciliation" and returns ready. Because the
`controlPlaneEndpoint` overwrite lives *inside* that same skipped function, our hand-written value
survives. This is the right call regardless: the LB creates exactly one TCP rule
(`cloud/services/loadbalancers/loadbalancers.go:82-91`), is never updated after creation
("no update supported for now"), needs a pre-existing MOC vippool that the API cannot create
(`cloud/services/vippools/vippools.go:64`), and its replica VMs boot with `bootstrapdata := ""`
(`controllers/azurestackhciloadbalancer_virtualmachine.go:222-223`) — meaning they require a
self-configuring haproxy appliance gallery image that does not exist for RHCOS.

**Ignition is delivered in the image, not through CAPHCI.** `MachineScope.GetBootstrapData()`
(`cloud/scope/machine.go:215`) reads the Secret's `value` key, base64-encodes it, and it lands as
MOC `OSProfile.CustomData` (`cloud/services/virtualmachines/virtualmachines.go:153`). The provider
contains zero occurrences of "ignition" or "cloud-init" — it does not care about the format. But
**whether RHCOS on MOC/Hyper-V reads CustomData at all is not determinable from any source
available here**, and it was the single biggest risk in the design. We sidestep it: each role gets
its ignition baked into its own disk image, so CustomData is never read and the question never has
to be answered.

CAPI's Machine contract still requires bootstrap data to exist before an infra machine is
provisioned, and `GetBootstrapData()` errors if the Secret or its `value` key is missing. So the
Secrets are still created — but with a short placeholder rather than the real config, since
nothing consumes them. That is also a small security win: `bootstrap.ign` carries the cluster root
CA private key and the pull secret, and it no longer needs to sit in a Secret on the management
cluster. A comment in the template should say why the Secret exists, so nobody later "fixes" it by
putting the real ignition back.

**Networking is flat, and node addressing comes from the physical network — i.e. DHCP.** This is
the constraint that most shapes the environment prerequisites, so it is worth spelling out.

Azure Local has two networking surfaces. The Arc-managed one — `az stack-hci-vm network lnet
create` — offers *logical networks* in either `Dynamic` (DHCP) or `Static` flavour, where Static
takes `--address-prefixes --gateway --dns-servers --ip-pool-start --ip-pool-end` and the platform
does IPAM. AKS on Azure Local uses the Static variety, reserving the control plane IP from inside
the CIDR but outside any pool.

**CAPHCI does not use that surface at all.** It talks to MOC/`wssd` directly and creates a
`network.VirtualNetwork` with `Type: "Transparent"` and nothing but an `AddressSpace`
(`cloud/services/virtualnetworks/virtualnetworks.go:76-88`) — no subnets, no gateway, no DNS
servers, no IP pool. The comment above `Reconcile` lists subnet CIDRs, NSGs and a route table as
things that "should be created upstream and provided as an input"; nothing creates them.
`Transparent` means the vNIC is bridged straight onto the physical L2, so addressing is whatever
that segment provides.

Nor does CAPHCI ever request an address. `networkinterfaces.Spec` has a `StaticIPAddress` field
that maps to `PrivateIPAddress` (`networkinterfaces.go:43,87`), but the reconciler that builds the
spec never populates it (`azurestackhcivirtualmachine_reconciler.go:232-238`). On the CRD side
`IpConfigurationSpec.IpAddress`, `.Gateway` and `.PrefixLength` carry the comment *"below fields
are unused, but adding for completeness"* (`api/v1beta2/types.go:125`), and `IPAllocationMethod` is
never plumbed through either — the internal `networkinterfaces.IPConfiguration` struct only has
`Name` and `Primary`. There is no path by which a node gets a configured address.

**So the design requires a DHCP server on the segment, and that is not a burden CAPHCI adds.**
`platform: baremetal` already requires it: Red Hat's guidance is a DHCP reservation per node with
the hostname supplied via DHCP, with reverse DNS as the fallback — and PTR records are needed
regardless, because RHCOS uses them to generate the node CSRs. DHCP is preferred precisely because
reverse lookup races node startup and leaves services seeing `localhost`. Reservations should use
infinite leases. Also note Azure Local is **IPv4 only**, and will not provision a VM on an address
that is the logical network's own gateway or DNS server.

Beyond addressing, the network has no public/private split, no NAT, no internet gateway and **no
security groups**. An empty `vnet.name` makes the provider create one at
`DefaultVnetCIDR = 10.0.0.0/8` (`cloud/defaults.go`), though under `Transparent` that address space
is largely advisory. The `AWSCluster` CNI ingress rules, the six subnets and the bootstrap security
group all have no analogue and are deleted. The flat L2 is also what makes keepalived/VRRP work,
so it suits the VIP design.

## Landmines in CAPHCI to code around

Small, verified, and each capable of costing a day:

- **`sshPublicKey` must be base64-encoded.**
  `controllers/azurestackhcivirtualmachine_reconciler.go:250` does
  `base64.StdEncoding.DecodeString(...Spec.SSHPublicKey)` and errors out otherwise. Applies to
  `AzureStackHCIMachine.spec.sshPublicKey` too. Hence `${SSH_PUBLIC_KEY_B64}`.
- **Omit `spec.availabilityZone`, and keep `${LOCATION}` off the hardcoded list.** In v1beta2
  `AvailabilityZone` is a **pointer** (`api/v1beta2/azurestackhcivirtualmachine_types.go:37`), but
  line 277 dereferences `Spec.AvailabilityZone.Enabled` unguarded whenever
  `isAvailabilityZoneSupported()` is true — which is a string match of `spec.location` against ten
  hardcoded Azure public region names in `cloud/defaults.go:73` (`centralus`, `eastus`, `eastus2`,
  `westus2`, `francecentral`, `northeurope`, `uksouth`, `westeurope`, `japaneast`,
  `southeastasia`). Naming an Azure Local location after one of those panics the controller.
- **`bootstrapData` is dereferenced without a nil check.** Line 303/304 does
  `CustomData: *…Spec.BootstrapData` with no guard. Only reachable when creating an
  `AzureStackHCIVirtualMachine` directly.
- **Base64 asymmetry between the two paths.** The Machine path base64-encodes for you
  (`GetBootstrapData()`); the standalone-VM path passes `spec.bootstrapData` through verbatim. A
  bare VM must therefore carry pre-encoded data.
- **Fix the latent bug in `01_capi-cluster.yaml`**: `infrastructureRef.namespace` is currently
  `openshift-cluster-api`, which is not where anything lives. Drop the field.

Four more found while writing the manifests rather than while surveying. The first is core CAPI
rather than CAPHCI, and it is the one that would have failed on first apply:

- **`infrastructureRef` is a `ContractVersionedObjectReference` in v1beta2, not an
  `ObjectReference`.** The fields are `apiGroup`, `kind`, `name` — there is no `apiVersion` and no
  `namespace`, and all three of the remaining fields are required. This applies to
  `Cluster.spec.infrastructureRef`, `Machine.spec.infrastructureRef` and
  `Machine.spec.bootstrap.configRef` alike. The version is no longer written by hand: CAPI looks it
  up from the `cluster.x-k8s.io/v1beta2` contract label on the referenced CRD.

  That has a deployment consequence worth stating in the README. CAPHCI applies the label from
  `config/crd/kustomization.yaml:29`, not from the CRD sources — so installing the CRDs by applying
  `config/crd/bases/*.yaml` directly produces unlabelled CRDs and every `infrastructureRef` fails
  to resolve.

  Install via `clusterctl`, not by hand and not with `kubectl apply -f`. CAPHCI has no `deploy`
  Make target, but it ships `metadata.yaml`, `hack/clusterctl.yaml` and a
  `create-local-provider-repository` target, so the supported route is
  `make release-manifests && make create-local-provider-repository`, then
  `clusterctl init --infrastructure azurestackhci`. `config/default` includes `../crd`, so the
  contract labels are in the generated `infrastructure-components.yaml`. The second, independent
  reason to go through `clusterctl` is `clusterctl move`: its object graph discovers what to move
  by listing CRDs carrying the `clusterctl.cluster.x-k8s.io` label, which only `clusterctl` applies
  (`cmd/clusterctl/client/cluster/objectgraph.go:422`). A hand-installed provider cannot be
  pivoted. Note that `create-local-provider-repository` overwrites `~/.cluster-api/clusterctl.yaml`
  wholesale.

  It also means `${CAPI_CORE_VERSION}` now only parameterises the top-level `apiVersion:` of the
  `Cluster` and `Machine` objects and the owner reference patched onto the user-data Secrets. It no
  longer appears in any infrastructure reference.



- **The `cluster.x-k8s.io/control-plane` label is load-bearing, not decorative.**
  `MachineScope.Role()` (`cloud/scope/machine.go:136-141`) derives the role from
  `util.IsControlPlaneMachine()`, which reads that label off the owning `Machine`; the VM spec
  mapping in `azurestackhcimachine_controller.go:288-360` ends in
  `default: return errors.Errorf("unknown value %s for label \`set\` on machine …")`. Without the
  label the machine is never created, and the error names a label we do not set. Both the bootstrap
  and the master `Machine`s carry it.
- **Three of the four `osDisk` fields are inert.** `generateStorageProfile()`
  (`cloud/services/virtualmachines/virtualmachines.go:245-266`) derives the OS disk URI from the VM
  name and reads only `OSDisk.OSType`; `Name`, `Source` and `DiskSizeGB` are never looked at. The
  CRD requires all four to be present, so they are set with a comment saying they do nothing —
  otherwise the next person sizes a disk here and wonders why nothing changes.
- **The guest OS hostname from MOC is random.** `generateComputerName()`
  (`virtualmachines.go:351-374`) builds `"moc-"` plus a role letter plus random characters to a
  total length of 15. This is more evidence for the DHCP requirement above rather than a separate
  problem: nothing in the CAPHCI path will ever give a node the name OpenShift expects.

## Repo restructure

Delete `templates/00_aws-cluster-controller-identity-default.yaml`,
`templates/00_aws-cluster-role-identity.yaml`, `templates/01_capi-awscluster.yaml`,
`templates/02_bootstrap-awsmachine.yaml`, `templates/03_master-{0,1,2}-awsmachine.yaml`, and all
four `*-iam-*.json` files at the repo root.

`metadata.json` for `platform: baremetal` carries no Azure Local specifics and there is no
`aws sts get-caller-identity` equivalent, so add **`azurelocal.env`** in the cluster directory
(sourced by both scripts) with an `azurelocal.env.example` at the repo root. New `envsubst`
variables, replacing `${REGION}` and `${AWS_ACCOUNT_ID}`: `${LOCATION}`, `${RESOURCE_GROUP}`,
`${VNET_NAME}`, `${VNET_RESOURCE_GROUP}`, `${SSH_PUBLIC_KEY_B64}`, `${STORAGE_CONTAINER}`,
`${CONTROL_PLANE_VM_SIZE}`, `${BOOTSTRAP_VM_SIZE}`, `${API_VIP}`, `${CLUSTER_DOMAIN}`,
`${KUBERNETES_VERSION}`, `${CAPI_CORE_VERSION}`. `${INFRA_ID}` stays. The single
`${RHCOS_IMAGE_NAME}` becomes three — `${BOOTSTRAP_IMAGE_NAME}`, `${MASTER_IMAGE_NAME}`,
`${WORKER_IMAGE_NAME}` — derived by the script as `${INFRA_ID}-{bootstrap,master,worker}` rather
than configured, since they are built per cluster.

## New `templates/`

Numbered-prefix ordering is preserved. All infra kinds are
`infrastructure.cluster.x-k8s.io/v1beta2`.

- `00_capi-guests-ns.yaml` — Namespace. Rename `openshift-cluster-api-guests` → `capi-guests`;
  the old name only made sense on an OpenShift management cluster.
- `01_capi-cluster.yaml` — `Cluster`. `spec.clusterNetwork.apiServerPort: 6443`;
  `infrastructureRef` → `AzureStackHCICluster/${INFRA_ID}` with the bogus namespace dropped.
- `01_capi-azurestackhcicluster.yaml` — `AzureStackHCICluster`. Required `resourceGroup`,
  `location`, `version`. `networkSpec.vnet.name` + `.group`.
  `controlPlaneEndpoint: {host: ${API_VIP}, port: 6443}`. **Deliberately omit
  `azureStackHCILoadBalancer`** — ship it commented out with a TODO recording exactly why.
- `02_bootstrap-machine.yaml` + `02_bootstrap-azurestackhcimachine.yaml`
- `03_master-{0,1,2}-machine.yaml` + `03_master-{0,1,2}-azurestackhcimachine.yaml`

`AzureStackHCIMachine` sets `vmSize`, `location`, `sshPublicKey` (all required, key base64'd),
`osDisk: {osType: Linux, diskSizeGB: 120}`, `storageContainer`, `allocatePublicIP: false`, and
omits `availabilityZone`. `image.name` is the per-role gallery image: `${BOOTSTRAP_IMAGE_NAME}` on
the bootstrap machine and `${MASTER_IMAGE_NAME}` on all three masters. This is the only field that
differs by role — which is the point of building three images.

Keep the bootstrap node as `Machine` + `AzureStackHCIMachine` rather than a bare
`AzureStackHCIVirtualMachine`. A bare VM is genuinely viable — `NewVirtualMachineScope` needs only
the CR — but it means hand-setting `resourceGroup`/`vnetName`/`clusterName`/`subnetName`,
pre-base64ing the bootstrap data, dodging the nil-deref, and losing cascade delete. The Machine
path handles all of that, keeps the shape symmetric with the masters, and preserves the existing
Secret + owner-reference cleanup trick. The one thing it costs — CAPI parking `NodeHealthy=False`
on a bootstrap node that never joins — is cosmetic in a PoC.

## `create-cluster.sh` rewrite

| Existing section | Action |
|---|---|
| Arg/dir validation | Keep; add `azurelocal.env` sourcing and a `preflight()` |
| `create manifests` + `sed` the MAPI manifests | **Delete.** Nothing is generated to patch. Add a guard that fails loudly if `openshift/99_openshift-cluster-api_*` files *do* appear — that means the MachineAPI capability wasn't actually disabled |
| `create ignition-configs` | Keep |
| envsubst templates | Keep; new variable set |
| user-data Secrets | Keep the creation, but write a placeholder `value` instead of the real `.ign`; drop `--from-literal format=ignition` |
| kubeconfig Secret | Keep verbatim — CAPI still requires `<cluster>-kubeconfig` with key `value` |
| IAM role creation | **Delete.** README prerequisite instead |
| Apply `00_`/`01_`, wait for infra cluster | Keep the shape; poll `.status.initialization.provisioned` |
| Build internal LB, target groups, listeners | **Delete** — keepalived/haproxy handle it in-cluster |
| Route53 public + private records | **Delete** — operator's DNS prerequisite |
| Bootstrap security group | **Delete** — CAPHCI has no security groups |
| Apply `02_`, wait for bootstrap | Keep; poll `.status.vmState == "Succeeded"` |
| Register bootstrap in target groups | **Delete** |
| Apply `03_`, wait for masters | Keep, same status-field change |
| Register masters in target groups | **Delete** |
| Wait for `kube-system/bootstrap` configmap | Keep verbatim |
| Delete bootstrap machine + SG | Keep the machine deletion; drop the SG deletion |

New `preflight()` before `create manifests`, checking: the `caphlogintoken` Secret exists in
`default`; the CAPHCI CRDs are installed with `v1beta2` as storage; every `azurelocal.env` variable
is non-empty; `${LOCATION}` is not on the availability-zone list; and `api.`/`api-int.` resolve.
Each failure should print the specific remedy.

### The new image-build stage

A new `build_image <role>` function runs between ignition generation and applying manifests, and is
called three times — `bootstrap`, `master`, `worker`. This is the largest piece of genuinely new
code in the port, so it gets its own function in a sourced `lib/build-image.sh` rather than being
inlined.

Per role:

1. Resolve the **metal** artifact, not the `azurestack` one:
   `openshift-install coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats."raw.gz".disk.location'`.
   Cache the download across roles — it is the same base image three times.
2. Write the role's ignition into a copy of that raw disk with
   `coreos-installer install --image-file <cached.raw.gz> --ignition-file <role>.ign <role>.raw`.
   `coreos-installer install` accepts a plain file as its target, so no VM boot is needed. Run it
   from the `quay.io/coreos/coreos-installer` container so the flow works on a machine without a
   local build of it.
3. `qemu-img convert -f raw -O vhdx -o subformat=dynamic <role>.raw <role>.vhdx`.
4. `mocctl compute galleryimage create --name ${INFRA_ID}-<role> --image-path <role>.vhdx
   --os-type Linux`, skipping if the image already exists so the script stays re-entrant.

Because the config is on disk at `/boot/ignition/config.ign` before first boot, Ignition consumes
it on the `metal` platform path — the same path RHCOS uses for every bare-metal install — and
never looks at CustomData. This also removes the size ceiling that made the `hyperv` KVP route
unworkable: `bootstrap.ign` is hundreds of KB and simply sits on the boot partition.

Fallback if writing to a file turns out not to work in the container: `coreos-installer iso
customize --dest-device /dev/vda --dest-ignition <role>.ign`, then boot that ISO in
`qemu-system-x86_64 -no-reboot` against a blank raw disk. qemu exits at the post-install reboot,
which captures the disk *before* Ignition has run. Same result, one more moving part.

Two practical notes for the README rather than the script: this needs a Linux host — on macOS
`coreos-installer` has to run in a container and the qemu fallback has no acceleration — and it
means building and uploading three multi-GB images for every install attempt.

Two fixes worth making while in here: the poll loops should abort on `.status.failureReason` /
`.status.failureMessage` (the VM controller sets `VMProvisionFailed`, `OutOfMemory`,
`OutOfCapacity`, `PathNotFound` — a missing gallery image — and `MOCUnreachable`) rather than
hanging forever as the AWS script does; and line 498's
`while [ ${OC} get -f ${bootstrap_machine} > /dev/null 2>&1 ]` is a malformed test that never
loops.

Switch `${OC}` to `${KUBECTL}` for management-cluster calls now that it is no longer OpenShift,
keeping `${OC}` only for guest-cluster calls that genuinely need it.

## `destroy-cluster.sh` rewrite

Drop the worker-MachineSet scale-down (no Machine API in the guest cluster). Keep `delete cluster`
and the wait for Machines to disappear, retargeted at the new namespace. Delete the ELB and
security-group cleanup entirely. Drop `openshift-install destroy cluster` — on this platform it
owns no infrastructure — and replace it with a printed manual-cleanup list: DNS records, and
`mocctl` inspection of the resource group for orphaned VMs, NICs and disks. Add explicit
`mocctl compute galleryimage delete` calls for all three `${INFRA_ID}-{bootstrap,master,worker}`
images — nothing else cleans them up, they are single-use per cluster, and at multiple GB each
they will silently fill the storage container across repeated PoC runs.

## `README.md` rewrite

Replace the AWS prerequisites and the entire "build a release image with cluster-bot /
TechPreviewNoUpgrade / install an OpenShift management cluster" section with:

- Management cluster: kind, `clusterctl init` for core CAPI, then install CAPHCI with
  `AZURESTACKHCI_CLOUDAGENT_FQDN` set on the controller Deployment.
- Out-of-band prerequisites: `mocctl security identity create`; the `caphlogintoken` Secret; the
  vnet; the storage container; DNS A records for `api.` and `*.apps.` pointing at the VIPs; a
  base64'd SSH public key. The three gallery images are *not* a prerequisite — `create-cluster.sh`
  builds and uploads them, because they are cluster-specific.
- A new "Building the node images" section explaining the three-VHD approach, why it exists (MOC
  CustomData delivery to RHCOS is unproven, and image-embedded ignition is the path RHCOS already
  supports everywhere), the Linux/qemu host requirement, and the disk-space and upload cost.
- Document the DHCP hostname requirement below, since it is an environment prerequisite that will
  not be obvious.
- install-config requirements: `platform: baremetal`, MachineAPI capability disabled,
  `provisioningNetwork: Disabled`, `apiVIPs`/`ingressVIPs` inside the machine network and distinct
  from each other, `compute[0].replicas: 0`.
- Rewrite the FAQ: the "why not `openshift-install` to destroy" answer is now about CAPHCI owning
  the VMs rather than AWS tag semantics, and the multi-cloud answer changes completely.

## Phase 2: workers and pivot

Gap 10 originally said the worker image was built and uploaded but nothing consumed it. This
section is what consumes it. The question it answers is a narrow one, and it is worth stating the
answer before the detail:

> **Would this get us to working worker machines after manual CSR approval?**
>
> Working worker **nodes**, yes. Working worker **Machines**, no.

Those are two different objects and only one of them works, so they are treated separately below.

### What works: the node

Nothing on the path from "MachineDeployment scaled up" to "node running pods" depends on anything
CAPHCI does badly.

1. The MachineSet controller clones `AzureStackHCIMachineTemplate/${INFRA_ID}-worker` into an
   `AzureStackHCIMachine`, and CAPHCI creates the MOC VM from `${WORKER_IMAGE_NAME}`.
2. The VM boots the worker gallery image. `worker.ign` is already at `/boot/ignition/config.ign`,
   so Ignition consumes it on the `metal` platform path, exactly as on the masters.
3. `worker.ign` is a **pointer config** — verified against `openshift-install` 5.0.0 it is nothing
   but a merge source and a CA bundle:

   ```json
   {"ignition":{"config":{"merge":[{"source":"https://<apiVIP>:22623/config/worker"}]},
    "security":{"tls":{"certificateAuthorities":[...]}}}}
   ```

   The node fetches its real MachineConfig from the machine config server. Two things follow.
   First, **the worker image does not go stale** the way the bootstrap and master images do: it
   holds the cluster root CA, not a 24-hour bootstrap certificate, so it stays valid for the life
   of the cluster and workers can be added months later. Second, the merge source is the API VIP,
   not `api-int.<domain>`, so scaling workers does not depend on DNS resolving from inside the
   guest cluster — keepalived is already answering on that address.

4. The kubelet starts and files a CSR. `machine-approver` will not approve it: with MachineAPI
   disabled there is no Machine object *in the guest cluster* for it to correlate against, which
   is precisely the check it performs. So two CSRs per node are approved by hand — the client
   cert, then the serving cert, and the second only appears once the first is approved.
5. The node goes `Ready` and schedules pods.

Steps 1–5 never touch the part of CAPI that is broken here. Role makes no difference to the VM
either: the `Node`/`ControlPlane` switch in `azurestackhcimachine_controller.go:311` only picks a
subnet name, and `networkinterfaces.Reconcile()` never reads `SubnetName` — it sets the NIC's
subnet ID to the *vnet* name. Workers land on the same flat L2 as everything else.

### What does not work: the Machine

`Machine.status.nodeRef` stays nil forever, on workers and masters alike.

CAPI resolves Machine → Node **only** by provider ID. `getNode()` in
`internal/controllers/machine/machine_controller_noderef.go` matches `Node.spec.providerID`
against `Machine.spec.providerID` and has no hostname fallback. CAPHCI does set
`Machine.spec.providerID`, to `moc://<machine-name>`
(`azurestackhcimachine_controller.go:239`). Nothing sets the other half:

- there is no Azure Local cloud controller manager to do node initialisation;
- MachineAPI is disabled, so nothing writes it from that side;
- the kubelet's `--provider-id` cannot come from a shared MachineConfig, because the value is
  per-node while the config is shared, and the DHCP-supplied hostname has no relationship to the
  CAPI-generated machine name.

Consequences, in increasing order of severity:

- `MachineDeployment.status.availableReplicas` sits at 0 and the Machines stay in `Provisioned`,
  never reaching `Running`. Cosmetic, but it means `kubectl get machines` tells you nothing useful
  about the cluster.
- Deleting a Machine skips drain. CAPI hits `errNilNodeRef` and goes straight to deleting the VM,
  so workloads are killed abruptly and the Node object is orphaned in the guest cluster.
- **`clusterctl move` refuses to run at all.** This is the one that turns a cosmetic problem into
  a blocker.

### Why pivot is blocked, not merely degraded

`checkProvisioningCompleted()` (`cmd/clusterctl/client/cluster/mover.go:227-281`) is a hard
precondition on the whole move, and it requires three things:

| Precondition | State here |
|---|---|
| `Cluster.status.initialization.infrastructureProvisioned` | True — CAPHCI sets it |
| `Cluster` condition `ControlPlaneInitialized` | **False** |
| **Every** `Machine` has `status.nodeRef` set | **False** |

The third fails for every Machine in the namespace, including the three masters that have been
running since the install. And the second is not an independent problem: with no `controlPlaneRef`
on the Cluster, `setControlPlaneInitializedCondition()` falls through to *"this cluster control
plane is composed by stand-alone machines, and initialized is assumed true when at least one of
those machines has a node"* — `controlPlaneMachines.Filter(collections.HasNode())`. It is the same
missing nodeRef, counted twice.

So `link-nodes.sh` is a **prerequisite for the pivot, not a convenience**. Until it has been run
against every Machine, `clusterctl move` will not start.

### `link-nodes.sh`

It patches `Node.spec.providerID` to the matching Machine's value, which is all CAPI needs.

The hard part is knowing which Node goes with which Machine, and the honest answer is that
**CAPHCI publishes nothing to join on**:

- `status.addresses` is declared on both `AzureStackHCIMachine` and
  `AzureStackHCIVirtualMachine` and never written;
- `networkinterfaces.Spec.MacAddress` exists and is applied to the NIC, but the reconciler that
  builds the spec never populates it;
- `converters.SDKToVM()` throws away everything MOC returns except ID and Name.

There is no IP, no MAC, and the VM name is CAPI-generated while the hostname comes from DHCP. So
the script does not guess. It acts only when there is exactly one unmatched Machine and exactly
one unmatched Node, and refuses otherwise with the two manual resolutions spelled out. **Scale
workers up one replica at a time** and that condition always holds — hence `WORKER_REPLICAS`
defaulting to 0 and `create-cluster.sh` printing the one-at-a-time instructions at the end.

The real fix is roughly forty lines in CAPHCI: the NIC `Get()` already returns the full
`network.Interface`, so read `IPConfigurations[0].PrivateIPAddress` and write it to
`status.addresses`. CAPI's `machine_controller_phases.go` already copies infra `status.addresses`
onto the Machine, and matching by IP would then be exact and automatic. Worth proposing upstream.

### `pivot-cluster.sh`

Runs the five preconditions as an explicit preflight — `clusterctl move` reports most of them
poorly — then `--dry-run`, then an interactive confirmation, then the move. The two preconditions
beyond `checkProvisioningCompleted()`:

- **CAPHCI must be installed in the guest cluster via `clusterctl init`, not `kubectl apply`.**
  `clusterctl move` discovers what to move by listing CRDs labelled
  `clusterctl.cluster.x-k8s.io`, and only clusterctl applies that label. This is the same reason
  the README installs the provider that way on the management cluster.
- **`default/caphlogintoken` must be copied across.** CAPHCI has no identity CRD; authentication
  is that one global Secret, and it lives outside the cluster's object graph so the move does not
  carry it. `AZURESTACKHCI_CLOUDAGENT_FQDN` must also be set on the controller Deployment there,
  and the guest cluster's pods must actually be able to reach the cloudagent — the kind cluster's
  network path to it says nothing about the guest cluster's.

### After the pivot: the cluster cannot destroy itself

Deleting the `Cluster` object is what removes the VMs, and after a pivot the controllers doing the
deleting are running on those VMs. The control plane disappears mid-reconcile and the remaining
VMs, NICs and disks leak.

`destroy-cluster.sh` therefore refuses to run when the `Cluster` is absent from the current
context but present in the guest cluster, and prints the `clusterctl move` command to bring the
objects back first. Without that guard it would carry on and delete the gallery images, leaving
VMs running that could no longer be rebuilt.

### What Phase 2 does not fix

- Machines still report `vmState: Succeeded` and `ready: true` the moment MOC has a VM record.
  `SDKToVM()` **hard-codes** `State: infrav1.VMStateSucceeded` with the comment *"Hard-coded for
  now until we expose provisioning state"*, so this says nothing about whether the VM booted. See
  gap 14.
- No `MachineHealthCheck`. An MHC keys off `nodeRef` and the Node conditions behind it; before
  `link-nodes.sh` runs it would either no-op or, if it treated "no node" as unhealthy, delete and
  recreate every worker in a loop.
- No autoscaling, no `Service type=LoadBalancer`, no dynamic PVs. Those need a CCM and a CSI
  driver, and neither exists for Azure Local.

## Known gaps to document

1. **The images are cluster-specific and single-use, and iteration is slow.** Every ignition
   change — every install attempt — means rebuilding and re-uploading three multi-GB VHDs. The
   images embed the cluster's certificates, so they cannot be shared between clusters and go stale
   with the 24-hour bootstrap certificate lifetime. Mitigate what is cheap to mitigate: cache the
   base metal artifact across the three roles and across runs, and make the gallery-image upload
   skip images that already exist so a re-run of the script does not repeat it. The rest is
   inherent to the approach.
2. **`coreos-installer install` writing to a plain file is the assumption to test first.** It is
   the whole reason this avoids booting a VM. If it turns out to require a real block device, the
   ISO-plus-qemu fallback above is documented and works, but it is slower and needs
   virtualisation on the build host. Test this before anything else — it is cheap to check and
   everything downstream depends on it.
3. **CustomData is left unproven rather than resolved.** We route around it, we do not answer it.
   For the record, if someone later wants to remove the image-build stage: the candidate
   [Ignition platform IDs](https://coreos.github.io/ignition/supported-platforms/) are `hyperv`,
   which reads KVP pool 0 keys capped at ~1 KiB each and so cannot carry `bootstrap.ign` at all,
   and `azurestack`, which reads custom data and exists *because* the plain `azure` path failed on
   Azure Stack's Hyper-V, where Ignition could not mount `/dev/disk/by-id/ata-Virtual_CD`
   ([fedora-coreos-tracker#476](https://github.com/coreos/fedora-coreos-tracker/issues/476)).
   Whether MOC presents the same OVF environment is the open question, and Afterburn's Azure
   "checkin" — which normally revokes custom data access after provisioning — is a second unknown.
   The middle path used by OpenShift's own
   [Azure Stack Hub UPI flow](https://github.com/openshift/installer/blob/main/docs/user/azure/install_upi_azurestack.md)
   is to put only a small **ignition shim** in custom data and serve the real config over HTTP;
   that would shrink the images to one shared base image but reintroduces a network dependency and
   an endpoint serving the root CA key and pull secret.
4. **All three masters boot an identical image, so addresses and hostnames must come from DHCP.**
   This is a hard environment prerequisite rather than a defect — see the networking section above
   for why neither CAPHCI nor a shared image can supply them — but it is the one most likely to be
   overlooked, and the failure mode is opaque: nodes come up as `localhost`, or three of them
   claim the same name, and the cluster never forms. Requirements: a DHCP reservation per node
   with an infinite lease, the hostname supplied via DHCP, and matching PTR records (needed for
   CSRs regardless). `preflight()` should warn if PTR records for the expected node names are
   missing, since that is the part it can actually check.

   **The documented alternative, if the segment has no usable DHCP**, is the standard UPI static
   route: pass the network configuration as kernel arguments at install time. Because we already
   build images with `coreos-installer`, this costs only
   `--append-karg 'ip=<ip>::<gw>:<mask>:<hostname>:<iface>:none' --append-karg nameserver=<dns>`
   in `build_image`. The price is that the master image is no longer shared — it becomes one image
   per node, five instead of three, with a correspondingly larger build and upload. Structure
   `build_image` so the karg list is a parameter, so switching between the two modes is a config
   change rather than a rewrite.
5. **The baremetal bootstrap ignition carries Ironic/Metal3, and it will deadlock.** This is the
   one gap that is not merely untidy — it is a hard blocker with a known cause.
   `pkg/asset/ignition/bootstrap/common.go:284-292` switches on platform name only; it is *not*
   gated on the MachineAPI capability. `master-bmh-update.sh` opens with
   `until oc get baremetalhosts -n openshift-machine-api` — with MachineAPI disabled that CRD never
   exists, so the loop never exits. And the script's own comment gives the consequence: the step
   after that wait is *"Shut down ironic containers so that the API VIP can fail over to the
   control plane."* **That unit is what hands the API VIP from the bootstrap node to the masters.**
   It is also `Before=progress.service`. Left in place it hangs forever, the bootstrap node keeps
   the VIP, and the install cannot complete.

   **Verified empirically** against a real `bootstrap.ign` generated by `openshift-install`
   5.0.0-0.nightly-2026-07-28-081944, which corrected the shape of this gap in two ways:

   - It is **four** units, not five: `build-ironic-env.service`, `build-metal3-env.service`,
     `master-bmh-update.service`, `provisioning-interface.service`. `extract-machine-os.service`
     no longer exists. The backing script for `provisioning-interface.service` is
     `start-provisioning-nic.sh`, not `provisioning-interface.sh`, so deriving script paths from
     unit names misses it.
   - Ironic and metal3 now ship as **Quadlets** — seven files under `/etc/containers/systemd/`
     (`ironic.container`, `ironic.volume`, `ironic-httpd`, `ironic-dnsmasq`, `ironic-ramdisk-logs`,
     `metal3-baremetal-operator`, `image-customization`). These are not `.systemd.units[]` entries,
     so filtering units alone leaves them in place and podman-systemd generates services from them
     at boot. They would fail to start — `ironic.container` has `Requires=build-ironic-env.service`
     and `Image=$IRONIC_IMAGE`, which only that unit appends to `/etc/ironic.env` — but
     `metal3-baremetal-operator.container` carries `Restart=always` and would restart-loop for the
     life of the bootstrap node.

   Mitigation: `provisioningNetwork: Disabled` *and* `strip_ironic_units` in `lib/build-image.sh`,
   which drops the four units, their four backing scripts and the seven Quadlets, and warns if the
   number of units it removed does not match the expected count — silence there is the dangerous
   outcome. Confirmed to leave the remaining ten units and valid ignition v3.2.0 behind. What it
   deliberately leaves in place is inert data with nothing to read it: `/etc/ironic.env`,
   `/etc/metal3.env`, `/opt/metal3/auth/*` and `/opt/openshift/tls/ironic/*`.

   With ironic gone there should be no VIP contention and keepalived's normal priority handover
   should apply, but that remains the assumption most in need of a real test. Note also that
   `build-ironic-env.service` is generated with `IRONIC_IP` set to the **API VIP**, which is what
   made the contention plausible in the first place.
6. **There is no RHCOS artifact for Azure Local, and the metal one must survive Hyper-V.** Using
   the `metal` artifact is what makes image-embedded ignition work — its
   `ignition.platform.id=metal` is baked into the kargs — but it is built for physical hardware.
   Open questions: the VM must be Hyper-V generation 2 for the image's UEFI boot to work; the
   `hyperv_vmbus`/`hv_storvsc`/`hv_netvsc` drivers must be in the initramfs (they normally are in
   RHEL); and the root device must resolve, which it should since RHCOS mounts by label. None of
   this is verifiable without hardware. If the metal image will not boot, the `azurestack` VHD is
   the fallback base — but its `ignition.platform.id=azurestack` reintroduces the CustomData
   question, so it would need a karg override to `metal` during the build.
7. **CAPHCI's load balancer is unusable for OpenShift** — one TCP rule, no 22623, no `*.apps`, no
   health checks, never reconciled after creation, requires an uncreatable vippool, and its
   replicas need a self-configuring haproxy appliance image that does not exist for RHCOS. Not a
   problem here only because keepalived replaces it.
8. **No static IPs, no security groups, no object storage, no DNS integration.** Four separate
   CAPA capabilities with no CAPHCI analogue.
9. **`destroy` leaks the vnet it created, and may delete one it didn't.** The ownership check in
   `cloud/services/virtualnetworks/virtualnetworks.go:118-123` is inverted relative to its own
   comment: it skips deletion when the `OWNER` tag is absent, nil, **or equal to `CAPH`**. So a
   CAPH-created vnet is never cleaned up, while a pre-existing vnet tagged with some *other*
   owner is deleted. Untagged pre-existing vnets are safe. Worth reporting upstream; until then,
   point `${VNET_NAME}` at a dedicated vnet and expect to remove it by hand.
10. **Partial guest-cluster node lifecycle.** *Revised by Phase 2 above; the original text said
    workers were static and the worker image unconsumed, and that is no longer true.* Workers now
    come from a CAPI `MachineDeployment`, and scaling it up does produce working, schedulable
    nodes — but only after their CSRs are approved by hand, because with MachineAPI disabled
    `machine-approver` has no Machine object in the guest cluster to correlate against. The
    Machine objects themselves never reach `Running`: with no CCM nothing sets
    `Node.spec.providerID`, so `status.nodeRef` stays nil, deletion skips drain, and
    `clusterctl move` refuses to start. `link-nodes.sh` patches the providerID by hand, one node
    at a time. Still absent entirely: dynamic PVs and `Service type=LoadBalancer`, which need a
    CSI driver and a CCM that do not exist for Azure Local.
11. **API version skew.** CAPHCI master is built against CAPI v1.13.3 and imports core
    `cluster.x-k8s.io/v1beta2`. Infra kinds are pinned to `v1beta2`; the core `Cluster`/`Machine`
    apiVersion is parameterised as `${CAPI_CORE_VERSION}` and must match what the management
    cluster serves.
12. **The `openshift/installer` checkout used for these citations is from 2024-08-12** and
    `machine-config-operator` from 2025-04-23; re-confirm the capability gating and the
    `onPremPlatform` list against the release actually being targeted. The capability gating and
    the Ironic content have since been re-confirmed against `openshift-install` 5.0.0 directly (see
    Verification steps 3 and 4), and the Ironic details had in fact changed. The `onPremPlatform`
    list has not been re-checked against 5.0.0 and remains the load-bearing unverified claim: if
    `BareMetalPlatformType` ever left it, there would be no keepalived, no haproxy and therefore no
    API VIP at all.
13. **The `baremetal` capability installs the cluster-baremetal-operator into a cluster with no
    Machine API.** Required by installer validation for `platform: baremetal`, and CBO's deployment
    manifest is annotated `capability.openshift.io/name: baremetal` only, so it is installed. The
    `openshift-machine-api` Namespace manifest carries no capability annotation, so the namespace
    it targets does exist. With `provisioningNetwork: Disabled` CBO should settle with nothing to
    reconcile, but this pairing is not a configuration Red Hat tests, and CBO watching a
    non-existent `Machine`/`BareMetalHost` API is the plausible failure. Watch
    `oc get clusteroperator baremetal` on the first install; if it never goes Available the install
    will not complete and the fallback is `platform: none`, which costs the on-prem VIP stack and
    therefore requires an external load balancer after all.
14. **`vmState: Succeeded` and `ready: true` do not mean the VM booted.**
    `converters.SDKToVM()` returns only the ID and Name from what MOC gives back and then
    **hard-codes** `State: infrav1.VMStateSucceeded`, with the comment *"Hard-coded for now until
    we expose provisioning state"*. The status therefore means "MOC has a VM record", nothing
    more. This directly undermines the bootstrap and master poll loops in `create-cluster.sh`:
    they will report success and move on while the VM is still coming up, or while it is failing
    to boot the image at all. The real signals are further downstream — the `kube-system/bootstrap`
    ConfigMap for the bootstrap node, and a node appearing for the masters — and both loops
    already wait on those, so the practical damage is a misleading progress message rather than a
    wrong outcome. It is still the first status field to distrust when debugging a failed install.
15. **`osDisk.diskSizeGB` is ignored, so the root disk size has to be baked into the image.**
    Nothing under `cloud/` or `controllers/` reads the field, and `reconcileDisk()` names the disk
    with `GenerateOSDiskName(vmScope.Name())` over a commented-out `//disk.Name`. Left alone, the
    root disk would be exactly the size of the RHCOS metal artifact, around 16 GiB — enough to
    boot and nowhere near enough for a control plane node once etcd and the release payload land
    on it. `build_image` therefore creates the VHDX at `IMAGE_DISK_SIZE_GB` (120 by default) and
    converts into it with `qemu-img convert -n`, rather than letting `convert` size the output to
    the input. The VHDX is dynamic so the empty tail is free, and RHCOS grows the root partition
    on first boot. The two-step `create` + `convert -n` form has not been run end to end; if `-n`
    rejects the VHDX target, a plain convert followed by `qemu-img resize` is equivalent.

## Verification

No test suite exists and none is proposed — this is a shell-and-YAML PoC. Verification is:

1. `bash -n create-cluster.sh destroy-cluster.sh lib/build-image.sh` — syntax. **Done, passes.**
2. Render every template with the documented variables set and validate each one against the
   `v1beta2` `openAPIV3Schema` in the provider's own `config/crd/bases/*.yaml` — checking required
   fields, unknown fields and types. **Done.** This turned out not to need a cluster at all, which
   is better than the originally planned server-side dry run: it needs only the two source
   checkouts and it is the check that caught the `ContractVersionedObjectReference` change above.
   All eleven templates render with no unsubstituted variables and validate clean against both
   CAPHCI `v1beta2` and core CAPI `v1beta2`.

   One caveat on the core half: the `cluster-api` checkout used was `v1.11.0-rc.0-346-g08b15d92fa`,
   whereas CAPHCI builds against `v1.13.3`. The reference type changed in v1.11 and holds in v1.13,
   but re-run this against the CAPI version actually deployed.

   A server-side dry run against a real kind cluster is still worth doing, since it additionally
   exercises the CEL validation rules and the contract-label lookup.
3. Confirm the load-bearing capability claim concretely. **Done**, with `openshift-install`
   5.0.0-0.nightly-2026-07-28-081944 against `cluster/install-config.yaml`. `create manifests`
   exits zero. The only kinds produced under `openshift/` are ConfigMap, FeatureGate, MachineConfig,
   OSImageStream, Provisioning and Secret — no Machines, no MachineSets, no ControlPlaneMachineSet
   and no BareMetalHosts. `mastersSchedulable` is set to `true` automatically.
   `cluster-infrastructure-02-config.yml` comes out with `type: BareMetal`, both VIPs in
   `platformStatus.baremetal` and no `loadBalancer` stanza, which is what leaves MCO's keepalived
   and haproxy in charge of them. `99_baremetal-provisioning-config.yaml` is written with
   `provisioningNetwork: "Disabled"` and everything else empty, as intended.

   Two corrections came out of this run:

   - The installer **does** still write
     `openshift/99_openshift-cluster-api_{master,worker}-user-data-secret.yaml` with MachineAPI
     disabled. They are only the pointer ignition Secrets — and notably their merge source is
     `https://<apiVIP>:22623/config/{master,worker}`, the VIP rather than an `api-int` DNS name.
     `create-cluster.sh`'s guard was globbing on that filename and so would have rejected a
     correctly configured cluster; it now greps for the kinds instead.
   - `openshift-install` also drops a zero-byte `000_capi-namespace.yaml` in the cluster directory
     root. Harmless, but do not mistake it for one of ours.

   Also confirmed against current installer master, since the local checkout is far older than the
   binary: `platform: baremetal` with `baselineCapabilitySet: None` **requires** the `baremetal`
   capability, and `Ingress` is required unconditionally. Neither was in the first draft of the
   README skeleton. `openshift/api` master declares no dependency of `baremetal` on `MachineAPI`,
   so the combination is legal — but it does deploy the cluster-baremetal-operator into a cluster
   with no Machine or BareMetalHost API, which is an untested combination and is now flagged in
   both the README and the example config.
4. Run `create ignition-configs` and confirm the Ironic strip. **Done**, same binary. Four units
   present, seven Quadlets present; `strip_ironic_units` removes 4 units and 11 files, leaves the
   remaining ten units untouched, and the output is still valid ignition v3.2.0 with no
   ironic/metal3 unit or Quadlet references anywhere. See gap 5 for what this corrected.
5. **Build one image end to end locally** — the most valuable check available without hardware.
   Run `build_image bootstrap` against a real `bootstrap.ign` on a Linux host, and assert: the
   `metal` artifact resolves and downloads; `coreos-installer install` accepts a file target and
   exits zero; the resulting raw disk contains the config at `/boot/ignition/config.ign` with
   content matching the input (mount the boot partition via loopback and `diff`); and
   `qemu-img convert` produces a VHDX that `qemu-img info` reports as dynamic. This settles gap 2
   outright and validates most of gap 1's cost estimate.
6. Optionally boot that raw disk once under local qemu to confirm Ignition runs and the config is
   consumed. It will fail later — no API to reach — but reaching the point where it tries proves
   the delivery mechanism, which is the crux of the whole design.
7. End-to-end provisioning needs real Azure Local + MOC access and is out of scope for the branch;
   the README should say so plainly.
8. Check the Phase 2 manifests and preconditions against source. **Done**, no cluster needed.
   `AzureStackHCIMachineTemplateSpec.Template` is an `AzureStackHCIMachineTemplateResource` whose
   `Spec` is a plain `AzureStackHCIMachineSpec`, so the worker template is field-for-field the same
   as the master machines; every required `OSDisk` field is present. The MachineDeployment webhook
   (`internal/webhooks/machinedeployment.go:191`) accepts `bootstrap.dataSecretName` on its own
   with no `configRef`, which is what makes running with no bootstrap provider legal. All thirteen
   templates render with no unsubstituted variables. `checkProvisioningCompleted()` and
   `setControlPlaneInitializedCondition()` were read directly and confirm the pivot blocker: with
   no `controlPlaneRef`, `ControlPlaneInitialized` comes from
   `controlPlaneMachines.Filter(collections.HasNode())`, so it is the same missing nodeRef as the
   per-Machine check.
9. Run the shell under the version of bash people will actually use. **Done**, and it caught one:
   `link-nodes.sh` used `mapfile`, which does not exist in the bash 3.2 that macOS ships, and it
   is the one script in the repo likely to be run from a laptop rather than the Linux build host.
   Replaced with a portable read loop, tested under 3.2. `bash -n` passes on all five scripts.
