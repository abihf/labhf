# SPDX-License-Identifier: GPL-3.0-or-later
# labhf — build, test in QEMU, install.
# Host needs: podman, qemu, swtpm, make. Builds are rootless; only writing a
# disk (vm-install) uses sudo.

PODMAN      ?= podman
IMAGE       ?= localhost/labhf:latest
TOOLS_IMAGE ?= localhost/labhf-tools:latest
# throwaway local registry so the VM can `bootc switch/upgrade` (QEMU host = 10.0.2.2)
REGISTRY    ?= localhost:5000
VM_REGISTRY ?= 10.0.2.2:5000
FEDORA      ?= 45
# extra `podman build` flags for the final (sealed) image, e.g. --label ... (CI)
BUILD_ARGS  ?=
# chunkah splits the flat tree into content-based layers (pinned by digest)
CHUNKAH_IMAGE ?= quay.io/coreos/chunkah:v0.7.1@sha256:71e593421c5de7dcc7c8c5c50e98d3bac572055a76f399f61a491d123c20a523
TREE_IMAGE    ?= localhost/labhf-tree:build
CHUNKED_IMAGE ?= localhost/labhf-chunked:build
# mtimes newer than this are clamped, so a rebuild of the same commit gives
# the same layers (generated files would otherwise change every build)
SOURCE_DATE_EPOCH ?= $(shell git log -1 --format=%ct 2>/dev/null || date +%s)
PUSH_ARGS   ?= --compression-format zstd
# 1: add console=ttyS0 (boot log + passphrase prompt on the serial console),
# for debugging in QEMU. Off in the image that ships.
SERIAL_CONSOLE ?= 0
# e.g. --no-cache: rebuild everything, as CI does on a fresh runner
TREE_BUILD_FLAGS ?=

# network installer UKI (make installer). Defaults: the QEMU VM.
#   real PC: INSTALLER_REGISTRY=<this PC>:5000 INSTALLER_NET=static:ADDR/24,GW[,DNS]
#            (static: also written into the installed system)
#            INSTALLER_TARGET=ghcr.io/<owner>/labhf:latest
INSTALLER_REGISTRY ?= $(VM_REGISTRY)
INSTALLER_TARGET   ?= $(INSTALLER_REGISTRY)/labhf:latest
INSTALLER_NET      ?= dhcp
INSTALLER_EXTRA    ?=
INSTALLER_CMDLINE   = rdinit=/usr/lib/systemd/systemd console=tty0 selinux=0 audit=0 \
                      systemd.firstboot=off labhf.registry=$(INSTALLER_REGISTRY) \
                      labhf.target-imgref=$(INSTALLER_TARGET) labhf.net=$(INSTALLER_NET) \
                      $(INSTALLER_EXTRA)
OUT         ?= out
DISK_SIZE   ?= 80G

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
SSH_PUBKEY  ?= $(shell cat $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_ecdsa.pub $(HOME)/.ssh/id_rsa.pub)) 2>/dev/null)

# files written to ./keys and ./vm must belong to the invoking user
ifeq ($(findstring sudo,$(PODMAN)),sudo)
TOOLS_USER = -u $(shell id -u):$(shell id -g)
else
TOOLS_USER = --userns=keep-id
endif
# keys/ may be a symlink to a private directory: resolve it, and mount it at
# its real path so the link inside /work points somewhere
KEYS_DIR  = $(realpath keys)
TOOLS_RUN = $(PODMAN) run --rm $(TOOLS_USER) \
            --security-opt label=disable -v $(CURDIR):/work -w /work \
            $(if $(KEYS_DIR),-v $(KEYS_DIR):$(KEYS_DIR)) $(TOOLS_IMAGE)

.PHONY: help tools keys import-sbctl installer vm-netinstall serve-install build lint vm-vars vm-install vm-run vm-ssh vm-clean clean clean-cache registry push

help:
	@echo "make tools       build helper container (openssl, sbsigntools, virt-fw-vars)"
	@echo "make keys        generate Secure Boot keys into ./keys (once!)"
	@echo "make import-sbctl  or: use an existing sbctl key set (keys/sbctl-keys.tgz)"
	@echo "make build       build the sealed image $(IMAGE)"
	@echo "make vm-vars     OVMF vars with our keys enrolled"
	@echo "make vm-install  install image to vm/disk.raw (LUKS root)"
	@echo "make vm-run      boot it (swtpm, Secure Boot); ssh: make vm-ssh"
	@echo "make registry push  serve the image to the VM at $(VM_REGISTRY)/labhf:latest"
	@echo "make installer  network installer UKI -> $(OUT)/labhf-installer.efi (after make build)"
	@echo "make vm-netinstall  fresh VM disk, installed by the installer UKI (no sudo)"
	@echo "make serve-install  registry read-only for an install over the LAN"

tools:
	$(PODMAN) build --build-arg FEDORA=$(FEDORA) -t $(TOOLS_IMAGE) -f Containerfile.tools .

keys/db.key:
	mkdir -p keys
	$(TOOLS_RUN) bash /work/scripts/gen-keys.sh

keys: keys/db.key

# use an existing sbctl key set (see scripts/import-sbctl.sh) instead of `make keys`
import-sbctl:
	$(TOOLS_RUN) bash /work/scripts/import-sbctl.sh

SIGN_ARGS = --secret id=sb_key,src=keys/db.key --secret id=sb_cert,src=keys/db.crt \
            --build-arg SB_CERT_SHA256=$$(sha256sum < keys/db.crt | cut -c1-64)

# 1. flat tree (packages, signed modules + systemd-boot)
# 2. chunkah: content-based layers; no network, no keys, only the tree mounted.
#    /sysroot/ is emptied: the base image's ostree repo (2G) is unused with composefs
# 3. seal: composefs digest + signed UKI over the chunked layers
build: keys/db.key
	$(PODMAN) build --build-arg FEDORA=$(FEDORA) $(SIGN_ARGS) \
	  --build-arg SERIAL_CONSOLE=$(SERIAL_CONSOLE) \
	  --security-opt label=disable \
	  --build-context keys=$(KEYS_DIR) \
	  $(TREE_BUILD_FLAGS) --target tree -t $(TREE_IMAGE) -f Containerfile .
	$(PODMAN) run --rm --network=none --security-opt label=disable \
	  --mount=type=image,src=$(TREE_IMAGE),dest=/chunkah \
	  -e SOURCE_DATE_EPOCH=$(SOURCE_DATE_EPOCH) \
	  $(CHUNKAH_IMAGE) build --max-layers 128 --prune /sysroot/ -t $(CHUNKED_IMAGE) \
	  | $(PODMAN) load
	$(PODMAN) build --build-arg FEDORA=$(FEDORA) $(SIGN_ARGS) \
	  --build-arg CHUNKED=$(CHUNKED_IMAGE) \
	  --security-opt label=disable \
	  $(BUILD_ARGS) \
	  -t $(IMAGE) -f Containerfile.seal .
	@echo "layers: $$($(PODMAN) inspect --format '{{len .RootFS.Layers}}' $(IMAGE))"

vm/OVMF_VARS.qcow2: keys/db.key
	mkdir -p vm
	$(TOOLS_RUN) bash /work/scripts/ovmf-vars.sh

vm-vars: vm/OVMF_VARS.qcow2

vm-install: vm/OVMF_VARS.qcow2
	# the installer reads root's image store; the build is in ours
	$(PODMAN) save --format oci-archive $(IMAGE) | sudo podman load
	sudo PODMAN=podman IMAGE=$(IMAGE) SSH_PUBKEY="$(SSH_PUBKEY)" \
	  LUKS_PASSWORD="$(LUKS_PASSWORD)" ABI_PASSWORD="$(ABI_PASSWORD)" scripts/vm-install.sh

vm-run:
	scripts/vm-run.sh

vm-ssh:
	ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null abi@localhost

# fresh firmware vars + TPM (as if new hardware)
vm-clean:
	rm -rf vm/tpm vm/OVMF_VARS.qcow2 vm/OVMF_CODE.secboot.* vm/raid*.qcow2

clean: vm-clean
	rm -f vm/disk.raw

# drop the shared dnf download cache (RUN --mount=type=cache)
clean-cache:
	$(PODMAN) system prune --build -f

# plain-HTTP registry on the host; the VM pulls from $(VM_REGISTRY)
# writable: for `make push` (recreated, so it is never left read-only)
registry:
	$(PODMAN) rm -f labhf-registry >/dev/null
	$(PODMAN) run -d --name labhf-registry -p 5000:5000 \
	  -v labhf-registry:/var/lib/registry docker.io/library/registry:2

# read-only while another machine installs from it over the LAN: plain HTTP
# and no auth, so nobody else can push. `make registry` makes it writable again.
serve-install:
	$(PODMAN) rm -f labhf-registry >/dev/null
	$(PODMAN) run -d --name labhf-registry -p 5000:5000 \
	  -e REGISTRY_STORAGE_MAINTENANCE_READONLY='{"enabled":true}' \
	  -v labhf-registry:/var/lib/registry docker.io/library/registry:2
	@echo "serving read-only: $$(hostname -I | cut -d' ' -f1):5000/labhf:latest"

# Secure Boot signed network installer (Containerfile.installer). Uses the
# tree from `make build`. No secrets inside: passwords are typed at install.
installer: keys/db.key
	mkdir -p $(OUT)/installer-ctx
	printf '%s\n' "$(SSH_PUBKEY)" > $(OUT)/installer-ctx/ssh.pub
	$(PODMAN) build --build-arg FEDORA=$(FEDORA) $(SIGN_ARGS) \
	  --build-arg TREE=$(TREE_IMAGE) \
	  --build-arg INSTALLER_CMDLINE="$(strip $(INSTALLER_CMDLINE))" \
	  --build-context installer=$(OUT)/installer-ctx \
	  --security-opt label=disable \
	  --target output -o type=local,dest=$(OUT) -f Containerfile.installer .
	@ls -lh $(OUT)/labhf-installer.efi

# a small FAT disk with the installer as the removable-media boot path,
# standing in for the target's existing ESP (mtools: no loop device)
vm/installer-esp.img: $(OUT)/labhf-installer.efi
	$(TOOLS_RUN) sh -c 'rm -f $@ && mkfs.vfat -C -n LABHFINST $@ 307200 >/dev/null && \
	  mmd -i $@ ::/EFI ::/EFI/BOOT && mcopy -i $@ $< ::/EFI/BOOT/BOOTX64.EFI && mdir -i $@ ::/EFI/BOOT'

# fresh VM install through the installer UKI, all without sudo:
#   make build push && make installer INSTALLER_EXTRA="console=ttyS0,115200 labhf.vm-test=1" && make vm-netinstall
# Replaces vm/disk.raw: refuses if it already holds an installed system,
# unless FORCE=1.
vm-netinstall: vm/OVMF_VARS.qcow2 vm/installer-esp.img
	@if [ -s vm/disk.raw ] && [ "$(FORCE)" != 1 ] && sfdisk -d vm/disk.raw >/dev/null 2>&1; then \
	  echo "vm/disk.raw has a partition table (an installed VM). make vm-netinstall FORCE=1 to replace it."; exit 1; fi
	rm -f vm/disk.raw && truncate -s $(DISK_SIZE) vm/disk.raw
	VM_INSTALLER=1 VM_MEM=8G scripts/vm-run.sh

push: registry
	$(PODMAN) push --tls-verify=false $(PUSH_ARGS) $(IMAGE) docker://$(REGISTRY)/labhf:latest
