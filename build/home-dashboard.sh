#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install home-dashboard (the native Wayland app the kiosk runs under cage) into
# /out (copied into rootfs): a single executable from
# https://github.com/abihf/home-dashboard/releases, downloaded and checksummed
# by the home-dashboard-src stage (ADD --checksum): /in/home-dashboard.tar.gz.
# Run by labhf-gui (gui.service). The font is embedded; its licence ships too.
set -euxo pipefail

tar -xzf /in/home-dashboard.tar.gz -C /tmp --wildcards '*/home-dashboard' '*/OFL.txt'
dir=$(echo /tmp/home-dashboard-*/)
install -D -m 0755 "$dir/home-dashboard" /out/usr/bin/home-dashboard
install -D -m 0644 "$dir/OFL.txt" /out/usr/share/licenses/home-dashboard/OFL.txt
# fixed mtime, so an unchanged binary keeps its layer (see k3s.sh)
touch -d @0 /out/usr/bin/home-dashboard /out/usr/share/licenses/home-dashboard/OFL.txt
