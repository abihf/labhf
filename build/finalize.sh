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
    var-home.mount \
    auditd.service \
    k3s.service \
    home-dashboard.service \
    labhf-k3s-manifests.service \
    labhf-firstboot-passwd.service \
    sysroot-state.mount
systemctl set-default multi-user.target
# gui.service (kiosk on tty1) stays disabled: until the TPM is enrolled, tty1
# must show the LUKS passphrase prompt / a login. Enabled by hand afterwards.
# DNS from networkd (DNS= / DHCP), via resolved's uplink file: programs that
# read resolv.conf (dig, containerd, k3s, Go binaries) ask the network's DNS
# servers directly. Not the stub (127.0.0.53): a k3s LoadBalancer or hostPort
# on 53 (a DNS server in the cluster) DNATs every local address's port 53,
# 127.0.0.53/54 included, to its pod; while that pod is down, the host has no
# DNS and can't even pull the pod's image. glibc lookups still go through
# resolved (nss-resolve), with its cache.
ln -sf ../run/systemd/resolve/resolv.conf /etc/resolv.conf
# / is composefs (no block device); root partition size is fixed by repart.d
systemctl mask systemd-growfs-root.service
# no reboot from the keyboard, no root shell on tty9
# (the base image already has ctrl-alt-del.target in /etc, so mask --force)
systemctl mask --force ctrl-alt-del.target debug-shell.service

# debugging in QEMU only (make build SERIAL_CONSOLE=1)
if [[ ${SERIAL_CONSOLE:-0} == 1 ]]; then
    cat > /usr/lib/bootc/kargs.d/05-labhf-serial.toml <<'TOML'
kargs = ["console=ttyS0,115200"]
TOML
fi

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

# --- modes git can't carry (rootfs/ comes from a checkout in CI) ---------------
chmod 0440 /etc/sudoers.d/*
chmod 0750 /etc/audit /etc/audit/rules.d
chmod 0640 /etc/audit/rules.d/50-labhf.rules

# --- setuid: allow-list, so a future package can't add one unnoticed ----------
# su, mount, chsh, pkexec, ... have no job here: administration is abi + sudo.
keep_suid=(/usr/bin/sudo /usr/bin/passwd /usr/bin/unix_chkpwd /usr/bin/nvidia-modprobe)
while read -r f; do
    [[ " ${keep_suid[*]} " == *" $f "* ]] || chmod ug-s "$f"
done < <(find /usr -xdev -type f -perm /6000)
find /usr -xdev -type f -perm /6000

# --- lock an account after repeated password failures (console, sudo) ---------
authselect enable-feature with-faillock
cat >> /etc/security/faillock.conf <<'FAILLOCK'
deny = 5
unlock_time = 300
FAILLOCK

# --- scrub state that must not be sealed -------------------------------------
# keep /ostree -> sysroot/ostree (bootc lint baseimage-root requires it)
find /var/log /var/cache /var/lib -mindepth 1 \
    -not -path '/var/lib/rpm-state*' -delete 2>/dev/null || true
rm -rf /var/lib/rpm-state
# /boot must be empty in the tree; the sealer stage adds the signed UKI
rm -rf /boot && mkdir -p /boot
# packages leave empty runtime dirs (kea: /run/kea, recreated by its unit /
# tmpfiles at boot); bootc lint rejects content under /run
rm -rf /run/dnf /run/kea
# lint runs in its own RUN step (Containerfile) without /run/secrets mounted
