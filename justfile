set shell := ["bash", "-uc"]

# Flavours live in recipes/<flavour>.yml. Override with e.g. `just build gaming`.
default_flavour := "workstation"

# Secure Boot: the blue-build base signs the kernel/modules with its own MOK key
# (not Fedora's). The ISO installer enrolls it; enter this password at the shim
# MOK manager on first boot. See README.md ("Secure Boot").
secure_boot_url := "https://github.com/blue-build/base-images/raw/main/files/base/etc/pki/akmods/certs/akmods-blue-build.der"
enrollment_password := "bluebuild"

# List available tasks.
default:
    @just --list

# Print the generated Containerfile for a flavour (to stdout).
containerfile flavour=default_flavour:
    bluebuild generate recipes/{{flavour}}.yml

# Print the fully-resolved recipe with all from-file includes expanded.
recipe-dump flavour=default_flavour:
    bluebuild generate --display-full-recipe recipes/{{flavour}}.yml

# Build a flavour image locally with podman/buildah.
build flavour=default_flavour:
    bluebuild build recipes/{{flavour}}.yml

# Build an offline ISO from a flavour recipe (embeds the Secure Boot key).
iso flavour=default_flavour:
    bluebuild generate-iso \
        --iso-name blue-hour-{{flavour}}.iso \
        --secure-boot-url {{secure_boot_url}} \
        --enrollment-password {{enrollment_password}} \
        recipe recipes/{{flavour}}.yml

# Boot an ISO in QEMU/KVM (UEFI, virtio-gpu, software GL fallback).
# Pass extra QEMU args after the ISO name, e.g. `just vm my.iso -nographic`.
vm iso="blue-hour-workstation.iso" *args:
    qemu-system-x86_64 \
        -enable-kvm -m 8192 -smp 4 -cpu host \
        -machine q35,accel=kvm \
        -device virtio-vga-gl -display gtk,gl=on \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
        -cdrom {{iso}} -boot d {{args}}
