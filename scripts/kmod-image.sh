#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Make sure the kmod base image for the base image's kernel exists, and print
# the --build-arg flags for the Containerfile:
#   KVER       the base image's kernel (kernel-core), e.g. 7.3.4-300.fc45.x86_64
#   KMOD_BASE  ${KMOD_REPO}:${KVER} (Containerfile.kmod), in local storage
#
# The image is used from local storage if it is there, else pulled, else
# built (and pushed with KMOD_PUSH=1, CI). Its label labhf.kmod-recipe is the
# hash of Containerfile.kmod + build/kmod-base.sh: an image built from another
# recipe is rebuilt (and its tag pushed again).
#
# usage: kmod-image.sh BASE_IMAGE
# env:   PODMAN, FEDORA
#        KMOD_REPO        e.g. ghcr.io/abihf/labhf-kmod
#        KMOD_PUSH        1: push a newly built image
#        KMOD_BUILD_ARGS  extra `podman build` flags (CI: --label ...)
set -euo pipefail
podman=${PODMAN:-podman}
base=${1:?base image}
repo=${KMOD_REPO:?KMOD_REPO is not set}
cd "$(dirname "$0")/.."

# same image `podman build` uses: the local one if present, else pulled (0.2 s)
kver=$($podman run --rm --network=none "$base" \
    rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)
[[ $kver =~ ^[0-9][^[:space:]/]*\.x86_64$ ]] || { echo "bad kernel version: $kver" >&2; exit 1; }

ref="${repo}:${kver}"
recipe=$(cat Containerfile.kmod build/kmod-base.sh | sha256sum | cut -c1-64)
label() { $podman image inspect --format '{{index .Labels "labhf.kmod-recipe"}}' "$ref" 2>/dev/null; }

if [[ $(label) == "$recipe" ]]; then
    how=local
elif $podman pull -q "$ref" >/dev/null 2>&1 && [[ $(label) == "$recipe" ]]; then
    how=pulled
else
    echo "kmod-image: building $ref" >&2
    # shellcheck disable=SC2086 # KMOD_BUILD_ARGS: several flags
    $podman build --build-arg FEDORA="${FEDORA:-45}" --build-arg KVER="$kver" \
        --label labhf.kmod-recipe="$recipe" ${KMOD_BUILD_ARGS:-} \
        --security-opt label=disable \
        -t "$ref" -f Containerfile.kmod . >&2
    [[ $(label) == "$recipe" ]]
    how=built
    if [[ ${KMOD_PUSH:-0} == 1 ]]; then
        $podman push --compression-format zstd "$ref" >&2
        how="built, pushed"
    fi
fi
echo "kmod-image: $ref ($how), kernel $kver" >&2
echo "--build-arg KVER=$kver --build-arg KMOD_BASE=$ref"
