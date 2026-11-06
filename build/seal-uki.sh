#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compute the composefs digest of /target and build a signed UKI with it.
# Kernel arguments come from /target/usr/lib/bootc/kargs.d/*.toml.
set -euxo pipefail

kver=$(ls /target/usr/lib/modules)
mkdir -p /out/boot/EFI/Linux

# --no-sign-kernel: the embedded vmlinuz is covered by the UKI's own signature
# (systemd-sbsign can't check whether it is already signed, so ukify needs the hint).
# Use the *target's* bootc so the digest matches what install/upgrade expects.
/target/usr/bin/bootc container ukify --rootfs /target \
    -- \
    --signtool systemd-sbsign \
    --no-sign-kernel \
    --secureboot-private-key /run/secrets/sb_key \
    --secureboot-certificate /run/secrets/sb_cert \
    --output "/out/boot/EFI/Linux/${kver}.efi"

ukify inspect "/out/boot/EFI/Linux/${kver}.efi" | sed -n '/\.cmdline/,/^\S/p'
