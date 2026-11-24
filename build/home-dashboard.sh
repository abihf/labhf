#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the home-dashboard server (the page the kiosk shows) into /out
# (copied into rootfs): a single executable from
# https://github.com/abihf/home-dashboard/releases, downloaded and checksummed
# by the home-dashboard-src stage (ADD --checksum): /in/home-dashboard.tar.gz.
# Served by home-dashboard.service on 127.0.0.1:3000.
set -euxo pipefail

tar -xzf /in/home-dashboard.tar.gz -C /tmp --wildcards '*/home-dashboard'
bin=$(echo /tmp/home-dashboard-*/home-dashboard)
install -D -m 0755 "$bin" /out/usr/libexec/home-dashboard/home-dashboard
# fixed mtime, so an unchanged binary keeps its layer
touch -d @0 /out/usr/libexec/home-dashboard/home-dashboard
