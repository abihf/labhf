#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Print the build time of the newest signed package in this tree.
#
# Used as SOURCE_DATE_EPOCH for everything that has no package build time of
# its own (files written by the build, the initramfs, chunkah's unclaimed
# layer). It depends only on the package set, never on the commit or the clock,
# so a commit that changes no packages leaves those files' mtimes alone, and
# with them the layers. Unsigned packages are left out: kmod-nvidia is built
# here (and gpg-pubkey entries are not packages).
set -euo pipefail
rpm -qa --qf '%{RSAHEADER:pgpsig}|%{BUILDTIME}\n' \
    | grep -v '^(none)|' | cut -d'|' -f2 | sort -n | tail -1
