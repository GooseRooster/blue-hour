# Userland: Nix, Home Manager, Homebrew and updates

This document covers the per-user layer of blue-hour — Nix, standalone Home
Manager and Homebrew — plus the system-side pieces it interacts with (the Zen
browser, the `topgrade` updater and its notification/tray). The user's
opinionated configuration (dotfiles, user Flatpaks, Noctalia settings) lives in
the separate `GooseRooster/home-manager` repo and is applied with standalone
Home Manager on the image's Nix.

The updater and Zen are image/system resources and live in the shared recipes
(`recipes/common-updates.yml` and `recipes/common-system.yml`), not in the
per-user layer (`recipes/common-userland.yml`).

See `docs/port-plan.md` phase 6 for the migration context.

## Nix and Home Manager

The image ships system-wide Nix with a persistent store (`/nix` backed by
`/var/nix`, see phase 1). Home Manager is **not** installed as a NixOS module;
run it standalone against the dotfiles repo:

```sh
# First run: install Home Manager into your user profile.
nix run home-manager/master -- init --switch ~/nixos-config

# Subsequent switches (activate a new generation):
home-manager switch --flake ~/nixos-config#<user>
```

Home Manager owns the user layer, including `~/.zshrc` and the zsh plugins. The
**image** owns the login shell itself: `/usr/bin/zsh`, `/etc/shells`, and
`blue-hour-set-login-shell.service`, which points installer-created users at
zsh on first boot. Do not remove the baseline CLI tools from the dotfiles repo —
they are intentionally portable to other machines and are added to the image
_only_ additively.

Home Manager is not wired into topgrade by default. To update it alongside
everything else, add a custom command to `~/.config/topgrade.toml`:

```toml
[commands]
"Home Manager" = "home-manager switch --flake ~/nixos-config#<user>"
```

## Homebrew

Linuxbrew is installed at `/home/linuxbrew/.linuxbrew` by the `brew` module
(uid/gid 1000), with `brew-update`/`brew-upgrade` timers. Brew is added to the
`PATH` in interactive/login shells via the module's `profile.d`/shell
integration; a non-interactive shell will not see it. Install formulae as your
user:

```sh
brew install <formula>
```

## The manual updater: topgrade

`topgrade` updates the OS (via `bootc`), system + user Flatpaks, and Homebrew in
one run. Run it in a terminal:

```sh
topgrade
# or, with the login shell already set up for Homebrew:
blue-hour-topgrade
```

The default configuration is shipped at
`/usr/share/blue-hour/topgrade/00-blue-hour.toml` and seeded into each user's
`~/.config/topgrade.d/00-blue-hour.toml` on first login. topgrade merges
`~/.config/topgrade.d/*` **before** reading `~/.config/topgrade.toml`, so you can
override anything by creating `~/.config/topgrade.toml` (or a later
`~/.config/topgrade.d/99-*.toml`). For example, to add Home Manager alongside
the defaults:

```toml
# ~/.config/topgrade.toml
[commands]
"Home Manager" = "home-manager switch --flake ~/nixos-config#<user>"
```

A `bootc` update is staged and applied at the next shutdown/reboot, so topgrade
will tell you when a restart is needed.

## Update notifications and the tray widget

blue-hour detects updates in two layers:

- **System service** (`blue-hour-update-status.service` + `.timer`, runs as
  root). `bootc status` refuses unprivileged users, so this service runs
  `bootc upgrade --check` (image metadata only) and `bootc status --json`, then
  writes `/run/blue-hour/update-status.json` (world-readable) with the
  staged/available state. It refreshes every 15 minutes.
- **User notifier** (`blue-hour-update-notify.service` + `.timer`). Reads the
  status file and sends a "restart to apply" desktop notification the first time
  a new deployment is staged. This works in any session, with or without
  Noctalia.

The **blue-hour Updates** Noctalia plugin
(`/usr/share/blue-hour/noctalia-plugins/updates`) adds a bar widget next to the
tray: a dot when an update is available or staged, a version tooltip, and
left-click opens `blue-hour-topgrade` in a terminal. It is enabled by default via
`/etc/noctalia/00-blue-hour-defaults.toml` (a low-priority "00-" default); move
or remove the widget from Noctalia Settings if you prefer, or disable the
`bluehour/updates` plugin.

The status timer runs 2 minutes after boot and every 15 minutes after that. To
test the notification/tray path on demand:

```sh
ujust blue-hour-test-update     # simulate a staged update + trigger the notifier
ujust blue-hour-update-status   # refresh from the real bootc status
ujust blue-hour-clear-update    # clear the simulation, run the real check
```

If a staged update is applied by the base auto-updater at shutdown, the file and
notification simply never appear — nothing to do.

## Zen Browser

Zen is installed system-wide from the COPR (`sneexy/zen-browser`) and is **not**
part of the Home Manager layer. The system `policies.json`
(`/opt/zen/distribution/policies.json`) keeps `DisableAppUpdate` (updates arrive
with the image) and adds telemetry/studies/Pocket opt-outs; edit
`files/system/usr/share/blue-hour/zen-policies.json` in this repo to change them.

## Steam skin (gaming flavour)

The Adwaita-for-Steam skin is staged in the image and applied to the user's
native Steam directory once, after Steam's first launch, by
`blue-hour-steam-theme.service` (triggered by `blue-hour-steam-theme.path`).

Your custom CSS lives **outside** the Steam tree at
`~/.config/adwaita-for-steam/custom.css`; it is passed to the installer with
`--custom-css` and is never overwritten. To pick up skin updates later, run:

```sh
blue-hour-steam-theme reapply
```
