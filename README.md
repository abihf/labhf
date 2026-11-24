# labhf

Immutable, sealed homelab OS built with [bootc](https://bootc.dev) on Fedora.

| Requirement | How |
|---|---|
| Atomic updates | bootc **composefs backend**, images pulled from an OCI registry, `bootc upgrade` / `rollback` |
| Upstream binaries | Fedora bootc base + Fedora / RPM Fusion / NVIDIA / COPR RPMs. Only compile: NVIDIA open kmod via akmods (built unsigned, signed in a separate offline stage) |
| Sealed boot, own keys | Secure Boot (own PK/KEK/db) → signed systemd-boot → signed **UKI** whose cmdline carries the composefs digest → fs-verity on every file |
| Encrypted state | root partition is **plain** (image only, fs-verity checked); bootc's `/state` (= `/etc`, `/var`, `/home`) is a separate LUKS2 partition mounted at `/sysroot/state` in the initrd; TPM2 policy PCR 0+2+3+5+7, PCR 15 = 0, plus a [rollback lock](#tpm-rollback-lock) (systemd-pcrlock on PCR 4): only UKIs of current bootc deployments unlock, not older signed releases |
| Data | existing mdadm RAID5 (USB, unencrypted) → `/media/data`; fast shared data in `/home/public` on the encrypted state volume, also at `/media/public` (symlink); both `container_file_t` for Kubernetes hostPaths |
| Disk health | `smartd` (smartmontools, Fedora's default `DEVICESCAN` config) checks the disks it finds, without waking spun-down ones (`-n standby`), and logs to the journal; disks behind USB bridges may need an explicit `-d sat` line in `/etc/smartmontools/smartd.conf` |
| Performance | CPU EPP `balance_performance` (amd-pstate, udev); `nvidia-persistenced` (started by udev when the driver binds a GPU), `nvidia-powerd` (laptop Dynamic Boost) off; md `stripe_cache_size` 4096 and `mq-deadline` for rotational disks; TCP BBR + `fq`; no `init_on_free`, lazy IOTLB flushing. Nothing pins clocks high |
| Network | systemd-networkd + systemd-resolved (no NetworkManager, no LLMNR/mDNS); DHCP on wired NICs by default, machine-local files in `/etc/systemd/network` |
| DNS / DHCP | `/etc/resolv.conf` lists the network's DNS servers directly; resolved has no 127.0.0.53/54 stub, so port 53 stays free for a DNS pod on the host port. `kea` (DHCPv4) is installed, `kea-dhcp4` disabled until a machine-local `/etc/kea/kea-dhcp4.conf` is in place |
| Firewall | own nftables table `inet labhf` next to Kubernetes rules: SSH and configured ingress hostPorts or NodePorts, pod/service IPs not reachable from outside; machine-local `/etc/labhf/firewall.d/*.nft` |
| VPN | WireGuard: in-kernel module (Fedora, signed) + `wireguard-tools` (`wg`); `wg0` as a networkd `.netdev` (or `wg-quick`) |
| SELinux | Fedora targeted policy, enforcing; `container-selinux` |
| Kubernetes + NVIDIA | Fedora Kubernetes 1.37 and CRI-O RPMs, OverlayFS image layers, standalone Kine with SQLite, and an NVIDIA RuntimeClass and device plugin |
| Users | `abi` (uid 1000) admin via `/etc/sudoers.d/50-abi`, password + SSH key set by `labhf-install-disk`; `gui` (uid 2000) runs the dashboard |
| Dashboard | user `gui` (uid 2000) auto-logins on tty1 → `labhf-gui`: picks the AMD iGPU (not the NVIDIA), `cage` + `wlr-randr` (HDMI-A-1 rotated 90°) + WPE `MiniBrowser` → `http://localhost:3000`, served by `home-dashboard.service` (a pinned release of [home-dashboard](https://github.com/abihf/home-dashboard), DynamicUser, localhost only; settings such as `BG_DIR` in `/etc/labhf/home-dashboard.env`) |

## Layout

```
Containerfile          image build up to rootfs (multi-stage, see header)
Containerfile.tree     rootfs with directory mtimes pinned, as one flat tree
Containerfile.seal     composefs digest + signed UKI over the chunked layers
Containerfile.tools    host helper container: openssl, sbsigntools, virt-fw-vars
build/                 scripts run inside build stages
rootfs/                files copied into the image
  usr/lib/bootc/kargs.d/      kernel args → baked into the signed UKI
  usr/lib/labhf/repart.d/     disk layout (systemd-repart, used by labhf-install-disk)
  usr/bin/labhf-*             install-disk, enroll-tpm, pcrlock, setup-raid
scripts/               host scripts (keys, OVMF vars, QEMU, CI build)
.github/workflows/     CI: build + push to ghcr.io
keys/                  Secure Boot keys (git-ignored, back them up!)
vm/                    QEMU disks, firmware vars, swtpm state (git-ignored)
```

## Build and test in QEMU

Host needs `podman`, `qemu`, `swtpm`, `make` (`sudo pacman -S podman` on Arch/CachyOS).
Builds are rootless (needs a subuid/subgid range for your user); only
`make vm-install`, which writes a disk, uses sudo. At boot the LUKS prompt is in
the QEMU window (`make build SERIAL_CONSOLE=1` also puts it on the serial console).

```bash
make tools        # helper container
make keys         # once; keys/db.key is the crown jewel (or: make import-sbctl)
make build        # -> localhost/labhf:latest
make vm-install   # vm/disk.raw: ESP + root + LUKS state; asks LUKS + abi passwords (sudo)
make vm-run       # Secure Boot + swtpm; type the LUKS passphrase
make vm-ssh       # ssh abi@localhost -p 2222
```

The VM install gets passwordless sudo for `abi` (`LABHF_VM_TEST=1`, set only by
`scripts/vm-install.sh`; the image has no such rule). Root has no SSH login.

Inside the VM (`sudo -i` first):

```bash
cat /proc/cmdline            # composefs.digest=... (from the signed UKI)
findmnt /                    # overlay ... verity=require
bootctl status               # Secure Boot: enabled (user)
findmnt /sysroot/state       # /dev/mapper/state (must be mounted!)
labhf-enroll-tpm             # bind LUKS state to TPM (PCR 0,2,3,5,7 + 15=0, pcrlock PCR 4)
labhf-pcrlock status         # deployments vs. UKIs in the rollback lock
reboot                       # should unlock without a prompt
labhf-setup-raid create /dev/vdb /dev/vdc /dev/vdd   # RAID5 test (adopt: reuse one)
```

### Dashboard settings (`/etc/labhf/gui.env`)

`gui.service` runs [`labhf-gui`](rootfs/usr/bin/labhf-gui). The PC has two
GPUs, and `cardN` numbers depend on driver load order, so the script picks
the card by kernel driver (`GUI_GPU`, default `amdgpu`; falls back to any
non-NVIDIA card, then any card). It pins cage (`WLR_DRM_DEVICES`,
`WLR_RENDER_DRM_DEVICE`), WebKit (`WEBKIT_WEB_RENDER_DEVICE_FILE`) and Mesa's
EGL (NVIDIA's EGL is skipped) to that card, rotates the output, then runs
MiniBrowser. Settings live in a machine-local env file (survives `bootc upgrade`):

```bash
sudo tee /etc/labhf/gui.env <<'EOF'
GUI_URL=http://localhost:3000
GUI_GPU=amdgpu          # driver name: amdgpu, i915, xe, nvidia
GUI_OUTPUT=HDMI-A-1     # output to rotate, "all", or empty for none
GUI_TRANSFORM=90        # normal, 90, 180, 270, flipped-90, ...
#GUI_BROWSER_ARGS=--bg-color=black
EOF
sudo systemctl restart gui.service
journalctl -b -t labhf-gui | grep labhf-gui:     # which GPU/output it picked
```

The script's output is in the login session's scope (`PAMName=`), not
under `-u gui.service`, hence `-t`. In QEMU (output `Virtual-1`, no AMD card)
only `GUI_TRANSFORM=normal` is needed. Images built before `labhf-gui` used an `ExecStart=` drop-in in
`/etc/systemd/system/gui.service.d/` instead. Remove it after upgrading:
`sudo rm -r /etc/systemd/system/gui.service.d && sudo systemctl daemon-reload`.

`make vm-run` uses a virgl GPU (`virtio-vga-gl`, `gtk,gl=on`). With plain
`virtio-vga` (`VM_GL=0 make vm-run`) the guest has no 3D, WebKit's web process
fails with `DRM_IOCTL_MODE_CREATE_DUMB failed: Permission denied`, and the
page stays black. Switching the GPU kept TPM unlock working (PCRs unchanged).

### Network

systemd-networkd manages the network; NetworkManager is not in the image. The
image ships `/usr/lib/systemd/network/80-labhf-wired.network` (DHCP on
`en*`/`eth*`), so a fresh install comes up without any configuration. Files in
`/etc/systemd/network/` are machine-local (on the encrypted state volume,
kept across upgrades), and a lower-numbered file that matches the same NIC
replaces the default, e.g. a static address:

```ini
# /etc/systemd/network/20-wired.network
[Match]
Name=en*

[Network]
Address=192.0.2.10/24
Gateway=192.0.2.1
DNS=192.0.2.1
```

Then `sudo networkctl reload` and `networkctl status`. Only links matching a
`.network` file are touched, so the pod bridge `labhf0` and `veth*` stay
unmanaged. `network-online.target` waits for any one link (60s at most), so an
unplugged second NIC doesn't hold boot. Kernel names (`eth0`) instead of
`enp…`: `sudo ln -s /dev/null /etc/systemd/network/99-default.link`.

### WireGuard VPN

`wg0` is a networkd `.netdev` + `.network` pair; the private key lives in the
`.netdev`, so keep it readable only by networkd:

```ini
# /etc/systemd/network/30-wg0.netdev   (root:systemd-network, mode 0640)
[NetDev]
Name=wg0
Kind=wireguard

[WireGuard]
PrivateKey=...
ListenPort=51820

[WireGuardPeer]
PublicKey=...
AllowedIPs=10.0.0.2/32
```

```ini
# /etc/systemd/network/35-wg0.network
[Match]
Name=wg0

[Network]
Address=10.0.0.1/24
```

`sudo networkctl reload && sudo wg show`. `wg-quick@wg0` with
`/etc/wireguard/wg0.conf` also works; use one or the other for an interface.

### Firewall

`labhf-firewall.service` loads [`/usr/lib/labhf/firewall.nft`](rootfs/usr/lib/labhf/firewall.nft)
into its own table, `inet labhf`. It only ever replaces that table, never the
whole ruleset: kube-proxy, kube-router and the CNI plugins maintain their own rules, and Fedora's `nftables.service` (not used) would
delete them on stop or reload with `nft flush ruleset`.

| | Default |
|---|---|
| Input | established, loopback, pods (`labhf0`), ICMP/ICMPv6, DHCPv6 replies, **TCP 22**; everything else dropped (rate-limited log `labhf-fw in drop:`) |
| Forward | established, pods, ingress hostPorts and NodePorts (DNAT from a host address); new connections from outside to pod or service IPs (10.42/16, 10.43/16) dropped, also after kube-proxy's DNAT; all other routing (e.g. LAN ↔ VPN) unchanged |
| Output | untouched |

So the Kubernetes API (6443) and kubelet (10250) are reachable from the host and
from pods only: use `kubectl` over ssh, or open 6443 for one subnet. Open
ports and rules per machine in `/etc/labhf/firewall.d/*.nft` (loaded in the
same transaction, after the base table):

```nft
# /etc/labhf/firewall.d/50-local.nft
add element inet labhf tcp_open { 445 }               # samba
add element inet labhf udp_open { 67, 51820 }         # DHCP server, WireGuard
add element inet labhf trusted_ifs { "wg0" }          # VPN peers: like the host itself
add rule inet labhf local_input ip saddr 192.0.2.0/24 tcp dport 6443 accept
```

`sudo systemctl reload labhf-firewall` applies changes; `sudo nft list table
inet labhf` shows the result. If the file has a syntax error the unit fails
and the previous table stays loaded (at boot: no table, i.e. no filtering);
check with `sudo nft -c -f /usr/lib/labhf/firewall.nft`. The QEMU VM forwards
host port 6443, which the firewall now drops; add a local rule for
`ip saddr 10.0.2.2` to use it.

## Kubernetes

Fedora's Kubernetes 1.37 RPMs provide the API server, controller manager,
scheduler, kube-proxy, kubelet and CLI. The host runs the packaged services
through `labhf-kubernetes.target`. CRI-O uses a dedicated OverlayFS store at
`/var/lib/crio/overlay-storage`. On upgrade from the earlier composefs
configuration, CRI-O pulls images into the new store and recreates pod
sandboxes. The old store at `/var/lib/crio/storage` is available for rollback.
Kine serves the API server
over a root-only Unix socket and stores data in
`/var/lib/labhf-kubernetes/db/state.db` on the encrypted state volume.

Fresh installs bootstrap one schedulable node automatically, with CoreDNS,
the NVIDIA RuntimeClass and device plugin. kube-router enforces Kubernetes
NetworkPolicy for pod ingress and egress using Fedora's iptables and ipset.
The single-node CNI bridge uses
`10.42.0.0/24` within the reserved pod range `10.42.0.0/16`. Services use
`10.43.0.0/16`. The API and kubelet use the IPv4 address selected by the
default route. To pin it on a multi-homed machine, put
`LABHF_KUBE_ADDRESS=192.0.2.10` in `/etc/kubernetes/labhf.env` before
bootstrap, substituting an address assigned to the host.

```bash
sudo kubectl --kubeconfig=/var/lib/labhf-kubernetes/credentials/admin.conf get nodes
sudo crictl info
sudo journalctl -b -u labhf-kubernetes-prepare -u labhf-kine -u kube-apiserver -u labhf-kubernetes-addons
```

The administrator kubeconfig uses `https://localhost:6443` and works through
`ssh -L 6443:localhost:6443` when copied securely to an administrator's
machine. Back up the SQLite database and `credentials/` together, including
the PKI and Secrets encryption key. Take a consistent SQLite backup or stop
`labhf-kubernetes.target` before copying the state directory. kubeadm issues
one-year control-plane and administrator certificates by default. Renew them
using the existing CA before expiration. For certificates in `pki/`, run
the relevant `kubeadm certs renew <certificate>` subcommands with
`--cert-dir=/var/lib/labhf-kubernetes/credentials/pki`. Reissue the client
kubeconfigs with `kubeadm init phase kubeconfig <name>` in an empty directory
and use `kubeadm kubeconfig user --client-name system:kube-proxy` for
`proxy.conf`, passing `--config /etc/kubernetes/labhf-kubeadm.yaml` to both.
Restart the target after installing the renewed files. If a restored kubelet
has lost its rotating certificate directory, generate a new kubelet
kubeconfig and install it as `/var/lib/kubelet/labhf-kubelet.conf`.

### Cut over from k3s

1. On the current k3s deployment, collect the workload manifests or Helm
   values, Secrets, and persistent-volume mappings you need to restore.
   Identify PVCs backed by k3s local-path and back up their data. Stop k3s
   before taking a filesystem backup of its complete server directory and
   configuration. The backup includes its SQLite database, credentials,
   token, and Secrets encryption material.
2. Deploy the new image and reboot. The bootstrap detects the old
   `/var/lib/rancher/k3s/server` and waits for authorization to initialize the
   replacement cluster. Keep that directory for bootc rollback.
3. Start the new cluster after checking the backup and preparing the
   workload restore.

   ```bash
   sudo install -m 0600 /dev/null /etc/kubernetes/labhf-cutover
   sudo systemctl start labhf-kubernetes.target
   sudo kubectl --kubeconfig=/var/lib/labhf-kubernetes/credentials/admin.conf get nodes
   ```

4. Restore workloads and bind their persistent volumes to the existing
   data. Restore ingress, storage provisioning and metrics explicitly if
   your workloads used k3s's Traefik, ServiceLB, local-path provisioner, or
   metrics-server. Check kube-router before bringing up workloads that rely
   on NetworkPolicy. The new cluster has its own identity and SQLite database.

## Disk layout

```
p1 ESP    vfat 1G      signed systemd-boot + signed UKIs
p2 root   ext4 40G     PLAIN: /composefs (image objects), /state = mount point
p3 state  LUKS2 ext4   deploy/<id>/etc, os/default/var  -> /etc, /var, /home
```

state takes all space after root (197.5G on the PC's 256G NVMe), including the fast
shared data in `/home/public`.

Data mounts (`/media` is a real directory on the sealed root, not Fedora's
`run/media` symlink, so a missing disk means read-only errors, never writes
into RAM or onto the state volume):

| Mount | Source | Set up by | If missing |
|---|---|---|---|
| `/media/public` | symlink → `/home/public` (encrypted state volume) | image (symlink), tmpfiles (directory) | always there |
| `/media/data` | mdadm array, fstab by UUID | `labhf-setup-raid adopt` (machine `/etc/fstab`) | boots (`nofail`); **Kubernetes stays down** (`RequiresMountsFor=`), so media apps never see an empty library |
| `/media/backup` | backup disk, fstab by UUID | by hand (fstab, e.g. `x-systemd.automount`) | |

The RAID is mounted with `context=system_u:object_r:container_file_t:s0`, so
with SELinux enforcing pods may use it through hostPath and 22T never needs
relabelling. `/home/public` gets the same type from an fcontext rule the image
ships (in `/etc/selinux/targeted/active/file_contexts.local`; check with
`matchpathcon /home/public`); after copying data in, run
`sudo restorecon -R /home/public`.

`sysroot-state.mount` mounts p3 twice: in the initrd (bootc-root-setup.service
requires it, so `/etc` and `/var` always come from the encrypted volume) and in
the booted system (bootc's `/sysroot` is a non-recursive clone, and
`bootc upgrade` writes new deployments under `/sysroot/state`).

### Recovering an unbootable machine

From a live USB, without any key:
- **ESP**: replace UKIs / systemd-boot with ones from a CI build, or pick the
  previous deployment in the systemd-boot menu. UKIs put on the ESP by hand
  aren't in the [rollback lock](#tpm-rollback-lock): that boot asks for the
  LUKS passphrase; rerun `labhf-enroll-tpm` once it is up.
- **root**: inspect `/composefs`; image files can't be edited by hand
  (fs-verity + the digest in the UKI reject them), so you fix a bad image by
  booting the previous entry or deploying a new image.

Deploying a new image or fixing `/etc` needs `state` unlocked (LUKS passphrase):
`cryptsetup open /dev/disk/by-partlabel/state state`.

## Updates

Push the image to a registry and point the machine at it (`LABHF_TARGET_IMGREF=` for
`labhf-install-disk`, or `bootc switch <ref>` later). Then `bootc upgrade && reboot`; a new
UKI signed by the same db key keeps PCR 7 stable, and `labhf-pcrlock.service`
adds the staged UKI to the rollback lock at shutdown, so TPM unlock keeps
working.

### TPM rollback lock

Secure Boot accepts every UKI ever signed with the db key, and root is plain,
so PCR 7 alone would let someone with the disk pull an old, vulnerable
release from the registry, copy its composefs objects and UKI onto root and
ESP, and boot it with `state` unlocked. `labhf-enroll-tpm` therefore adds a
[systemd-pcrlock](https://www.freedesktop.org/software/systemd/man/latest/systemd-pcrlock.html)
policy on PCR 4 (the Authenticode hashes of systemd-boot and of the UKI that
booted) to the LUKS token, next to the literal PCR policy; both must match.
The policy lives in a TPM NV index, so it changes without re-enrolling:

| When | `labhf-pcrlock` | Allowed UKIs |
|---|---|---|
| `labhf-enroll-tpm` | `enroll`: records systemd-boot and the booted, staged and rollback UKIs from the ESP | all current deployments |
| shutdown (service stop) | `shutdown`: records the staged UKI that `bootc upgrade` wrote | + staged |
| boot (service start) | `boot`: drops UKIs whose deployment bootc no longer has | booted + rollback |

Records are taken only from the running system (the ESP is writable offline)
and kept on the encrypted volume (`/var/lib/labhf/pcrlock.d`; the policy and
the NV index's sealed PIN in `/var/lib/systemd/pcrlock.json`). The initrd gets
the public part of the policy from `/boot/loader/credentials/pcrlock.*.cred`.
A boot that unlocked with the passphrase is never recorded automatically:
`labhf-pcrlock boot` logs a warning instead. `make-policy` runs with
`--strict`: without it, a boot that matches no record drops PCR 4 and writes
an empty policy that always unseals.

`sudo labhf-pcrlock status` lists deployments vs. records. `bootc rollback`
keeps unlocking (the rollback UKI stays recorded). A systemd-boot update on
the ESP (`bootc upgrade` doesn't do one) needs `labhf-enroll-tpm` again.
Without the lock: `sudo LABHF_PCRLOCK=0 labhf-enroll-tpm`.

### Update size: chunked layers

bootc has no partial (per-file) pulls, also not with zstd:chunked, but it
skips layers it already has. So `make build` doesn't ship one flat tree: it
builds the tree, splits it with [chunkah](https://github.com/coreos/chunkah)
into up to 128 content-based layers (one or more RPMs per layer, offline, no
keys, only the tree mounted), then computes the composefs digest and signs
the UKI over exactly those layers (`Containerfile.seal`; `/boot` is the last,
small layer). A package update then only changes its layers. The base image's
unused ostree repo in `/sysroot/` (2G) is dropped in the same step, and images
are pushed with zstd. Chunking must happen before sealing: chunkah changes
mtimes, and mtimes are part of the composefs metadata.

A layer is only reused if its bytes are identical, mtimes included, so
nothing in it may depend on the commit or the clock:
- chunkah clamps a packaged file's mtime to its package's build time, and
  every other file's to `SOURCE_DATE_EPOCH`. That is the newest package
  build time in the tree (`build/source-date-epoch.sh`), not the commit time:
  it moves with the package set only.
- Directories all get mtime 0 (`build/normalize-mtimes.sh`, as ostree does).
  Many are shared (`/usr/lib/.build-id`, icon theme dirs) and each layer
  carries its parent directories, so one added package used to change the
  mtime of `/usr/lib/.build-id` in ~100 layers.
- The initramfs is built with `SOURCE_DATE_EPOCH` set (dracut's
  `reproducible=yes`), and the NVIDIA kmod RPM, rebuilt on every CI run, takes
  its build time from its changelog and a fixed build host.
- rpm stamps install times from `SOURCE_DATE_EPOCH` (the base image's
  package set's, `packages.sh`), so the rpmdb only changes with packages.
- The kmod RPM is built with `rpmbuild` in a fixed directory, not by
  akmods in a random one: that path ended up in each module's build-id.
- systemd-boot is signed in `Containerfile.seal`, as a layer of its own: the
  signature carries a signing time, and in the tree it made systemd's 15M
  layer new on every build.
- dnf's transaction history (build timestamps) is not shipped; font caches
  are rebuilt over the pinned directory mtimes.
- Files the build installs itself (Kine, the signed NVIDIA modules) get a
  fixed mtime.

Measured in QEMU: the image is 129 layers, 1.33 GiB with zstd (was one 4G
layer; 1.75 GiB before stripping, below). Two full rebuilds of the tree
(`make build TREE_BUILD_FLAGS=--no-cache`) now give identical
chunked layers; only the signed systemd-boot (0.2M) and the UKI (~81M) are
new on every CI build, since a fresh runner signs them again. Before, the
same rebuild changed 16 layers (~215M: initramfs, rpmdb, kmod, every layer
holding a directory the build touched), and adding one package ~110 (~640M).
Package updates add the layers of the packages that changed.

### What the image leaves out

`packages.sh` removes, as whole packages (so the rpmdb and the per-package
layers stay accurate), what this machine never uses: `qemu-user-static-*`
(foreign-arch containers), the AWS SDK (`python3-boto3`, `botocore`,
`s3transfer`), `nvidia-gpu-firmware` (nouveau's; the driver's own firmware
comes with `xorg-x11-drv-nvidia`), Wi-Fi/WWAN and Intel GPU/NPU/audio
firmware, `microcode_ctl` (Intel CPU), `intel-mediasdk` and
`mesa-vulkan-drivers` (cage and WPE render with GL). Our packages install
without `%doc`, and only English translations are kept; the base image's docs,
man pages and other translations are deleted. Licenses stay (the image is
redistributed). The build fails if a removal ever takes a package that matters
(kernel, bootc, skopeo, WPE/cage/Mesa, NVIDIA, AMD/Realtek firmware, Kubernetes
SELinux). Not removable: `flite` (WebKit speech synthesis) and `x265-libs`
(via libheif-freeworld); either takes `wpewebkit` with it. The rpmdb stays:
chunkah needs it for the layers, and scanners and `rpm -qf` need it.
Uncompressed tree: 3.9G → 2.9G. Different hardware (Wi-Fi, Intel) may need
some of these back.

`/etc` is machine-local and 3-way merged on upgrade (Kubernetes config,
crypttab, mdadm.conf live there). Local deletions survive too, e.g. a
`systemctl disable`.

### Upgrading the QEMU VM

`make push` starts a throwaway plain-HTTP registry on the host (port 5000)
and pushes the image; the VM reaches it as `10.0.2.2:5000`. Once, in the VM:

```bash
sudo tee /etc/containers/registries.conf.d/50-labhf-dev.conf <<'EOF'
[[registry]]
location = "10.0.2.2:5000"
insecure = true
EOF
sudo bootc switch 10.0.2.2:5000/labhf:latest && sudo reboot
```

After that: `make build push` on the host, `sudo bootc upgrade && sudo reboot`
in the VM. `sudo bootc rollback && sudo reboot` returns to the previous image.

### CI: GitHub Actions → ghcr.io

[`.github/workflows/image.yml`](.github/workflows/image.yml) builds the sealed
image on every push to `main`, weekly (Fedora/NVIDIA updates) and on demand,
and pushes `ghcr.io/<owner>/labhf:{latest,YYYYMMDD,sha-<commit>}`. It runs
`make build` directly on the runner, with Ubuntu 26.04's podman installed by
[`redhat-actions/podman-install`](https://github.com/redhat-actions/podman-install)
(rootful, image storage on `/mnt`), via [`scripts/ci-build.sh`](scripts/ci-build.sh),
and fails if the db key turns up anywhere in the image.

The layer cache of the `Containerfile` build (up to `rootfs`) is kept in
`ghcr.io/<owner>/labhf-cache` (`--cache-from`/`--cache-to`, one tag per build
step), so a run only rebuilds the steps whose inputs changed. Each app is its
own stage, and each step mounts only the scripts it runs: editing
`finalize.sh` keeps the dnf, NVIDIA, Kine and dashboard layers. Downloads are
`ADD --checksum` in `FROM scratch` stages, so they survive a new base image.
Pinning directory mtimes and flattening (`Containerfile.tree`), chunkah and
the seal run every time and are not cached: their layers change whenever
`rootfs` does, and the flat one is the whole image. A new
digest of `quay.io/fedora/fedora-bootc` (frequent) invalidates every step after
`FROM base`. Package updates that land without a new base image wait for the next
one. Keep the `labhf-cache`
package private, and prune old tags now and then; the dnf download cache
(`--mount=type=cache`) is not part of it.

Signing needs three repository secrets. Only the **db** key goes to GitHub;
`PK.key`/`KEK.key` stay offline:

```bash
gh secret set SB_DB_KEY < keys/db.key
gh secret set SB_DB_CRT < keys/db.crt
tar -C keys -cz auth | base64 -w0 | gh secret set SB_AUTH_TGZ   # public .auth files
```

Anyone with write access to the repo's workflows can use the db key, and an
image signed with it boots on the PC: keep the repo's collaborators and
Actions settings tight. Pull requests are never built with the secrets.
The checkout and podman-install actions are pinned by commit
(bump them deliberately), since this job holds the key.

#### Where the db key is used

An image signed with the db key unlocks the TPM-sealed `state` volume once a
machine stages it (the [rollback lock](#tpm-rollback-lock) only keeps out
images the machine never staged, not a bad new one), so the
key is mounted only in `--network=none` build steps of stages built from the
plain Fedora base, which run Fedora's tools and our scripts only:

| Stage | Signs | With |
|---|---|---|
| `nvidia-sign` | NVIDIA `.ko` files | kernel-devel's `sign-file` |
| `sdboot-sign` | systemd-boot | `systemd-sbsign` |
| `sealer` | the UKI | `bootc container ukify` (the sealer's own bootc, byte-identical to the target's) |

RPM Fusion's kmod build (its akmod SRPM), the RPM Fusion / COPR / NVIDIA / Kine installs and
dracut (with installed packages' modules) run without the key, so their code
can neither send it out nor hide it in the image. The kmod RPM is built
unsigned; `packages.sh` lays the signed modules over its files and fails on any
module without our signature (so `rpm -V kmod-nvidia-*` reports them as
changed; expected).

Point the PC at it with `sudo bootc switch ghcr.io/<owner>/labhf:latest`. New
ghcr packages are **private**: either make the package public (it then
redistributes NVIDIA and GPL binaries, see [License](#license)) or give the
machine a read-only token in `/etc/ostree/auth.json`
(`{"auths":{"ghcr.io":{"auth":"<base64 user:PAT with read:packages>"}}}`, mode 0600).

### Using existing sbctl keys

If the machine already boots with your own keys via `sbctl`, sign labhf with
those: the firmware needs no change, and its db stays as sbctl built it
(e.g. your cert plus option ROM hashes from the TPM event log, no Microsoft
CAs, so shims can't boot). On the PC with this checkout:

```bash
# private keys (root-only on the machine); keys/ is git-ignored
ssh -t <host> 'umask 077; sudo tar -C /var/lib/sbctl -czf /tmp/sbctl-keys.tgz GUID keys && sudo chown "$USER:" /tmp/sbctl-keys.tgz'
scp <host>:/tmp/sbctl-keys.tgz keys/ && ssh <host> rm /tmp/sbctl-keys.tgz && chmod 600 keys/sbctl-keys.tgz
# what is enrolled now (world-readable, without the 4-byte attribute header)
mkdir -p keys/sbctl-efivars
for v in PK-8be4df61-93ca-11d2-aa0d-00e098032b8c KEK-8be4df61-93ca-11d2-aa0d-00e098032b8c db-d719b2cb-3d3a-4596-a3bc-dad00e67656f; do
  ssh <host> cat /sys/firmware/efi/efivars/$v | tail -c +5 > keys/sbctl-efivars/${v%%-*}.esl
done
make import-sbctl
```

[`import-sbctl.sh`](scripts/import-sbctl.sh) checks that every key matches its
certificate and that each certificate is the one enrolled, moves any previous
keys to `keys/replaced-<date>/`, and writes the usual `keys/` layout with
`.auth` files that re-enroll exactly the current PK/KEK/db. Then update the
CI secrets and rebuild. The machine itself no longer needs sbctl or the db
key once it runs labhf: CI signs.

## Installing on the real PC

`labhf-install-disk` **wipes the whole target disk** (ESP, root, state). Back
up anything on it first, and unplug data disks you want to keep so it can only
see the target. Machine-specific notes (e.g. migrating an
existing install) belong in a git-ignored `MIGRATION.md`.

1. Back up `keys/`. Only `keys/db.key` + `keys/db.crt` are needed to build
   (CI secrets); keep `PK.key`/`KEK.key` offline.
2. Firmware: enable TPM 2.0. **Already using your own keys with sbctl?**
   Import them ([Using existing sbctl keys](#using-existing-sbctl-keys)) and skip the key steps: the firmware keeps what is
   enrolled. Otherwise **clear the Secure Boot keys / enter Setup Mode**.
3. Boot a live Linux with podman (e.g. Fedora live), then:
   ```bash
   sudo podman pull ghcr.io/<owner>/labhf:latest
   sudo podman run --rm -it --privileged --pid=host --ipc=host \
     --security-opt label=type:unconfined_t \
     -v /var/lib/containers:/var/lib/containers -v /dev:/dev \
     -e LABHF_IMAGE=ghcr.io/<owner>/labhf:latest \
     -e LABHF_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" \
     ghcr.io/<owner>/labhf:latest labhf-install-disk /dev/nvme0n1
   ```
4. Reboot. In Setup Mode systemd-boot offers **"Enroll Secure Boot keys:
   labhf"** (`secure-boot-enroll manual`); pick it. With `make keys` the db
   includes Microsoft's UEFI CA 2011 (+ the 2023 Option ROM CA) so a GPU
   option ROM still loads; note that this also lets any Microsoft-signed
   shim (i.e. most Linux live USBs) boot. They can't unlock `state` (PCR 7
   differs), but prefer option ROM hashes (sbctl) and a BIOS password.
5. Boot, type the LUKS passphrase, run `labhf-enroll-tpm`. The passphrase
   stays as the only fallback (there is no recovery key), so make it strong.
   Reboot once to check the unattended unlock, then start the kiosk, which
   the image leaves disabled: `sudo systemctl enable --now gui.service`.
6. Data array: `sudo labhf-setup-raid adopt` for an existing mdadm array (no
   data is changed), or `sudo labhf-setup-raid create DISK DISK DISK...` for a
   new one (destroys the disks).
7. Kubernetes hostPaths outside `/media/*` need an SELinux label pods may use. There
   is no Python, so no `semanage`: add the rule to the policy store's local
   file contexts (what `semanage fcontext -a` writes) and rebuild with
   `semodule`. The rule needs the `/var/home` path: `/home` is an equivalence
   alias. A policy module's `filecon` won't do, because home directory rules
   override it.
   ```bash
   echo '/var/home/abi/compose(/.*)?    system_u:object_r:container_file_t:s0' | sudo tee -a /etc/selinux/targeted/active/file_contexts.local
   sudo semodule -B && sudo restorecon -R /var/home/abi/compose
   ```
   To remove it, delete the line and run `semodule -B` again. `chcon -t container_file_t`
   labels at once but doesn't last: the next `restorecon` resets it.

After a BIOS, GPU firmware or dbx update the TPM won't unlock: type the
LUKS passphrase, then rerun `labhf-enroll-tpm`. An unexpected passphrase
prompt after an ordinary reboot, with `journalctl -b -u labhf-pcrlock`
saying the booted UKI is not in the TPM policy, means a UKI that wasn't
staged by this machine booted: rerun `labhf-enroll-tpm` only if you know why
(e.g. `labhf-pcrlock.service` wasn't running when the upgrade was staged).

## Hardening

| Area | What the image does |
|---|---|
| SSH | Keys only; `AllowUsers abi`, no root login, no agent/X11 forwarding or tunnels, `AllowTcpForwarding local` (for `ssh -L 6443`), `MaxAuthTries 3`; firewall limits new connections per source (burst 20, then 10/min) |
| Accounts | `root` and `gui` locked, `gui` has no shell; sudo asks for a password, `use_pty`, 5-minute timestamp; 5 failed passwords lock the account for 5 minutes (console, sudo) |
| Kernel | `lockdown=confidentiality` (no kprobes, tracefs, kernel perf, BPF kernel reads, `/proc/kcore` or `/dev/mem`, even for root), `module.sig_enforce=1`, `debugfs=off`, no ftrace or tracefs mount, perf sampling at 1/s, no kexec-tools, `oops=panic`; `kptr_restrict`, `dmesg_restrict`, `hash_pointers=always`, no unprivileged BPF, userfaultfd, io_uring or perf, ptrace scope 1, no kexec, SysRq or binfmt_misc; `init_on_alloc`, `slab_nomerge`, `randomize_kstack_offset`, max mmap ASLR; no 32-bit userspace (`vsyscall=none vdso32=0 ia32_emulation=0`); RDRAND and boot loader seed not credited; no nested KVM; forced IOMMU with per-device isolation (lazy IOTLB flushing), `efi=disable_early_pci_dma`. Mostly secureblue's set, minus forced CPU mitigations, `nosmt`, `init_on_free`, strict IOTLB flushing (performance) and `slab_debug` |
| Boot | `rd.shell=0 rd.emergency=reboot`, debug shell and Ctrl-Alt-Del masked, no serial console |
| Modules | `firewire-*`, `thunderbolt`, `bluetooth`, rare protocols and filesystems can't load (`usr/lib/modprobe.d/60-labhf-unused.conf`), plus secureblue's list (`61-labhf-secureblue.conf`): IPsec/xfrm, l2tp, RxRPC, RDMA, NFS/CIFS/sunrpc, cdrom, DVB, joysticks, IR remotes, debug/test drivers. Kubernetes volumes can't use NFS or SMB |
| Files | Setuid allow-list: only `sudo`, `passwd`, `unix_chkpwd`, `nvidia-modprobe`. `/home` is `nosuid,nodev`. No core dumps |
| Packages | No Python (so no `semanage`, `audit2allow` or setools), no desktop portals, file indexer, audio stack, `nvidia-settings`/gtk3, shim or grub; none of the full base's sssd/samba, NFS client, LVM/udisks, clevis, fwupd, avahi or polkit (`build/packages.sh`). systemd-homed masked |
| Kubernetes | Secrets encrypted, `protectKernelDefaults`, API audit log (metadata only) in `/var/lib/labhf-kubernetes/logs/`. Pod Security warns and audits at `baseline` but doesn't enforce, because baseline forbids hostPath; enforce per namespace with `pod-security.kubernetes.io/enforce=baseline` |
| Kiosk | `NoNewPrivileges`, read-only system, private `/tmp`, restricted address families. Not `ProtectKernelTunables`, `ProtectKernelLogs` or `ProtectHostname`: each masks part of `/proc`, and WebKit's sandbox then can't mount its own |
| Audit | `auditd` logs changes to the machine-local `/etc` (accounts, sudo, SSH, systemd, Kubernetes, CRI-O, SELinux) |

`kernel.panic_on_oops=1` and `kernel.panic=10` are required by
`protectKernelDefaults`, so a kernel oops reboots the machine. With several
keys in an agent, use `IdentitiesOnly yes` or `MaxAuthTries 3` may reject you.
`/etc` and `/var` stay writable, so a root compromise can still persist there;
the sealed image only protects `/usr`.

See [Verified](#verified) for results from previous images and hardware.

## Verified

| What | QEMU | Real PC (`home`) |
|---|---|---|
| Fresh install, 3 partitions | ESP 1G / root 40G / state (80G disk); passphrase-only LUKS until `labhf-enroll-tpm`, then unattended TPM2 unlock with the passphrase slot kept; networkd DHCP, DNS through resolved, boot ~14s | ESP 1G / root 40G / state 197.5G; `state` has a tpm2 and a password slot |
| Split root/state | `bootc switch` + reboot (staged finalize with `/sysroot/state` still mounted, `/etc` merged), `bootc rollback` both ways, TPM unlock across all of them; the plain root's `state/` stays empty | booted + rollback deployment from ghcr.io; the plain root's `state/` is empty (`mount --bind /sysroot /run/x && ls -A /run/x/state`) |
| Chunked + sealed | `bootc switch`/`upgrade` to the chunkah image boots under Secure Boot (digest computed after chunking matches), TPM unlock, signed modules load | runs the CI-built chunked image |
| NVIDIA modules | db-signed kmod accepted under lockdown (`.platform` keyring, no shim/MOK); split signing (akmods output unsigned, 5 modules signed in `nvidia-sign`); ESP systemd-boot from `sdboot-sign` boots, TPM unlock unchanged | under Secure Boot + `lockdown=confidentiality` the open module (620.70) loads, `nvidia-smi` lists the RTX 2000 Ada |
| Data + hostPaths (previous k3s image) | `labhf-setup-raid adopt`; a pod writes `/media/data` and `/media/public` (→ `/home/public`), files are `container_file_t`, cluster DNS and egress work, SELinux enforcing, no AVCs | 22T RAID5 (4 USB disks) at `/media/data`, `/home/public` `container_file_t`, k3s pods on both |
| Firewall (previous k3s image) | from an untrusted client (veth + netns) 22 and Traefik 80/443 open, 6443/10250 and pod / service IPs closed; pods keep DNS, egress, the API server and metrics-server → kubelet; k3s's rules unchanged by start, reload and stop; no AVCs | |
| Dashboard | virtio fallback, rotation | `labhf-gui: gpu card1/renderD128 (amdgpu) ... rotate HDMI-A-1 90` with defaults (no `gui.env`); `HDMI-A-1` the only enabled output, NVIDIA outputs off |
| IOMMU arguments | (QEMU has no IOMMU here) | AMD-Vi active; NVIDIA, iGPU, NVMe and USB disks all work |
| TPM rollback lock | pcrlock token unlocks in the initrd (policy from the ESP credential); `bootc upgrade` + reboot records the staged UKI at shutdown and unlocks unattended, the next boot drops the removed deployment; an older db-signed UKI booted as a one-shot entry stops at the passphrase prompt | not yet (see below) |

The previous QEMU image had no NVIDIA GPU. On the replacement image,
`scripts/vm-check.sh` exercises cluster DNS, local storage, Secret encryption,
the firewall, and NetworkPolicy ingress and egress. Validate GPU allocation
separately on the real hardware.

## Open items / known risks

- **TPM rollback lock is not on the real PC yet**: it runs an image from
  before the lock, so `state` still unlocks for any db-signed UKI. After the
  upgrade: `sudo labhf-enroll-tpm`, reboot, `sudo labhf-pcrlock status`.
- **Rollback lock assumptions**: the initrd must measure nothing into PCR 4
  before unlocking (`--location=749`, no os-separator in dracut's initrd); if
  that changes, `labhf-pcrlock boot` fails `--strict` and logs it. systemd's
  `350-action-efi-application` is left out only when this boot's event log
  lacks it: QEMU's firmware measures it, the real PC's doesn't (its PCR 4 is
  the separator, `BOOTX64.EFI` and the UKI). Allowing both would double the
  values, and a TPM policy takes at most 8 per PCR (deployments × variants).
  Other firmware may measure more and need its own record. A boot
  entry without `version` on the ESP makes `bootc status` fail, and with it
  `labhf-pcrlock` (the policy stays as it was, so the next upgrade asks for
  the passphrase).
- **Split root/state is not an upstream-tested layout.** Re-test after bootc
  updates (see Verified).
- **Coarse IOMMU isolation** on the real PC: 5 IOMMU groups (no ACS on the
  board); the NVIDIA card shares one with its root port, the iGPU one with
  USB and the crypto engine.
- **`rd.emergency=reboot`** has not been triggered anywhere.
- **Dashboard GPU**: the integrated GPU must stay enabled in the firmware
  when the NVIDIA card is installed (often "iGPU multi-monitor" / "IGD"). See
  [Dashboard settings](#dashboard-settings-etclabhfguienv).
- **QEMU TPM** needs Fedora's 4M OVMF (qcow2). The 2M raw build has no TPM:
  every PCR stays zero and `bootctl status` says "firmware unavailable".
- **WPE WebKit** comes from the unofficial COPR `philn/wpewebkit` (retired from
  Fedora). Fallback: `webkitgtk6.0`/epiphany or chromium `--kiosk`.
- Sealed images are Tech Preview upstream; composefs has no boot counting /
  automatic rollback yet.
- Kernel args are fixed in the signed UKI; change them in
  `rootfs/usr/lib/bootc/kargs.d/` and rebuild.

## License

Copyright (C) 2026 Abi Hafshin. Licensed under the GNU General Public License
v3.0 or later ([LICENSE](LICENSE), `SPDX-License-Identifier: GPL-3.0-or-later`).
This covers the files in this repository. The built image also contains Fedora,
RPM Fusion, NVIDIA, Kine, kube-router and other packages under their own licenses (an
aggregate in GPL-3.0 terms); publishing the image means meeting those licenses
too (e.g. corresponding source for GPL packages, NVIDIA's driver license).
