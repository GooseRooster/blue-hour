set shell := ["bash", "-uc"]

# Flavours live in recipes/<flavour>.yml. Override with e.g. `just build gaming`.
default_flavour := "workstation"

# Secure Boot: the blue-build base signs the kernel/modules with its own MOK key
# (not Fedora's). The ISO installer enrolls it; enter this password at the shim
# MOK manager on first boot. See README.md ("Secure Boot").
secure_boot_url := "https://github.com/blue-build/base-images/raw/main/files/base/etc/pki/akmods/certs/akmods-blue-build.der"
enrollment_password := "bluebuild"

# bootc-image-builder: builds disk/ISO images directly from a local bootc
# container image (no registry needed). Used by `just disk`.
bib_image := "quay.io/centos-bootc/bootc-image-builder:latest"

# build-container-installer: the third-party ISO builder that BlueBuild's
# `generate-iso` wraps. `iso-direct` calls it directly. Pinned to the tag
# bluebuild itself uses (utils/src/constants.rs: JASONN3_INSTALLER_IMAGE).
installer_image := "ghcr.io/jasonn3/build-container-installer:v1.5.0"

# Fedora release of the installer runtime for `iso-direct`. bluebuild resolves
# this from the image's VERSION_ID; we pass it explicitly (the builder's own
# default is a stale F39). Keep in sync with the base image (image-version:
# latest -> currently Fedora 44).
iso_version := "44"

# List available tasks.
default:
    @just --list

# Print the generated Containerfile for a flavour (to stdout).
containerfile flavour=default_flavour:
    bluebuild generate recipes/{{flavour}}.yml

# Print the fully-resolved recipe with all from-file includes expanded.
recipe-dump flavour=default_flavour:
    bluebuild generate --display-full-recipe recipes/{{flavour}}.yml

# Build a flavour image locally (rootless podman storage).
build flavour=default_flavour:
    bluebuild build recipes/{{flavour}}.yml

# Needed because bootc-image-builder runs rootful and only sees
# /var/lib/containers/storage.

# Build a flavour image into rootful podman storage.
build-root flavour=default_flavour:
    sudo "$(command -v bluebuild)" build recipes/{{flavour}}.yml

# The reliable local alternative to the broken `generate-iso recipe` path;
# see docs/testing.md.

# Build a bootable QCOW2 from the local image (run `just build-root` first).
disk flavour=default_flavour:
    mkdir -p output
    sudo podman run --rm -it --privileged --pull=newer \
        --security-opt label=type:unconfined_t \
        -v ./bib/config.toml:/config.toml:ro \
        -v ./output:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        {{bib_image}} \
        --type qcow2 --use-librepo=True --rootfs btrfs \
        --config /config.toml \
        localhost/blue-hour-{{flavour}}:latest

# Extra QEMU args may be appended, e.g. `just vm-disk workstation -nographic`.

# Boot the QCOW2 from `just disk` in QEMU/KVM.
vm-disk flavour=default_flavour *args:
    qemu-system-x86_64 \
        -enable-kvm -m 8192 -smp 4 -cpu host \
        -machine q35,accel=kvm \
        -device virtio-vga-gl -display gtk,gl=on \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
        -drive file=output/qcow2/disk.qcow2,if=virtio,format=qcow2 {{args}}

# Build the offline ISO from a *published* image, embedding the Secure Boot key.
# The local `recipe` form is broken in bluebuild (the locally built oci-archive
# is written with a `_linux_amd64` platform suffix while the installer is told
# the unsuffixed name -> "archive file not found"); use `just disk` for local
# testing. `generate-iso` runs the installer container privileged, so run the
# CLI as your user but pre-authenticate sudo first (the `sudo -v` prompts in
# your terminal; bluebuild's internal `sudo podman` then uses the cached
# timestamp and no root-owned files land in the repo).
#
# The ISO pre-creates no user and sets no root password: account setup is
# Anaconda's job. Of the variants the CLI allows, only `server` shows the
# account spokes -- but it forces XFS-on-LVM. `kinoite`/`silverblue` hide the
# spokes and defer to a first-boot initial-setup this image doesn't ship, which
# leaves a locked root-only system. For a generic profile (spokes + Btrfs), use
# `just iso-direct` instead.

# Build the offline ISO from a published image.
iso flavour=default_flavour variant="server":
    sudo -v
    bluebuild generate-iso \
        --iso-name blue-hour-{{flavour}}.iso \
        --variant {{variant}} \
        --secure-boot-url {{secure_boot_url}} \
        --enrollment-password {{enrollment_password}} \
        image ghcr.io/gooserooster/blue-hour-{{flavour}}:latest

# Build the offline ISO by invoking build-container-installer directly instead
# of through `bluebuild generate-iso`. This exposes the knobs the CLI hides:
#   * an explicit VERSION for the installer runtime (bluebuild auto-detects it
#     from the image; the builder's own default is a stale F39);
#   * an empty VARIANT, which the CLI cannot express (it only allows
#     kinoite/silverblue/server). The builder's own default is Server.
# An empty VARIANT makes lorax install plain `fedora-release`, so Anaconda picks
# the generic `fedora` profile: base Fedora theme, visible User/Root spokes and
# Btrfs (zstd:1) by default. Server shows the spokes but forces XFS-on-LVM;
# kinoite/silverblue hide the spokes (deferred to a first-boot initial-setup
# this image doesn't ship). Pass a variant to override, e.g.
#   just iso-direct workstation server
# Extra make variables may be appended, e.g.
#   just iso-direct workstation "" 44 WEB_UI=true
#
# The output ISO is removed first: xorriso refuses to reuse a non-empty outdev,
# and a previous `just iso` leaves a root-owned ISO at the same path.
#
# Build the offline ISO directly (generic Fedora profile: spokes + Btrfs).
iso-direct flavour=default_flavour variant="" version=iso_version *extra:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -f "$PWD/blue-hour-{{flavour}}.iso" "$PWD/blue-hour-{{flavour}}.iso-CHECKSUM"
    sudo -v
    args=(
        ISO_NAME=build/blue-hour-{{flavour}}.iso
        DNF_CACHE=/cache/dnf
        SECURE_BOOT_KEY_URL={{secure_boot_url}}
        ENROLLMENT_PASSWORD={{enrollment_password}}
        IMAGE_REPO=ghcr.io/gooserooster
        IMAGE_NAME=blue-hour-{{flavour}}
        IMAGE_TAG=latest
        VERSION={{version}}
    )
    # The builder expands `-t $(VARIANT)` unquoted, so a truly empty value
    # leaves `-t` with no argument and breaks lorax. Pass the two literal quotes
    # instead: the shell hands lorax a real empty argument, selecting the
    # generic profile.
    if [ -n "{{variant}}" ]; then
        args+=(VARIANT={{variant}})
    else
        args+=("VARIANT=''")
    fi
    sudo podman run --rm -it --privileged --pull=always \
        --security-opt label=type:unconfined_t \
        -v "$PWD:/build-container-installer/build" -v dnf-cache:/cache/dnf \
        {{installer_image}} \
        "${args[@]}" {{extra}}

# Remove stale root-owned bluebuild artifacts left by an aborted root run.
clean:
    sudo rm -rf .bluebuild-scripts_

# Boot an ISO in QEMU/KVM (UEFI, virtio-gpu, software GL fallback). Extra QEMU
# args may be appended after the ISO name, e.g. `just vm my.iso -nographic`.

# Boot an ISO in QEMU/KVM.
vm iso="blue-hour-workstation.iso" *args:
    qemu-system-x86_64 \
        -enable-kvm -m 8192 -smp 4 -cpu host \
        -machine q35,accel=kvm \
        -device virtio-vga-gl -display gtk,gl=on \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
        -cdrom {{iso}} -boot d {{args}}
