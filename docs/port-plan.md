# Port plan — NixOS config → blue-hour

This document tracks the port of the author's `nixos-config` flake into the
blue-hour BlueBuild image. It is the place for migration detail; `README.md`
describes the intended end-state, not the migration.

## Guiding principles

- **Keep the system/user split.** The system side (boot, hardware, session,
  OS-integrated apps) is declared in the image recipes. The opinionated user
  layer (dotfiles, user Flatpaks, Noctalia settings, CLI bundles) stays in the
  `GooseRooster/home-manager` dotfiles repo and is applied per-user with
  standalone Home Manager on the image's Nix.
- **Don't duplicate what the base already provides.** `fedora-base` ships
  codecs/hardware accel (negativo17 + fedora-multimedia), bootc/flatpak
  auto-update timers, and the `ublue-os/packages` COPR. Never call
  `nonfree: rpmfusion` (it disables negativo17); add RPMFusion packages with
  explicit `repos.files` + `repos.keys`.
- **Declarative first.** Prefer `dnf`, `files`, `systemd`, `default-flatpaks`,
  `brew`, `script`. Use `containerfile`/`stages` only for builds that must not
  pollute the final image (Sway).
- **Users are installer-created.** No user module; the graphical installer makes
  the account and Home Manager runs as that user afterwards.
- **Verify in the VM.** Every phase below has acceptance criteria that must be
  exercised with the ISO in QEMU before the phase is considered done.

## NixOS → BlueBuild mapping

| NixOS source | BlueBuild target |
| --- | --- |
| `modules/core/system.nix` (printing, NetworkManager, tpm2, base packages) | `dnf` (cups), `systemd`. Timezone/locale/keymap are set at install time and intentionally not baked in. |
| `modules/core/hardware.nix` (firmware, microcode, zram) | base image + `files` (zram-generator), `dnf` |
| `modules/core/kernel.nix` | stock Fedora kernel (decided; no custom kernel for now) |
| `modules/core/perf.nix` (sysctls, I/O scheduler, system76-scheduler) | `files` (sysctl + udev rules), `dnf` (ananicy-cpp COPR) |
| `modules/core/nix.nix` (flakes, trusted-users, allowUnfree) | `dnf` (`nix`, `nix-daemon`), `files` (nix config, `nix.mount`), `systemd` |
| `modules/core/users.nix` | *dropped* — installer handles users |
| `modules/core/ssh.nix`, `gnupg.nix` | `dnf` + `files` (config), optional |
| `modules/core/hardening.nix` | *dropped* — Fedora defaults already cover it (see below) |
| `modules/core/maintenance.nix`, `auto-upgrade.nix` | base `bootc-fetch-apply-updates.timer` + flatpak timers; `dnf` (fwupd) |
| `modules/core/secure-boot.nix` (Lanzaboote) | *not portable* — replaced by BlueBuild's base MOK signing (`akmods-blue-build.der`, password `bluebuild`); enroll via the ISO installer or `ujust enroll-secure-boot-key`. See README "Secure Boot". |
| `modules/core/podman.nix`, `quadlets/` | base podman; `files` (`/etc/containers/systemd`) |
| `modules/flatpak/system.nix` | `default-flatpaks` (system scope) |
| `modules/desktop/apps.nix` (nautilus, sushi, fonts) | `dnf` + `fonts` module |
| `modules/desktop/noctalia.nix` | `dnf` (`noctalia`), `files` (config defaults), `systemd` |
| `modules/desktop/sway.nix` + `sway-base.conf` | `stages` (build sway from source), `dnf`, `files` (`/etc/sway/config`) |
| `modules/desktop/graphics.nix`, `pipewire.nix`, `portals.nix`, `power.nix`, `keyring.nix`, `virtualization.nix`, `terminal.nix`, `gsr.nix` | `dnf`, `files`, `systemd`, `script` (gsr helpers) |
| `modules/desktop/apps.nix` — Ly DM | `dnf` (`ly`, `ly-selinux`), `files` (`/etc/ly/config.ini`, PAM) |
| `modules/extras/tuned.nix` | `dnf` (`tuned`, `tuned-ppd`), `files` (profiles + ppd mapping) |
| `modules/gaming/*` | `dnf` + RPMFusion repo files, `script` (game-performance), `systemd` |
| `pkgs/hatter`, `pkgs/adwaita-for-steam` | `files` + `script` (package from source at build time) |
| home-manager dotfiles repo | standalone Home Manager on the image's Nix |

## Hardening: why it's dropped

Fedora already enables SELinux (enforcing), firewalld, systemd service
sandboxing and compiler hardening; systemd's `50-default.conf` sets
`fs.protected_hardlinks/symlinks/regular/fifos`, `rp_filter=2`,
`accept_source_route=0`, and `sysrq=16`. The NixOS module's extras
(`kptr_restrict`, `dmesg_restrict`, `slab_nomerge`, `init_on_alloc/free`,
`page_alloc.shuffle`) are not needed, and `init_on_free`/`page_alloc.shuffle`
cost performance on a desktop. Optional, if wanted later: a two-line sysctl
drop-in for `kernel.kptr_restrict=2` and `kernel.dmesg_restrict=1`.

---

## Phases

### Phase 0 — Foundations ✅ (this scaffold)
Flake dev shell, recipe scaffold, CI matrix, README/AGENTS/docs.

**Done when:** `nix flake check` passes, `bluebuild generate` succeeds for both
flavours.

### Phase 1 — Nix spike (highest risk)
Goal: system-wide Nix with a store that survives image updates.

- `dnf install nix nix-daemon` (Fedora package; flakes enabled by default).
- Move the seeded store to `/var/nix`; ship `nix.mount`
  (`What=/var/nix`, `Where=/nix`, `Type=none`, `Options=bind`).
- Ensure `nix-daemon.service`/`.socket` start after `nix.mount` (drop-in with
  `RequiresMountsFor=/nix`).
- SELinux: rely on the Fedora package's policy; verify contexts with
  `restorecon -RF /nix` and `ausearch -m avc` in the VM. Add `semanage fcontext`
  rules only if the package's policy is insufficient.
- Acceptance: after an update+rebase, `nix run nixpkgs#hello` still works and
  `/nix/store` is on `/var/nix`.
- **Fallback:** rootless single-user (`nix-core`), documented but not preferred.

### Phase 2 — Base system
Base CLI packages, zram, fwupd, CUPS (printing), and sysctl/udev from
`perf.nix` (minus system76-scheduler → ananicy-cpp, already in `common.yml`).
Fonts. Timezone/locale/keymap are install-time/session concerns and are **not**
baked in (the installer writes `/etc/localtime`/`locale.conf`/`vconsole.conf`;
Sway sets its own layout). The console **font** for Ly is handled in phase 3.

### Phase 3 — Desktop
- **Sway**: `stages` build of the latest upstream release (pinned via Renovate),
  compiled against Fedora's wlroots and `copy`ed into `/usr`. Ship our own
  `/etc/sway/config` and `sway.desktop`; do not install `sway-config-*`.
  Acceptance: `sway --version ≥ 1.12`.
- **Ly**: `dnf install ly ly-selinux`; enable `ly.service`; ship
  `/etc/ly/config.ini` (bg/fg/hide_borders/clock/bigclock) and the terminus
  console font (via `/etc/vconsole.conf` FONT=) that Ly's TUI/bigclock renders
  with.
- **Noctalia**: `dnf install noctalia`; seed `/etc/noctalia/00-*.toml` defaults.
- **Session plumbing**: pipewire, portals (wlr/gtk/gnome), polkit, keyring,
  gcr-ssh-agent, udisks2, adw-gtk3, Hatter, nwg-look.
- **GPU Screen Recorder** (COPR `brycensranch/gpu-screen-recorder-git`,
  fallback Terra; already installed from `common.yml`) with the `gsr-shot`/
  `gsr-rec` helpers in `files/scripts`. GSR uses **VA-API, not VDPAU**; the
  base already ships the vendor drivers (AMD: fedora-multimedia mesa; Intel:
  iHD + i965), so no extra packages are needed. Verify with `vainfo` per GPU.
  The NixOS config's `libva-vdpau-driver`/`libvdpau-va-gl` are VDPAU interop
  for other apps and are not required (and `mesa-vdpau-drivers` risks a mesa
  version clash with the base's replaced mesa).
- **Keyring auto-unlock** — see Phase 8 (oo7).

### Phase 4 — Flatpaks
Port `modules/flatpak/system.nix` into `default-flatpaks` (system scope). User
Flatpaks stay in Home Manager.

### Phase 5 — Gaming flavour
- RPMFusion repo files (`repos.files` + `repos.keys`, **not** `nonfree:`) for
  Steam; native Steam + Adwaita-for-Steam, Wine/winetricks/Faugus.
- `tuned` + `tuned-ppd`: shared mapping in `common` (power-saver→powersave,
  balanced→balanced, performance→throughput-performance); gaming overrides
  performance→latency-performance.
- `game-performance` helper (TuneD + Noctalia IPC + notifications).
- ananicy-cpp and GPU Screen Recorder are **not** gaming-only — they live in
  `common.yml` (see phases 2 and 3).
- **No GameMode** (uses the custom script instead).
- **Kernel: stock Fedora** for now. (Revisit later: OGC kernel via a
  CachyOS-style swap script — stub `05-rpmsostree.install`/`50-dracut.install`,
  replace `kernel*`, `depmod` + `dracut`; needs MOK enrollment/SB off.)

### Phase 6 — Nix / Home Manager / Homebrew userland
- Homebrew via the `brew` module.
- Document running standalone Home Manager against the dotfiles repo.
- `topgrade` (COPR `lilay/topgrade`) as the manual updater.
- Zen Browser moves **to the system** (COPR `sneexy/zen-browser`, x86_64;
  `architektapx/zen-browser` for aarch64) with a `policies.json`; remove it
  from the Home Manager layer.

### Phase 7 — Flavours, CI, branding
`common.yml` + `workstation.yml` + `gaming.yml`, CI matrix, `os-release`
branding, cosign signing (base + recipe `signing` last), `justfiles` for
`ujust`-style update commands.

### Phase 8 — Updates, notifications, secrets provider
- Automatic updates already come from the base (`bootc-fetch-apply-updates.timer`
  + flatpak timers). Add a small unit that detects a staged bootc deployment
  (`bootc status`) and `notify-send`s "updates staged — reboot to apply".
- `topgrade`/`uupd` as the manual/optional updater.
- **Secrets provider (oo7) — phased.** Fedora 44 uses gnome-keyring; Fedora 45
  switches the default Secret Service provider to **oo7** (`oo7-daemon` +
  `pam_oo7`), with automatic one-way migration from gnome-keyring/KWallet.
  - *F44 (now):* add `pam_gnome_keyring.so` (auth + session) to `/etc/pam.d/ly`
    so the login keyring unlocks at Ly login; wire the SSH agent socket into the
    Sway session.
  - *F45 (prep now, apply at base bump):* swap the PAM module in `/etc/pam.d/ly`
    to `pam_oo7`, install `oo7-daemon`, and re-verify that the Secret Service
    bus name (`org.freedesktop.secrets`) is owned by oo7 and that sandboxed
    (Flatpak) apps can read secrets. Keep the PAM drop-in abstracted so this is
    a one-line switch per Fedora version.
  - Note: migration to oo7 is one-way — test on a throwaway VM profile.

---

## Open risks

1. Nix `/nix` persistence + SELinux + daemon ordering (phase 1).
2. Sway-from-source must track a wlroots-compatible release; build wlroots too
   if upstream outpaces Fedora's.
3. RPMFusion vs negativo17 coexistence for Steam/Wine/Faugus.
4. GSR `gsr-kms-server` capability behaviour from the RPM (promptless capture).
5. Noctalia v5 Fedora package is currently a beta in F44 updates.
6. oo7 migration is one-way; sequence the F45 bump carefully.
