#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Upstream's setup commands used to tee /etc/pam.d/polkit-1 themselves. This
# fork compiles that file through omarchy-apply-polkit-pam so face,
# fingerprint, and FIDO2 share one stack. A hand-rolled stack that lists
# pam_unix directly instead of `include system-auth` silently drops
# pam_faillock. Assert the setup commands stay on the helper, and that the
# helper still defers to system-auth.

helper="$ROOT/bin/omarchy-apply-polkit-pam"

for setup in omarchy-setup-security-fingerprint omarchy-setup-security-fido2; do
  script="$ROOT/bin/$setup"
  method=fingerprint
  if [[ $setup == *fido2 ]]; then
    method=fido2
  fi

  grep -q "omarchy-apply-polkit-pam add $method" "$script" ||
    fail "$setup configures polkit through omarchy-apply-polkit-pam"
  ! grep -q 'tee /etc/pam.d/polkit-1' "$script" ||
    fail "$setup does not hand-roll /etc/pam.d/polkit-1"
  pass "$setup creates a polkit-1 stack through omarchy-apply-polkit-pam"
done

for phase in auth account password session; do
  grep -qE "${phase}[[:space:]]+include[[:space:]]+system-auth" "$helper" ||
    fail "omarchy-apply-polkit-pam $phase defers to system-auth (keeps faillock)"
done
! grep -qE "(account|password|session)[[:space:]]+required[[:space:]]+pam_unix" "$helper" ||
  fail "omarchy-apply-polkit-pam does not hand-roll a bare pam_unix stack"
pass "omarchy-apply-polkit-pam creates a polkit-1 stack that includes system-auth"
