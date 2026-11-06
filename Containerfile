# SPDX-License-Identifier: GPL-3.0-or-later
# labhf — sealed bootc image for the homelab PC
#
# Fedora bootc + composefs backend + signed UKI ("sealed image").
# Secure Boot (your own keys) verifies systemd-boot and the UKI; the UKI's
# command line carries the composefs digest, so every file under / is checked
# by fs-verity at runtime.
#
# Stages:
#   base          upstream Fedora bootc image
#   nvidia-build  builds the NVIDIA open kernel module, unsigned (only compile step)
#   nvidia-sign   signs its .ko files
#   rootfs        packages, config overlay, initramfs
#   signer        base + systemd-ukify (sbsign/ukify), the only signing tools
#   sdboot-sign   signs rootfs's systemd-boot
#   tree          rootfs + signed systemd-boot (what gets sealed)
#   sealer        computes composefs digest, builds + signs the UKI
#   final         tree + /boot/EFI/Linux/<kver>.efi
#
# The db key (build secret sb_key) is mounted ONLY in --network=none steps of
# stages built from the clean Fedora base: nvidia-sign, sdboot-sign, sealer.
# Steps that run third-party code (RPM Fusion, COPR, NVIDIA, k3s, dracut
# modules of installed packages) never see it, so they can neither send it
# anywhere nor hide it in the image.
#
# Build with `make build` (needs keys from `make keys`).

ARG FEDORA=45
ARG BASE=quay.io/fedora/fedora-bootc:${FEDORA}

FROM ${BASE} AS base

# ---------------------------------------------------------------------------
# Only the script is mounted (not all of build/): editing other build scripts
# must not invalidate the slow kmod build.
FROM base AS nvidia-build
RUN --mount=type=bind,source=build/nvidia-kmod.sh,target=/ctx/nvidia-kmod.sh \
    --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/nvidia-kmod.sh deps
RUN --network=none \
    --mount=type=bind,source=build/nvidia-kmod.sh,target=/ctx/nvidia-kmod.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/nvidia-kmod.sh build

FROM base AS nvidia-sign
RUN --mount=type=bind,source=build/nvidia-kmod.sh,target=/ctx/nvidia-kmod.sh \
    --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/nvidia-kmod.sh sign-deps
RUN --network=none \
    --mount=type=bind,source=build/nvidia-kmod.sh,target=/ctx/nvidia-kmod.sh \
    --mount=type=bind,from=nvidia-build,source=/out,target=/in \
    --mount=type=secret,id=sb_key \
    --mount=type=secret,id=sb_cert \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/nvidia-kmod.sh sign

# ---------------------------------------------------------------------------
FROM base AS rootfs
ARG K3S_VERSION=v1.37.2+k3s1
ARG K3S_SHA256=265b3ee6a3198ef14033c63ef46cbb32370d83795199fb6d1b01f21575eddbda

RUN --mount=type=bind,source=build,target=/ctx/build \
    --mount=type=bind,from=nvidia-sign,source=/out,target=/ctx/nvidia \
    --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    --mount=type=tmpfs,target=/tmp \
    /ctx/build/packages.sh

RUN --mount=type=bind,source=build,target=/ctx/build \
    --mount=type=tmpfs,target=/tmp \
    K3S_VERSION="${K3S_VERSION}" K3S_SHA256="${K3S_SHA256}" /ctx/build/k3s.sh

# Config overlay (systemd units, kargs, dracut, repart, scripts, ...)
COPY rootfs/ /
# Public Secure Boot enrollment files (.auth) for systemd-boot auto-enroll
COPY keys/auth/ /usr/lib/bootc/install/secureboot-keys/labhf/

RUN --network=none \
    --mount=type=bind,source=build,target=/ctx/build \
    --mount=type=tmpfs,target=/tmp \
    /ctx/build/finalize.sh

# Separate step so no build-secret mount exists under /run
RUN rm -rf /run/dnf /run/secrets 2>/dev/null; \
    bootc container lint --fatal-warnings --no-truncate

# ---------------------------------------------------------------------------
FROM base AS signer
RUN --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    dnf -y --setopt=keepcache=True install systemd-ukify

# ---------------------------------------------------------------------------
FROM signer AS sdboot-sign
RUN --network=none \
    --mount=type=bind,from=rootfs,source=/usr/lib/systemd/boot/efi,target=/in \
    --mount=type=secret,id=sb_key \
    --mount=type=secret,id=sb_cert \
    mkdir -p /out && \
    /usr/lib/systemd/systemd-sbsign sign \
        --private-key /run/secrets/sb_key \
        --certificate /run/secrets/sb_cert \
        --output /out/systemd-bootx64.efi.signed \
        /in/systemd-bootx64.efi && \
    cp /out/systemd-bootx64.efi.signed /out/systemd-bootx64.efi

# ---------------------------------------------------------------------------
# Fixed, flattened input for the composefs digest.
FROM scratch AS tree
COPY --from=rootfs / /
COPY --from=sdboot-sign /out/ /usr/lib/systemd/boot/efi/

# ---------------------------------------------------------------------------
FROM signer AS sealer
RUN --network=none \
    --mount=type=bind,from=tree,target=/target \
    --mount=type=bind,source=build,target=/ctx/build \
    --mount=type=secret,id=sb_key \
    --mount=type=secret,id=sb_cert \
    --mount=type=tmpfs,target=/tmp \
    /ctx/build/seal-uki.sh

# ---------------------------------------------------------------------------
FROM tree
COPY --from=sealer /out/boot /boot
LABEL containers.bootc=1
LABEL org.opencontainers.image.title="labhf"
LABEL org.opencontainers.image.description="Sealed Fedora bootc homelab image: k3s, NVIDIA, mdadm, cage+WPE kiosk"
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
