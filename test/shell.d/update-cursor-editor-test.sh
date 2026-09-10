#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command ar
require_command bsdtar
require_command sha256sum
require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
curl_urls="$test_tmp/curl-urls"
outcome="$test_tmp/outcome"
log="$test_tmp/log"
deb="$test_tmp/cursor_3.19.19_amd64.deb"
mkdir -p "$stub_bin"

API_JSON='{"version":"3.19.19","debUrl":"https://downloads.cursor.com/production/6496ea8a068aebfcd21990e70ff522e9abf10c8c/linux/x64/deb/amd64/deb/cursor_3.19.19_amd64.deb","commitSha":"6496ea8a068aebfcd21990e70ff522e9abf10c8c"}'

make_fake_deb() {
  local dest=$1 version=$2
  local work
  work=$(mktemp -d)
  mkdir -p "$work/control" "$work/data/usr/share/cursor"
  printf 'Package: cursor\nVersion: %s\n' "$version" >"$work/control/control"
  tar -czf "$work/control.tar.gz" -C "$work/control" control
  printf '2.0\n' >"$work/debian-binary"
  printf '#!/bin/bash\necho cursor\n' >"$work/data/usr/share/cursor/cursor"
  chmod +x "$work/data/usr/share/cursor/cursor"
  tar -czf "$work/data.tar.gz" -C "$work/data" usr
  (cd "$work" && ar r "$dest" debian-binary control.tar.gz data.tar.gz >/dev/null)
  rm -rf "$work"
}

write_stub() {
  local name=$1
  local body=$2
  cat >"$stub_bin/$name" <<SH
#!/bin/bash
$body
SH
  chmod +x "$stub_bin/$name"
}

write_stub uname '
if [[ $1 == -m ]]; then
  echo x86_64
  exit 0
fi
exec /usr/bin/uname "$@"
'

write_stub pacman '
if [[ $1 == "-Q" && $2 == "cursor-bin" ]]; then
  if (( TEST_PRESENT )); then
    printf "cursor-bin %s\n" "$TEST_INSTALLED"
    exit 0
  fi
  exit 1
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
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  case ${args[i]} in
  -o | --output)
    output=${args[i + 1]}
    i=$((i + 2))
    continue
    ;;
  esac
  i=$((i + 1))
done
url=${args[-1]}
printf "%s\n" "$url" >>"$TEST_CURL_URLS"

if [[ $url == *www.cursor.com/api/download* ]]; then
  [[ ${TEST_API:-1} == 1 ]] || exit 22
  printf "%s\n" "$TEST_API_JSON"
  exit 0
fi

if [[ $url == *.deb ]]; then
  [[ -n $output ]] || exit 22
  cat "$TEST_DEB" >"$output"
  exit 0
fi

exit 22
'

write_stub makepkg '
bash -n PKGBUILD
grep "^sha256sums=" PKGBUILD >>"$TEST_LOG"
grep "^pkgname=" PKGBUILD >>"$TEST_LOG"
version=$(sed -n "s/^pkgver=//p" PKGBUILD)
pkg="cursor-bin-${version}-1-x86_64.pkg.tar.zst"
: >"${PKGDEST:-.}/$pkg"
printf "makepkg %s\n" "$pkg" >>"$TEST_LOG"
'

write_stub omarchy-notification-send 'exit 0'
write_stub pgrep 'exit 1'

run_editor() {
  : >"$curl_urls"
  : >"$outcome"
  : >"$log"
  PATH="$stub_bin:$ROOT/bin:/usr/bin:/bin" \
    OMARCHY_VENDOR_OUTCOME="$outcome" \
    TEST_CURL_URLS="$curl_urls" \
    TEST_LOG="$log" \
    TEST_DEB="$deb" \
    TEST_API_JSON="${TEST_API_JSON:-$API_JSON}" \
    TEST_API="${TEST_API:-1}" \
    TEST_PRESENT="${TEST_PRESENT:-1}" \
    TEST_INSTALLED="${TEST_INSTALLED:-3.19.18-1}" \
    "$ROOT/bin/omarchy-update-cursor-editor" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
}

assert_outcome() {
  local expected=$1 description=$2
  local got
  got=$(<"$outcome")
  [[ $got == "$expected" ]] || fail "$description" "$got"
}

make_fake_deb "$deb" 3.19.19
deb_digest=$(sha256sum "$deb" | awk '{ print $1 }')

TEST_PRESENT=0
set +e
run_editor
rc=$?
set -e
(( rc == 0 )) || fail "absent editor exits 0"
assert_outcome $'cursor-editor\tabsent\t--\t--' "absent editor is silent"
grep -q '\.deb$' "$curl_urls" && fail "absent editor does not download"
pass "absent editor is skipped"

TEST_PRESENT=1
TEST_INSTALLED=3.19.19-1
set +e
run_editor
rc=$?
set -e
(( rc == 0 )) || fail "current editor exits 0"
assert_outcome $'cursor-editor\tcurrent\t3.19.19\t3.19.19' "current editor records current"
grep -q '\.deb$' "$curl_urls" && fail "current editor does not download"
pass "current editor is left alone"

TEST_INSTALLED=3.19.18-1
set +e
run_editor
rc=$?
set -e
(( rc == 0 )) || fail "newer editor updates" "$(cat "$test_tmp/err") $(cat "$test_tmp/out")"
assert_outcome $'cursor-editor\tupdated\t3.19.18\t3.19.19' "newer editor records updated"
grep -q "sha256sums=('${deb_digest}')" "$log" || fail "PKGBUILD pins the local digest" "$(cat "$log")"
grep -qx 'pkgname=cursor-bin' "$log" || fail "PKGBUILD uses pkgname=cursor-bin" "$(cat "$log")"
grep -q 'makepkg cursor-bin-3.19.19-1-x86_64.pkg.tar.zst' "$log" || fail "editor builds an Arch package" "$(cat "$log")"
grep -q 'pacman -U --noconfirm' "$log" || fail "editor installs with pacman -U" "$(cat "$log")"
pass "newer editor repackages cursor-bin"

make_fake_deb "$deb" 9.9.9
set +e
run_editor
rc=$?
set -e
(( rc == 1 )) || fail "inspect mismatch exits 1" "exit $rc"
assert_outcome $'cursor-editor\tfailed\t3.19.18\t3.19.19' "inspect mismatch records failed"
grep -q 'makepkg\|pacman -U' "$log" && fail "inspect mismatch does not apply" "$(cat "$log")"
pass "vendor_inspect refuses a Version mismatch"

TEST_API=0
set +e
run_editor
rc=$?
set -e
(( rc == 0 )) || fail "unreachable editor API exits 0"
assert_outcome $'cursor-editor\tunreachable\t3.19.18\t--' "unreachable editor API records unreachable"
pass "unreachable editor API is a soft skip"

TEST_API=1
TEST_API_JSON='{"version":"3.19.19","debUrl":"https://downloads.cursor.com/production/deadbeefdeadbeefdeadbeefdeadbeefdeadbeef/linux/x64/deb/amd64/deb/cursor_3.19.19_amd64.deb"}'
set +e
run_editor
rc=$?
set -e
(( rc == 0 )) || fail "missing commitSha exits 0"
assert_outcome $'cursor-editor\tunreachable\t3.19.18\t--' "missing commitSha fails resolve"
pass "missing vendor field fails resolve"
