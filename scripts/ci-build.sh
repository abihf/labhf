#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI: build the sealed image and push it. Runs inside quay.io/podman/stable
# (privileged) so CI uses a current podman/buildah, like a local `make build`.
#
# Env: IMAGE_REPO (ghcr.io/<owner>/labhf), TAGS (space separated),
#      REGISTRY_USER, REGISTRY_TOKEN, BUILD_LABELS (extra --label flags).
#      PUSH=0 (pull requests): read the layer cache only (the token is
#      read-only there), push nothing; the keys are throwaway ones.
# Layer cache of the tree stage: ${IMAGE_REPO}-cache (one tag per step).
# Expects keys/db.key, keys/db.crt and keys/auth/*.auth in the checkout.
# Writes a size report to ci-sizes.md.
set -euo pipefail
: "${PUSH:=1}"

dnf -y -q install make >/dev/null

# Only the tree stage is cached (nvidia kmod build, dnf installs); chunkah and
# the seal depend on it. Secrets are not in the cache key: SB_CERT_SHA256 is,
# so a new db key re-runs the signing steps. Cached layers hold signed files,
# never the key. A new base image digest invalidates everything after FROM.
# Pull requests only read it: layers built from PR code must never land in
# the cache that main's signed builds start from.
cache="${IMAGE_REPO}-cache"
# logged in for the whole build: the layer cache lives in ghcr too
podman login ghcr.io -u "$REGISTRY_USER" --password-stdin <<<"$REGISTRY_TOKEN"
trap 'podman logout ghcr.io >/dev/null 2>&1 || true' EXIT
if (( PUSH )); then
    cache_flags="--cache-from $cache --cache-to $cache"
else
    cache_flags="--cache-from $cache"
fi
make build PODMAN=podman IMAGE=localhost/labhf:ci BUILD_ARGS="$BUILD_LABELS" \
    TREE_BUILD_FLAGS="--layers $cache_flags"

# the db key is a build secret only: make sure no copy of it is in the image
needle=$(sed -n 2p keys/db.key)
if podman run --rm --network=none -e NEEDLE="$needle" localhost/labhf:ci \
        sh -c 'grep -rlsF -m1 -e "$NEEDLE" /usr /etc /boot /var /opt 2>/dev/null' | grep -q .; then
    echo "::error::the Secure Boot db key was found in the image" >&2; exit 1
fi

# size report: image, installed packages, largest packages
{
    echo "### Image size"
    echo
    echo "- image: $(podman image inspect --format '{{.Size}}' localhost/labhf:ci | numfmt --to=iec-i --suffix=B)"
    podman run --rm --network=none localhost/labhf:ci sh -c '
        echo "- /usr: $(du -sh -x /usr | cut -f1)"
        echo "- packages: $(rpm -qa | wc -l), $(rpm -qa --qf "%{SIZE}\n" | awk "{s+=\$1} END {print s}" | numfmt --to=iec-i --suffix=B) installed"
        echo
        echo "<details><summary>Largest 40 packages</summary>"
        echo
        echo "| size | package |"
        echo "|---:|---|"
        rpm -qa --qf "%{SIZE}\t%{NAME}\n" | sort -rn | head -40 | awk -F"\t" "{printf \"| %.1f MiB | %s |\\n\", \$1/1048576, \$2}"
        echo
        echo "</details>"'
} | tee ci-sizes.md

(( PUSH )) || exit 0
for tag in $TAGS; do
    # zstd: smaller than gzip; bootc pulls it (plain zstd, not zstd:chunked)
    podman push --compression-format zstd localhost/labhf:ci "docker://${IMAGE_REPO}:${tag}"
done
