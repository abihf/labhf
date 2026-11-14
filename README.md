# labhf

Immutable, sealed homelab OS built with [bootc](https://bootc.dev) on Fedora.

| Requirement | How |
|---|---|
| Atomic updates | bootc **composefs backend**, images pulled from an OCI registry, `bootc upgrade` / `rollback` |
| Upstream binaries | Fedora bootc base + Fedora / RPM Fusion / NVIDIA / Rancher / COPR RPMs. Only compile: NVIDIA open kmod via akmods (built unsigned, signed in a separate offline stage) |
| Sealed boot, own keys | Secure Boot (own PK/KEK/db) → signed systemd-boot → signed **UKI** whose cmdline carries the composefs digest → fs-verity on every file |
| Encrypted state | root partition is **plain** (image only, fs-verity checked); bootc's `/state` (= `/etc`, `/var`, `/home`) is a separate LUKS2 partition mounted at `/sysroot/state` in the initrd; TPM2 policy PCR 0+2+3+5+7, PCR 15 = 0 |
| Data | existing mdadm RAID5 (USB, unencrypted) → `/media/data`; fast shared data in `/home/public` on the encrypted state volume, also at `/media/public` (symlink); both `container_file_t` for k3s hostPaths |
| Network | systemd-networkd + systemd-resolved (no NetworkManager, no LLMNR/mDNS); DHCP on wired NICs by default, machine-local files in `/etc/systemd/network` |
| Firewall | own nftables table `inet labhf` next to k3s's rules: inbound only SSH + Traefik/NodePorts by default, pod/service IPs not reachable from outside; machine-local `/etc/labhf/firewall.d/*.nft` |
| VPN | WireGuard: in-kernel module (Fedora, signed) + `wireguard-tools` (`wg`); `wg0` as a networkd `.netdev` (or `wg-quick`) |
| SELinux | Fedora targeted policy, enforcing; `container-selinux` + `k3s-selinux` |
| k3s + NVIDIA | static k3s binary, `nvidia-container-toolkit`; k3s auto-registers the `nvidia` runtime; RuntimeClass + device plugin auto-deployed |
| Users | `abi` (uid 1000) admin via `/etc/sudoers.d/50-abi`, password + SSH key set by the installer; `gui` (uid 2000) runs the dashboard |
| Dashboard | user `gui` (uid 2000) auto-logins on tty1 → `labhf-gui`: picks the AMD iGPU (not the NVIDIA), `cage` + `wlr-randr` (HDMI-A-1 rotated 90°) + WPE `MiniBrowser` → `http://localhost:3000` |

## Layout

```
Containerfile          image build up to the flat tree (multi-stage, see header)
Containerfile.seal     composefs digest + signed UKI over the chunked layers
Containerfile.tools    host helper container: openssl, sbsigntools, virt-fw-vars
build/                 scripts run inside build stages
rootfs/                files copied into the image
  usr/lib/bootc/kargs.d/      kernel args → baked into the signed UKI
  usr/lib/labhf/repart.d/     disk layout for the installer
  usr/bin/labhf-*             install-disk, enroll-tpm, setup-raid
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
# or, without sudo, through the network installer (see "Network install"):
#   make push && make installer INSTALLER_EXTRA="console=ttyS0,115200 labhf.vm-test=1" && make vm-netinstall
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
labhf-enroll-tpm             # bind LUKS state to TPM (PCR 0,2,3,5,7 + 15=0)
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
journalctl -b -u gui.service | grep labhf-gui:   # which GPU/output it picked
```

In QEMU (output `Virtual-1`, no AMD card) only `GUI_TRANSFORM=normal` is
needed. Images built before `labhf-gui` used an `ExecStart=` drop-in in
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
`.network` file are touched, so k3s's `cni0`, `flannel.1` and `veth*` stay
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
whole ruleset: k3s's kube-proxy / flannel / network-policy rules live in their
own iptables-nft tables, and Fedora's `nftables.service` (not used) would
delete them on stop or reload with `nft flush ruleset`.

| | Default |
|---|---|
| Input | established, loopback, k3s pods (`cni0`, `flannel.1`), ICMP/ICMPv6, DHCPv6 replies, **TCP 22**; everything else dropped (rate-limited log `labhf-fw in drop:`) |
| Forward | established, pods, Traefik / NodePorts (DNAT from a host address); new connections from outside to pod or service IPs (10.42/16, 10.43/16) dropped, also after kube-proxy's DNAT; all other routing (e.g. LAN ↔ VPN) unchanged |
| Output | untouched |

So the k3s API (6443) and kubelet (10250) are reachable from the host and
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

## Disk layout

```
p1 ESP    vfat 1G      signed systemd-boot + signed UKIs
p2 root   ext4 40G     PLAIN: /composefs (image objects), /state = mount point
p3 state  LUKS2 ext4   deploy/<id>/etc, os/default/var  -> /etc, /var, /home
```

state takes all space after root (~215G on the 256G NVMe), including the fast
shared data in `/home/public`.

Data mounts (`/media` is a real directory on the sealed root, not Fedora's
`run/media` symlink, so a missing disk means read-only errors, never writes
into RAM or onto the state volume):

| Mount | Source | Set up by | If missing |
|---|---|---|---|
| `/media/public` | symlink → `/home/public` (encrypted state volume) | image (symlink), tmpfiles (directory) | always there |
| `/media/data` | mdadm array, fstab by UUID | `labhf-setup-raid adopt` (machine `/etc/fstab`) | boots (`nofail`); **k3s stays down** (`x-systemd.required-by`), so media apps never see an empty library |
| `/media/backup` | backup disk, fstab by UUID | by hand (fstab, e.g. `x-systemd.automount`) | |

The RAID is mounted with `context=system_u:object_r:container_file_t:s0`, so
with SELinux enforcing k3s pods may use it through hostPath and 11T never needs
relabelling. `/home/public` gets the same type from an fcontext rule the image
ships (`semanage fcontext -l -C`); after copying data in, run
`sudo restorecon -R /home/public`.

`sysroot-state.mount` mounts p3 twice: in the initrd (bootc-root-setup.service
requires it, so `/etc` and `/var` always come from the encrypted volume) and in
the booted system (bootc's `/sysroot` is a non-recursive clone, and
`bootc upgrade` writes new deployments under `/sysroot/state`).

### Recovering an unbootable machine

From a live USB, without any key:
- **ESP**: replace UKIs / systemd-boot with ones from a CI build, or pick the
  previous deployment in the systemd-boot menu.
- **root**: inspect `/composefs`; image files can't be edited by hand
  (fs-verity + the digest in the UKI reject them), so you fix a bad image by
  booting the previous entry or deploying a new image.

Deploying a new image or fixing `/etc` needs `state` unlocked (LUKS passphrase):
`cryptsetup open /dev/disk/by-partlabel/state state`.

## Updates

Push the image to a registry and point the machine at it (`TARGET_IMGREF=` at
install, or `bootc switch <ref>` later). Then `bootc upgrade && reboot`; a new
UKI signed by the same db key keeps PCR 7 stable, so TPM unlock keeps working.

### Update size: chunked layers

bootc has no partial (per-file) pulls, also not with zstd:chunked, but it
skips layers it already has. So `make build` doesn't ship one flat tree: it
builds the tree, splits it with [chunkah](https://github.com/coreos/chunkah)
into up to 128 content-based layers (one or more RPMs per layer, offline, no
keys, only the tree mounted), then computes the composefs digest and signs
the UKI over exactly those layers (`Containerfile.seal`; `/boot` is the last,
small layer). A package update then only changes its layers. The base image's
unused ostree repo in `/sysroot/` (2G) is dropped in the same step, and images
are pushed with zstd. Chunking must happen before sealing: chunkah clamps
mtimes to `SOURCE_DATE_EPOCH` (the commit time), and mtimes are part of the
composefs metadata. Files the build installs itself (k3s, the signed NVIDIA
modules) get a fixed mtime so the clamp doesn't move them to a new layer on
every commit.

Measured in QEMU: the image is 129 layers, 1.33 GiB with zstd (was one 4G
layer; 1.75 GiB before stripping, below). An update after a full rebuild of a new commit (`make build
TREE_BUILD_FLAGS=--no-cache`, as CI does) downloaded 222 MiB: the UKI
(~92M, new digest every build), the initramfs (~74M, dracut is not
reproducible), rpmdb, hwdb, SELinux policy store and the rebuilt nvidia.ko.
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
(kernel, bootc, skopeo, WPE/cage/Mesa, NVIDIA, AMD/Realtek firmware, k3s
SELinux). Not removable: `flite` (WebKit speech synthesis) and `x265-libs`
(via libheif-freeworld); either takes `wpewebkit` with it. The rpmdb stays:
chunkah needs it for the layers, and scanners and `rpm -qf` need it.
Uncompressed tree: 3.9G → 2.9G. Different hardware (Wi-Fi, Intel) may need
some of these back.

`/etc` is machine-local and 3-way merged on upgrade (k3s config,
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
`make build` inside `quay.io/podman/stable` (a current podman, like local
builds; Ubuntu's podman is too old) via [`scripts/ci-build.sh`](scripts/ci-build.sh),
and fails if the db key turns up anywhere in the image.

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
The checkout action and the podman image are pinned by commit / digest
(bump them deliberately), since this job holds the key.

#### Where the db key is used

An image signed with the db key unlocks the TPM-sealed `state` volume, so the
key is mounted only in `--network=none` build steps of stages built from the
plain Fedora base, which run Fedora's tools and our scripts only:

| Stage | Signs | With |
|---|---|---|
| `nvidia-sign` | NVIDIA `.ko` files | kernel-devel's `sign-file` |
| `sdboot-sign` | systemd-boot | `systemd-sbsign` |
| `sealer` | the UKI | `bootc container ukify` (the sealer's own bootc, byte-identical to the target's) |

RPM Fusion's akmods build, the RPM Fusion / COPR / NVIDIA / k3s installs and
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

## Network install

`make installer` (after `make build`) writes `out/labhf-installer.efi`: one
Secure Boot signed UKI (~95 MiB) whose initrd is a complete small system
(Fedora minimal, systemd, networkd, podman; `Containerfile.installer`).
Copied to the target's ESP and picked in the boot menu, it boots from RAM,
brings up the network, pulls `labhf:latest` from a registry and runs the
image's own `labhf-install-disk`, as from a live USB. Nothing on the target
is touched before the disk prompt, and the pull is complete by then.

| | |
|---|---|
| Settings | Kernel command line, signed, set at build time: `INSTALLER_REGISTRY` (`host:port`, plain HTTP), `INSTALLER_NET` (`dhcp` or `static:ADDR/PREFIX,GATEWAY`), `INSTALLER_TARGET` (where the installed system updates from, e.g. `ghcr.io/<owner>/labhf:latest`). abi's SSH key is baked in; passwords are typed at install time |
| Registry | This PC: `make push`, then `make serve-install` (the registry read-only, so nobody on the LAN can push during the install; `make registry` makes it writable again). Plain HTTP is fine: a tampered image can't boot (signed UKI + composefs digest) |
| USB disks | The installer has no `usb-storage`/`uas` drivers: USB disks (e.g. a data array) are invisible to it. USB NICs and keyboards work |
| TPM | Signed with the same db key, so PCR 7 matches the installed system's policy. It extends PCR 15 at boot, which the policy requires to be zero: an installed disk can't be TPM-unlocked from the installer. No logins or shells either |
| RAM | Image (~3G) and podman's temporary copies live in RAM (tmpfs up to 90%): 8G is enough |
| Size | The build fails above 250 MiB (`INSTALLER_MAX_MB`): it has to fit in an existing ESP next to what is there |

`make vm-netinstall` does the same in QEMU with an empty `vm/disk.raw`, the
installer on a small FAT disk standing in for the target's ESP, and a USB
stick the installer must not see; all rootless. It refuses to replace an
installed `vm/disk.raw` unless `FORCE=1`. `labhf.vm-test=1` (VM builds only)
gives abi passwordless sudo, for `scripts/vm-check.sh`:
`ssh -p 2222 abi@localhost sudo bash -s < scripts/vm-check.sh`.

Verified in QEMU: Secure Boot boot of the installer, PCR 15 extended, DHCP,
pull, USB stick not listed, install, reboot into the installed system, and
`vm-check.sh` all passing on it.

## Installing on the real PC

`labhf-install-disk` **wipes the whole target disk** (ESP, root, state). Back up anything on it first, and unplug data disks you want to keep
so it can only see the target. Machine-specific notes (e.g. migrating an
existing install) belong in a git-ignored `MIGRATION.md`.

1. Back up `keys/`. Only `keys/db.key` + `keys/db.crt` are needed to build
   (CI secrets); keep `PK.key`/`KEK.key` offline.
2. Firmware: enable TPM 2.0. **Already using your own keys with sbctl?**
   Import them (below) and skip the key steps: the firmware keeps what is
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
7. k3s hostPaths outside `/media/*` need an SELinux label pods may use, e.g.
   `sudo semanage fcontext -a -t container_file_t '/home/abi/compose(/.*)?' && sudo restorecon -R /home/abi/compose`.

After a BIOS, GPU firmware or dbx update the TPM won't unlock: type the
LUKS passphrase, then rerun `labhf-enroll-tpm`.

## Hardening

| Area | What the image does |
|---|---|
| SSH | Keys only; `AllowUsers abi`, no root login, no agent/X11 forwarding or tunnels, `AllowTcpForwarding local` (for `ssh -L 6443`), `MaxAuthTries 3`; firewall limits new connections per source (burst 20, then 10/min) |
| Accounts | `root` and `gui` locked, `gui` has no shell; sudo asks for a password, `use_pty`, 5-minute timestamp; 5 failed passwords lock the account for 5 minutes (console, sudo) |
| Kernel | `lockdown=integrity`; `kptr_restrict`, `dmesg_restrict`, no unprivileged BPF, ptrace scope 1; `init_on_alloc`, `slab_nomerge`, `randomize_kstack_offset`, `vsyscall=none`; strict IOMMU, `efi=disable_early_pci_dma` |
| Boot | `rd.shell=0 rd.emergency=reboot`, debug shell and Ctrl-Alt-Del masked, no serial console |
| Modules | `firewire-*`, `thunderbolt`, `bluetooth`, rare protocols and filesystems can't load (`usr/lib/modprobe.d/60-labhf-unused.conf`) |
| Files | Setuid allow-list: only `sudo`, `passwd`, `unix_chkpwd`, `nvidia-modprobe`. `/home` is `nosuid,nodev`. No core dumps |
| k3s | Secrets encrypted, `protect-kernel-defaults`, API audit log (metadata only) in `/var/lib/rancher/k3s/server/logs/`. Pod Security warns and audits at `baseline` but doesn't enforce, because baseline forbids hostPath; enforce per namespace with `pod-security.kubernetes.io/enforce=baseline` |
| Kiosk | `NoNewPrivileges`, read-only system, private `/tmp`, restricted address families. Not `ProtectKernelTunables`, `ProtectKernelLogs` or `ProtectHostname`: each masks part of `/proc`, and WebKit's sandbox then can't mount its own |
| Audit | `auditd` logs changes to the machine-local `/etc` (accounts, sudo, SSH, systemd, k3s, SELinux) |

`kernel.panic_on_oops=1` and `kernel.panic=10` are required by
`protect-kernel-defaults`, so a kernel oops reboots the machine. With several
keys in an agent, use `IdentitiesOnly yes` or `MaxAuthTries 3` may reject you.
`/etc` and `/var` stay writable, so a root compromise can still persist there;
the sealed image only protects `/usr`.

Verified in QEMU: all of the above, except that QEMU has no IOMMU here (so the
DMA arguments are untested until real hardware) and the `rd.emergency=reboot`
path was not triggered.

## Open items / known risks

- **Split root/state is not an upstream-tested layout.** Verified in QEMU:
  `bootc switch` + reboot (staged finalize runs with `/sysroot/state` still
  mounted, `/etc` merged), `bootc rollback` both ways, TPM unlock across all
  of them, and the plain root's `state/` directory stays empty
  (`mount --bind /sysroot /run/x && ls -A /run/x/state`). Re-test after bootc
  updates.

- **NVIDIA module trust** (verified in QEMU): the kmod is signed with the db
  key, which the Fedora kernel loads into `.platform` and accepts for modules
  under lockdown=integrity. `modprobe nvidia` → "No NVIDIA GPU found" in the VM;
  no shim/MOK needed. Re-check on the real PC (`lsmod | grep nvidia`).
  Also verified with the split signing (akmods output unsigned, all 5 modules
  signed in `nvidia-sign`), and a `bootc switch` + ESP systemd-boot from
  `sdboot-sign` booting under Secure Boot with TPM unlock unchanged.
- **Fresh install** (verified in QEMU, 80G disk; then with a separate `public`
  partition, since folded into state): ESP 1G / root 40G / state; passphrase-only LUKS until `labhf-enroll-tpm`, then TPM2
  unlocks unattended with the passphrase slot kept. networkd DHCP from the
  image default, resolved stub DNS, boot ~14s. `labhf-setup-raid adopt` of an
  existing array; a pod with hostPaths `/media/data` and `/home/public`
  (→ `/media/public`) writes both, cluster DNS and egress work, SELinux
  enforcing, no AVCs. Without an NVIDIA GPU (the VM) `nvidia-cdi-refresh` and
  the `nvidia-device-plugin` pod fail; expected.
- **`/home/public` on state** (verified in QEMU, fresh install, 3 partitions):
  a pod with hostPaths `/media/public` (symlink) and `/media/data` writes
  both, new files are `container_file_t`, `abi` owns `/home/public`, no AVCs.
- **Firewall with k3s** (verified in QEMU): from an untrusted client (veth +
  netns) 22 and Traefik 80/443 open, 6443/10250 and pod / service IPs closed;
  pods keep cluster + external DNS, egress, the API server and metrics-server
  → kubelet; k3s's own rules unchanged by start, reload and stop; no AVCs.
  Right after boot Traefik's ports answer only once k3s has written its
  rules (as without the firewall).
- **k3s restarts once or twice at boot** when a NIC gets a SLAAC IPv6
  address after k3s has started: kube-proxy exits on a node IP change and
  systemd restarts k3s (~20s). Pin the address in
  `/etc/rancher/k3s/config.yaml` (`node-ip: <LAN IPv4>`) on a server.
- **Chunked + sealed** (verified in QEMU): `bootc switch`/`upgrade` to the
  chunkah image boots under Secure Boot (composefs digest computed after
  chunking matches), TPM unlock, signed modules load.
- **QEMU TPM** needs Fedora's 4M OVMF (qcow2). The 2M raw build has no TPM:
  every PCR stays zero and `bootctl status` says "firmware unavailable".
- **WPE WebKit** comes from the unofficial COPR `philn/wpewebkit` (retired from
  Fedora). Fallback: `webkitgtk6.0`/epiphany or chromium `--kiosk`.
- **Dashboard GPU**: `labhf-gui` is tested in QEMU only (virtio fallback,
  rotation). On the real PC check `journalctl -b -u gui.service | grep labhf-gui:`
  says `amdgpu` and the HDMI output name matches `GUI_OUTPUT` (`wlr-randr`
  lists outputs). The integrated GPU must stay enabled in the firmware when
  the NVIDIA card is installed (often "iGPU multi-monitor" / "IGD").
  See [Dashboard settings](#dashboard-settings-etclabhfguienv).
- Sealed images are Tech Preview upstream; composefs has no boot counting /
  automatic rollback yet.
- Kernel args are fixed in the signed UKI; change them in
  `rootfs/usr/lib/bootc/kargs.d/` and rebuild.

## License

Copyright (C) 2026 Abi Hafshin. Licensed under the GNU General Public License
v3.0 or later ([LICENSE](LICENSE), `SPDX-License-Identifier: GPL-3.0-or-later`).
This covers the files in this repository. The built image also contains Fedora,
RPM Fusion, NVIDIA, k3s and other packages under their own licenses (an
aggregate in GPL-3.0 terms); publishing the image means meeting those licenses
too (e.g. corresponding source for GPL packages, NVIDIA's driver license).
