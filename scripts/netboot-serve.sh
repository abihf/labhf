#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Serve the installer UKI for UEFI network boot (PXE over TFTP, and UEFI HTTP
# boot) from this machine, for a LAN whose usual DHCP server is down (e.g. it
# runs on the machine being installed).
#
#   NETBOOT_IFACE  this machine's LAN interface (e.g. eth0)
#   NETBOOT_MACS   the target's MAC(s), comma-separated; only they get an answer
#   NETBOOT_IP     address handed to the target (e.g. 192.0.2.13)
#   NETBOOT_GW     router; NETBOOT_DNS (default: the router)
#   OUT            directory with labhf-installer.efi (default: out)
#
# dnsmasq (DHCP + TFTP) runs in a throwaway root container on the host
# network: DHCP needs port 67 and broadcasts, so this is the one step that
# uses sudo. It answers only the listed MACs ("static" range), so the rest of
# the LAN is not affected. The HTTP side runs rootless on port 8080.
# Ctrl-C stops both.
set -euo pipefail
: "${NETBOOT_IFACE:?}" "${NETBOOT_MACS:?}" "${NETBOOT_IP:?}" "${NETBOOT_GW:?}"
NETBOOT_DNS=${NETBOOT_DNS:-$NETBOOT_GW}
OUT=$(realpath "${OUT:-out}")
FEDORA=${FEDORA:-45}
[[ -f $OUT/labhf-installer.efi ]] || { echo "no $OUT/labhf-installer.efi (make installer)" >&2; exit 1; }
server=$(ip -4 -o addr show "$NETBOOT_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -1)
[[ -n $server ]] || { echo "no IPv4 address on $NETBOOT_IFACE" >&2; exit 1; }
net=${NETBOOT_IP%.*}.0

echo ">> HTTP: http://$server:8080/labhf-installer.efi"
python3 -m http.server 8080 --bind "$server" --directory "$OUT" >/dev/null 2>&1 &
http_pid=$!
trap 'kill $http_pid 2>/dev/null || true' EXIT

echo ">> DHCP + TFTP on $NETBOOT_IFACE for $NETBOOT_MACS -> $NETBOOT_IP (sudo)"
sudo podman run --rm -it --network=host --cap-add=NET_ADMIN,NET_RAW,NET_BIND_SERVICE \
    --security-opt label=disable -v "$OUT:/srv:ro" \
    "registry.fedoraproject.org/fedora-minimal:$FEDORA" sh -c "
dnf -y -q install dnsmasq >/dev/null 2>&1 || { echo 'dnf install dnsmasq failed'; exit 1; }
exec dnsmasq --no-daemon --port=0 --log-dhcp --no-resolv \
  --interface=$NETBOOT_IFACE --bind-interfaces \
  --dhcp-range=$net,static,255.255.255.0,1h \
  --dhcp-host=$NETBOOT_MACS,$NETBOOT_IP \
  --dhcp-option=option:router,$NETBOOT_GW \
  --dhcp-option=option:dns-server,$NETBOOT_DNS \
  --dhcp-match=set:pxe64,option:client-arch,7 \
  --dhcp-match=set:pxe64,option:client-arch,9 \
  --dhcp-match=set:http64,option:client-arch,16 \
  --dhcp-boot=tag:pxe64,labhf-installer.efi \
  --dhcp-option-force=tag:http64,60,HTTPClient \
  --dhcp-boot=tag:http64,http://$server:8080/labhf-installer.efi \
  --enable-tftp --tftp-root=/srv --tftp-secure
"
