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

This builds rootless into your user's podman storage.

## 3. Boot it in a VM (recommended local path)

BlueBuild's `generate-iso recipe` (local tarball) path is currently broken: it
writes the locally built image as `blue-hour-<flavour>.tar_linux_amd64.gz`
(a platform suffix from `Platform::tagged_path`) but tells the installer to read
the unsuffixed `blue-hour-<flavour>.tar.gz`, so `skopeo` fails with
`archive file not found`. Build a disk image directly from the local container
image with `bootc-image-builder` instead:

```sh
just build-root workstation   # build into rootful podman storage (bib needs it)
just disk workstation         # -> output/qcow2/disk.qcow2
just vm-disk workstation      # boot it in QEMU/KVM
```

`bib/config.toml` injects a throwaway `bluehour`/`bluehour` account so you can
log straight into Ly -> Sway without running the installer. It is local-test
only; real accounts are created by the installer. If `--rootfs btrfs` is wrong
for your base, adjust the `disk` recipe.

Boot the disk manually:

```sh
qemu-system-x86_64 \
  -enable-kvm -m 8192 -smp 4 -cpu host \
  -machine q35,accel=kvm \
  -device virtio-vga-gl -display gtk,gl=on \
  -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
  -drive file=output/qcow2/disk.qcow2,if=virtio,format=qcow2
```

## 4. Generate an installer ISO (optional)

The offline ISO embeds BlueBuild's MOK key and runs Anaconda, matching a real
install. Both builders require a **published image** (CI, or `bluebuild build
--push`); the local `generate-iso recipe` path is broken (see step 3).

Anaconda picks its profile from the *installer* runtime's `/etc/os-release`,
which `lorax --variant` sets via `fedora-release-<variant>`: `server` shows the
account spokes but forces XFS-on-LVM; `kinoite`/`silverblue` hide the spokes
(deferred to a first-boot initial-setup this image does not ship); an empty
variant selects the generic `fedora` profile (spokes + Btrfs).

### 4.1 `just iso-direct` (recommended)

`just iso` (the BlueBuild CLI wrapper) can only select kinoite/silverblue/server
and always passes one of them, so it cannot reach the generic profile.
`iso-direct` calls the same underlying `build-container-installer` image
directly and passes an empty `VARIANT` (as literal `''`, because the builder's
Makefile does not quote `-t $(VARIANT)`), giving the generic Fedora installer:
base theme, visible User/Root spokes and Btrfs (zstd:1) by default.

```sh
sudo -v
just iso-direct                 # generic Fedora profile: user/root spokes + Btrfs
just iso-direct gaming          # other flavour
# optional overrides: <flavour> <variant> <version> [extra make vars]
just iso-direct workstation server 44 WEB_UI=true
```

The output ISO is written to the repo root and removed first, because xorriso
refuses to reuse a non-empty outdev and a previous `just iso` leaves one there.

### 4.2 Plain BlueBuild CLI: `just iso`

```sh
sudo -v    # authenticate once, up front, in your terminal
bluebuild generate-iso --iso-name blue-hour-workstation.iso \
  --secure-boot-url https://github.com/blue-build/base-images/raw/main/files/base/etc/pki/akmods/certs/akmods-blue-build.der \
  --enrollment-password bluebuild \
  --variant server \
  image ghcr.io/gooserooster/blue-hour-workstation:latest
# or: just iso workstation        (defaults to the server variant)
```

Only `--variant server` exposes the account spokes on this image, and it
defaults storage to XFS-on-LVM (see 4.1 for the generic profile).

Both paths run the installer container with `--privileged`, so `sudo podman` is
used internally. Pre-authenticate with `sudo -v` first: the prompt then appears
in your terminal, the internal sudo uses the cached timestamp, and no
root-owned `.bluebuild-scripts_` is left in the repo. From a non-interactive
shell, `sudo -v` must be done in a terminal first; if a graphical
`SUDO_ASKPASS` is set but not working, `unset SUDO_ASKPASS` so sudo prompts on
the tty. If a previous aborted root run left a root-owned `.bluebuild-scripts_`,
remove it with `just clean`.

### 4.3 Keeping the install path in sync across Fedora revisions

`iso-direct` bakes in a few Fedora-version assumptions. Whenever the base image
moves to a new Fedora release, re-check these (all in `justfile`):

- **`iso_version`** — the release used for the installer runtime (`lorax
  -v/-r`). Keep it equal to the base image's `/usr/lib/os-release` `VERSION_ID`
  (currently `44`). A mismatch means an installer built from the wrong release.
- **`installer_image`** — the pinned `build-container-installer` tag. BlueBuild
  pins the same image/tag in `utils/src/constants.rs`
  (`JASONN3_INSTALLER_IMAGE`); bump deliberately and re-test, do not float
  `:latest`.
- **Profile behaviour** — confirm an empty `VARIANT` still selects the generic
  `fedora` profile and that it shows the user/root spokes and defaults to Btrfs.
  Cross-check the new release's `/etc/anaconda/anaconda.conf` and
  `profile.d/*.conf` (upstream `anaconda` repo: `data/conf.d/`,
  `data/profile.d/`), then re-run the section-5 smoke check on the ISO.

After a base bump, build the ISO, boot it in QEMU, and confirm the installer
shows the account spokes and partitions to Btrfs (`lsblk -f` / `findmnt` in the
installed system).

Equivalent QEMU boot:

```sh
just vm blue-hour-workstation.iso
# qemu-system-x86_64 ... -cdrom blue-hour-workstation.iso -boot d
```


Notes:

- **Secure Boot (QCOW2):** `bootc-image-builder` does not enroll BlueBuild's MOK
  key, so boot the QCOW2 with Secure Boot off (the QEMU invocation in `just
  vm-disk` uses no OVMF vars). Use the ISO to exercise Secure Boot.
- **Secure Boot (ISO):** the ISO embeds BlueBuild's MOK key and enrolls it at
  install. At the first boot, select **Enroll MOK** in the shim manager and
  enter `bluebuild`. To test enforced SB in QEMU, use OVMF with Secure Boot on;
  otherwise disable SB in the VM firmware for a simpler boot. See the README's
  Secure Boot section.
- Use OVMF (`/usr/share/OVMF/OVMF_CODE.fd` + a writable `OVMF_VARS.fd` copy) if
  you need to exercise UEFI/Secure Boot paths.
- The VM **cannot** validate HDR, VRR, or GPU-specific behaviour (VRR/HDR,
  LACT/overdrive, hardware encode). Those need the real host.
- Give the VM 8–16 GiB and a 40+ GiB disk for install/rebase tests.

## 5. Per-flavour smoke checklist

Boot the VM (the QCOW2 from `just disk`/`just vm-disk`, or an installed ISO),
then log in (QCOW2: the throwaway `bluehour`/`bluehour` account) and check:

- [ ] Boot reaches Ly; log in (QCOW2: `bluehour`; ISO: the installer-created
      user).
- [ ] Login shell is zsh: `echo $SHELL` and `getent passwd "$USER"` end in
      `/usr/bin/zsh` (and survive an update + reboot).
- [ ] Baseline CLI is present pre-HM: `bat`, `fd`, `rg`, `eza`, `jq`, `btop`,
      `tealdeer`, `ncdu` resolve.
- [ ] Fonts: `fc-list | grep -i nerd` and `fc-list | grep -i adwaita` return
      the expected families.
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
