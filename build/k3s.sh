#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the upstream k3s static binary into /out (copied into rootfs).
# Downloaded and checksummed by the k3s-src stage (ADD --checksum): /in/k3s.
set -euxo pipefail

install -D -m 0755 /in/k3s /out/usr/bin/k3s
for l in kubectl crictl ctr; do
    ln -sf k3s "/out/usr/bin/$l"
done
# fixed mtime: chunkah clamps newer mtimes to SOURCE_DATE_EPOCH, which would
# put the same 80M binary in a new layer on every package change (pinned by
# sha256 anyway)
touch -h -d @0 /out/usr/bin/{k3s,kubectl,crictl,ctr}

/out/usr/bin/k3s --version
