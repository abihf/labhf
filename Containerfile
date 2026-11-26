# SPDX-License-Identifier: GPL-3.0-or-later
# labhf — sealed bootc image for the homelab PC
#
# Fedora bootc + composefs backend + signed UKI ("sealed image").
# Secure Boot (your own keys) verifies systemd-boot and the UKI; the UKI's
# command line carries the composefs digest, so every file under / is checked
# by fs-verity at runtime.
#
# Stages:
#   base            upstream Fedora bootc image
#   kmod-base       plain Fedora, pinned by digest (KMOD_BASE, from the Makefile),
#                   + kernel-devel for KVER and the module build/sign tools
#   nvidia-build    builds the NVIDIA open kernel module, unsigned (only compile step)
#   nvidia-sign     signs its .ko files
#   falco-build     Falco's kmod: prebuilt if Falco has one for KVER, else compiled
#   falco-sign      signs it
#   falco-manifest  HelmChart for k3s, pinned to the Falco release of that module
#   k3s, home-dashboard   one per downloaded app (ADD --checksum), files in /out
#   packages        all dnf work
#   rootfs          packages + apps, config overlay, initramfs (the last stage here)
# then, in `make build` (none of it in the CI layer cache):
#   Containerfile.tree: rootfs, directory mtimes pinned, flat
#   chunkah       splits tree into up to 128 layers by package (offline, no keys)
#   Containerfile.seal: signs systemd-boot, composefs digest + signed UKI
#                 over the split image; final = split layers + signed
#                 systemd-boot + /boot/EFI/Linux/<kver>.efi
# Layers then only change with their packages, so `bootc upgrade` downloads
# the changed ones instead of the whole image (bootc has no partial pulls).
#
# The db key (build secret sb_key) is mounted ONLY in --network=none steps of
# stages built from a clean Fedora image: nvidia-sign, falco-sign here (kmod-base),
# sdboot-sign and sealer in Containerfile.seal.
# Steps that run third-party code (RPM Fusion, COPR, NVIDIA, k3s, dracut
# modules of installed packages) never see it, so they can neither send it
# anywhere nor hide it in the image.
#
# Build with `make build` (needs keys from `make keys`).

ARG FEDORA=45
ARG BASE=quay.io/fedora/fedora-bootc:${FEDORA}
# plain Fedora for the kmod stages, pinned by digest (set by the Makefile)
ARG KMOD_BASE
# Falco: the release deployed in k3s (falco-manifest) and the driver its
# kmod is built from (falco-src); see the Falco kmod section below
ARG FALCO_VERSION=0.45.2
ARG FALCO_CHART_VERSION=9.2.2
ARG FALCO_DRIVER_VERSION=11.0.1+driver
ARG FALCO_LIBS_SHA256=45eeaa959b3b5a7d2cd7928d1e0acfdaef66581b4436274e7020ad24dc74e8c7

FROM ${BASE} AS base

# ---------------------------------------------------------------------------
# NVIDIA kmod. Not FROM base: its image changes every day or two, and every
# step after FROM base misses the layer cache. Built on the pinned KMOD_BASE
# for KVER (the base image's kernel) and NVIDIA_VERSION (RPM Fusion's
# akmod-nvidia), both set by the Makefile (scripts/nvidia-versions.sh), so the
# cache only misses when the kernel or the driver changes.
# Only the script is mounted (not all of build/): editing other build scripts
# must not invalidate the slow kmod build.
# kmod-base: kernel-devel for KVER + build and signing tools (Fedora packages
# only), shared by the build and the sign stages of both kmods.
FROM ${KMOD_BASE} AS kmod-base
ARG KVER
RUN --mount=type=bind,source=build/kmod-base.sh,target=/ctx/kmod-base.sh \
    --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/kmod-base.sh

FROM kmod-base AS nvidia-build
ARG KVER
ARG NVIDIA_VERSION
RUN --mount=type=bind,source=build/nvidia-kmod.sh,target=/ctx/nvidia-kmod.sh \
    --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/nvidia-kmod.sh deps
RUN --network=none \
    --mount=type=bind,source=build/nvidia-kmod.sh,target=/ctx/nvidia-kmod.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/nvidia-kmod.sh build

FROM kmod-base AS nvidia-sign
ARG KVER
# No packages added: kmod-base has sign-file, modinfo and openssl.
# Build secrets are not part of the layer cache key: the cert's hash is, via
# this arg, so a new db key re-runs every signing step (checked against the
# mounted secret in each of them).
ARG SB_CERT_SHA256
RUN --network=none \
    --mount=type=bind,source=build/nvidia-kmod.sh,target=/ctx/nvidia-kmod.sh \
    --mount=type=bind,from=nvidia-build,source=/out,target=/in \
    --mount=type=secret,id=sb_key \
    --mount=type=secret,id=sb_cert \
    --mount=type=tmpfs,target=/tmp \
    test "$(sha256sum < /run/secrets/sb_cert | cut -c1-64)" = "$SB_CERT_SHA256" && \
    bash /ctx/nvidia-kmod.sh sign

# ---------------------------------------------------------------------------
# Falco kmod (Falco in k3s with driver.kind=kmod: its eBPF drivers can't read
# kernel memory under lockdown=confidentiality). Same layout as the NVIDIA one:
# Falco's prebuilt module for KVER if download.falco.org has one, else built
# from the libs source; signed in a separate offline stage.
# The image also deploys that Falco release in k3s (falco-manifest), so the
# module and Falco only change together. To bump: FALCO_VERSION, its chart
# (FALCO_CHART_*), image digest, and FALCO_DRIVER_VERSION / FALCO_LIBS_SHA256 =
# DRIVER_VERSION / DRIVER_CHECKSUM in the release's cmake/modules/driver.cmake
# (FALCO_DRIVER_CMAKE_SHA256: that file). falco-manifest fails if they disagree.
FROM scratch AS falco-src
ARG FALCO_DRIVER_VERSION
ARG FALCO_LIBS_SHA256
ADD --link --checksum=sha256:${FALCO_LIBS_SHA256} \
    https://github.com/falcosecurity/libs/archive/refs/tags/${FALCO_DRIVER_VERSION}.tar.gz \
    /libs.tar.gz

FROM kmod-base AS falco-build
ARG KVER
ARG FALCO_DRIVER_VERSION
RUN --mount=type=bind,source=build/falco-kmod.sh,target=/ctx/falco-kmod.sh \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/falco-kmod.sh deps
RUN --network=none \
    --mount=type=bind,source=build/falco-kmod.sh,target=/ctx/falco-kmod.sh \
    --mount=type=bind,from=falco-src,target=/in \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/falco-kmod.sh build

FROM kmod-base AS falco-sign
ARG KVER
ARG FALCO_DRIVER_VERSION
ARG SB_CERT_SHA256
RUN --network=none \
    --mount=type=bind,source=build/falco-kmod.sh,target=/ctx/falco-kmod.sh \
    --mount=type=bind,from=falco-build,source=/out,target=/in \
    --mount=type=secret,id=sb_key \
    --mount=type=secret,id=sb_cert \
    --mount=type=tmpfs,target=/tmp \
    test "$(sha256sum < /run/secrets/sb_cert | cut -c1-64)" = "$SB_CERT_SHA256" && \
    bash /ctx/falco-kmod.sh sign

# Falco's Helm chart, and its driver.cmake (which driver it needs)
FROM scratch AS falco-chart-src
ARG FALCO_VERSION
ARG FALCO_CHART_VERSION
ARG FALCO_CHART_SHA256=b8a1aa984c3d513ab1639be760e6a07a9eb203d4da77a45a1512d382b6d3687d
ARG FALCO_DRIVER_CMAKE_SHA256=e449fde358288f45b4e29232da880282027040e3754707c419c3ad6bc9bf4cf1
ADD --link --checksum=sha256:${FALCO_CHART_SHA256} \
    https://github.com/falcosecurity/charts/releases/download/falco-${FALCO_CHART_VERSION}/falco-${FALCO_CHART_VERSION}.tgz \
    /falco.tgz
ADD --link --checksum=sha256:${FALCO_DRIVER_CMAKE_SHA256} \
    https://raw.githubusercontent.com/falcosecurity/falco/${FALCO_VERSION}/cmake/modules/driver.cmake \
    /driver.cmake

# HelmChart manifest + chart file for k3s (no key, no network)
FROM kmod-base AS falco-manifest
ARG FALCO_VERSION
ARG FALCO_CHART_VERSION
# multi-arch index of docker.io/falcosecurity/falco:${FALCO_VERSION}
ARG FALCO_IMAGE_DIGEST=sha256:1562a643953f938e02f47319b5214d93a235f11f646d60e9b8a516fd5a64698e
ARG FALCO_DRIVER_VERSION
ARG FALCO_LIBS_SHA256
RUN --network=none \
    --mount=type=bind,source=build/falco-manifest.sh,target=/ctx/falco-manifest.sh \
    --mount=type=bind,from=falco-chart-src,target=/in \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/falco-manifest.sh

# ---------------------------------------------------------------------------
# One stage per downloaded app: built independently of the packages, and the
# download itself (FROM scratch, checksummed by ADD) survives a new base image.
# The install steps pin the mtime: chunkah clamps newer mtimes to
# SOURCE_DATE_EPOCH (the newest package build time), which would put the same
# binary in a new layer whenever any package changes.

# k3s: upstream static binary
FROM scratch AS k3s-src
ARG K3S_VERSION=v1.37.2+k3s1
ARG K3S_SHA256=265b3ee6a3198ef14033c63ef46cbb32370d83795199fb6d1b01f21575eddbda
ADD --link --checksum=sha256:${K3S_SHA256} \
    https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION}/k3s /k3s

FROM base AS k3s
RUN --network=none \
    --mount=type=bind,source=build/k3s.sh,target=/ctx/k3s.sh \
    --mount=type=bind,from=k3s-src,target=/in \
    bash /ctx/k3s.sh

# the native dashboard the kiosk runs under cage (github.com/abihf/home-dashboard)
FROM scratch AS home-dashboard-src
ARG HOME_DASHBOARD_VERSION=v0.1.0
ARG HOME_DASHBOARD_SHA256=40e75b6ec9bd90a6a6593fa0630b9e20f74b2b510d76ca341c81489ecd9ebeb8
ADD --link --checksum=sha256:${HOME_DASHBOARD_SHA256} \
    https://github.com/abihf/home-dashboard/releases/download/${HOME_DASHBOARD_VERSION}/home-dashboard-${HOME_DASHBOARD_VERSION}-x86_64-linux.tar.gz \
    /home-dashboard.tar.gz

FROM base AS home-dashboard
RUN --network=none \
    --mount=type=bind,source=build/home-dashboard.sh,target=/ctx/home-dashboard.sh \
    --mount=type=bind,from=home-dashboard-src,target=/in \
    --mount=type=tmpfs,target=/tmp \
    bash /ctx/home-dashboard.sh

# ---------------------------------------------------------------------------
# All dnf work in one stage. Only the scripts it runs are mounted, so editing
# other build scripts keeps this (slowest) layer.
FROM base AS packages
ARG FEDORA
# third-party repo files (not pinned: a changed file re-runs the dnf step)
ADD --link --chmod=0644 \
    https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
    /etc/yum.repos.d/nvidia-container-toolkit.repo
RUN --mount=type=bind,source=build/packages.sh,target=/ctx/build/packages.sh \
    --mount=type=bind,source=build/source-date-epoch.sh,target=/ctx/build/source-date-epoch.sh \
    --mount=type=bind,from=nvidia-sign,source=/out,target=/ctx/nvidia \
    --mount=type=cache,id=labhf-dnf,target=/var/cache/libdnf5,sharing=locked \
    --mount=type=tmpfs,target=/tmp \
    /ctx/build/packages.sh

# ---------------------------------------------------------------------------
# The last stage here, and the last one CI caches. Containerfile.tree then
# pins directory mtimes and flattens it, uncached (new on every build).
FROM packages AS rootfs
COPY --link --from=k3s /out/ /
COPY --link --from=home-dashboard /out/ /
# signed falco.ko (depmod: finalize.sh)
COPY --link --from=falco-sign /out/rootfs/ /
COPY --link --from=falco-manifest /out/ /

# Config overlay (systemd units, kargs, dracut, repart, scripts, ...)
COPY rootfs/ /
# Public Secure Boot enrollment files (.auth) for systemd-boot auto-enroll
# from the "keys" build context (make passes the real directory: keys/ may be
# a symlink to a private directory, which the build context would not follow)
COPY --from=keys auth/ /usr/lib/bootc/install/secureboot-keys/labhf/

ARG SERIAL_CONSOLE=0
RUN --network=none \
    --mount=type=bind,source=build/finalize.sh,target=/ctx/build/finalize.sh \
    --mount=type=bind,source=build/source-date-epoch.sh,target=/ctx/build/source-date-epoch.sh \
    --mount=type=tmpfs,target=/tmp \
    SERIAL_CONSOLE="${SERIAL_CONSOLE}" /ctx/build/finalize.sh

# Separate step so no build-secret mount exists under /run
RUN rm -rf /run/dnf /run/secrets 2>/dev/null; \
    bootc container lint --fatal-warnings --no-truncate
