#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install everything from upstream binary repos.
set -euxo pipefail

# Keep downloaded RPMs in the build cache mount (/var/cache/libdnf5)
dnf() { command dnf --setopt=keepcache=True "$@"; }

fedver=$(rpm -E %fedora)

# --- third-party repos -------------------------------------------------------
dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm"

# WPE WebKit was retired from Fedora; unofficial COPR by an Igalia dev.
# Provides /usr/libexec/wpe-webkit-2.0/MiniBrowser.
curl -fsSL -o /etc/yum.repos.d/philn-wpewebkit.repo \
    "https://copr.fedorainfracloud.org/coprs/philn/wpewebkit/repo/fedora-${fedver}/philn-wpewebkit-fedora-${fedver}.repo"

curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
    https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo

cat > /etc/yum.repos.d/rancher-k3s-common.repo <<'EOF'
[rancher-k3s-common-stable]
name=Rancher K3s Common (stable)
baseurl=https://rpm.rancher.io/k3s/stable/common/coreos/noarch
enabled=1
gpgcheck=1
repo_gpgcheck=0
gpgkey=https://rpm.rancher.io/public.key
EOF

# --- boot chain: systemd-boot instead of grub/bootupd ------------------------
rpm -e bootupd || true
rm -rf /usr/lib/bootupd /usr/lib/ostree-boot
rpm -qa 'grub2-*' | xargs -r rpm -e --nodeps
dnf -y remove rpm-ostree || true

# --- packages ----------------------------------------------------------------
nvidia_evr=$(cat /ctx/nvidia/nvidia-version)

dnf -y install \
    systemd-boot-unsigned \
    cryptsetup tpm2-tools tpm2-tss openssl sudo \
    fsverity-utils dosfstools e2fsprogs mokutil \
    mdadm \
    systemd-networkd wireguard-tools \
    container-selinux k3s-selinux \
    policycoreutils-python-utils setools-console audit \
    cage wlr-randr wpewebkit \
    mesa-dri-drivers mesa-vulkan-drivers \
    google-noto-sans-fonts google-noto-emoji-fonts \
    nvidia-container-toolkit \
    "xorg-x11-drv-nvidia-${nvidia_evr}" \
    "xorg-x11-drv-nvidia-cuda-${nvidia_evr}" \
    /ctx/nvidia/kmod-nvidia-*.rpm

# The kmod RPM is built unsigned (RPM Fusion's build never sees the db key);
# the nvidia-sign stage signed its modules. Lay them over the RPM's files and
# check that every module the RPM installed now carries our signature.
kver=$(ls /usr/lib/modules)
signer=$(cat /ctx/nvidia/signer)
n=0
for f in $(rpm -ql "kmod-nvidia-${kver}" | grep -E '\.ko(\.xz|\.zst)?$'); do
    install -v -m 0644 "/ctx/nvidia/modules/${f#/}" "$f"
    [[ $(modinfo -F signer "$f") == "$signer" ]] || { echo "unsigned module: $f" >&2; exit 1; }
    n=$((n + 1))
done
(( n > 0 ))
depmod -a "$kver"

# systemd-networkd replaces NetworkManager: it only touches links a .network
# file matches (k3s's cni0/flannel/veth stay alone), and wg0 is a plain .netdev
dnf -y remove 'NetworkManager*'
if rpm -qa | grep '^NetworkManager'; then echo 'NetworkManager still installed' >&2; exit 1; fi
rpm -q systemd-networkd systemd-resolved bootc

# The kmod must never be rebuilt on the host
rpm -q akmod-nvidia && dnf -y remove akmod-nvidia akmods || true

# xorg-x11-drv-nvidia Requires grubby -> grub2-tools; we boot systemd-boot only
rpm -qa 'grub2-*' grubby | xargs -r rpm -e --nodeps
rm -rf /boot/grub2 /etc/grub.d /etc/default/grub /etc/systemd/user/timers.target.wants/grub-boot-success.timer

# akmods/kmods leave units around that try to build at boot
systemctl disable akmods.service 2>/dev/null || true

bootc --version
