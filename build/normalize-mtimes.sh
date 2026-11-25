#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Last step on the tree, so the same packages and config give the same layers
# on every build (a layer is only reused if its bytes, mtimes included, are
# identical).
#
# Directories: all get mtime 0 (as ostree does). chunkah clamps each file's
# mtime to its package's build time, but a directory changes mtime whenever an
# entry is added, and many (/usr/lib/.build-id, /usr/lib/.build-id/NN, icon
# theme dirs) are owned by several packages or by none. Their mtime then
# followed whatever the build touched, or whichever owner chunkah picked;
# since every layer carries its parent directories, installing one more
# package rewrote ~100 layers.
set -euxo pipefail

pin_dirs() {
    # skipped: mount points of this build step (in the image they are empty
    # dirs of the filesystem package, clamped to its build time); /ctx is
    # this script
    find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /ctx \) -prune \
        -o -type d -exec touch -h -d @0 {} +
}
pin_dirs

# fontconfig's caches record their font directories' mtimes: rebuild them
# over the pinned ones (same fonts -> same caches), then pin the cache dir.
# Nothing in the image needs fontconfig now (the dashboard embeds its font),
# but a package may bring it back.
if command -v fc-cache >/dev/null; then
    fc-cache -s -f
    pin_dirs
fi

