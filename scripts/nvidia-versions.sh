#!/usr/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Print the --build-arg flags that key the NVIDIA kmod stages (Containerfile):
#   KVER            the base image's kernel (kernel-core), e.g. 7.3.4-300.fc45.x86_64
#   NVIDIA_VERSION  RPM Fusion's current akmod-nvidia, e.g. 3:620.73.04-1.fc45
# Those stages build FROM a pinned plain Fedora image, so their layer cache
# only misses when one of these changes, not with every new base image.
#
# usage: nvidia-versions.sh BASE_IMAGE KMOD_BASE_IMAGE
# env:   PODMAN
#        NVIDIA_VERSION        use this akmod-nvidia version, don't ask RPM Fusion
#        NVIDIA_VERSION_CACHE  file that keeps RPM Fusion's answer for 12 hours
#                              (local builds: the query takes 5-10 s)
set -euo pipefail
podman=${PODMAN:-podman}
base=${1:?base image} kmod_base=${2:?kmod base image}
cache=${NVIDIA_VERSION_CACHE:-}

# same image `podman build` uses: the local one if present, else pulled (0.2 s)
kver=$($podman run --rm --network=none "$base" \
    rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core)

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
[[ $kver =~ ^[0-9].*\.x86_64$ && $(wc -l <<<"$kver") == 1 ]] || { echo "bad kernel version: $kver" >&2; exit 1; }
[[ $nvidia =~ ^[0-9]+:[0-9.]+-[^[:space:]]+$ ]] || { echo "bad akmod-nvidia version: $nvidia" >&2; exit 1; }
echo "nvidia-versions: kernel $kver, akmod-nvidia $nvidia" >&2
echo "--build-arg KVER=$kver --build-arg NVIDIA_VERSION=$nvidia"
