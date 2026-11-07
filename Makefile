# SPDX-License-Identifier: GPL-3.0-or-later
# labhf — build, test in QEMU, install.
# Host needs: podman (rootful via sudo), qemu, swtpm, make.

PODMAN      ?= sudo podman
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
# e.g. --no-cache: rebuild everything, as CI does on a fresh runner
TREE_BUILD_FLAGS ?=

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
SSH_PUBKEY  ?= $(shell cat $(firstword $(wildcard $(HOME)/.ssh/id_ed25519.pub $(HOME)/.ssh/id_ecdsa.pub $(HOME)/.ssh/id_rsa.pub)) 2>/dev/null)

TOOLS_RUN = $(PODMAN) run --rm -u $(shell id -u):$(shell id -g) \
            --security-opt label=disable -v $(CURDIR):/work -w /work $(TOOLS_IMAGE)

.PHONY: help tools keys import-sbctl build lint vm-vars vm-install vm-run vm-ssh vm-clean clean clean-cache registry push

help:
	@echo "make tools       build helper container (openssl, sbsigntools, virt-fw-vars)"
	@echo "make keys        generate Secure Boot keys into ./keys (once!)"
	@echo "make import-sbctl  or: use an existing sbctl key set (keys/sbctl-keys.tgz)"
	@echo "make build       build the sealed image $(IMAGE)"
	@echo "make vm-vars     OVMF vars with our keys enrolled"
	@echo "make vm-install  install image to vm/disk.raw (LUKS root)"
	@echo "make vm-run      boot it (swtpm, Secure Boot); ssh: make vm-ssh"
	@echo "make registry push  serve the image to the VM at $(VM_REGISTRY)/labhf:latest"

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
	  --security-opt label=disable \
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
registry:
	$(PODMAN) container exists labhf-registry || \
	  $(PODMAN) run -d --name labhf-registry -p 5000:5000 \
	    -v labhf-registry:/var/lib/registry docker.io/library/registry:2
	$(PODMAN) start labhf-registry

push: registry
	$(PODMAN) push --tls-verify=false $(PUSH_ARGS) $(IMAGE) docker://$(REGISTRY)/labhf:latest
