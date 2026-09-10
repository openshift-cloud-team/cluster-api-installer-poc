#!/bin/bash
#
# Build per-role RHCOS gallery images with the ignition config baked in.
#
# Why this exists: CAPHCI hands bootstrap data to MOC as OSProfile.CustomData, but nothing
# establishes that RHCOS on MOC/Hyper-V reads it, and the hyperv Ignition platform reads Hyper-V
# KVP keys capped at ~1 KiB each -- far too small for bootstrap.ign. Rather than bet the port on
# an unproven delivery mechanism, we write each role's ignition into its own disk image. Ignition
# then consumes it from /boot/ignition/config.ign on the metal platform path, which is what RHCOS
# does for every bare metal install, and CustomData is never read.
#
# The cost is three multi-GB images built and uploaded per install. See
# docs/azurestackhci-port-plan.md for the fallbacks if this proves unworkable.

set -o pipefail

COREOS_INSTALLER_IMAGE=${COREOS_INSTALLER_IMAGE:-quay.io/coreos/coreos-installer:release}
CONTAINER_RUNTIME=${CONTAINER_RUNTIME:-podman}
QEMU_IMG=${QEMU_IMG:-qemu-img}
MOCCTL=${MOCCTL:-mocctl}

# Ignition units that the baremetal platform always adds to bootstrap.ign.
#
# pkg/asset/ignition/bootstrap/common.go switches on the platform name only -- it is not gated on
# the MachineAPI capability -- so these arrive even though we have no BareMetalHosts. Left in
# place, master-bmh-update.sh blocks forever on
#     until oc get baremetalhosts -n openshift-machine-api
# waiting for a CRD that MachineAPI-disabled clusters never create. That matters beyond being
# untidy: the step after that wait is the one that shuts down the ironic containers "so that the
# API VIP can fail over to the control plane". master-bmh-update.service is also
# Before=progress.service, so the whole bootstrap progress reporting stalls behind it.
#
# The list below was checked against the real bootstrap.ign from openshift-install
# 5.0.0-0.nightly-2026-07-28-081944. Note that extract-machine-os.service, which older releases
# carried, no longer exists.
IRONIC_UNITS=(
    build-ironic-env.service
    build-metal3-env.service
    master-bmh-update.service
    provisioning-interface.service
)

# Backing scripts for the units above. Derived by hand rather than from the unit names: the script
# for provisioning-interface.service is start-provisioning-nic.sh, not provisioning-interface.sh.
IRONIC_SCRIPTS=(
    /usr/local/bin/build-ironic-env.sh
    /usr/local/bin/build-metal3-env.sh
    /usr/local/bin/master-bmh-update.sh
    /usr/local/bin/start-provisioning-nic.sh
)

# Ironic and metal3 also ship as Quadlets rather than as systemd.units entries, so removing the
# units above does not remove them -- podman-systemd generates ironic.service and friends from
# these files at boot. They would not actually run (ironic.container has
# Requires=build-ironic-env.service, which no longer exists, and $IRONIC_IMAGE is only appended to
# /etc/ironic.env by that unit), but metal3-baremetal-operator.container has Restart=always and
# would restart-loop for the life of the bootstrap node. Drop them outright.
IRONIC_QUADLETS=(
    /etc/containers/systemd/image-customization.container
    /etc/containers/systemd/ironic-dnsmasq.container
    /etc/containers/systemd/ironic-httpd.container
    /etc/containers/systemd/ironic-ramdisk-logs.container
    /etc/containers/systemd/ironic.container
    /etc/containers/systemd/ironic.volume
    /etc/containers/systemd/metal3-baremetal-operator.container
)

# strip_ironic_units <input.ign> <output.ign>
#
# Removes the units above, their backing scripts and the ironic/metal3 Quadlets.
strip_ironic_units() {
    local input=$1
    local output=$2

    local units_json files_json
    units_json=$(printf '%s\n' "${IRONIC_UNITS[@]}" | jq -R . | jq -sc .)
    files_json=$(printf '%s\n' "${IRONIC_SCRIPTS[@]}" "${IRONIC_QUADLETS[@]}" | jq -R . | jq -sc .)

    jq --argjson units "${units_json}" --argjson files "${files_json}" '
        .systemd.units = ((.systemd.units // []) | map(select(.name as $n | ($units | index($n)) | not)))
        | .storage.files = ((.storage.files // []) | map(select(.path as $p | ($files | index($p)) | not)))
    ' "${input}" > "${output}" || return 1

    local removed_units removed_files
    removed_units=$(( $(jq '(.systemd.units // []) | length' "${input}") - $(jq '(.systemd.units // []) | length' "${output}") ))
    removed_files=$(( $(jq '(.storage.files // []) | length' "${input}") - $(jq '(.storage.files // []) | length' "${output}") ))
    echo "Stripped ${removed_units} ironic/metal3 units and ${removed_files} files from $(basename "${input}")"

    # If the release being installed renamed or added units, silence here is the dangerous
    # outcome: the bootstrap node would deadlock exactly as described above with no warning.
    if [ "${removed_units}" -ne "${#IRONIC_UNITS[@]}" ]; then
        echo "WARNING: expected to strip ${#IRONIC_UNITS[@]} units, stripped ${removed_units}." >&2
        echo "         The ironic unit set has changed in this release. Re-check IRONIC_UNITS" >&2
        echo "         against 'jq -r .systemd.units[].name bootstrap.ign' before trusting this." >&2
    fi
}

# fetch_metal_artifact <cache-dir>
#
# Downloads the RHCOS metal raw image once and echoes its path. Deliberately the metal artifact
# rather than azurestack: it carries ignition.platform.id=metal, which is the whole reason
# image-embedded ignition works.
fetch_metal_artifact() {
    local cache_dir=$1
    local url sha cached

    url=$(${OPENSHIFT_INSTALL} coreos print-stream-json |
        jq -r '.architectures.x86_64.artifacts.metal.formats."raw.gz".disk.location')
    if [ -z "${url}" ] || [ "${url}" == "null" ]; then
        echo "Could not resolve the RHCOS metal raw.gz artifact from the release payload" >&2
        return 1
    fi

    sha=$(${OPENSHIFT_INSTALL} coreos print-stream-json |
        jq -r '.architectures.x86_64.artifacts.metal.formats."raw.gz".disk.sha256')
    cached="${cache_dir}/$(basename "${url}")"

    if [ -f "${cached}" ]; then
        echo "Using cached RHCOS metal image ${cached}" >&2
    else
        echo "Downloading RHCOS metal image from ${url}" >&2
        mkdir -p "${cache_dir}"
        curl -fL --retry 3 -o "${cached}.partial" "${url}" || return 1
        mv "${cached}.partial" "${cached}"
    fi

    if [ -n "${sha}" ] && [ "${sha}" != "null" ] && command -v sha256sum > /dev/null 2>&1; then
        if ! echo "${sha}  ${cached}" | sha256sum -c --status; then
            echo "Checksum mismatch for ${cached}; delete it and retry" >&2
            return 1
        fi
    fi

    echo "${cached}"
}

# Size of the VHDX we hand to MOC, in GiB.
#
# This is load bearing, and the reason it lives here rather than on the machine templates: CAPHCI
# ignores osDisk.diskSizeGB. Nothing in cloud/ or controllers/ reads the field, and
# reconcileDisk() names the disk with GenerateOSDiskName(vmScope.Name()) over a commented-out
# `//disk.Name`. The VM's root disk is therefore exactly as big as the image we upload, and the
# RHCOS metal artifact is around 16 GiB -- far too small for a control plane node once etcd and
# the release payload images land on it.
#
# So the size has to be baked into the image. The VHDX is dynamic, so the empty tail costs nothing
# on disk or on upload, and RHCOS grows the root partition to fill the disk on first boot.
IMAGE_DISK_SIZE_GB=${IMAGE_DISK_SIZE_GB:-120}

# build_image <work-dir> <base-image> <ignition-file> <output-vhdx> [karg ...]
#
# Writes the ignition config into a copy of the base metal image and converts the result to VHDX.
#
# coreos-installer install accepts a plain file as its target, which is what lets us skip booting
# a VM. If that turns out not to hold, the documented fallback is
#     coreos-installer iso customize --dest-device /dev/vda --dest-ignition <role>.ign
# booted under qemu-system-x86_64 -no-reboot against a blank disk, which exits at the post-install
# reboot and so captures the disk before Ignition has run. Same result, one more moving part.
build_image() {
    local work_dir=$1
    local base_image=$2
    local ignition=$3
    local output=$4
    shift 4
    local kargs=("$@")

    if [ -f "${output}" ]; then
        echo "Image $(basename "${output}") already built, skipping"
        return 0
    fi

    local raw="${work_dir}/$(basename "${output}" .vhdx).raw"
    rm -f "${raw}"
    : > "${raw}"

    local karg_args=()
    local karg
    for karg in "${kargs[@]}"; do
        [ -n "${karg}" ] && karg_args+=(--append-karg "${karg}")
    done

    echo "Writing $(basename "${ignition}") into $(basename "${raw}")"
    ${CONTAINER_RUNTIME} run --rm --privileged \
        -v /dev:/dev -v /run/udev:/run/udev \
        -v "$(cd "$(dirname "${base_image}")" && pwd)":/base:ro \
        -v "$(cd "${work_dir}" && pwd)":/work \
        -v "$(cd "$(dirname "${ignition}")" && pwd)":/ign:ro \
        -w /work \
        "${COREOS_INSTALLER_IMAGE}" install \
        --image-file "/base/$(basename "${base_image}")" \
        --ignition-file "/ign/$(basename "${ignition}")" \
        "${karg_args[@]}" \
        "/work/$(basename "${raw}")" || return 1

    # Create the target at the size we want first, then convert into it with -n ("skip the
    # creation of the target volume"). qemu-img convert on its own sizes the output to the input,
    # which would leave us with a ~16 GiB root disk -- see IMAGE_DISK_SIZE_GB above.
    #
    # UNTESTED: this two-step form has not been run end to end, only the single-step convert has.
    # If -n rejects the vhdx target, the equivalent is a plain convert followed by
    #     ${QEMU_IMG} resize "${output}" ${IMAGE_DISK_SIZE_GB}G
    echo "Converting $(basename "${raw}") to a ${IMAGE_DISK_SIZE_GB}GiB VHDX"
    rm -f "${output}.partial"
    ${QEMU_IMG} create -f vhdx -o subformat=dynamic "${output}.partial" \
        "${IMAGE_DISK_SIZE_GB}G" || return 1
    ${QEMU_IMG} convert -f raw -O vhdx -n "${raw}" "${output}.partial" || return 1
    mv "${output}.partial" "${output}"
    rm -f "${raw}"
}

# upload_gallery_image <image-name> <vhdx-path>
upload_gallery_image() {
    local name=$1
    local path=$2

    if ${MOCCTL} compute galleryimage show --name "${name}" > /dev/null 2>&1; then
        echo "Gallery image ${name} already exists, skipping upload"
        return 0
    fi

    echo "Uploading gallery image ${name} (this takes a while)"
    ${MOCCTL} compute galleryimage create --name "${name}" --image-path "${path}" --os-type Linux
}

# delete_gallery_image <image-name>
delete_gallery_image() {
    local name=$1

    if ! ${MOCCTL} compute galleryimage show --name "${name}" > /dev/null 2>&1; then
        return 0
    fi

    echo "Deleting gallery image ${name}"
    ${MOCCTL} compute galleryimage delete --name "${name}"
}
