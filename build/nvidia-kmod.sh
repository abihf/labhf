#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# NVIDIA *open* kernel module for the image's kernel, signed with our Secure
# Boot db key. The key never meets third-party code or the network:
#
#   nvidia-build stage (base + RPM Fusion):
#     deps        online, no key: RPM Fusion repos, kernel-devel, akmod-nvidia
#     build       --network=none, no key: akmods -> unsigned kmod RPM in /out
#   nvidia-sign stage (clean base, Fedora packages only):
#     sign-deps   online, no key: kernel-devel (for scripts/sign-file), cpio
#     sign        --network=none, key: sign every .ko from the RPM with
#                 Fedora's sign-file -> /out/modules/..., /out/signer
#
# rootfs installs the RPM and lays the signed modules over its files
# (packages.sh), so RPM Fusion's spec/build scripts never see the key.
set -euxo pipefail

# Keep downloaded RPMs in the build cache mount (/var/cache/libdnf5)
dnf() { command dnf --setopt=keepcache=True "$@"; }

kver=$(ls /usr/lib/modules)
fedver=$(rpm -E %fedora)

# kernel-devel must match the image kernel exactly. Fedora's updates repo only
# keeps the newest build, so fall back to koji for an older one.
install_kernel_devel() {
    if ! dnf -y install "kernel-devel-${kver}"; then
        local kv=${kver%.*} arch=${kver##*.}
        local ver=${kv%%-*} rel=${kv#*-}
        dnf -y install "https://kojipkgs.fedoraproject.org/packages/kernel/${ver}/${rel}/${arch}/kernel-devel-${kver}.rpm"
    fi
}

case ${1:?usage: nvidia-kmod.sh deps|build|sign-deps|sign} in
deps)
    dnf -y install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
        "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm"
    install_kernel_devel
    # Build the open kernel modules (Turing and newer GPUs)
    echo '%_with_kmod_nvidia_open 1' > /etc/rpm/macros.nvidia-kmod
    dnf -y install akmods akmod-nvidia
    ;;

build)
    # No key pair => kmodtool leaves the modules unsigned
    rm -rf /etc/pki/akmods/private/* /etc/pki/akmods/certs/*
    akmods --force --kernels "${kver}" --kmod nvidia
    mkdir -p /out
    cp -v /var/cache/akmods/nvidia/kmod-nvidia-"${kver}"-*.rpm /out/
    rpm -q --qf '%{EPOCH}:%{VERSION}-%{RELEASE}\n' akmod-nvidia | sed 's/(none)://' > /out/nvidia-version
    cat /out/nvidia-version
    ;;

sign-deps)
    install_kernel_devel
    dnf -y install cpio xz zstd openssl
    ;;

sign)
    signfile=/usr/src/kernels/${kver}/scripts/sign-file
    rpmfile=$(ls /in/kmod-nvidia-"${kver}"-*.rpm)
    work=/tmp/kmod
    mkdir -p "$work" /out/modules
    rpm2cpio "$rpmfile" | (cd "$work" && cpio -idm --quiet)

    signer=$(openssl x509 -in /run/secrets/sb_cert -noout -subject -nameopt multiline \
        | sed -n 's/^ *commonName *= *//p')
    [[ -n $signer ]]
    n=0
    while read -r f; do
        rel=${f#"$work"/}
        mkdir -p "/out/modules/$(dirname "$rel")"
        case $f in
        *.ko.xz)  xz -dc "$f" > /tmp/m.ko ;;
        *.ko.zst) zstd -dcq "$f" > /tmp/m.ko ;;
        *.ko)     cp "$f" /tmp/m.ko ;;
        esac
        # an already signed module would get a second, ignored signature
        [[ -z $(modinfo -F signer /tmp/m.ko) ]] || { echo "$rel is already signed" >&2; exit 1; }
        "$signfile" sha256 /run/secrets/sb_key /run/secrets/sb_cert /tmp/m.ko
        [[ $(modinfo -F signer /tmp/m.ko) == "$signer" ]]
        # same compression as the RPM (Fedora's flags for in-kernel xz)
        case $f in
        *.ko.xz)  xz -c --check=crc32 --lzma2=dict=1MiB /tmp/m.ko > "/out/modules/$rel" ;;
        *.ko.zst) zstd -qc -T0 /tmp/m.ko > "/out/modules/$rel" ;;
        *.ko)     cp /tmp/m.ko "/out/modules/$rel" ;;
        esac
        echo "signed: $rel"
        n=$((n + 1))
    done < <(find "$work" -type f -name '*.ko*')
    (( n > 0 )) || { echo "no modules in $rpmfile" >&2; exit 1; }
    printf '%s\n' "$signer" > /out/signer
    cp -v "$rpmfile" /in/nvidia-version /out/
    ;;

*) echo "unknown phase: $1" >&2; exit 1 ;;
esac
