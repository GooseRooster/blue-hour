#!/usr/bin/bash
# Label the Nix store for SELinux.
#
# Fedora's selinux-policy ships no Nix module and the nix RPM carries no policy
# either, so /nix (a bind mount of /var/nix) is unlabeled (default_t). systemd
# (init_t) is then denied creating /nix/var/nix/daemon-socket/socket, because it
# may not create a default_t sock_file. These are the file contexts from the
# nix-community / Determinate Systems installer (selinux/nix.fc); every type
# already exists in the base policy, so `semanage fcontext` + `restorecon` are
# enough and no compiled policy module is needed (a module would land in
# /var/lib/selinux, which does not survive a bootc deployment anyway).
#
# The contexts are registered at build time; the runtime /nix is a fresh bind of
# an empty /var/nix, so the one context systemd needs is applied each boot by
# the `z` entry in files/system/usr/lib/tmpfiles.d/blue-hour-nix.conf.
set -euo pipefail

add_fcontext() {
  local type="$1" path="$2"
  # -a fails if the rule already exists; fall back to -m so rebuilds are safe.
  semanage fcontext -a -t "$type" "$path" 2>/dev/null \
    || semanage fcontext -m -t "$type" "$path"
}

add_fcontext bin_t               '/nix/store/[^/]+/s?bin(/.*)?'
add_fcontext systemd_unit_file_t '/nix/store/[^/]+/lib/systemd/system(/.*)?'
add_fcontext lib_t               '/nix/store/[^/]+/lib(/.*)?'
add_fcontext man_t               '/nix/store/[^/]+/man(/.*)?'
add_fcontext etc_t               '/nix/store/[^/]+/etc(/.*)?'
add_fcontext usr_t               '/nix/store/[^/]+/share(/.*)?'
add_fcontext var_run_t           '/nix/var/nix/daemon-socket(/.*)?'
add_fcontext usr_t               '/nix/var/nix/profiles(/per-user/[^/]+)?/[^/]+'
