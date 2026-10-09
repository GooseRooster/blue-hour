#!/usr/bin/bash
# Install the Hatter icon theme.
#
# Hatter has no Fedora package and publishes no releases/tags, so we clone the
# default branch and install the GNOME variants (mirrors the nixos-config
# pkgs/hatter derivation). The KDE flavours are skipped.
set -euo pipefail

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

git clone --depth 1 https://github.com/Mibea/Hatter.git "$tmp/hatter"

install -d /usr/share/icons
for theme in "$tmp"/hatter/Hatter*; do
  case "$(basename "$theme")" in
    Hatter-kde*) continue ;;
  esac
  cp -r "$theme" /usr/share/icons/
done

# Keep Adwaita's stock "Show Applications" glyph: drop Hatter's override so the
# Inherits= chain (Hatter-* -> Hatter -> Adwaita) resolves it.
find /usr/share/icons -name 'view-app-grid-symbolic.svg' -delete

# Remove shipped caches so GTK regenerates them from the patched tree (a stale
# cache would otherwise keep serving the removed icon).
find /usr/share/icons \( -name 'icon-theme.cache' -o -name '.icon-theme.cache' \) -delete
