#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command tar
require_command sha256sum
require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
test_home="$test_tmp/home"
curl_urls="$test_tmp/curl-urls"
outcome="$test_tmp/outcome"
fixture="$ROOT/test/shell.d/fixtures/origin-install.sh"
mkdir -p "$stub_bin" "$test_home/.local/bin" "$test_home/.local/share/cursor/origin"

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash
if [[ $1 == -m ]]; then
  echo "${OMARCHY_TEST_UNAME_M:-x86_64}"
  exit 0
fi
exec /usr/bin/uname "$@"
SH

cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
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
printf '%s\n' "$url" >>"$TEST_CURL_URLS"

if [[ $url == https://downloads.cursor.com/origin/install.sh ]]; then
  if [[ -n $output ]]; then
    cat "$TEST_INSTALL_SH" >"$output"
  else
    cat "$TEST_INSTALL_SH"
  fi
  exit 0
fi

if [[ $url == https://downloads.cursor.com/co/*/linux-*/co.tar.gz ]]; then
  [[ -n $output ]] || exit 22
  printf '%s' "${TEST_ARTIFACT:-wrong-bytes}" >"$output"
  exit 0
fi

exit 22
SH

cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
exit 0
SH

chmod +x "$stub_bin"/*

install_owned() {
  local ver=${1:-1.0.0}
  local dir="$test_home/.local/share/cursor/origin/$ver"
  mkdir -p "$dir"
  printf '#!/bin/bash\necho old-origin\n' >"$dir/origin"
  chmod +x "$dir/origin"
  ln -sfn "$dir/origin" "$test_home/.local/bin/origin"
}

run_origin() {
  : >"$curl_urls"
  : >"$outcome"
  HOME="$test_home" \
    XDG_CONFIG_HOME="$test_home/.config" \
    PATH="$test_home/.local/bin:$stub_bin:$ROOT/bin:/usr/bin:/bin" \
    OMARCHY_VENDOR_OUTCOME="$outcome" \
    TEST_CURL_URLS="$curl_urls" \
    TEST_INSTALL_SH="${TEST_INSTALL_SH:-$fixture}" \
    TEST_ARTIFACT="${TEST_ARTIFACT:-wrong-bytes}" \
    OMARCHY_TEST_UNAME_M="${OMARCHY_TEST_UNAME_M:-x86_64}" \
    ORIGIN_INSTALL_CHANNEL="${ORIGIN_INSTALL_CHANNEL:-}" \
    CO_INSTALL_CHANNEL="${CO_INSTALL_CHANNEL:-}" \
    "$ROOT/bin/omarchy-update-origin" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
}

assert_outcome() {
  local expected=$1 description=$2
  local got
  got=$(<"$outcome")
  [[ $got == "$expected" ]] || fail "$description" "$got"
}

tarball_fetched() {
  grep -q '/co.tar.gz$' "$curl_urls"
}

rm -rf "$test_home/.local/share/cursor/origin" "$test_home/.local/bin/origin"
mkdir -p "$test_home/.local/share/cursor/origin" "$test_home/.local/bin"
install_owned 1.0.0

set +e
run_origin --check
rc=$?
set -e
(( rc == 0 )) || fail "origin --check exits 0" "$(cat "$test_tmp/err")"
assert_outcome $'origin\tcurrent\t1.0.0\t2026.09.08-22-50-39-8f6b2f8' "origin --check parses today's stable linux-x64 block"
tarball_fetched && fail "origin --check does not fetch the tarball"
pass "origin --check parses the stable linux-x64 block"

set +e
run_origin
rc=$?
set -e
(( rc == 1 )) || fail "digest mismatch exits 1" "exit $rc $(cat "$test_tmp/err") $(cat "$test_tmp/out")"
assert_outcome $'origin\trefused\t1.0.0\t2026.09.08-22-50-39-8f6b2f8' "digest mismatch records refused"
tarball_fetched || fail "digest mismatch fetched the artifact"
[[ ! -e $test_home/.local/share/cursor/origin/2026.09.08-22-50-39-8f6b2f8 ]] ||
  fail "digest mismatch does not apply"
[[ $(readlink -f "$test_home/.local/bin/origin") == "$test_home/.local/share/cursor/origin/1.0.0/origin" ]] ||
  fail "digest mismatch leaves the installed origin in place"
pass "sha256 mismatch refuses apply"

mkdir -p "$test_home/.config/origin-cli"
printf '%s\n' '{"channel":"latest"}' >"$test_home/.config/origin-cli/config.json"
set +e
run_origin --check
rc=$?
set -e
(( rc == 0 )) || fail "config.json channel --check exits 0"
assert_outcome $'origin\tcurrent\t1.0.0\t2026.09.10-22-25-12-9621f10' "config.json channel wins over the stable default"
rm -f "$test_home/.config/origin-cli/config.json"
pass "origin channel reads config.json before env"

missing_sha="$test_tmp/install-no-sha.sh"
sed '/sha=/d' "$fixture" >"$missing_sha"
TEST_INSTALL_SH=$missing_sha
set +e
run_origin
rc=$?
set -e
(( rc == 0 )) || fail "missing vendor sha is a soft skip" "exit $rc"
assert_outcome $'origin\tunreachable\t1.0.0\t--' "missing vendor sha fails resolve"
tarball_fetched && fail "missing vendor sha does not fetch"
TEST_INSTALL_SH=$fixture
pass "missing vendor field fails resolve"

rm -rf "$test_home/.local/share/cursor/origin" "$test_home/.local/bin/origin"
printf '#!/bin/bash\necho vendor-origin\n' >"$test_home/.local/bin/origin"
chmod +x "$test_home/.local/bin/origin"
set +e
run_origin
rc=$?
set -e
(( rc == 0 )) || fail "foreign origin exits 0"
assert_outcome $'origin\tforeign\t--\t--' "foreign origin is left alone"
tarball_fetched && fail "foreign origin does not fetch"
pass "foreign origin is left alone"

set +e
HOME="$test_home" PATH="$stub_bin:$ROOT/bin:/usr/bin:/bin" "$ROOT/bin/omarchy-install-origin" --check
rc=$?
set -e
(( rc == 1 )) || fail "omarchy-install-origin --check is --installed"
pass "omarchy-install-origin --check uses --installed"
