#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
mkdir -p "$stub_bin"

write_child() {
  local name=$1
  local body=$2
  cat >"$stub_bin/$name" <<SH
#!/bin/bash
$body
SH
  chmod +x "$stub_bin/$name"
}

run_fanout() {
  PATH="$stub_bin:$ROOT/bin:/usr/bin:/bin" \
    "$ROOT/bin/omarchy-update-cursor" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
}

write_child omarchy-update-cursor-editor '
printf "%s\t%s\t%s\t%s\n" cursor-editor absent -- -- >>"$OMARCHY_VENDOR_OUTCOME"
exit 0
'
write_child omarchy-update-cursor-agent '
printf "%s\t%s\t%s\t%s\n" cursor-agent absent -- -- >>"$OMARCHY_VENDOR_OUTCOME"
exit 0
'
write_child omarchy-update-origin '
printf "%s\t%s\t%s\t%s\n" origin absent -- -- >>"$OMARCHY_VENDOR_OUTCOME"
exit 0
'

set +e
run_fanout
rc=$?
set -e
(( rc == 0 )) || fail "all-absent fan-out exits 0"
[[ ! -s $test_tmp/out ]] || fail "all-absent fan-out is silent" "$(cat "$test_tmp/out")"
pass "all-absent fan-out is silent"

write_child omarchy-update-cursor-editor '
echo "Update Cursor Editor"
printf "%s\t%s\t%s\t%s\n" cursor-editor updated 3.19.18 3.19.19 >>"$OMARCHY_VENDOR_OUTCOME"
exit 0
'
write_child omarchy-update-cursor-agent '
echo "Update Cursor Agent"
printf "%s\t%s\t%s\t%s\n" cursor-agent current 2026.09.08-6caf4ff 2026.09.08-6caf4ff >>"$OMARCHY_VENDOR_OUTCOME"
exit 0
'
write_child omarchy-update-origin '
printf "%s\t%s\t%s\t%s\n" origin absent -- -- >>"$OMARCHY_VENDOR_OUTCOME"
exit 1
'

set +e
run_fanout
rc=$?
set -e
(( rc == 1 )) || fail "fan-out uses the worst child exit" "exit $rc"
grep -q 'Update Cursor Editor' "$test_tmp/out" || fail "fan-out prints member output"
grep -q 'Cursor: 1 updated, 1 current, 1 not installed.' "$test_tmp/out" ||
  fail "fan-out prints a summary" "$(cat "$test_tmp/out")"
pass "fan-out prints members and a summary"

write_child omarchy-update-cursor-editor '
printf "%s\t%s\t%s\t%s\n" cursor-editor stale 3.19.18 3.19.19 >>"$OMARCHY_VENDOR_OUTCOME"
echo "cursor-editor   3.19.18 -> 3.19.19               pinned-url"
exit 0
'
write_child omarchy-update-cursor-agent '
printf "%s\t%s\t%s\t%s\n" cursor-agent current 2026.09.08-6caf4ff 2026.09.08-6caf4ff >>"$OMARCHY_VENDOR_OUTCOME"
echo "cursor-agent    2026.09.08-6caf4ff     current   pinned-url"
exit 0
'
write_child omarchy-update-origin '
printf "%s\t%s\t%s\t%s\n" origin absent -- -- >>"$OMARCHY_VENDOR_OUTCOME"
echo "origin          not installed"
exit 0
'

set +e
run_fanout --check
rc=$?
set -e
(( rc == 0 )) || fail "fan-out --check exits 0" "exit $rc"
grep -q 'cursor-editor   3.19.18 -> 3.19.19' "$test_tmp/out" || fail "fan-out --check prints member status"
grep -q 'Cursor: 1 newer, 1 current, 1 not installed.' "$test_tmp/out" ||
  fail "fan-out --check summarizes stale as newer" "$(cat "$test_tmp/out")"
pass "fan-out --check summarizes stale as newer"

set +e
run_fanout --please
rc=$?
set -e
(( rc == 2 )) || fail "fan-out rejects unknown flags" "exit $rc"
pass "fan-out rejects unknown flags"
