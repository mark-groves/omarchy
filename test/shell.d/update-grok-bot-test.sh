#!/bin/bash

set -euo pipefail

source "$(dirname "$0")/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

FEED_JSON='{"version":"0.43.0","url":"https://downloads.cursor.com/grokbot/stable/dd6e1fd3efb029e94e3c9d5c4d3e66510a917395/linux/x64/Sand-0.43.0-x86_64.AppImage.zsync","productVersion":"0.43.0"}'
PAGE_HTML='<a href="https://downloads.cursor.com/grokbot/stable/d8bc9c753edddb313047c9c69b480b7f8f321087/linux/x64/grok-bot_0.39.0_amd64.deb">deb</a>'

write_stub() {
  local name=$1
  local body=$2

  cat >"$stub_bin/$name" <<SH
#!/bin/bash
$body
SH
  chmod +x "$stub_bin/$name"
}

run_update() {
  PATH="$stub_bin:$PATH" \
    TEST_LOG="$test_tmp/log" \
    TEST_PRESENT="${TEST_PRESENT:-1}" \
    TEST_INSTALLED="${TEST_INSTALLED:-0.29.0-1}" \
    TEST_FEED="${TEST_FEED:-1}" \
    TEST_PAGE="${TEST_PAGE:-1}" \
    TEST_PROBE="${TEST_PROBE:-1}" \
    "$ROOT/bin/omarchy-update-grok-bot" >"$test_tmp/out" 2>"$test_tmp/err"
}

: >"$test_tmp/log"

write_stub omarchy-pkg-present '
if [[ $1 == "grok-bot" ]]; then
  if (( TEST_PRESENT )); then
    exit 0
  fi
fi
exit 1
'

write_stub pacman '
if [[ $1 == "-Q" && $2 == "grok-bot" ]]; then
  printf "grok-bot %s\n" "$TEST_INSTALLED"
  exit 0
fi
if [[ $1 == "-U" ]]; then
  printf "pacman %s\n" "$*" >>"$TEST_LOG"
  exit 0
fi
exit 1
'

write_stub sudo '
printf "sudo %s\n" "$*" >>"$TEST_LOG"
exec "$@"
'

write_stub curl '
output=""
head=0
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  case ${args[i]} in
    -o | --output)
      output=${args[i + 1]}
      i=$((i + 2))
      continue
      ;;
    -I | -fsI | --head)
      head=1
      ;;
  esac
  i=$((i + 1))
done

url=${args[-1]}

if [[ $url == *api2.cursor.sh/updates/api/update* ]]; then
  if [[ ${TEST_FEED:-1} == 1 ]]; then
    printf "%s\n" '"'$FEED_JSON'"'
    exit 0
  fi
  exit 22
fi

if [[ $url == *cursor.com/download/bot* ]]; then
  if [[ ${TEST_PAGE:-1} == 1 ]]; then
    printf "%s\n" '"'$PAGE_HTML'"'
    exit 0
  fi
  exit 22
fi

if [[ $url == *.deb ]]; then
  if [[ ${TEST_PROBE:-1} != 1 ]]; then
    exit 22
  fi
  if (( head )); then
    exit 0
  fi
  if [[ -n $output ]]; then
    : >"$output"
    printf "download %s\n" "$url" >>"$TEST_LOG"
    exit 0
  fi
  exit 0
fi

exit 22
'

write_stub makepkg '
bash -n PKGBUILD
version=$(sed -n "s/^pkgver=//p" PKGBUILD)
pkg="grok-bot-${version}-1-x86_64.pkg.tar.zst"
: >"${PKGDEST:-.}/$pkg"
printf "makepkg %s\n" "$pkg" >>"$TEST_LOG"
'

write_stub omarchy-notification-send '
printf "notify %s\n" "$*" >>"$TEST_LOG"
'

write_stub pgrep 'exit 1'

write_stub uname '
if [[ $1 == "-m" ]]; then
  echo x86_64
  exit 0
fi
/usr/bin/uname "$@"
'

TEST_PRESENT=1
if ! run_update; then
  fail "an installed outdated Grok Bot updates from the official feed" "$(cat "$test_tmp/err")"
fi
grep -q 'Official Grok Bot 0.43.0 is newer than installed 0.29.0' "$test_tmp/out" ||
  fail "updater reports the official newer version" "$(cat "$test_tmp/out")"
grep -q 'download https://downloads.cursor.com/grokbot/stable/dd6e1fd3efb029e94e3c9d5c4d3e66510a917395/linux/x64/grok-bot_0.43.0_amd64.deb' "$test_tmp/log" ||
  fail "updater downloads the official linux-x64 .deb" "$(cat "$test_tmp/log")"
grep -q 'makepkg grok-bot-0.43.0-1-x86_64.pkg.tar.zst' "$test_tmp/log" ||
  fail "updater builds an Arch package from the official .deb" "$(cat "$test_tmp/log")"
grep -q 'pacman -U --noconfirm' "$test_tmp/log" ||
  fail "updater installs the rebuilt package with pacman -U" "$(cat "$test_tmp/log")"
grep -q 'Grok Bot updated to 0.43.0' "$test_tmp/out" ||
  fail "updater reports the installed official version" "$(cat "$test_tmp/out")"
pass "an installed outdated Grok Bot updates from the official feed"

: >"$test_tmp/log"
TEST_INSTALLED=0.43.0-1
run_update || fail "an already current Grok Bot should succeed"
grep -q 'Grok Bot is already current (0.43.0)' "$test_tmp/out" ||
  fail "updater reports Grok Bot is already current" "$(cat "$test_tmp/out")"
if grep -q 'makepkg\|pacman -U\|download ' "$test_tmp/log"; then
  fail "already current Grok Bot still downloaded or installed" "$(cat "$test_tmp/log")"
fi
pass "an already current Grok Bot is left alone"

: >"$test_tmp/log"
TEST_INSTALLED=0.29.0-1
TEST_PRESENT=0
run_update || fail "missing Grok Bot should be a no-op"
if [[ -s $test_tmp/out ]]; then
  fail "missing Grok Bot printed update output" "$(cat "$test_tmp/out")"
fi
if grep -q 'makepkg\|pacman -U\|download ' "$test_tmp/log"; then
  fail "missing Grok Bot still tried to update" "$(cat "$test_tmp/log")"
fi
pass "Grok Bot is skipped when the package is not installed"

: >"$test_tmp/log"
TEST_PRESENT=1
TEST_FEED=0
run_update || fail "download-page fallback should succeed" "$(cat "$test_tmp/err")"
grep -q 'Official Grok Bot 0.39.0 is newer than installed 0.29.0' "$test_tmp/out" ||
  fail "updater falls back to the public download page" "$(cat "$test_tmp/out")"
grep -q 'grok-bot_0.39.0_amd64.deb' "$test_tmp/log" ||
  fail "download-page fallback uses the page .deb" "$(cat "$test_tmp/log")"
pass "a failed release feed falls back to the public download page"

: >"$test_tmp/log"
TEST_FEED=0
TEST_PAGE=0
run_update || fail "unreachable official releases should skip rather than fail the update"
grep -q 'Could not reach official Grok Bot releases; skipping.' "$test_tmp/out" ||
  fail "unreachable official releases explain the skip" "$(cat "$test_tmp/out")"
if grep -q 'makepkg\|pacman -U\|download ' "$test_tmp/log"; then
  fail "unreachable official releases still tried to install" "$(cat "$test_tmp/log")"
fi
pass "unreachable official releases skip without failing the update"
