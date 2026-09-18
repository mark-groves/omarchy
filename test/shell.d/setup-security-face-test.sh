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

if grep -E 'howdy[[:space:]]+(enroll|add)' "$setup" >/dev/null; then
  fail "face setup does not enroll"
fi
if grep -F 'omarchy-lock-face' "$setup" >/dev/null || grep -F 'omarchy-lock-face' "$remove" >/dev/null; then
  fail "face setup and remove do not write omarchy-lock-face"
fi
if grep -F '/etc/pam.d/sudo' "$setup" >/dev/null || grep -F '/etc/pam.d/sudo' "$remove" >/dev/null; then
  fail "face setup and remove do not edit sudo"
fi
if grep -F 'system-auth' "$setup" >/dev/null; then
  fail "face setup does not edit system-auth"
fi
pass "face setup checks Howdy and only adds polkit face"

grep -F 'omarchy-apply-polkit-pam remove face' "$remove" >/dev/null ||
  fail "face remove goes through the polkit compiler"
pass "face remove only drops polkit face"

grep -F 'omarchy-pam-pair-drop' "$fingerprint_remove" >/dev/null ||
  fail "fingerprint remove pair-drops sudo fprintd"
if grep -E "sed[[:space:]].*omarchy-hw-laptop-closed" "$fingerprint_remove" >/dev/null; then
  fail "fingerprint remove no longer globally deletes lid-gate lines"
fi
grep -F 'omarchy-apply-polkit-pam remove fingerprint' "$fingerprint_remove" >/dev/null ||
  fail "fingerprint remove drops polkit fingerprint through the compiler"
pass "fingerprint remove pair-drops sudo and compiles polkit"
