# labhf — sealed bootc image for the homelab PC
#
# Fedora bootc + composefs backend + signed UKI ("sealed image").
# Secure Boot (your own keys) verifies systemd-boot and the UKI; the UKI's
# command line carries the composefs digest, so every file under / is checked
# by fs-verity at runtime.
#
# Stages:
#   base         upstream Fedora bootc image
#   nvidia-kmod  builds + signs the NVIDIA open kernel module (only compile step)
#   rootfs       packages, config overlay, signed systemd-boot, initramfs
#   tree         flattened single-layer copy of rootfs (what gets sealed)
#   sealer       computes composefs digest, builds + signs the UKI
#   final        tree + /boot/EFI/Linux/<kver>.efi
#
# Build with `make build` (needs keys from `make keys`).

ARG FEDORA=45
ARG BASE=quay.io/fedora/fedora-bootc:${FEDORA}

FROM ${BASE} AS base

# ---------------------------------------------------------------------------
FROM base AS nvidia-kmod
RUN --mount=type=bind,source=build,target=/ctx/build \
    --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    --mount=type=secret,id=sb_key \
    --mount=type=secret,id=sb_cert \
    --mount=type=tmpfs,target=/tmp \
    /ctx/build/nvidia-kmod.sh

# ---------------------------------------------------------------------------
FROM base AS rootfs
ARG K3S_VERSION=v1.37.2+k3s1
ARG K3S_SHA256=265b3ee6a3198ef14033c63ef46cbb32370d83795199fb6d1b01f21575eddbda

RUN --mount=type=bind,source=build,target=/ctx/build \
    --mount=type=bind,from=nvidia-kmod,source=/out,target=/ctx/nvidia \
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

RUN --mount=type=bind,source=build,target=/ctx/build \
    --mount=type=secret,id=sb_key \
    --mount=type=secret,id=sb_cert \
    --mount=type=tmpfs,target=/tmp \
    /ctx/build/finalize.sh

# Separate step so no build-secret mount exists under /run
RUN rm -rf /run/dnf /run/secrets 2>/dev/null; \
    bootc container lint --fatal-warnings --no-truncate

# ---------------------------------------------------------------------------
# Flatten into one layer: gives the composefs digest a deterministic input.
FROM scratch AS tree
COPY --from=rootfs / /

# ---------------------------------------------------------------------------
FROM base AS sealer
RUN --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    dnf -y --setopt=keepcache=True install systemd-ukify
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
