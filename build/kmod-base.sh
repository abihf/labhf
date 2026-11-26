#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# kmod-base stage: plain Fedora + the headers of the image kernel (KVER) and
# the tools to build and sign out-of-tree modules. Shared by nvidia-build,
# falco-build (which add third-party code in their own stages) and the sign
# stages nvidia-sign / falco-sign (which add nothing: Fedora packages only).
set -euxo pipefail

# Keep downloaded RPMs in the build cache mount (/var/cache/libdnf5)
dnf() { command dnf --setopt=keepcache=True "$@"; }

kver=${KVER:?build arg KVER (kernel of the base image) is not set}

# kernel-devel must match the image kernel exactly. Fedora's updates repo only
# keeps the newest build, so fall back to koji for an older one.
if ! dnf -y install "kernel-devel-${kver}"; then
    kv=${kver%.*} arch=${kver##*.}
    ver=${kv%%-*} rel=${kv#*-}
    dnf -y install "https://kojipkgs.fedoraproject.org/packages/kernel/${ver}/${rel}/${arch}/kernel-devel-${kver}.rpm"
fi

# build: gcc, make, libelf (objtool), cmake + a C++ compiler (Falco's driver
# CMake project() checks for one); sign: openssl (signer name), kmod (modinfo:
# plain Fedora doesn't have it, the bootc base does), cpio/xz/zstd (unpack and
# recompress modules); binutils: strip
dnf -y install \
    gcc gcc-c++ make cmake elfutils-libelf-devel binutils \
    openssl kmod cpio xz zstd tar gzip
[[ -x /usr/src/kernels/${kver}/scripts/sign-file ]]
command -v modinfo
