#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install everything from upstream binary repos.
set -euxo pipefail

# Keep downloaded RPMs in the build cache mount (/var/cache/libdnf5); skip
# %doc files (licenses are %license and stay: the image is redistributed)
dnf() { command dnf --setopt=keepcache=True --setopt=tsflags=nodocs "$@"; }

# Only English translations from here on (base image files: see below)
echo '%_install_langs C.utf8:en:en_US:en_GB' > /etc/rpm/macros.image-language-conf

fedver=$(rpm -E %fedora)

# rpm stamps each package's install time into the rpmdb (a 14M layer) and
# takes SOURCE_DATE_EPOCH when set. The base image's package set's, read
# before anything is installed: the same base and packages give the same rpmdb.
SOURCE_DATE_EPOCH=$(/ctx/build/source-date-epoch.sh)
export SOURCE_DATE_EPOCH

# --- third-party repos -------------------------------------------------------
dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm"

# COPR wpewebkit and nvidia-container-toolkit .repo files: ADDed by the
# Containerfile (packages stage)
ls /etc/yum.repos.d/philn-wpewebkit.repo /etc/yum.repos.d/nvidia-container-toolkit.repo

# --- boot chain: systemd-boot instead of grub/bootupd ------------------------
rpm -e bootupd || true
rm -rf /usr/lib/bootupd /usr/lib/ostree-boot
rpm -qa 'grub2-*' | xargs -r rpm -e --nodeps
dnf -y remove rpm-ostree || true

# --- packages ----------------------------------------------------------------
nvidia_evr=$(cat /ctx/nvidia/nvidia-version)
kubernetes_pkgs=(kubernetes1.37 kubernetes1.37-client kubernetes1.37-systemd
                 kubernetes1.37-kubeadm cri-o1.37 cri-tools1.37
                 containernetworking-plugins ipset)

dnf -y install \
    systemd-boot-unsigned \
    cryptsetup tpm2-tools tpm2-tss openssl sudo \
    fsverity-utils dosfstools e2fsprogs \
    mdadm smartmontools htop usbutils \
    systemd-networkd wireguard-tools kea \
    container-selinux "${kubernetes_pkgs[@]}" \
    audit \
    cage wlr-randr wpewebkit \
    mesa-dri-drivers \
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
    # fixed mtime, so unchanged modules keep their layer
    touch -d @0 "$f"
    [[ $(modinfo -F signer "$f") == "$signer" ]] || { echo "unsigned module: $f" >&2; exit 1; }
    n=$((n + 1))
done
(( n > 0 ))
depmod -a "$kver"

# systemd-networkd replaces NetworkManager: it only touches links a .network
# file matches (pod bridge/veth stay alone), and wg0 is a plain .netdev
dnf -y remove 'NetworkManager*'
if rpm -qa | grep '^NetworkManager'; then echo 'NetworkManager still installed' >&2; exit 1; fi
rpm -q systemd-networkd systemd-resolved bootc

# --- strip what this machine never uses --------------------------------------
# Whole packages via dnf, so the rpmdb (and chunkah's per-package layers) stay
# accurate. All leaves or only weakly wanted; the check below fails the build
# if a removal ever drags in something that matters.
strip_pkgs=(
    'qemu-user-static*'                        # foreign-arch containers (175M)
    python3-boto3 python3-botocore python3-s3transfer   # AWS SDK (125M)
    nvidia-gpu-firmware                        # nouveau firmware; blacklisted (101M)
    atheros-firmware mt7xxx-firmware brcmfmac-firmware tiwilink-firmware
    nxpwireless-firmware qcom-wwan-firmware    # Wi-Fi / WWAN chips (~95M)
    intel-gpu-firmware intel-npu-firmware intel-audio-firmware cirrus-audio-firmware
    microcode_ctl                              # Intel CPU microcode (AMD here)
    intel-mediasdk                             # Intel video (libvpl weak dep)
    mesa-vulkan-drivers                        # weak dep; cage/WPE render with GL (174M)
    kexec-tools makedumpfile                   # no kdump: kexec_load_disabled=1
    xdg-desktop-portal-gtk xdg-desktop-portal  # desktop portals, with geoclue2/ModemManager (32M)
    localsearch tinysparql                     # file indexer, metadata miners: osinfo, exiv2, poppler (65M)
    pipewire-alsa pipewire-jack-audio-connection-kit pipewire-pulseaudio
    pipewire-plugin-libcamera                  # kiosk has no audio; pipewire/wireplumber/libcamera follow
    hunspell-en-AU hunspell-en-CA hunspell-en-GB  # not hunspell-en(-US): wpewebkit's enchant2 needs one
    libheif-freeworld                          # HEVC/HEIC images in WebKit (25M)
    7zip os-prober xfsprogs efibootmgr         # less's weak dep; grub; no XFS; systemd-boot sets its entries
    policycoreutils-python-utils setools-console  # semanage etc.: Python (base image ships them)
    # what the full fedora-bootc base brings for other kinds of machines:
    sssd-ad sssd-ipa sssd-krb5 sssd-ldap sssd-common sssd-client sssd-nfs-idmap adcli
    libsmbclient samba-client-libs samba-core-libs samba-ndr-libs samba-common
                                               # AD/IPA/LDAP logins; authselect profile is local
    nfs-utils nfs-common-utils nfsv3-client-utils nfsv4-client-utils nfs-client-utils
    rpcbind gssproxy quota                     # NFS: modules blocked, rpc_pipefs masked
    lvm2 lvm2-libs device-mapper-persistent-data udisks2 libudisks2
    btrfs-progs exfatprogs f2fs-tools nilfs-utils ntfs-3g ntfsprogs udftools
                                               # storage: mdadm + LUKS + ext4 only
    clevis clevis-luks clevis-pin-tpm2 clevis-systemd  # TPM unlock is systemd-cryptenroll
    dracut-squash squashfs-tools               # squashfs: module blocked
    fwupd libqmi libmbim ModemManager-glib     # firmware updates: BIOS/vendor tools instead
    avahi                                      # mDNS; the firewall doesn't let 5353 in
    toolbox sos WALinuxAgent-udev cloud-utils-growpart
    console-login-helper-messages console-login-helper-messages-profile
    flatpak-session-helper fuse-overlayfs criu stalld zram-generator chunkah
                                               # dev/cloud/desktop tools; sos is Python
    man-db groff-base net-tools iptables-services gawk-all-langpacks bind-utils bind-libs
                                               # no docs shipped; legacy tools
    polkit polkit-libs                         # admin is sudo only; its setuid helper is stripped
    # kept on purpose: cracklib-dicts (pam_pwquality), glibc-gconv-extra (glibc),
    # nvme-cli sg3_utils lsof ethtool socat iproute-tc jq vim-minimal irqbalance
    # not flite (WebKit's speech synthesis) or x265-libs on its own: removing
    # either takes wpewebkit with it
)
# GTK settings GUI, hard-required by xorg-x11-drv-nvidia but unused by the
# driver, CUDA and the container toolkit. Removed first, so the dnf remove
# below cleans up gtk3 and its tree as unused dependencies (~150M).
rpm -e --nodeps nvidia-settings
mapfile -t present < <(rpm -qa --qf '%{NAME}\n' "${strip_pkgs[@]}" | sort -u)
(( ${#present[@]} )) && dnf -y remove "${present[@]}"
# No Python on the machine (~59M). kea (kea-shell), at-spi2-core,
# xorg-x11-drv-nvidia (nvidia-networking-bug-report.py), gstreamer1 (a doc
# generator) and libwacom (libwacom-update-db) require python3 only for
# scripts nothing runs, and those are dead now; a dnf remove would take
# wpewebkit, cage, kea and the driver with it. SELinux file contexts come from
# a CIL module (semodule) instead of semanage: see finalize.sh.
rpm -qa --qf '%{NAME}\n' 'python*' mpdecimal | xargs -r rpm -e --nodeps
# rpm leaves the removed packages' system accounts behind, and bootc lint
# rejects accounts no sysusers.d defines
for u in geoclue pipewire rtkit usbmuxd; do
    if getent passwd "$u" >/dev/null; then userdel "$u"; fi
    if getent group "$u" >/dev/null; then groupdel "$u"; fi
done
keep=(kernel-core bootc skopeo podman wpewebkit cage mesa-dri-drivers llvm-libs
      linux-firmware amd-gpu-firmware amd-ucode-firmware realtek-firmware
      xorg-x11-drv-nvidia xorg-x11-drv-nvidia-cuda-libs nvidia-container-toolkit
      container-selinux "${kubernetes_pkgs[@]}" systemd-networkd kmscon fuse3)
rpm -q "${keep[@]}"
if rpm -qa 'qemu-user-static*' python3-botocore nvidia-gpu-firmware localsearch \
        pipewire nvidia-settings python3 policycoreutils-python-utils \
        sssd-common avahi fwupd lvm2 nfs-utils polkit | grep .; then
    echo "strip list not removed" >&2; exit 1
fi
if command -v python3; then echo "python3 still installed" >&2; exit 1; fi

# docs and translations the base image already shipped (ours are skipped by
# tsflags=nodocs and _install_langs above). rpm -V reports them as missing.
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/*
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d ! -name 'en' ! -name 'en_*' -exec rm -rf {} +

# The kmod must never be rebuilt on the host
rpm -q akmod-nvidia && dnf -y remove akmod-nvidia akmods || true

# xorg-x11-drv-nvidia Requires grubby -> grub2-tools; we boot systemd-boot only
rpm -qa 'grub2-*' grubby | xargs -r rpm -e --nodeps
# own Secure Boot keys, no shim (dnf protects it, so rpm)
rpm -qa shim-x64 mokutil | xargs -r rpm -e
rm -rf /boot/grub2 /etc/grub.d /etc/default/grub /etc/systemd/user/timers.target.wants/grub-boot-success.timer

# akmods/kmods leave units around that try to build at boot
systemctl disable akmods.service 2>/dev/null || true

bootc --version
