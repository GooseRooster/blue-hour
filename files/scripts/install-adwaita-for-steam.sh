#!/usr/bin/bash
# Stage the Adwaita-for-Steam skin sources into the image.
#
# Adwaita-for-Steam (tkashkin/Adwaita-for-Steam) is a CSS skin for the native
# Steam client. It is per-user (it writes into ~/.steam/steam), so the image
# only ships the sources; the user unit blue-hour-steam-theme.service runs
# install.py once against the user's Steam directory after its first launch.
#
# Like install-autotiling.sh this fetches the latest upstream release at build
# time (with a branch fallback), so the build is network-dependent and
# non-reproducible by design. See docs/port-plan.md phase 5.
set -euo pipefail

FALLBACK_REF="master"
API="https://api.github.com/repos/tkashkin/Adwaita-for-Steam/releases/latest"
DEST="/usr/share/blue-hour/adwaita-for-steam"

tag=""
if command -v curl >/dev/null 2>&1; then
  tag="$(curl -fsSL "$API" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
    | head -n1 || true)"
fi
[ -n "$tag" ] || tag="$FALLBACK_REF"
echo "adwaita-for-steam: staging ${tag}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "https://github.com/tkashkin/Adwaita-for-Steam/archive/refs/tags/${tag}.tar.gz" \
  -o "$tmp/adwaita.tar.gz" \
  || curl -fsSL "https://github.com/tkashkin/Adwaita-for-Steam/archive/refs/heads/${tag}.tar.gz" \
    -o "$tmp/adwaita.tar.gz"

tar -xzf "$tmp/adwaita.tar.gz" -C "$tmp"
src="$(find "$tmp" -maxdepth 1 -type d -name 'Adwaita-for-Steam-*' | head -n1)"
[ -n "$src" ] || { echo "adwaita-for-steam: source tree not found (${tag})" >&2; exit 1; }

mkdir -p "$DEST"
cp -a "$src/." "$DEST/"
[ -f "$DEST/install.py" ] || { echo "adwaita-for-steam: install.py missing" >&2; exit 1; }
find "$DEST" -name '*.pyc' -delete 2>/dev/null || true
