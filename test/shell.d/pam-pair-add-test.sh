#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

add="$ROOT/bin/omarchy-pam-pair-add"
drop="$ROOT/bin/omarchy-pam-pair-drop"
fixtures="$ROOT/test/shell.d/fixtures/polkit-pam"

[[ -x $add ]] || fail "omarchy-pam-pair-add is executable"

assert_print_matches() {
  local input=$1 expected=$2 module=$3
  local got
  got=$(mktemp)
  "$add" --from "$input" --print "$module" >"$got"
  diff -u "$expected" "$got" >/dev/null ||
    fail "pair-add $(basename "$input") $module matches $(basename "$expected")" "$(diff -u "$expected" "$got")"
  rm -f "$got"
  pass "pair-add $(basename "$input") $module is $(basename "$expected")"
}

assert_print_matches "$fixtures/sudo-vendor.pam" "$fixtures/sudo-vendor-plus-howdy.pam" pam_howdy.so
assert_print_matches "$fixtures/sudo-vendor-plus-howdy.pam" "$fixtures/sudo-vendor-plus-howdy.pam" pam_howdy.so
assert_print_matches "$fixtures/sudo-howdy-only.pam" "$fixtures/sudo-howdy-only.pam" pam_howdy.so
assert_print_matches "$fixtures/sudo-howdy-no-gate.pam" "$fixtures/sudo-howdy-only.pam" pam_howdy.so
assert_print_matches "$fixtures/sudo-fprintd-only.pam" "$fixtures/sudo-howdy-then-fprintd.pam" pam_howdy.so
assert_print_matches "$fixtures/sudo-howdy-only.pam" "$fixtures/sudo-fprintd-then-howdy.pam" pam_fprintd.so
assert_print_matches "$fixtures/sudo-fprintd-plus-howdy.pam" "$fixtures/sudo-fprintd-plus-howdy.pam" pam_howdy.so

roundtrip=$(mktemp)
"$add" --from "$fixtures/sudo-vendor.pam" --print pam_howdy.so >"$roundtrip"
"$drop" --from "$roundtrip" --print pam_howdy.so >"$roundtrip.dropped"
diff -u "$fixtures/sudo-vendor.pam" "$roundtrip.dropped" >/dev/null ||
  fail "pair-add then pair-drop on vendor sudo is identity" "$(diff -u "$fixtures/sudo-vendor.pam" "$roundtrip.dropped")"
rm -f "$roundtrip" "$roundtrip.dropped"
pass "pair-add then pair-drop on vendor sudo is identity"

set +e
"$add" --from "$fixtures/sudo-howdy-only.pam" pam_howdy.so >/dev/null 2>&1
status=$?
set -e
(( status == 64 )) || fail "--from without --print exits 64" "exit $status"
pass "--from without --print exits 64"

set +e
"$add" --from "$fixtures/sudo-no-recovery.pam" --print pam_howdy.so >/dev/null 2>&1
status=$?
set -e
(( status == 1 )) || fail "pair-add without password recovery exits 1" "exit $status"
pass "pair-add without password recovery exits 1"
