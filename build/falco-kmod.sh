#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Falco kernel module (falco.ko) for the image's kernel, signed with our
# Secure Boot db key. Falco's eBPF drivers don't work under
# lockdown=confidentiality (no BPF kernel reads), the kmod does: it only uses
# kernel tracepoints, and loads under module.sig_enforce once signed.
#
# Both stages are plain Fedora (kmod-base, with kernel-devel and the build and
# sign tools: build/kmod-base.sh), like the NVIDIA kmod: KVER is the base
# image's kernel, FALCO_DRIVER_VERSION the falcosecurity/libs driver tag (must
# match the Falco release deployed in k3s: its cmake/modules/driver.cmake).
#
#   falco-build stage (kmod-base):
#     deps        online, no key: Falco's prebuilt module for this kernel, if
#                 download.falco.org has one
#     build       --network=none, no key: the prebuilt, or the module built
#                 from the libs source (/in/libs.tar.gz, falco-src stage,
#                 ADD --checksum) -> unsigned /out/falco.ko
#   falco-sign stage (clean kmod-base, Fedora packages only):
#     sign        --network=none, key: sign it -> /out/rootfs/usr/lib/modules/
#                 <kver>/extra/falco.ko.xz (copied into rootfs)
set -euxo pipefail

kver=${KVER:?build arg KVER (kernel of the base image) is not set}
dver=${FALCO_DRIVER_VERSION:?build arg FALCO_DRIVER_VERSION is not set}
# Falco names prebuilt modules falco_<distro>_<uname -r>_<N>.ko, N from
# `uname -v` ("#1 SMP ..."): always 1 for Fedora's kernels
prebuilt_url="https://download.falco.org/driver/${dver/+/%2B}/x86_64/falco_fedora_${kver}_1.ko"

# an unsigned falco module for exactly this kernel and driver version
check_module() {
    [[ $(modinfo -F name "$1") == falco ]]
    [[ $(modinfo -F version "$1") == "$dver" ]]
    [[ $(modinfo -F vermagic "$1") == "$kver "* ]]
    [[ -z $(modinfo -F signer "$1") ]] || { echo "$1 is already signed" >&2; exit 1; }
}

case ${1:?usage: falco-kmod.sh deps|build|sign} in
deps)
    mkdir -p /prebuilt
    # No checksum is published for the prebuilt modules: TLS only, and
    # check_module (build step) makes sure it is the module we asked for.
    if curl -fsSL --retry 3 -o /prebuilt/falco.ko "$prebuilt_url"; then
        echo "prebuilt falco module: $prebuilt_url"
    else
        rm -f /prebuilt/falco.ko
        echo "no prebuilt falco module for ${kver} (${dver}), building it"
    fi
    ;;

build)
    mkdir -p /out
    if [[ -f /prebuilt/falco.ko ]]; then
        cp /prebuilt/falco.ko /out/falco.ko
        echo prebuilt > /out/falco-source
    else
        # fixed directory: the build path ends up in the module's build-id
        src=/tmp/falco-libs build=/tmp/falco-build
        mkdir -p "$src"
        tar -xzf /in/libs.tar.gz -C "$src" --strip-components=1
        [[ $(<"$src/driver/API_VERSION") == "${dver%%+*}" ]]
        cmake -S "$src/driver" -B "$build" \
            -DCMAKE_MODULE_PATH="$src/cmake/modules" \
            -DDRIVER_VERSION="$dver" -DDRIVER_NAME=falco -DDRIVER_DEVICE_NAME=falco \
            -DENABLE_DKMS=OFF
        make -C "$build/src" KERNELDIR="/usr/src/kernels/${kver}" -j"$(nproc)"
        # like Fedora's own modules (4M -> 1M)
        strip --strip-debug -o /out/falco.ko "$build/src/falco.ko"
        echo built > /out/falco-source
    fi
    check_module /out/falco.ko
    printf '%s\n' "$dver" > /out/falco-version
    echo "falco module: $(<"/out/falco-source"), $(modinfo -F version /out/falco.ko)"
    ;;

sign)
    command -v modinfo
    signfile=/usr/src/kernels/${kver}/scripts/sign-file
    signer=$(openssl x509 -in /run/secrets/sb_cert -noout -subject -nameopt multiline \
        | sed -n 's/^ *commonName *= *//p')
    [[ -n $signer ]]
    check_module /in/falco.ko
    cp /in/falco.ko /tmp/falco.ko
    "$signfile" sha256 /run/secrets/sb_key /run/secrets/sb_cert /tmp/falco.ko
    [[ $(modinfo -F signer /tmp/falco.ko) == "$signer" ]]
    dir=/out/rootfs/usr/lib/modules/${kver}/extra
    mkdir -p "$dir"
    # Fedora's flags for in-kernel xz
    xz -c --check=crc32 --lzma2=dict=1MiB /tmp/falco.ko > "$dir/falco.ko.xz"
    chmod 0644 "$dir/falco.ko.xz"
    # fixed mtime, so an unchanged module keeps its layer (see k3s.sh)
    touch -d @0 "$dir/falco.ko.xz"
    [[ $(modinfo -F signer "$dir/falco.ko.xz") == "$signer" ]]
    echo "signed: falco.ko ($(</in/falco-source))"
    ;;

*) echo "unknown phase: $1" >&2; exit 1 ;;
esac
