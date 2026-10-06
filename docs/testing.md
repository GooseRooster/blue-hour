# Testing blue-hour

How to build, boot and smoke-test the image locally. The golden rule: **recipe
changes are verified in the VM before merge**, not just by a successful build.

## 0. Enter the dev shell

```sh
nix develop
just            # list tasks
```

Local builds need a container engine. On NixOS:
`virtualisation.podman.enable = true`.

## 1. Validate a recipe (fast, no build)

```sh
bluebuild generate recipes/workstation.yml >/dev/null
bluebuild generate --display-full-recipe recipes/gaming.yml | less
```

This catches YAML errors, bad module config and broken `from-file` includes.
CI runs it on every PR.

## 2. Build the image locally

```sh
bluebuild build recipes/workstation.yml
# or: just build workstation
```

## 3. Generate an offline ISO from the local recipe

```sh
bluebuild generate-iso --iso-name blue-hour-workstation.iso recipe recipes/workstation.yml
# or: just iso workstation
```

Use `recipe` (not `image`) so you are testing the working tree, not a published
build.

## 4. Boot it in QEMU/KVM

```sh
just vm blue-hour-workstation.iso
```

Equivalent:

```sh
qemu-system-x86_64 \
  -enable-kvm -m 8192 -smp 4 -cpu host \
  -machine q35,accel=kvm \
  -device virtio-vga-gl -display gtk,gl=on \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  -cdrom blue-hour-workstation.iso -boot d
```

Notes:

- **Secure Boot:** the ISO embeds BlueBuild's MOK key and enrolls it at install.
  At the first boot, select **Enroll MOK** in the shim manager and enter
  `bluebuild`. To test enforced SB in QEMU, use OVMF with Secure Boot on;
  otherwise disable SB in the VM firmware for a simpler boot. See the README's
  Secure Boot section.
- Use OVMF (`/usr/share/OVMF/OVMF_CODE.fd` + a writable `OVMF_VARS.fd` copy) if
  you need to exercise UEFI/Secure Boot paths.
- The VM **cannot** validate HDR, VRR, or GPU-specific behaviour (VRR/HDR,
  LACT/overdrive, hardware encode). Those need the real host.
- Give the VM 8–16 GiB and a 40+ GiB disk for install/rebase tests.

## 5. Per-flavour smoke checklist

Boot the ISO, install, then log in and check:

- [ ] Boot reaches Ly; login as the installer-created user.
- [ ] Sway starts; `sway --version` is the expected upstream version.
- [ ] Noctalia shell appears (bar, launcher, OSD).
- [ ] Audio works (PipeWire): `pactl info`, play a sound.
- [ ] Portals: screen-share chooser works from a browser.
- [ ] Keyring unlocks at login; `secret-tool` round-trips.
- [ ] Flatpaks: a baseline app launches; `flatpak list` is sane.
- [ ] Nix: `nix run nixpkgs#hello` works.
- [ ] Home Manager: `home-manager switch --flake <dotfiles>#<user>` succeeds.
- [ ] Homebrew: `brew install <small formula>` works.
- [ ] `topgrade --dry-run` finds the expected managers.
- [ ] Gaming only: Steam launches; a Proton game starts; `game-performance`
      switches TuneD and restores it; GSR records a clip.

## 6. Update / rollback / persistence

```sh
# On the booted image:
sudo bootc upgrade            # stage an update
sudo bootc status             # confirm a staged deployment
sudo systemctl reboot         # apply
# After reboot: verify /nix/store still resolves and a Nix command works.
sudo bootc rollback           # if the new deployment is bad
```

Also confirm the "updates staged — reboot to apply" notification fires after a
staged update.

## 7. Signing

```sh
cosign verify --key cosign.pub ghcr.io/gooserooster/blue-hour-workstation
```

## 8. CI

The GitHub Action builds each recipe in the matrix (`.github/workflows/build.yml`)
on push and daily. Pull requests get preview-tagged images; a failed
`bluebuild generate` fails the run.

## Reporting a good/bad build

Record the image digest, the Fedora base version, and the recipe flavour when
filing an issue, plus the `ausearch -m avc -ts recent` output for SELinux
problems (Ly, Nix).
