#!/bin/bash

# Cloud Agent setup for the Omarchy checkout.
#
# Omarchy targets Arch Linux, but Cloud Agents boot a Debian/Ubuntu base image.
# This installs the handful of tools the CLI and the `./test/all` suites shell
# out to that the base image lacks, bridges ImageMagick 7's `magick` to Ubuntu's
# ImageMagick 6, and mirrors the uwsm session environment Omarchy runtime code
# assumes (`OMARCHY_PATH`, the checkout's bin/ on PATH). It is idempotent and
# safe to re-run.

set -euo pipefail

OMARCHY_PATH="${OMARCHY_PATH:-/workspace}"

# System packages. The base image already ships bash, jq, git, curl, node, and
# ripgrep; these are the Arch invariants Ubuntu's base image is missing:
#   gawk               - mawk lacks the \s regexes and multibyte length() the
#                        ascii and power-profile helpers/tests depend on
#   lua5.4             - Hyprland config and several helpers are Lua
#   imagemagick        - wallpaper sampling (the magick shim below bridges IM7)
#   libxkbcommon-tools - xkbcli, keyboard-layout validation
#   iproute2           - `ip route`, Wi-Fi interface detection
#   qrencode           - the Wi-Fi QR helper
#   python-is-python3  - the suites invoke `python`
packages=(
  gawk
  lua5.4
  imagemagick
  libxkbcommon-tools
  iproute2
  qrencode
  python-is-python3
  jq
)
sudo apt-get update -qq
sudo apt-get install -y -qq "${packages[@]}"

# ImageMagick 7 ships a unified `magick`; Ubuntu ships ImageMagick 6 (`convert`
# and friends). Bridge them so `magick <input> ... info:-` pipelines run
# unchanged.
if [[ ! -x /usr/local/bin/magick ]]; then
  sudo tee /usr/local/bin/magick >/dev/null <<'SHIM'
#!/bin/bash
case "${1:-}" in
  convert | identify | mogrify | composite | montage | compare | import | display | animate | conjure | stream)
    tool="$1"
    shift
    exec "$tool" "$@"
    ;;
  *)
    exec convert "$@"
    ;;
esac
SHIM
  sudo chmod +x /usr/local/bin/magick
fi

# Sibling checkouts a few cross-repo packaging/ISO tests look for. Best effort:
# the rest of the suite does not need them, so a network hiccup must not fail
# setup.
clone_sibling() {
  local name="$1"
  local dest="$HOME/$name"
  local org

  [[ -d $dest ]] && return 0
  for org in omacom-io omacom; do
    if git clone --depth 1 "https://github.com/$org/$name.git" "$dest"; then
      return 0
    fi
  done
  return 0
}
clone_sibling omarchy-pkgs
clone_sibling omarchy-iso

# Mirror the Omarchy uwsm session environment. Omarchy runtime code assumes
# OMARCHY_PATH is exported and the checkout's bin/ is on PATH; the base image
# also exports NO_COLOR=1 (which suppresses the about launcher's logo sheen its
# test checks).
#
# The Cloud Agent boots by sourcing ~/.bashrc once to build the base
# environment every command inherits, so OMARCHY_PATH, the sibling-repo
# pointers, and the checkout's bin/ on PATH live there. NO_COLOR is special: the
# exec-daemon re-injects it into every command AFTER ~/.bashrc runs, so it is
# cleared from a $BASH_ENV script instead, which non-interactive bash (the Shell
# tool and every `bash test/shell.d/*-test.sh` the runner spawns) sources at
# startup. The BASH_ENV script deliberately does nothing else, so it never
# perturbs a test's own PATH or OMARCHY_PATH.
env_script="$HOME/.omarchy-cloud-env.sh"
cat >"$env_script" <<'EOF'
# Sourced by every non-interactive bash via BASH_ENV. Clear the NO_COLOR the
# exec-daemon injects after ~/.bashrc so Omarchy keeps its colored output and
# the about-launcher sheen test passes. Only launch-about touches NO_COLOR, and
# it does so within its own already-started shell, so this does not interfere.
unset NO_COLOR
EOF

marker="# >>> omarchy cloud-agent dev env >>>"
if ! grep -qF "$marker" "$HOME/.bashrc" 2>/dev/null; then
  cat >>"$HOME/.bashrc" <<EOF

$marker
export OMARCHY_PATH="$OMARCHY_PATH"
case ":\$PATH:" in
  *":\$OMARCHY_PATH/bin:"*) ;;
  *) export PATH="\$OMARCHY_PATH/bin:\$PATH" ;;
esac
export OMARCHY_PKGS_PATH="\$HOME/omarchy-pkgs"
export OMARCHY_ISO_PATH="\$HOME/omarchy-iso"
export BASH_ENV="\$HOME/.omarchy-cloud-env.sh"
unset NO_COLOR
# <<< omarchy cloud-agent dev env <<<
EOF
fi
