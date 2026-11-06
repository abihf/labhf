#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Create OVMF vars with our PK/KEK/db enrolled and Secure Boot on (tools container).
# Fedora's TPM-enabled firmware is the 4M build, shipped as qcow2 only (the raw
# 2M OVMF_CODE.secboot.fd has no TPM support: PCRs stay zero, no event log).
set -euo pipefail
ovmf=/usr/share/edk2/ovmf
guid=$(cat /work/keys/GUID)
virt-fw-vars \
    --input "$ovmf/OVMF_VARS_4M.qcow2" \
    --secure-boot \
    --set-pk  "$guid" /work/keys/PK.crt \
    --add-kek "$guid" /work/keys/KEK.crt \
    --add-db  "$guid" /work/keys/db.crt \
    --output /work/vm/OVMF_VARS.qcow2
cp "$ovmf/OVMF_CODE_4M.secboot.qcow2" /work/vm/OVMF_CODE.secboot.qcow2
rm -f /work/vm/OVMF_CODE.secboot.fd
