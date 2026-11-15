#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI: build the sealed image and push it. Runs inside quay.io/podman/stable
# (privileged) so CI uses a current podman/buildah, like a local `make build`.
#
# Env: IMAGE_REPO (ghcr.io/<owner>/labhf), TAGS (space separated),
#      REGISTRY_USER, REGISTRY_TOKEN, BUILD_LABELS (extra --label flags).
# Layer cache of the Containerfile stages: ${IMAGE_REPO}-cache (one tag per step).
# Expects keys/db.key, keys/db.crt and keys/auth/*.auth in the checkout.
set -euo pipefail

dnf -y -q install make >/dev/null

# logged in for the whole build: the layer cache lives in ghcr too
podman login ghcr.io -u "$REGISTRY_USER" --password-stdin <<<"$REGISTRY_TOKEN"
trap 'podman logout ghcr.io >/dev/null 2>&1 || true' EXIT

# Only the Containerfile build (up to rootfs) is cached: nvidia kmod, apps,
# dnf installs, finalize. The normalize + flatten (Containerfile.tree), chunkah
# and the seal run every time: their layers are new whenever rootfs is, and
# the flat one is the whole image. Secrets are not in the cache key: SB_CERT_SHA256 is,
# so a new db key re-runs the signing steps. Cached layers hold signed files,
# never the key. A new base image digest invalidates everything after FROM.
cache="${IMAGE_REPO}-cache"
make build PODMAN=podman IMAGE=localhost/labhf:ci BUILD_ARGS="$BUILD_LABELS" \
    TREE_BUILD_FLAGS="--layers --cache-from $cache --cache-to $cache"

# the db key is a build secret only: make sure no copy of it is in the image
needle=$(sed -n 2p keys/db.key)
if podman run --rm -e NEEDLE="$needle" localhost/labhf:ci \
        sh -c 'grep -rlsF -m1 -e "$NEEDLE" /usr /etc /boot /var /opt 2>/dev/null' | grep -q .; then
    echo "::error::the Secure Boot db key was found in the image" >&2; exit 1
fi

for tag in $TAGS; do
    # zstd: smaller than gzip; bootc pulls it (plain zstd, not zstd:chunked)
    podman push --compression-format zstd localhost/labhf:ci "docker://${IMAGE_REPO}:${tag}"
done
