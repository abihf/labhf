#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compute the composefs digest of /target and build a signed UKI with it.
# Kernel arguments come from /target/usr/lib/bootc/kargs.d/*.toml.
set -euxo pipefail

kver=$(ls /target/usr/lib/modules)
mkdir -p /out/boot/EFI/Linux

# Everything signed in other stages must carry *this* cert's signature (a
# cached layer from an older key would otherwise ship): systemd-boot and
# every out-of-tree module. Read-only checks with the sealer's own tools.
sbverify --cert /run/secrets/sb_cert /target/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed
cmp /target/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed /target/usr/lib/systemd/boot/efi/systemd-bootx64.efi
norm() { tr -d ':\n' | tr '[:lower:]' '[:upper:]' | sed 's/^0*//'; }
serial=$(openssl x509 -in /run/secrets/sb_cert -noout -serial | cut -d= -f2 | norm)
n=0
for m in $(find "/target/usr/lib/modules/${kver}/extra" -name '*.ko*' -type f); do
    [[ $(modinfo -F sig_key "$m" | norm) == "$serial" ]] || { echo "not signed with sb_cert: $m" >&2; exit 1; }
    n=$((n + 1))
done
(( n > 0 )) || { echo "no out-of-tree modules found" >&2; exit 1; }
echo "systemd-boot + $n modules signed with sb_cert"

# --no-sign-kernel: the embedded vmlinuz is covered by the UKI's own signature
# (systemd-sbsign can't check whether it is already signed, so ukify needs the hint).
# The digest must match what the target's bootc computes at install/upgrade,
# but nothing from /target may run while the key is mounted: use the sealer's
# own bootc (same base image) and insist it is the very same binary.
cmp /usr/bin/bootc /target/usr/bin/bootc
bootc container ukify --rootfs /target \
    -- \
    --signtool systemd-sbsign \
    --no-sign-kernel \
    --secureboot-private-key /run/secrets/sb_key \
    --secureboot-certificate /run/secrets/sb_cert \
    --output "/out/boot/EFI/Linux/${kver}.efi"

sbverify --cert /run/secrets/sb_cert "/out/boot/EFI/Linux/${kver}.efi"
ukify inspect "/out/boot/EFI/Linux/${kver}.efi" | sed -n '/\.cmdline/,/^\S/p'
