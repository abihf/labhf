#!/usr/bin/bash
# Build the NVIDIA *open* kernel module for the image's kernel with akmods
# (RPM Fusion) and sign it with our Secure Boot db key.
# Output: /out/*.rpm (kmod package) and /out/nvidia-version (EVR to pin userspace)
set -euxo pipefail

# Keep downloaded RPMs in the build cache mount (/var/cache/libdnf5)
dnf() { command dnf --setopt=keepcache=True "$@"; }

kver=$(ls /usr/lib/modules)
fedver=$(rpm -E %fedora)

dnf -y install \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedver}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedver}.noarch.rpm"

# kernel-devel must match the image kernel exactly. Fedora's updates repo only
# keeps the newest build, so fall back to koji for an older one.
if ! dnf -y install "kernel-devel-${kver}"; then
    kv=${kver%.*}; arch=${kver##*.}
    ver=${kv%%-*}; rel=${kv#*-}
    dnf -y install "https://kojipkgs.fedoraproject.org/packages/kernel/${ver}/${rel}/${arch}/kernel-devel-${kver}.rpm"
fi

# Build the open kernel modules (Turing and newer GPUs)
echo '%_with_kmod_nvidia_open 1' > /etc/rpm/macros.nvidia-kmod

dnf -y install akmods akmod-nvidia openssl

# akmods signs with this key pair; use our db key so the kernel trusts it.
install -D -m 0600 /run/secrets/sb_key /etc/pki/akmods/private/private_key.priv
install -d /etc/pki/akmods/certs
openssl x509 -in /run/secrets/sb_cert -outform DER -out /etc/pki/akmods/certs/public_key.der
chown -R akmods:akmods /etc/pki/akmods || true

akmods --force --kernels "${kver}" --kmod nvidia

# never leave the key in a layer
rm -f /etc/pki/akmods/private/private_key.priv

mkdir -p /out
cp -v /var/cache/akmods/nvidia/kmod-nvidia-"${kver}"-*.rpm /out/
rpm -q --qf '%{EPOCH}:%{VERSION}-%{RELEASE}\n' akmod-nvidia | sed 's/(none)://' > /out/nvidia-version
cat /out/nvidia-version

# sanity check: module is signed by our key
tmp=$(mktemp -d)
rpm2cpio /out/kmod-nvidia-*.rpm | (cd "$tmp" && cpio -idm --quiet)
ko=$(find "$tmp" -name 'nvidia.ko*' | head -1)
case "$ko" in *.xz) xz -dk "$ko"; ko=${ko%.xz} ;; *.zst) zstd -dq "$ko"; ko=${ko%.zst} ;; esac
modinfo -F signer "$ko"
modinfo -F license "$ko"
