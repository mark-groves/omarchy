#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

apply="$ROOT/bin/omarchy-apply-polkit-pam"
fixtures="$ROOT/test/shell.d/fixtures/polkit-pam"
polkit_overlay=/etc/pam.d/polkit-1

[[ -x $apply ]] || fail "omarchy-apply-polkit-pam is executable"

overlay_existed=0
[[ -e $polkit_overlay || -L $polkit_overlay ]] && overlay_existed=1

assert_overlay_untouched() {
  if (( overlay_existed )); then
    [[ -e $polkit_overlay || -L $polkit_overlay ]] ||
      fail "the compiler tests must not remove $polkit_overlay"
  else
    [[ ! -e $polkit_overlay && ! -L $polkit_overlay ]] ||
      fail "the compiler tests must not create $polkit_overlay"
  fi
}

print_from() {
  local input=$1
  shift
  "$apply" --from "$input" --print "$@"
}

assert_print_matches() {
  local input=$1 expected=$2
  shift 2
  local got status
  got=$(mktemp)
  set +e
  print_from "$input" "$@" >"$got"
  status=$?
  set -e
  (( status == 0 )) || fail "print from $(basename "$input") $*" "$(cat "$got")"
  diff -u "$expected" "$got" >/dev/null ||
    fail "print from $(basename "$input") $* matches $(basename "$expected")" "$(diff -u "$expected" "$got")"
  rm -f "$got"
  pass "print from $(basename "$input") $* is $(basename "$expected")"
}

assert_print_exits() {
  local expected_status=$1
  shift
  local got status
  got=$(mktemp)
  set +e
  "$apply" "$@" >"$got" 2>/dev/null
  status=$?
  set -e
  (( status == expected_status )) ||
    fail "omarchy-apply-polkit-pam $* exits $expected_status" "exit $status"
  if (( expected_status != 0 )); then
    [[ ! -s $got ]] || fail "omarchy-apply-polkit-pam $* writes no stack on error"
  fi
  rm -f "$got"
  pass "omarchy-apply-polkit-pam $* exits $expected_status"
}

assert_fixed_point() {
  local input=$1
  local first second
  first=$(mktemp)
  second=$(mktemp)
  print_from "$input" >"$first"
  print_from "$first" >"$second"
  diff -u "$first" "$second" >/dev/null ||
    fail "--from --print of $(basename "$input") is a fixed point" "$(diff -u "$first" "$second")"
  rm -f "$first" "$second"
  pass "--from --print of $(basename "$input") is a fixed point"
}

root_path_guard=$(awk '
  /^if \(\( EUID == 0 \)\); then$/ { inside = 1 }
  inside { print }
  inside && /^fi$/ { exit }
' "$apply")
grep -Fx '  export PATH=/usr/share/omarchy/bin:/usr/local/bin:/usr/bin:/bin' <<<"$root_path_guard" >/dev/null ||
  fail "the root compiler replaces its inherited command path"
if grep -E '(\.local/bin|target_user|target_home)' <<<"$root_path_guard" >/dev/null; then
  fail "the root compiler does not retain a user-controlled command directory"
fi
pass "the root compiler uses only trusted command directories"

assert_print_matches "$fixtures/face-only.pam" "$fixtures/face-only.pam"
assert_print_matches "$fixtures/fingerprint-island.pam" "$fixtures/fingerprint-island-normalized.pam"
assert_print_matches "$fixtures/fingerprint-island.pam" "$fixtures/fingerprint-island-plus-face.pam" add face
assert_print_matches "$fixtures/fingerprint-island-plus-face.pam" "$fixtures/fingerprint-island-plus-face-minus-fingerprint.pam" remove fingerprint
assert_print_matches "$fixtures/fingerprint-island-plus-face-minus-fingerprint.pam" "$fixtures/unix-island-body.pam" remove face
assert_print_matches "$fixtures/fido2-island.pam" "$fixtures/fido2-island-normalized.pam"
assert_print_matches "$fixtures/fido2-island.pam" "$fixtures/fido2-island-plus-face.pam" add face
assert_print_matches "$fixtures/required-howdy.pam" "$fixtures/required-howdy-normalized.pam"
assert_print_matches "$fixtures/required-howdy-normalized.pam" "$fixtures/required-howdy-normalized.pam"
assert_print_matches "$fixtures/wrong-gate.pam" "$fixtures/face-only.pam"
assert_print_matches "$fixtures/vendor-includes.pam" "$fixtures/face-only.pam" add face
assert_print_matches "$fixtures/face-only.pam" "$fixtures/face-only.pam" add face
assert_print_matches "$fixtures/face-only.pam" "$fixtures/face-plus-fingerprint.pam" add fingerprint
assert_print_matches "$fixtures/face-only.pam" "$fixtures/face-plus-fido2.pam" add fido2

missing="$fixtures/does-not-exist.pam"
assert_print_matches "$missing" "$fixtures/face-only.pam" add face

assert_print_exits 3 --from "$fixtures/vendor-includes.pam" --print
assert_print_exits 3 --from "$fixtures/face-only.pam" --print remove face
assert_print_exits 3 --from "$missing" --print
assert_print_exits 1 --from "$fixtures/leading-foreign.pam" --print
assert_print_exits 1 --from "$fixtures/no-recovery.pam" --print
assert_print_exits 64 --from "$fixtures/face-only.pam"
assert_print_exits 64 --from "$fixtures/face-only.pam" --print add toes
assert_print_exits 64 --list --print

symlink=$(mktemp)
rm -f "$symlink"
ln -s "$fixtures/face-only.pam" "$symlink"
assert_print_exits 64 --from "$symlink" --print
rm -f "$symlink"

for fixture in face-only.pam fingerprint-island-plus-face.pam fido2-island-plus-face.pam \
  required-howdy-normalized.pam fingerprint-island-normalized.pam fido2-island-normalized.pam \
  face-plus-fingerprint.pam face-plus-fido2.pam unix-island-body.pam; do
  assert_fixed_point "$fixtures/$fixture"
done

assert_overlay_untouched
pass "--from --print never writes $polkit_overlay"
