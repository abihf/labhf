#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Boot vm/disk.raw: q35 + SMM, Secure Boot OVMF with our keys, swtpm TPM 2.0,
# 3 extra disks for RAID5 testing. ssh: `ssh -p 2222 root@localhost`.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VM_MEM:=6G}" "${VM_CPUS:=4}" "${VM_GL:=1}" "${VM_INSTALLER:=0}"
# VM_INSTALLER=1: also attach vm/installer-esp.img (boots when disk.raw has no
# ESP yet) and a small USB stick the installer must not see
extra=()
if (( VM_INSTALLER )); then
    [[ -f vm/usb-test.img ]] || truncate -s 64M vm/usb-test.img
    extra=(-drive file=vm/installer-esp.img,format=raw,if=none,id=inst,readonly=on
           -device virtio-blk-pci,drive=inst,bootindex=1
           -device qemu-xhci,id=xhci
           -drive if=none,id=usbstick,format=raw,file=vm/usb-test.img
           -device usb-storage,bus=xhci.0,drive=usbstick)
fi
# virgl (VM_GL=1): the guest render node gets real 3D. Without it, WebKit's web
# process can't allocate buffers (dumb buffers are refused on render nodes) and
# MiniBrowser stays black. VM_GL=0: plain virtio-vga, e.g. without host GL.
if (( VM_GL )); then
    gpu=virtio-vga-gl; : "${VM_DISPLAY:=gtk,gl=on}"
else
    gpu=virtio-vga;    : "${VM_DISPLAY:=gtk}"
fi

mkdir -p vm/tpm
[[ -f vm/OVMF_CODE.secboot.qcow2 ]] || { echo "old 2M firmware (no TPM): run make vm-clean vm-vars" >&2; exit 1; }
for i in 1 2 3; do
    [[ -f vm/raid$i.qcow2 ]] || qemu-img create -q -f qcow2 vm/raid$i.qcow2 8G
done

swtpm socket --tpm2 --tpmstate dir=vm/tpm \
    --ctrl type=unixio,path=vm/tpm/sock --terminate --daemon \
    --log file=vm/tpm/swtpm.log
for _ in $(seq 50); do [[ -S vm/tpm/sock ]] && break; sleep 0.1; done

exec qemu-system-x86_64 \
    -name labhf -enable-kvm -cpu host -smp "$VM_CPUS" -m "$VM_MEM" \
    -machine q35,smm=on \
    -global driver=cfi.pflash01,property=secure,value=on \
    -drive if=pflash,format=qcow2,unit=0,readonly=on,file=vm/OVMF_CODE.secboot.qcow2 \
    -drive if=pflash,format=qcow2,unit=1,file=vm/OVMF_VARS.qcow2 \
    -chardev socket,id=chrtpm,path=vm/tpm/sock \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
    -drive file=vm/disk.raw,format=raw,if=none,id=root,cache=unsafe \
    -device virtio-blk-pci,drive=root,bootindex=0 \
    -drive file=vm/raid1.qcow2,if=virtio -drive file=vm/raid2.qcow2,if=virtio \
    -drive file=vm/raid3.qcow2,if=virtio \
    -nic user,model=virtio-net-pci,hostfwd=tcp::2222-:22,hostfwd=tcp::6443-:6443 \
    -device "$gpu" -display "$VM_DISPLAY" \
    -serial mon:stdio \
    "${extra[@]}"
