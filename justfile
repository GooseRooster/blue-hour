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

# Anaconda overrides injected by `iso-direct`. See the file's header.
iso_template := "iso/blue-hour-anaconda.tmpl"

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
# Anaconda's job. The variant controls when it happens -- `server` (default)
# and `kinoite` ask at install time, while `silverblue` defers to first boot,
# which never runs on this image (no initial-setup/GNOME) and leaves a locked
# root-only system. Override with `just iso <flavour> <variant>`.

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
#   * any installer VARIANT (the CLI only allows kinoite/silverblue/server);
#   * ADDITIONAL_TEMPLATES, used here to inject iso/blue-hour-anaconda.tmpl.
# That template forces the base Fedora installer theme and always shows the
# User/Root spokes, so account setup happens at install time regardless of the
# variant's Anaconda profile. Requires a *published* image (image mode), same
# as `just iso`. Extra make variables may be appended, e.g.
#   just iso-direct workstation "" 44 iso/blue-hour-anaconda.tmpl WEB_UI=true
#
# By default no VARIANT is passed: the builder uses its own default (Server),
# and the injected template overrides that profile's theme and storage, so the
# result is the base Fedora look on Btrfs regardless. Pass a variant to override
# (e.g. `just iso-direct workstation kinoite`).
#
# Build the offline ISO directly (base Fedora installer theme + account spokes).
iso-direct flavour=default_flavour variant="" version=iso_version template=iso_template *extra:
    #!/usr/bin/env bash
    set -euo pipefail
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
    # Pass VARIANT only when set; otherwise the builder's default (Server)
    # applies and the injected template normalises theme/storage/spokes.
    if [ -n "{{variant}}" ]; then
        args+=(VARIANT={{variant}})
    fi
    mounts=(-v "$PWD:/build-container-installer/build" -v dnf-cache:/cache/dnf)
    if [ -n "{{template}}" ]; then
        mounts+=(-v "$PWD/{{template}}:/blue-hour-anaconda.tmpl:ro")
        args+=(ADDITIONAL_TEMPLATES=/blue-hour-anaconda.tmpl)
    fi
    sudo podman run --rm -it --privileged --pull=always \
        --security-opt label=type:unconfined_t \
        "${mounts[@]}" \
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
