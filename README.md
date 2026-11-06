# labhf

Immutable, sealed homelab OS built with [bootc](https://bootc.dev) on Fedora.

| Requirement | How |
|---|---|
| Atomic updates | bootc **composefs backend**, images pulled from an OCI registry, `bootc upgrade` / `rollback` |
| Upstream binaries | Fedora bootc base + Fedora / RPM Fusion / NVIDIA / Rancher / COPR RPMs. Only compile: NVIDIA open kmod via akmods |
| Sealed boot, own keys | Secure Boot (own PK/KEK/db) → signed systemd-boot → signed **UKI** whose cmdline carries the composefs digest → fs-verity on every file |
| Encrypted state | root partition is **plain** (image only, fs-verity checked); bootc's `/state` (= `/etc`, `/var`, `/home`) is a separate LUKS2 partition mounted at `/sysroot/state` in the initrd; TPM2 policy PCR 0+2+3+5+7, PCR 15 = 0 |
| RAID5 | `mdadm` → ext4 at `/srv/data`, unencrypted (public data), mounted `nofail,nodev,nosuid,noexec` |
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
scripts/               host scripts (keys, OVMF vars, QEMU)
keys/                  Secure Boot keys (git-ignored, back them up!)
vm/                    QEMU disks, firmware vars, swtpm state (git-ignored)
```

## Build and test in QEMU

Host needs `podman`, `qemu`, `swtpm`, `make` (`sudo pacman -S podman` on Arch/CachyOS).

```bash
make tools        # helper container
make keys         # once; keys/db.key is the crown jewel
make build        # -> localhost/labhf:latest
make vm-install   # vm/disk.raw: ESP + root + LUKS state; asks LUKS + abi passwords, prints the RECOVERY KEY
make vm-run       # Secure Boot + swtpm; type the temporary passphrase
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
labhf-setup-raid /dev/vdb /dev/vdc /dev/vdd   # RAID5 test
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

## Disk layout

```
p1 ESP    vfat 1G      signed systemd-boot + signed UKIs
p2 root   ext4 40G     PLAIN: /composefs (image objects), /state = mount point
p3 state  LUKS2 ext4   deploy/<id>/etc, os/default/var  -> /etc, /var, /home
```

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

Deploying a new image or fixing `/etc` needs `state` unlocked (recovery key):
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

## Installing on the real PC

1. Back up `keys/`. Only `keys/db.key` + `keys/db.crt` are needed to build
   (store them as CI secrets later); keep `PK.key`/`KEK.key` offline.
2. Firmware: enable TPM 2.0, **clear Secure Boot keys / enter Setup Mode**.
3. Boot any live Linux with podman (e.g. Fedora live), then:
   ```bash
   sudo podman pull <registry>/labhf:latest
   sudo podman run --rm -it --privileged --pid=host --ipc=host \
     --security-opt label=type:unconfined_t \
     -v /var/lib/containers:/var/lib/containers -v /dev:/dev \
     -e LABHF_IMAGE=<registry>/labhf:latest \
     -e LABHF_SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" \
     <registry>/labhf:latest labhf-install-disk /dev/nvme0n1
   ```
4. Reboot. systemd-boot offers **"Enroll Secure Boot keys: labhf"**
   (`secure-boot-enroll manual`); pick it. The db includes Microsoft UEFI CA
   2011/2023 so the GPU option ROM still loads — don't drop them unless you
   know your GPU/NIC firmware is not MS-signed (no picture otherwise).
5. Boot, type the temporary passphrase, run `labhf-enroll-tpm --wipe-password`.
6. `labhf-setup-raid /dev/sda /dev/sdb /dev/sdc`.

After a BIOS, GPU firmware or dbx update the TPM won't unlock: use the
recovery key, then rerun `labhf-enroll-tpm`.

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
