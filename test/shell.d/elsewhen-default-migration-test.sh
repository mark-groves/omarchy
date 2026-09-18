#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq
require_command git

migration="$ROOT/migrations/1789581661.sh"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

mkdir -p "$test_dir/bin"
export INSTALLED_PACKAGES="$test_dir/installed" CALL_LOG="$test_dir/calls" SHELL_CALLS="$test_dir/shell-calls"
# The checkout cases use the real git; keep the developer's config (signing,
# hooks, safe.directory) out of what it sees.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# Keep the real package helpers, but contain every pacman transaction here.
cat >"$test_dir/bin/pacman" <<'SH'
#!/bin/bash
case "$1" in
  -Q) grep -Fxq -- "$2" "$INSTALLED_PACKAGES" ;;
  -S)
    [[ ${FAIL_INSTALL:-0} == 0 ]] || exit 1
    shift 3 # -S --noconfirm --needed
    printf '%s\n' "$@" >>"$INSTALLED_PACKAGES"
    printf '%s\n' "$@" >>"$CALL_LOG"
    ;;
  *) exit 1 ;;
esac
SH
cat >"$test_dir/bin/sudo" <<'SH'
#!/bin/bash
[[ $1 == "pacman" ]] || exit 1
"$@"
SH
# The migration runs under a shell that predates the packaged root, or under
# none at all, so it must only ever ask the shell for best-effort refreshes.
cat >"$test_dir/bin/omarchy-shell" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$SHELL_CALLS"
[[ $1 != "-q" ]] || exit 0
exit "${SHELL_STATUS:-0}"
SH
chmod +x "$test_dir/bin/"*

home="$test_dir/home"
config="$home/.config/omarchy/shell.json"
checkout="$home/.config/omarchy/plugins/omacom.elsewhen"
output="$test_dir/output"
mkdir -p "$home/.config/omarchy"

run_migration() {
  : >"$CALL_LOG"
  : >"$SHELL_CALLS"
  HOME="$home" OMARCHY_PATH="$ROOT" PATH="$test_dir/bin:$ROOT/bin:$PATH" \
    bash -euo pipefail "$migration" >"$output"
}

ids() {
  jq -c ".bar.layout.$1 | map(if type == \"object\" then .id else . end)" "$config"
}

# ------------------------------------------------------------ package install
: >"$INSTALLED_PACKAGES"
cat >"$config" <<'JSON'
{
  "version": 1,
  "bar": {
    "layout": {
      "left": [{ "id": "omarchy.menu" }],
      "center": [{ "id": "omarchy.clock", "format": "HH:mm" }],
      "right": [
        { "id": "omarchy.tray" },
        { "id": "omarchy.agents", "syncMode": "On" },
        { "id": "omarchy.power" }
      ]
    }
  },
  "plugins": []
}
JSON

run_migration
grep -Fxq elsewhen "$CALL_LOG" || fail "migration installs the elsewhen package" "$(cat "$CALL_LOG")"
pass "migration installs the elsewhen package"

[[ $(ids center) == '["omacom.elsewhen","omarchy.clock"]' && $(ids right) == '["omarchy.tray","omarchy.agents","omarchy.power"]' ]] ||
  fail "migration puts the widget just before the center clock" "$(cat "$config")"
pass "migration puts the widget just before the center clock"

[[ $(jq -c '.bar.layout.right[1]' "$config") == '{"id":"omarchy.agents","syncMode":"On"}' ]] ||
  fail "migration keeps the settings of its neighbours" "$(cat "$config")"
[[ $(jq -c '.bar.layout.center[1]' "$config") == '{"format":"HH:mm","id":"omarchy.clock"}' ]] ||
  fail "migration keeps the clock settings" "$(cat "$config")"
pass "migration leaves the rest of the layout alone"

grep -q 'shell rescanPlugins' "$SHELL_CALLS" && grep -q 'shell reloadConfig' "$SHELL_CALLS" ||
  fail "migration asks the running shell to rescan and reload" "$(cat "$SHELL_CALLS")"
pass "migration asks the running shell to rescan and reload"

before=$(sha256sum "$config")
run_migration
[[ $before == $(sha256sum "$config") ]] || fail "migration is idempotent" "$(cat "$config")"
[[ ! -s $CALL_LOG ]] || fail "migration does not reinstall a present package" "$(cat "$CALL_LOG")"
pass "migration is idempotent"

# ------------------------------------------------------------- placements
cat >"$config" <<'JSON'
{
  "version": 1,
  "bar": { "layout": { "left": [], "center": ["omarchy.clock", "omarchy.tray"], "right": ["omarchy.power"] } }
}
JSON
run_migration
[[ $(ids center) == '["omacom.elsewhen","omarchy.clock","omarchy.tray"]' && $(ids right) == '["omarchy.power"]' ]] ||
  fail "migration reads string clock entries" "$(cat "$config")"
pass "migration reads string clock entries"

cat >"$config" <<'JSON'
{ "version": 1, "bar": { "layout": { "right": [{ "id": "omarchy.agents" }, { "id": "omarchy.power" }] } } }
JSON
run_migration
[[ $(ids center) == '["omacom.elsewhen"]' && $(ids right) == '["omarchy.agents","omarchy.power"]' ]] ||
  fail "migration prepends to the center section when the clock is off the bar" "$(cat "$config")"
pass "migration prepends to the center section when the clock is off the bar"

cat >"$config" <<'JSON'
{
  "version": 1,
  "bar": { "layout": { "left": [{ "id": "omacom.elsewhen" }], "center": [], "right": [{ "id": "omarchy.tray" }, { "id": "omarchy.agents" }] } }
}
JSON
before=$(sha256sum "$config")
run_migration
[[ $before == $(sha256sum "$config") ]] ||
  fail "migration leaves a widget the user already placed where it is" "$(cat "$config")"
pass "migration leaves a widget the user already placed where it is"

# A customized clock keeps its section and settings; insert only its neighbour.
for section in left right; do
  jq -n --arg section "$section" '{version: 1, bar: {layout: {center: ["omarchy.weather"], ($section): ["omarchy.menu", {id: "omarchy.clock", format: "HH:mm"}]}}}' >"$config"
  run_migration
  [[ $(ids "$section") == '["omarchy.menu","omacom.elsewhen","omarchy.clock"]' && $(ids center) == '["omarchy.weather"]' ]] ||
    fail "migration follows a clock customized into $section" "$(cat "$config")"
  pass "migration follows a clock customized into $section"
done

# ------------------------------------------------------------- edge cases
rm -f "$config"
run_migration
[[ ! -e $config ]] || fail "migration writes no shell.json where the defaults apply" "$(cat "$config")"
pass "migration writes no shell.json where the defaults apply"

for partial in \
  '{"version":1,"idle":{"lock":600}}' \
  '{"version":1,"bar":null,"idle":{"lock":600}}' \
  '{"version":1,"bar":{"position":"bottom"}}' \
  '{"bar":{"layout":{"center":["omarchy.clock"]}}}'; do
  printf '%s\n' "$partial" >"$config"
  before=$(sha256sum "$config")
  run_migration
  [[ $before == $(sha256sum "$config") ]] || fail "migration preserves fallback configuration" "$(cat "$config")"
  pass "migration preserves fallback configuration: $partial"
done

printf '{ not json' >"$config"
run_migration
[[ $(cat "$config") == '{ not json' ]] || fail "migration leaves an unparsable config untouched" "$(cat "$config")"
pass "migration leaves an unparsable config untouched"

cat >"$config" <<'JSON'
{ "version": 1, "bar": { "layout": { "right": [{ "id": "omarchy.tray" }, { "id": "omarchy.agents" }] } } }
JSON
SHELL_STATUS=1 run_migration
[[ $(ids center) == '["omacom.elsewhen"]' && $(ids right) == '["omarchy.tray","omarchy.agents"]' ]] ||
  fail "migration places the widget with no shell running" "$(cat "$config")"
pass "migration places the widget with no shell running"

# A package the mirror does not carry yet leaves the migration pending rather
# than half-done: the layout must not name a widget nothing can install.
: >"$INSTALLED_PACKAGES"
cat >"$config" <<'JSON'
{ "version": 1, "bar": { "layout": { "right": [{ "id": "omarchy.tray" }, { "id": "omarchy.agents" }] } } }
JSON
before=$(sha256sum "$config")
if FAIL_INSTALL=1 run_migration 2>/dev/null; then
  fail "a failed package installation must leave the migration pending"
fi
[[ $before == $(sha256sum "$config") ]] ||
  fail "a failed package installation leaves the layout untouched" "$(cat "$config")"
pass "a failed package installation is propagated and changes nothing"

# ------------------------------------------------- pre-package checkouts
# Users who followed the README before the package existed hold a git clone
# under ~/.config/omarchy/plugins, which the packaged copy now shadows. Only a
# clone of the upstream repo with nothing local in it is retired; everything
# else is the user's and stays, and shell.json gets the widget either way.

# A clone made by `omarchy plugin add`: one commit, the given origin, nothing
# local. Built with init rather than clone so the origin can be any URL form.
make_checkout() {
  local origin="$1"
  rm -rf "$checkout"
  mkdir -p "$checkout"
  git -C "$checkout" init -q
  git -C "$checkout" remote add origin "$origin"
  printf '{ "id": "omacom.elsewhen" }\n' >"$checkout/manifest.json"
  printf 'import QtQuick\nItem {}\n' >"$checkout/Panel.qml"
  git -C "$checkout" add -A
  git -C "$checkout" commit -q -m "Elsewhen"
  git -C "$checkout" update-ref refs/remotes/origin/main HEAD
}

reset_layout() {
  cat >"$config" <<'JSON'
{ "version": 1, "bar": { "layout": { "right": [{ "id": "omarchy.tray" }, { "id": "omarchy.power" }] } } }
JSON
}

assert_widget_placed() {
  [[ $(ids center) == '["omacom.elsewhen"]' && $(ids right) == '["omarchy.tray","omarchy.power"]' ]] ||
    fail "$1 still gets the widget" "$(cat "$config")"
}

assert_retired() {
  local description="$1"
  [[ ! -e $checkout && ! -L $checkout ]] || fail "$description is retired" "$(ls -la "$checkout")"
  grep -q 'Retired the omacom.elsewhen checkout' "$output" || fail "$description is reported as retired" "$(cat "$output")"
  assert_widget_placed "$description"
  pass "$description is retired"
}

assert_kept() {
  local description="$1"
  [[ -e $checkout || -L $checkout ]] || fail "$description is kept"
  grep -q 'takes precedence over' "$output" || fail "$description is reported as shadowed" "$(cat "$output")"
  assert_widget_placed "$description"
  pass "$description is kept"
}

for origin in \
  https://github.com/omacom/elsewhen.git \
  https://github.com/omacom/elsewhen \
  git@github.com:omacom/elsewhen.git \
  ssh://git@github.com/omacom/elsewhen.git \
  https://GitHub.com/Omacom/Elsewhen/; do
  make_checkout "$origin"
  reset_layout
  run_migration
  assert_retired "a pristine clone with origin $origin"
done

make_checkout https://github.com/omacom/elsewhen.git
printf 'import QtQuick\nItem { id: mine }\n' >"$checkout/Panel.qml"
reset_layout
run_migration
assert_kept "a clone with a modified tracked file"
[[ $(cat "$checkout/Panel.qml") == $'import QtQuick\nItem { id: mine }' ]] ||
  fail "a kept clone keeps its local change" "$(cat "$checkout/Panel.qml")"
pass "a kept clone keeps its local change"

make_checkout https://github.com/omacom/elsewhen.git
printf 'notes\n' >"$checkout/NOTES.md"
reset_layout
run_migration
assert_kept "a clone with an untracked file"

make_checkout https://github.com/omacom/elsewhen.git
printf 'import QtQuick\nItem { id: mine }\n' >"$checkout/Panel.qml"
git -C "$checkout" add Panel.qml
git -C "$checkout" commit -q -m "Local customization"
local_commit=$(git -C "$checkout" rev-parse HEAD)
reset_layout
run_migration
assert_kept "a clean clone with an unpublished commit"
[[ $(git -C "$checkout" rev-parse HEAD) == "$local_commit" ]] || fail "local commit survives"

make_checkout https://github.com/omacom/elsewhen.git
git -C "$checkout" checkout -qb local-work
printf 'local branch\n' >"$checkout/Panel.qml"
git -C "$checkout" commit -qam "Unpublished branch"
git -C "$checkout" checkout -q --detach refs/remotes/origin/main
reset_layout
run_migration
assert_kept "an unpublished commit on another branch"

make_checkout https://github.com/omacom/elsewhen.git
printf 'stashed work\n' >"$checkout/Panel.qml"
git -C "$checkout" stash push -q
reset_layout
run_migration
assert_kept "a clean clone with stashed work"

make_checkout https://github.com/omacom/elsewhen.git
git -C "$checkout" config status.showUntrackedFiles no
printf 'private-notes\n' >"$checkout/.git/info/exclude"
printf 'ignored work\n' >"$checkout/private-notes"
reset_layout
run_migration
assert_kept "a clone with an ignored file"
[[ $(cat "$checkout/private-notes") == "ignored work" ]] || fail "ignored file survives"

make_checkout https://github.com/omacom/elsewhen.git
printf 'recoverable work\n' >"$checkout/Panel.qml"
git -C "$checkout" commit -qam "Recoverable local commit"
git -C "$checkout" reset -q --hard refs/remotes/origin/main
reset_layout
run_migration
assert_kept "a local commit retained only by the reflog"

make_checkout https://github.com/omacom/elsewhen.git
git -C "$checkout" update-ref -d refs/remotes/origin/main
reset_layout
run_migration
assert_kept "a clone without recorded upstream history"

make_checkout https://github.com/omacom/elsewhen.git
git -C "$checkout" config status.showUntrackedFiles no
printf 'untracked work\n' >"$checkout/NOTES.md"
reset_layout
run_migration
assert_kept "untracked files hidden by the user Git configuration"

make_checkout https://github.com/someone/elsewhen-fork.git
reset_layout
run_migration
assert_kept "a clone of another repository"

make_checkout https://github.com/omacom/elsewhen.git
git -C "$checkout" remote remove origin
reset_layout
run_migration
assert_kept "a clone without an origin remote"

rm -rf "$checkout"
mkdir -p "$checkout"
printf '{ "id": "omacom.elsewhen" }\n' >"$checkout/manifest.json"
reset_layout
run_migration
assert_kept "a plain directory without .git"

rm -rf "$checkout"
make_checkout https://github.com/omacom/elsewhen.git
mv "$checkout" "$test_dir/elsewhen-src"
ln -s "$test_dir/elsewhen-src" "$checkout"
reset_layout
run_migration
assert_kept "a symlinked checkout"
[[ -L $checkout && -f $test_dir/elsewhen-src/manifest.json ]] ||
  fail "a symlinked checkout stays a symlink with its target intact" "$(ls -la "$checkout" "$test_dir/elsewhen-src")"
pass "a symlinked checkout stays a symlink with its target intact"

rm -f "$checkout"
reset_layout
run_migration
grep -q 'omacom.elsewhen checkout\|takes precedence' "$output" && fail "no checkout means no checkout report" "$(cat "$output")"
assert_widget_placed "a machine without a checkout"
pass "a machine without a checkout is left alone"
