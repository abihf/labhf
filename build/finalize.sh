#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Last mutations of the tree that gets sealed.
set -euxo pipefail

kver=$(ls /usr/lib/modules)

# --- units -------------------------------------------------------------------
systemctl enable \
    sshd.service \
    k3s.service \
    gui.service \
    labhf-k3s-manifests.service \
    labhf-firstboot-passwd.service \
    sysroot-state.mount
systemctl set-default multi-user.target
# / is composefs (no block device); root partition size is fixed by repart.d
systemctl mask systemd-growfs-root.service

# --- sign systemd-boot with our db key (part of the sealed tree) -------------
/usr/lib/systemd/systemd-sbsign sign \
    --private-key /run/secrets/sb_key \
    --certificate /run/secrets/sb_cert \
    --output /tmp/systemd-bootx64.efi.signed \
    /usr/lib/systemd/boot/efi/systemd-bootx64.efi
install -m 0644 /tmp/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
install -m 0644 /tmp/systemd-bootx64.efi.signed /usr/lib/systemd/boot/efi/systemd-bootx64.efi

# --- initramfs (bootc composefs module, LUKS + TPM2) -------------------------
export DRACUT_NO_XATTR=1
# /root -> var/roothome; dracut's base module copies /root and fails if the
# target is missing. The dir is created by tmpfiles at boot, so remove it again.
roothome_tmp=0; [[ -d /var/roothome ]] || { mkdir -p /var/roothome; roothome_tmp=1; }
dracut --force --kver "$kver" "/usr/lib/modules/${kver}/initramfs.img"
(( roothome_tmp )) && rmdir /var/roothome
lsinitrd "/usr/lib/modules/${kver}/initramfs.img" | grep -E 'bootc|systemd-cryptsetup|libtss2-esys|sysroot-state|crypttab' | head -20
lsinitrd -f /etc/crypttab "/usr/lib/modules/${kver}/initramfs.img"

# --- scrub state that must not be sealed -------------------------------------
# keep /ostree -> sysroot/ostree (bootc lint baseimage-root requires it)
find /var/log /var/cache /var/lib -mindepth 1 \
    -not -path '/var/lib/rpm-state*' -delete 2>/dev/null || true
rm -rf /var/lib/rpm-state
# /boot must be empty in the tree; the sealer stage adds the signed UKI
rm -rf /boot && mkdir -p /boot
rm -rf /run/dnf
# lint runs in its own RUN step (Containerfile) without /run/secrets mounted
