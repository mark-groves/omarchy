#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

setup="$ROOT/bin/omarchy-setup-security-face"
remove="$ROOT/bin/omarchy-remove-security-face"
fingerprint_remove="$ROOT/bin/omarchy-remove-security-fingerprint"

grep -F '/usr/lib/security/pam_howdy.so' "$setup" >/dev/null ||
  fail "face setup requires pam_howdy.so"
grep -F 'polkit-agent-helper@.service.d/10-howdy.conf' "$setup" >/dev/null ||
  fail "face setup requires the Howdy polkit helper drop-in"
grep -F 'omarchy-apply-polkit-pam add face' "$setup" >/dev/null ||
  fail "face setup adds face through the polkit compiler"
grep -F 'omarchy-pam-pair-add /etc/pam.d/sudo pam_howdy.so' "$setup" >/dev/null ||
  fail "face setup pair-adds sudo howdy"
grep -F '/etc/pam.d/omarchy-lock-face' "$setup" >/dev/null ||
  fail "face setup writes omarchy-lock-face"
grep -F 'auth       required                    pam_howdy.so' "$setup" >/dev/null ||
  fail "lock face is a required howdy conversation"

if grep -E 'howdy[[:space:]]+(enroll|add)' "$setup" >/dev/null; then
  fail "face setup does not enroll"
fi
if grep -F 'system-auth' "$setup" >/dev/null; then
  fail "face setup does not edit system-auth"
fi
pass "face setup checks Howdy and writes lock, sudo, and polkit"

grep -F 'omarchy-apply-polkit-pam remove face' "$remove" >/dev/null ||
  fail "face remove goes through the polkit compiler"
grep -F 'omarchy-pam-pair-drop /etc/pam.d/sudo pam_howdy.so' "$remove" >/dev/null ||
  fail "face remove pair-drops sudo howdy"
grep -F '/etc/pam.d/omarchy-lock-face' "$remove" >/dev/null ||
  fail "face remove deletes omarchy-lock-face"
if grep -F 'omarchy-pkg-drop' "$remove" >/dev/null; then
  fail "face remove does not drop howdy packages"
fi
pass "face remove drops lock, sudo, and polkit face"

grep -F 'omarchy-pam-pair-drop' "$fingerprint_remove" >/dev/null ||
  fail "fingerprint remove pair-drops sudo fprintd"
if grep -E "sed[[:space:]].*omarchy-hw-laptop-closed" "$fingerprint_remove" >/dev/null; then
  fail "fingerprint remove no longer globally deletes lid-gate lines"
fi
grep -F 'omarchy-apply-polkit-pam remove fingerprint' "$fingerprint_remove" >/dev/null ||
  fail "fingerprint remove drops polkit fingerprint through the compiler"
pass "fingerprint remove pair-drops sudo and compiles polkit"
