#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the home-dashboard server (the page the kiosk shows): a single
# executable from https://github.com/abihf/home-dashboard/releases, pinned and
# checksummed. Served by home-dashboard.service on 127.0.0.1:3000.
set -euxo pipefail

: "${HOME_DASHBOARD_VERSION:?}" "${HOME_DASHBOARD_SHA256:?}"

name="home-dashboard-${HOME_DASHBOARD_VERSION}-linux-x64"
url="https://github.com/abihf/home-dashboard/releases/download/${HOME_DASHBOARD_VERSION}/${name}.tar.gz"
curl -fsSL -o /tmp/hd.tar.gz "$url"
echo "${HOME_DASHBOARD_SHA256}  /tmp/hd.tar.gz" | sha256sum -c -
tar -xzf /tmp/hd.tar.gz -C /tmp "${name}/home-dashboard"
install -D -m 0755 "/tmp/${name}/home-dashboard" /usr/libexec/home-dashboard/home-dashboard
# fixed mtime, so an unchanged binary keeps its layer (see k3s.sh)
touch -d @0 /usr/libexec/home-dashboard/home-dashboard
rm -rf /tmp/hd.tar.gz "/tmp/${name}"
