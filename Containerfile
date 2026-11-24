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
#   nvidia-build    builds the NVIDIA open kernel module, unsigned (only compile step)
#   nvidia-sign     signs its .ko files
#   kine, kube-router, home-dashboard   one per downloaded app (ADD --checksum), files in /out
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
# stages built from the clean Fedora base: nvidia-sign here, sdboot-sign and
# sealer in Containerfile.seal.
# Steps that run third-party code (RPM Fusion, COPR, NVIDIA, Kine, kube-router, dracut
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
# Build secrets are not part of the layer cache key: the cert's hash is, via
# this arg, so a new db key re-runs every signing step (checked against the
# mounted secret in each of them).
ARG SB_CERT_SHA256
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
    test "$(sha256sum < /run/secrets/sb_cert | cut -c1-64)" = "$SB_CERT_SHA256" && \
    bash /ctx/nvidia-kmod.sh sign

# ---------------------------------------------------------------------------
# One stage per downloaded app: built independently of the packages, and the
# download itself (FROM scratch, checksummed by ADD) survives a new base image.
# The install steps pin the mtime: chunkah clamps newer mtimes to
# SOURCE_DATE_EPOCH (the newest package build time), which would put the same
# binary in a new layer whenever any package changes.

# Kine exposes the etcd v3 storage API over a local socket backed by SQLite.
FROM scratch AS kine-src
ARG KINE_VERSION=v0.17.1
ARG KINE_SHA256=5d67d481774822153a1c9f635e4ca78efdc77108b4288c0b5867a4cbb042a0d0
ADD --link --checksum=sha256:${KINE_SHA256} \
    https://github.com/k3s-io/kine/releases/download/${KINE_VERSION}/kine-amd64-nocgo /kine

FROM base AS kine
RUN --network=none \
    --mount=type=bind,from=kine-src,target=/in \
    install -D -m 0755 /in/kine /out/usr/bin/kine && \
    touch -d @0 /out/usr/bin/kine && /out/usr/bin/kine --version

# kube-router enforces NetworkPolicy using the host's iptables and ipset.
FROM scratch AS kube-router-src
ARG KUBE_ROUTER_VERSION=2.12.0
ARG KUBE_ROUTER_SHA256=3d7e2f741f28b75ecae4dc1f7761a6f62fb908664ec06bfb6bde743d933a700e
ADD --link --checksum=sha256:${KUBE_ROUTER_SHA256} \
    https://github.com/cloudnativelabs/kube-router/releases/download/v${KUBE_ROUTER_VERSION}/kube-router_${KUBE_ROUTER_VERSION}_linux_amd64.tar.gz /kube-router.tar.gz

FROM base AS kube-router
RUN --network=none \
    --mount=type=bind,from=kube-router-src,target=/in \
    --mount=type=tmpfs,target=/tmp \
    tar -xzf /in/kube-router.tar.gz -C /tmp kube-router LICENSE && \
    install -D -m 0755 /tmp/kube-router /out/usr/bin/kube-router && \
    install -D -m 0644 /tmp/LICENSE /out/usr/share/licenses/kube-router/LICENSE && \
    touch -d @0 /out/usr/bin/kube-router /out/usr/share/licenses/kube-router/LICENSE && \
    /out/usr/bin/kube-router --version

# the dashboard server the kiosk shows (github.com/abihf/home-dashboard)
FROM scratch AS home-dashboard-src
ARG HOME_DASHBOARD_VERSION=v0.0.3
ARG HOME_DASHBOARD_SHA256=ef9d41a34e76e0a55364e07e491f8de55fda55802e8c6103bfca530f9a030e5b
ADD --link --checksum=sha256:${HOME_DASHBOARD_SHA256} \
    https://github.com/abihf/home-dashboard/releases/download/${HOME_DASHBOARD_VERSION}/home-dashboard-${HOME_DASHBOARD_VERSION}-linux-x64.tar.gz \
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
# WPE WebKit was retired from Fedora; unofficial COPR by an Igalia dev.
# Provides /usr/libexec/wpe-webkit-2.0/MiniBrowser.
ADD --link --chmod=0644 \
    https://copr.fedorainfracloud.org/coprs/philn/wpewebkit/repo/fedora-${FEDORA}/philn-wpewebkit-fedora-${FEDORA}.repo \
    /etc/yum.repos.d/philn-wpewebkit.repo
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
COPY --link --from=kine /out/ /
COPY --link --from=kube-router /out/ /
COPY --link --from=home-dashboard /out/ /

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
