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
Containerfile          image build (multi-stage, see header)
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

```bash
make tools        # helper container
make keys         # once; keys/db.key is the crown jewel
make build        # -> localhost/labhf:latest
make vm-install   # vm/disk.raw: ESP + root + LUKS state; asks LUKS + abi passwords
make vm-run       # Secure Boot + swtpm; type the LUKS passphrase
make vm-ssh       # ssh abi@localhost -p 2222
```

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

## Installing on the real PC

`labhf-install-disk` **wipes the whole target disk** (ESP, root, state). Back up anything on it first, and unplug data disks you want to keep
so it can only see the target. Machine-specific notes (e.g. migrating an
existing install) belong in a git-ignored `MIGRATION.md`.

1. Back up `keys/`. Only `keys/db.key` + `keys/db.crt` are needed to build
   (CI secrets); keep `PK.key`/`KEK.key` offline.
2. Firmware: enable TPM 2.0, **clear the Secure Boot keys / enter Setup Mode**.
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
4. Reboot. systemd-boot offers **"Enroll Secure Boot keys: labhf"**
   (`secure-boot-enroll manual`); pick it. The db includes Microsoft UEFI CA
   2011/2023 so the GPU option ROM still loads — don't drop them unless you
   know your GPU/NIC firmware is not MS-signed (no picture otherwise).
5. Boot, type the LUKS passphrase, run `labhf-enroll-tpm`. The passphrase
   stays as the only fallback (there is no recovery key), so make it strong.
6. Data array: `sudo labhf-setup-raid adopt` for an existing mdadm array (no
   data is changed), or `sudo labhf-setup-raid create DISK DISK DISK...` for a
   new one (destroys the disks).
7. k3s hostPaths outside `/media/*` need an SELinux label pods may use, e.g.
   `sudo semanage fcontext -a -t container_file_t '/home/abi/compose(/.*)?' && sudo restorecon -R /home/abi/compose`.

After a BIOS, GPU firmware or dbx update the TPM won't unlock: type the
LUKS passphrase, then rerun `labhf-enroll-tpm`.

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
