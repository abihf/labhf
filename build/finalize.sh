#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Last mutations of the tree that gets sealed.
set -euxo pipefail

kver=$(ls /usr/lib/modules)

# --- units -------------------------------------------------------------------
systemctl enable \
    sshd.service \
    systemd-networkd.service \
    systemd-resolved.service \
    labhf-firewall.service \
    k3s.service \
    labhf-k3s-manifests.service \
    labhf-firstboot-passwd.service \
    sysroot-state.mount
systemctl set-default multi-user.target
# gui.service (kiosk on tty1) stays disabled: until the TPM is enrolled, tty1
# must show the LUKS passphrase prompt / a login. Enabled by hand afterwards.
# DNS from networkd (DNS= / DHCP) goes through resolved's stub
ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
# / is composefs (no block device); root partition size is fixed by repart.d
systemctl mask systemd-growfs-root.service

# systemd-boot is signed in the sdboot-sign stage (Containerfile): this tree
# has third-party packages installed, so the db key is never mounted here.

# --- initramfs (bootc composefs module, LUKS + TPM2) -------------------------
# The base image adds dracut's clevis module; clevis-dracut left together with
# NetworkManager (we unlock with systemd-cryptenroll's TPM2 token, not clevis)
for f in $(grep -lsw clevis /usr/lib/dracut/dracut.conf.d/*.conf /etc/dracut.conf.d/*.conf); do
    cat "$f"
    sed -i -E '/add_dracutmodules/ s/\<clevis(-pin-[a-z0-9]+)?\>//g' "$f"
done
export DRACUT_NO_XATTR=1
# /root -> var/roothome; dracut's base module copies /root and fails if the
# target is missing. The dir is created by tmpfiles at boot, so remove it again.
roothome_tmp=0; [[ -d /var/roothome ]] || { mkdir -p /var/roothome; roothome_tmp=1; }
dracut --force --kver "$kver" "/usr/lib/modules/${kver}/initramfs.img"
(( roothome_tmp )) && rmdir /var/roothome
lsinitrd "/usr/lib/modules/${kver}/initramfs.img" | grep -E 'bootc|systemd-cryptsetup|libtss2-esys|sysroot-state|crypttab' | head -20
lsinitrd -f /etc/crypttab "/usr/lib/modules/${kver}/initramfs.img"

# --- data mount points ---
# /media is a symlink to run/media (tmpfs) in Fedora. Make the mount points real
# directories on the sealed, read-only root: if a disk is missing, writes to it
# fail (EROFS) instead of filling RAM. Mounted by machine-local fstab entries
# (labhf-setup-raid: /media/data; backup disk).
rm -f /media
mkdir -p /media/data /media/backup
# /media/public: fast shared data, on the encrypted state volume
ln -s /home/public /media/public

# pods (k3s hostPath) may read/write /home/public; the policy maps /home to
# /var/home, so one rule covers both. Stored in /etc/selinux (store-root),
# i.e. it ships in the image and survives local `semanage fcontext -a`.
semanage fcontext -a -t container_file_t '/var/home/public(/.*)?'
for p in /home/public /var/home/public /home/public/x; do
    [[ $(matchpathcon -n "$p") == *:container_file_t:* ]] || { echo "bad label for $p: $(matchpathcon -n "$p")" >&2; exit 1; }
done

# --- scrub state that must not be sealed -------------------------------------
# keep /ostree -> sysroot/ostree (bootc lint baseimage-root requires it)
find /var/log /var/cache /var/lib -mindepth 1 \
    -not -path '/var/lib/rpm-state*' -delete 2>/dev/null || true
rm -rf /var/lib/rpm-state
# /boot must be empty in the tree; the sealer stage adds the signed UKI
rm -rf /boot && mkdir -p /boot
rm -rf /run/dnf
# lint runs in its own RUN step (Containerfile) without /run/secrets mounted
