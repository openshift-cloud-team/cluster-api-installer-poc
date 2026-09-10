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
# API VIP can fail over to the control plane". If it never runs, the bootstrap node keeps the API
# VIP and the install cannot complete.
IRONIC_UNITS=(
    build-ironic-env.service
    build-metal3-env.service
    master-bmh-update.service
    provisioning-interface.service
    extract-machine-os.service
)

# strip_ironic_units <input.ign> <output.ign>
#
# Removes the units above and their backing /usr/local/bin scripts.
strip_ironic_units() {
    local input=$1
    local output=$2

    local units_json scripts_json
    units_json=$(printf '%s\n' "${IRONIC_UNITS[@]}" | jq -R . | jq -sc .)
    scripts_json=$(printf '%s\n' "${IRONIC_UNITS[@]}" | sed 's|^|/usr/local/bin/|; s|\.service$|.sh|' | jq -R . | jq -sc .)

    jq --argjson units "${units_json}" --argjson scripts "${scripts_json}" '
        .systemd.units = ((.systemd.units // []) | map(select(.name as $n | ($units | index($n)) | not)))
        | .storage.files = ((.storage.files // []) | map(select(.path as $p | ($scripts | index($p)) | not)))
    ' "${input}" > "${output}" || return 1

    local removed
    removed=$(( $(jq '(.systemd.units // []) | length' "${input}") - $(jq '(.systemd.units // []) | length' "${output}") ))
    echo "Stripped ${removed} ironic/metal3 units from $(basename "${input}")"
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

    echo "Converting $(basename "${raw}") to VHDX"
    ${QEMU_IMG} convert -f raw -O vhdx -o subformat=dynamic "${raw}" "${output}.partial" || return 1
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
