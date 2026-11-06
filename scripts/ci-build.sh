#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI: build the sealed image and push it. Runs inside quay.io/podman/stable
# (privileged) so CI uses a current podman/buildah, like a local `make build`.
#
# Env: IMAGE_REPO (ghcr.io/<owner>/labhf), TAGS (space separated),
#      REGISTRY_USER, REGISTRY_TOKEN, BUILD_LABELS (extra --label flags).
# Expects keys/db.key, keys/db.crt and keys/auth/*.auth in the checkout.
set -euo pipefail

dnf -y -q install make >/dev/null

make build PODMAN=podman IMAGE=localhost/labhf:ci BUILD_ARGS="$BUILD_LABELS"

# the db key is a build secret only: make sure no copy of it is in the image
needle=$(sed -n 2p keys/db.key)
if podman run --rm --network=none -e NEEDLE="$needle" localhost/labhf:ci \
        sh -c 'grep -rlsF -m1 -e "$NEEDLE" /usr /etc /boot /var /opt 2>/dev/null' | grep -q .; then
    echo "::error::the Secure Boot db key was found in the image" >&2; exit 1
fi

podman login ghcr.io -u "$REGISTRY_USER" --password-stdin <<<"$REGISTRY_TOKEN"
for tag in $TAGS; do
    podman push localhost/labhf:ci "docker://${IMAGE_REPO}:${tag}"
done
podman logout ghcr.io
