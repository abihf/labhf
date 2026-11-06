#!/usr/bin/bash
# Install the image into vm/disk.raw through a loop device (needs root podman).
set -euo pipefail
: "${PODMAN:=podman}" "${IMAGE:?}" "${DISK_SIZE:=80G}"
cd "$(dirname "$0")/.."

rm -f vm/disk.raw
truncate -s "$DISK_SIZE" vm/disk.raw
loop=$(losetup --show -fP vm/disk.raw)
trap 'losetup -d "$loop"' EXIT

# The checkout's installer overrides the image's copy (no rebuild while iterating).
$PODMAN run --rm -it --privileged --pid=host --ipc=host \
    --security-opt label=type:unconfined_t \
    -v /var/lib/containers:/var/lib/containers -v /dev:/dev \
    -v "$PWD/rootfs/usr/bin/labhf-install-disk:/usr/bin/labhf-install-disk:ro" \
    -e LABHF_IMAGE="$IMAGE" \
    -e LABHF_TARGET_IMGREF="${TARGET_IMGREF:-$IMAGE}" \
    -e LABHF_SSH_PUBKEY="${SSH_PUBKEY:-}" \
    -e LABHF_LUKS_PASSWORD="${LUKS_PASSWORD:-}" \
    -e LABHF_ABI_PASSWORD="${ABI_PASSWORD:-}" \
    -e LABHF_YES=1 \
    "$IMAGE" labhf-install-disk "$loop"

chown "${SUDO_UID:-0}:${SUDO_GID:-0}" vm/disk.raw
