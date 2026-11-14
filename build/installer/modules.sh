#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copy the kernel, the modules the installer needs (with dependencies) and NIC
# firmware out of the labhf tree into /out. Runs in the tree image.
# Deliberately no usb-storage/uas: the installer can't see USB disks (the RAID).
set -euo pipefail
kver=$(ls /usr/lib/modules)
mods=(
    nvme virtio_blk virtio_scsi virtio_pci virtio_net virtio_rng
    ext4 vfat nls_cp437 nls_iso8859_1 nls_utf8 efivarfs
    dm_mod dm_crypt overlay erofs loop fuse
    r8169 realtek r8152 cdc_ether xhci_pci xhci_hcd usbhid hid_generic
    tpm_crb tpm_tis
)
out=/out/usr/lib/modules/$kver
mkdir -p "$out"
for m in "${mods[@]}"; do
    modprobe -S "$kver" --show-depends "$m" 2>/dev/null || true
done | awk '$1 == "insmod" {print $2}' | sort -u | while read -r f; do
    f=$(readlink -f "$f")
    install -D -m 0644 "$f" "/out$f"
done
cp /usr/lib/modules/"$kver"/modules.{order,builtin,builtin.modinfo} "$out"/
cp /usr/lib/modules/"$kver"/vmlinuz /out/vmlinuz
echo "$kver" > /out/kver
mkdir -p /out/usr/lib/firmware
cp -a /usr/lib/firmware/rtl_nic /out/usr/lib/firmware/
find /out -name '*.ko*' | wc -l
du -sh /out
