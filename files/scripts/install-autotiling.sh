#!/usr/bin/bash
# Install autotiling from the latest upstream GitHub release.
#
# autotiling is not packaged in Fedora and its `main.py` is a self-contained
# script (deps: python3-i3ipc, installed via dnf). We deliberately fetch the
# latest release at build time so the image tracks upstream; FALLBACK_TAG is
# used only if the GitHub API is unreachable. Note this makes the build
# network-dependent and non-reproducible. See docs/port-plan.md phase 3.
set -euo pipefail

FALLBACK_TAG="1.9.3"
API="https://api.github.com/repos/nwg-piotr/autotiling/releases/latest"

tag=""
if command -v curl >/dev/null 2>&1; then
  tag="$(curl -fsSL "$API" 2>/dev/null \
    | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' \
    | head -n1 || true)"
fi
[ -n "$tag" ] || tag="$FALLBACK_TAG"
echo "autotiling: installing release ${tag}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

curl -fsSL "https://github.com/nwg-piotr/autotiling/archive/refs/tags/${tag}.tar.gz" \
  -o "$tmp/autotiling.tar.gz"
tar -xzf "$tmp/autotiling.tar.gz" -C "$tmp"

src="$(find "$tmp" -type f -path '*/autotiling/main.py' | head -n1)"
[ -n "$src" ] || { echo "autotiling: main.py not found in ${tag}" >&2; exit 1; }

install -Dm0755 "$src" /usr/bin/autotiling
/usr/bin/autotiling --version || true
