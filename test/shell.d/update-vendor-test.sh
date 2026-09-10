#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command sha256sum
require_command vercmp

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
driver="$test_tmp/omarchy-update-fake"
outcome="$test_tmp/outcome"
apply_log="$test_tmp/apply"
curl_log="$test_tmp/curl"
installed_file="$test_tmp/installed"
mkdir -p "$stub_bin"

allow='^https://downloads\.cursor\.com/fake/[A-Za-z0-9._+-]+/app\.tar\.gz$'
good_url='https://downloads.cursor.com/fake/1.2.3/app.tar.gz'
right_bytes='official-bytes'
right_digest=$(printf '%s' "$right_bytes" | sha256sum | awk '{ print $1 }')

pinned_record=$(printf 'version=%s\turl=%s\tintegrity=%s' '1.2.3' "$good_url" 'pinned-url')
digest_record=$(printf 'version=%s\turl=%s\tintegrity=%s\tdigest=%s' '1.2.3' "$good_url" 'digest' "$right_digest")
current_record=$(printf 'version=%s\turl=%s\tintegrity=%s' '1.0.0' 'https://downloads.cursor.com/fake/1.0.0/app.tar.gz' 'pinned-url')
untrusted_record=$(printf 'version=%s\turl=%s\tintegrity=%s' '1.2.3' 'https://evil.example/fake/1.2.3/app.tar.gz' 'pinned-url')
rebuild_record=$(printf 'version=%s\turl=%s\tintegrity=%s' '2026.09.08-e8db854' 'https://downloads.cursor.com/fake/2026.09.08-e8db854/app.tar.gz' 'pinned-url')
older_date_record=$(printf 'version=%s\turl=%s\tintegrity=%s' '2026.08.11-e8db854' 'https://downloads.cursor.com/fake/2026.08.11-e8db854/app.tar.gz' 'pinned-url')

cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_CURL_LOG"
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
[[ $url == https://downloads.cursor.com/* ]] || exit 22
[[ -n $output ]] || exit 22
printf '%s' "${TEST_ARTIFACT:-}" >"$output"
exit 0
SH

cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
exit 0
SH

chmod +x "$stub_bin"/*

cat >"$driver" <<'SH'
#!/bin/bash
set -euo pipefail
source omarchy-update-vendor

VENDOR_ID=${TEST_VENDOR_ID:-fake}
VENDOR_LABEL=${TEST_VENDOR_LABEL:-Fake App}
VENDOR_ICON=""
VENDOR_URL_ALLOW=$TEST_URL_ALLOW
VENDOR_INTEGRITY_FLOOR=$TEST_FLOOR

vendor_arch() {
  [[ ${TEST_ARCH_FAIL:-0} == 1 ]] && return 1
  printf '%s\n' "${TEST_ARCH:-x64}"
}

vendor_installed() {
  if [[ -n ${TEST_PROBE:-} ]]; then
    printf '%s\n' "$TEST_PROBE"
    return 0
  fi
  if [[ -f $TEST_INSTALLED_FILE ]]; then
    printf 'installed\t%s\n' "$(<"$TEST_INSTALLED_FILE")"
    return 0
  fi
  printf 'absent\n'
}

vendor_resolve() {
  [[ ${TEST_RESOLVE_FAIL:-0} == 1 ]] && return 1
  printf '%s\n' "$TEST_RECORD"
}

vendor_apply() {
  printf 'apply\t%s\t%s\n' "$1" "$2" >>"$TEST_APPLY_LOG"
  [[ ${TEST_APPLY_FAIL:-0} == 1 ]] && return 1
  printf '%s\n' "$2" >"$TEST_INSTALLED_FILE"
}

if [[ ${TEST_INSPECT:-} == fail ]]; then
  vendor_inspect() { return 1; }
fi

omarchy_update_vendor "$@"
SH
chmod +x "$driver"

run_vendor() {
  : >"$outcome"
  : >"$apply_log"
  : >"$curl_log"
  PATH="$stub_bin:$ROOT/bin:/usr/bin:/bin" \
    OMARCHY_VENDOR_OUTCOME="$outcome" \
    TEST_URL_ALLOW="$allow" \
    TEST_FLOOR="${TEST_FLOOR:-pinned-url}" \
    TEST_APPLY_LOG="$apply_log" \
    TEST_CURL_LOG="$curl_log" \
    TEST_INSTALLED_FILE="$installed_file" \
    TEST_ARTIFACT="${TEST_ARTIFACT:-$right_bytes}" \
    TEST_PROBE="${TEST_PROBE-}" \
    TEST_RECORD="${TEST_RECORD:-}" \
    TEST_RESOLVE_FAIL="${TEST_RESOLVE_FAIL:-0}" \
    TEST_ARCH_FAIL="${TEST_ARCH_FAIL:-0}" \
    TEST_APPLY_FAIL="${TEST_APPLY_FAIL:-0}" \
    TEST_INSPECT="${TEST_INSPECT:-}" \
    "$driver" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
}

outcome_line() {
  [[ -s $outcome ]] || printf ''
  [[ -s $outcome ]] && cat "$outcome"
}

assert_outcome() {
  local expected=$1 description=$2
  local got
  got=$(outcome_line)
  [[ $got == "$expected" ]] || fail "$description" "$got"
}

assert_exit() {
  local expected=$1 description=$2
  set +e
  run_vendor "${@:3}"
  local rc=$?
  set -e
  (( rc == expected )) || fail "$description" "exit $rc"
}

rm -f "$installed_file"

if "$ROOT/bin/omarchy-update-vendor" >/dev/null 2>&1; then
  fail "engine refuses to run as a command"
fi
pass "engine refuses to run as a command"

TEST_PROBE=absent
TEST_RECORD=$pinned_record
assert_exit 0 "skip-if-absent exits 0"
[[ ! -s $test_tmp/out ]] || fail "skip-if-absent is silent" "$(cat "$test_tmp/out")"
[[ ! -s $apply_log ]] || fail "skip-if-absent does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tabsent\t--\t--' "skip-if-absent records absent"
pass "skip-if-absent, silently"

TEST_PROBE=$'foreign\t/tmp/mise/shims/cursor-agent\tnot Omarchy'\''s install'
TEST_RECORD=$pinned_record
assert_exit 0 "skip-if-foreign exits 0"
[[ ! -s $apply_log ]] || fail "skip-if-foreign does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tforeign\t--\t--' "skip-if-foreign records foreign"
pass "skip-if-foreign, loudly, without applying"

TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$current_record
assert_exit 0 "skip-if-current exits 0"
[[ ! -s $apply_log ]] || fail "skip-if-current does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tcurrent\t1.0.0\t1.0.0' "skip-if-current records current"
pass "skip-if-current"

TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$pinned_record
TEST_RESOLVE_FAIL=1
assert_exit 0 "skip-if-unreachable exits 0"
[[ ! -s $apply_log ]] || fail "skip-if-unreachable does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tunreachable\t1.0.0\t--' "skip-if-unreachable records unreachable"
TEST_RESOLVE_FAIL=0
pass "skip-if-unreachable, exit 0"

TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$untrusted_record
assert_exit 0 "skip-if-untrusted exits 0"
[[ ! -s $apply_log ]] || fail "skip-if-untrusted does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tunreachable\t1.0.0\t--' "skip-if-untrusted records unreachable"
pass "skip-if-untrusted, exit 0"

TEST_FLOOR=digest
TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$pinned_record
assert_exit 0 "skip-if-downgraded exits 0"
[[ ! -s $apply_log ]] || fail "skip-if-downgraded does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tunreachable\t1.0.0\t--' "skip-if-downgraded records unreachable"
TEST_FLOOR=pinned-url
pass "skip-if-downgraded, exit 0"
pass "digest-floor downgrade is unreachable"

TEST_FLOOR=digest
TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$digest_record
TEST_ARTIFACT='wrong-bytes'
assert_exit 1 "refuse-on-digest-mismatch exits 1"
[[ ! -s $apply_log ]] || fail "refuse-on-digest-mismatch does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\trefused\t1.0.0\t1.2.3' "refuse-on-digest-mismatch records refused"
TEST_FLOOR=pinned-url
TEST_ARTIFACT=$right_bytes
pass "refuse-on-digest-mismatch, exit 1"

rm -f "$installed_file"
TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$pinned_record
assert_exit 0 "apply-when-newer exits 0"
[[ -s $apply_log ]] || fail "apply-when-newer calls apply"
assert_outcome $'fake\tupdated\t1.0.0\t1.2.3' "apply-when-newer records updated"
pass "apply-when-newer, exit 0"

rm -f "$installed_file"
TEST_PROBE=absent
TEST_RECORD=$pinned_record
assert_exit 0 "apply-when-absent without --install stays absent"
assert_outcome $'fake\tabsent\t--\t--' "absent without --install does not apply"
assert_exit 0 "apply-when-absent under --install exits 0" --install
[[ -s $apply_log ]] || fail "apply-when-absent under --install calls apply"
assert_outcome $'fake\tupdated\t--\t1.2.3' "apply-when-absent under --install records updated"
pass "apply-when-absent under --install"

rm -f "$installed_file"
TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$pinned_record
assert_exit 0 "idempotent first run exits 0"
assert_outcome $'fake\tupdated\t1.0.0\t1.2.3' "idempotent first run updates"
unset TEST_PROBE
assert_exit 0 "idempotent second run exits 0"
[[ ! -s $apply_log ]] || fail "idempotent second run does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tcurrent\t1.2.3\t1.2.3' "idempotent second run is current"
TEST_PROBE=$'installed\t1.0.0'
pass "idempotent"

: >"$curl_log"
TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$pinned_record
assert_exit 0 "--check exits 0" --check
[[ ! -s $curl_log ]] || fail "--check never downloads" "$(cat "$curl_log")"
[[ ! -s $apply_log ]] || fail "--check never applies" "$(cat "$apply_log")"
assert_outcome $'fake\tstale\t1.0.0\t1.2.3' "--check records stale when newer"
pass "--check never downloads"

TEST_PROBE=$'installed\t1.2.3'
TEST_RECORD=$pinned_record
assert_exit 0 "--check current exits 0" --check
assert_outcome $'fake\tcurrent\t1.2.3\t1.2.3' "--check records current when current"
pass "--check records current when current"

TEST_PROBE=$'installed\t2026.09.08-6caf4ff'
TEST_RECORD=$rebuild_record
assert_exit 0 "--check same-day rebuild exits 0" --check
assert_outcome $'fake\tstale\t2026.09.08-6caf4ff\t2026.09.08-e8db854' "--check records stale for a same-day rebuild"
pass "--check records stale for a same-day rebuild"

rm -f "$installed_file"
TEST_PROBE=$'installed\t2026.09.08-6caf4ff'
TEST_RECORD=$older_date_record
assert_exit 0 "older release date exits 0"
[[ ! -s $apply_log ]] || fail "older release date does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tcurrent\t2026.09.08-6caf4ff\t2026.08.11-e8db854' "older release date stays current"
pass "an older release date never downgrades"

TEST_PROBE=absent
TEST_RECORD=$pinned_record
assert_exit 0 "--check absent exits 0" --check
grep -q 'not installed' "$test_tmp/out" || fail "--check absent prints not installed" "$(cat "$test_tmp/out")"
assert_outcome $'fake\tabsent\t--\t--' "--check absent records absent"
[[ ! -s $apply_log ]] || fail "--check absent does not apply" "$(cat "$apply_log")"
pass "--check absent prints not installed"

TEST_INSPECT=fail
TEST_PROBE=$'installed\t1.0.0'
TEST_RECORD=$pinned_record
assert_exit 1 "inspect-hook failure exits 1"
[[ ! -s $apply_log ]] || fail "inspect-hook failure does not apply" "$(cat "$apply_log")"
assert_outcome $'fake\tfailed\t1.0.0\t1.2.3' "inspect-hook failure records failed"
unset TEST_INSPECT
pass "inspect-hook failure"
