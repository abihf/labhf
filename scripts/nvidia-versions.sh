#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Print the --build-arg flag that keys the NVIDIA kmod stages (Containerfile)
# besides KVER (scripts/kmod-image.sh):
#   NVIDIA_VERSION  RPM Fusion's current akmod-nvidia, e.g. 3:620.73.04-1.fc45
# Those stages build FROM the kmod image for KVER, so their layer cache only
# misses when one of these changes, not with every new base image.
#
# usage: nvidia-versions.sh KMOD_BASE_IMAGE   (runs the RPM Fusion query in it)
# env:   PODMAN
#        NVIDIA_VERSION        use this akmod-nvidia version, don't ask RPM Fusion
#        NVIDIA_VERSION_CACHE  file that keeps RPM Fusion's answer for 12 hours
#                              (local builds: the query takes 5-10 s)
set -euo pipefail
podman=${PODMAN:-podman}
kmod_base=${1:?kmod base image}
cache=${NVIDIA_VERSION_CACHE:-}

if [[ -n ${NVIDIA_VERSION:-} ]]; then
    nvidia=$NVIDIA_VERSION
elif [[ -n $cache && -n $(find "$cache" -mmin -720 2>/dev/null) ]]; then
    nvidia=$(<"$cache")
else
    # only RPM Fusion nonfree's metadata, not Fedora's (rpm -i: no dnf
    # transaction). The release package's key isn't imported yet (dnf install
    # <url> in the build doesn't check it either); the version is only a cache
    # key, and the build's own dnf install of akmod-nvidia checks its signature.
    nvidia=$($podman run --rm "$kmod_base" bash -euo pipefail -c '
        curl -fsSLo /tmp/rf.rpm "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm"
        rpm -i --quiet --nosignature /tmp/rf.rpm
        dnf -q repoquery --repo=rpmfusion-nonfree --repo=rpmfusion-nonfree-updates \
            --latest-limit=1 --qf "%{epoch}:%{version}-%{release}\n" akmod-nvidia.x86_64')
    if [[ -n $cache ]]; then mkdir -p "$(dirname "$cache")"; printf '%s\n' "$nvidia" > "$cache"; fi
fi
[[ $nvidia =~ ^[0-9]+:[0-9.]+-[^[:space:]]+$ ]] || { echo "bad akmod-nvidia version: $nvidia" >&2; exit 1; }
echo "nvidia-versions: akmod-nvidia $nvidia" >&2
echo "--build-arg NVIDIA_VERSION=$nvidia"
