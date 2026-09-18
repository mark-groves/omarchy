#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

drop="$ROOT/bin/omarchy-pam-pair-drop"
fixtures="$ROOT/test/shell.d/fixtures/polkit-pam"

[[ -x $drop ]] || fail "omarchy-pam-pair-drop is executable"

assert_print_matches() {
  local input=$1 expected=$2 module=$3
  local got
  got=$(mktemp)
  "$drop" --from "$input" --print "$module" >"$got"
  diff -u "$expected" "$got" >/dev/null ||
    fail "pair-drop $(basename "$input") $module matches $(basename "$expected")" "$(diff -u "$expected" "$got")"
  rm -f "$got"
  pass "pair-drop $(basename "$input") $module is $(basename "$expected")"
}

assert_print_matches "$fixtures/sudo-fprintd-plus-howdy.pam" "$fixtures/sudo-howdy-after-drop-fprintd.pam" pam_fprintd.so
assert_print_matches "$fixtures/sudo-howdy-only.pam" "$fixtures/sudo-howdy-only.pam" pam_fprintd.so

mutated=$(mktemp)
sed -e '/pam_fprintd\.so/d' -e '/omarchy-hw-laptop-closed/d' "$fixtures/sudo-fprintd-plus-howdy.pam" >"$mutated"
if diff -q "$fixtures/sudo-howdy-after-drop-fprintd.pam" "$mutated" >/dev/null; then
  fail "a global lid-line sed still strips the howdy gate" "$(cat "$mutated")"
fi
rm -f "$mutated"
pass "a global lid-line sed still fails to keep the howdy gate"

set +e
"$drop" --from "$fixtures/sudo-howdy-only.pam" pam_fprintd.so >/dev/null 2>&1
status=$?
set -e
(( status == 64 )) || fail "--from without --print exits 64" "exit $status"
pass "--from without --print exits 64"
