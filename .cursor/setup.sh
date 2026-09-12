#!/bin/bash

# Cloud Agent development environment setup for Omarchy.
#
# Omarchy targets Arch Linux, but Cloud Agents boot an Ubuntu base image. This
# script installs the toolchain the non-graphical test suites (`./test/all`)
# expect, provides `vercmp`/`magick` shims for the two Arch-only binaries the
# code calls, checks out the sibling repositories the packaging tests look for,
# and exports the runtime environment Omarchy assumes (`$OMARCHY_PATH`, the
# `bin/` directory on `PATH`). It is idempotent: re-running it converges without
# duplicating state.

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
GUM_VERSION="0.14.5"

# Cloud Agents grant passwordless sudo; fall back to running directly as root.
if [[ $EUID -eq 0 ]]; then
  sudo() { "$@"; }
fi

install_packages() {
  local packages=(
    build-essential   # ar, make, compilers for the vendor/deb tests
    curl
    figlet            # ascii wordmark rendering
    gawk              # Omarchy relies on GNU awk extensions, not mawk
    git
    imagemagick       # provides ImageMagick 6 tooling; `magick` is shimmed below
    iproute2          # `ip`, used for network interface detection
    jq
    libarchive-tools  # bsdtar, used by the .deb vendor updaters
    libxkbcommon-tools # xkbcli, used by the keybindings menu
    lua5.4            # lua interpreter for hyprland/config lint tests
    plocate           # updatedb for the locate service tests
    python-is-python3 # the CLI and several tests invoke `python`
    python3
    qrencode          # network QR code helper
  )
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"
  # Omarchy code assumes GNU awk; make it the default `awk`.
  sudo update-alternatives --set awk /usr/bin/gawk
}

install_gum() {
  if command -v gum >/dev/null 2>&1; then
    return 0
  fi
  local tmp
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/gum.tar.gz" \
    "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_x86_64.tar.gz"
  tar -xzf "$tmp/gum.tar.gz" -C "$tmp"
  sudo install -m755 "$tmp/gum_${GUM_VERSION}_Linux_x86_64/gum" /usr/bin/gum
  rm -rf "$tmp"
}

# pacman's `vercmp`, reimplemented so version comparisons behave the same on this
# non-Arch host as they do on Arch. Installed to /usr/bin so it is found even by
# tests that reset PATH to a minimal set.
install_vercmp() {
  sudo tee /usr/bin/vercmp >/dev/null <<'VERCMP'
#!/usr/bin/env python3
"""Standalone reimplementation of pacman's `vercmp` (alpm_pkg_vercmp).

Mirrors lib/libalpm/version.c so version comparisons behave the same on this
non-Arch host as they do on Arch. Prints -1, 0, or 1.
"""
import sys


def _rpmvercmp(a, b):
    if a == b:
        return 0
    one = 0
    two = 0
    la, lb = len(a), len(b)
    while one < la and two < lb:
        s1 = one
        while one < la and not a[one].isalnum():
            one += 1
        s2 = two
        while two < lb and not b[two].isalnum():
            two += 1
        if (one - s1) != (two - s2):
            return -1 if (one - s1) < (two - s2) else 1
        if one >= la or two >= lb:
            break
        p1 = one
        p2 = two
        if a[p1].isdigit():
            while p1 < la and a[p1].isdigit():
                p1 += 1
            while p2 < lb and b[p2].isdigit():
                p2 += 1
            isnum = True
        else:
            while p1 < la and a[p1].isalpha():
                p1 += 1
            while p2 < lb and b[p2].isalpha():
                p2 += 1
            isnum = False
        seg1 = a[one:p1]
        seg2 = b[two:p2]
        if seg2 == "":
            return 1 if isnum else -1
        if isnum:
            seg1 = seg1.lstrip("0")
            seg2 = seg2.lstrip("0")
            if len(seg1) > len(seg2):
                return 1
            if len(seg2) > len(seg1):
                return -1
        if seg1 < seg2:
            return -1
        if seg1 > seg2:
            return 1
        one = p1
        two = p2
    if one >= la and two >= lb:
        return 0
    if (one >= la and not (two < lb and b[two].isalpha())) or (one < la and a[one].isalpha()):
        return -1
    return 1


def _parse_evr(evr):
    s = 0
    while s < len(evr) and evr[s].isdigit():
        s += 1
    if s < len(evr) and evr[s] == ":":
        epoch = evr[:s] or "0"
        rest = evr[s + 1:]
    else:
        epoch = "0"
        rest = evr
    idx = rest.rfind("-")
    if idx >= 0:
        version = rest[:idx]
        release = rest[idx + 1:]
    else:
        version = rest
        release = None
    return epoch, version, release


def vercmp(a, b):
    if a == b:
        return 0
    e1, v1, r1 = _parse_evr(a)
    e2, v2, r2 = _parse_evr(b)
    ret = _rpmvercmp(e1, e2)
    if ret == 0:
        ret = _rpmvercmp(v1, v2)
        if ret == 0 and r1 is not None and r2 is not None:
            ret = _rpmvercmp(r1, r2)
    return ret


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: vercmp <version1> <version2>\n")
        return 2
    print(vercmp(argv[1], argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
VERCMP
  sudo chmod +x /usr/bin/vercmp
}

# ImageMagick 7's `magick` entrypoint, backed by the ImageMagick 6 tools Ubuntu
# ships. Only installed when a real `magick` (IM7) is absent.
install_magick_shim() {
  if command -v magick >/dev/null 2>&1; then
    return 0
  fi
  sudo tee /usr/bin/magick >/dev/null <<'MAGICK'
#!/bin/bash
# ImageMagick 7 `magick` compatibility shim backed by ImageMagick 6 tools.
subcmds="convert identify mogrify composite montage compare import display animate conjure stream"
if (( $# > 0 )) && [[ " $subcmds " == *" $1 "* ]]; then
  cmd="$1"
  shift
  exec "$cmd" "$@"
else
  exec convert "$@"
fi
MAGICK
  sudo chmod +x /usr/bin/magick
}

# The packaging and installer tests look for sibling checkouts of these repos.
clone_sibling_repo() {
  local url="$1" dest="$2"
  if [[ -d "$dest/.git" ]]; then
    return 0
  fi
  git clone --depth 1 "$url" "$dest"
}

write_env_profile() {
  sudo tee /etc/profile.d/omarchy-dev.sh >/dev/null <<PROFILE
# Omarchy Cloud Agent development environment.
# \$OMARCHY_PATH is a runtime invariant Omarchy code relies on; on a real system
# the uwsm session exports it. Mirror that here and put bin/ on PATH so the
# omarchy-* helpers resolve the way they do on an installed system.
export OMARCHY_PATH="$ROOT"
case ":\$PATH:" in
  *":$ROOT/bin:"*) ;;
  *) export PATH="$ROOT/bin:\$PATH" ;;
esac
export OMARCHY_PKGS_PATH="\$HOME/omarchy-pkgs"
export OMARCHY_ISO_PATH="\$HOME/omarchy-iso"
# The test suite expects a colour-capable terminal like a real desktop session;
# the Cloud Agent runner sets these to suppress colour, so clear them here.
unset NO_COLOR
unset FORCE_COLOR
PROFILE
}

main() {
  install_packages
  install_gum
  install_vercmp
  install_magick_shim
  clone_sibling_repo "https://github.com/omacom-io/omarchy-pkgs.git" "$HOME/omarchy-pkgs"
  clone_sibling_repo "https://github.com/omacom-io/omarchy-iso.git" "$HOME/omarchy-iso"
  write_env_profile
  echo "Omarchy Cloud Agent development environment ready."
}

main "$@"
