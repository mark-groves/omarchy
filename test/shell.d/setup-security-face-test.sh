#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

setup="$ROOT/bin/omarchy-setup-security-face"
remove="$ROOT/bin/omarchy-remove-security-face"
fingerprint_setup="$ROOT/bin/omarchy-setup-security-fingerprint"
fingerprint_remove="$ROOT/bin/omarchy-remove-security-fingerprint"

grep -F '/usr/lib/security/pam_howdy.so' "$setup" >/dev/null ||
  fail "face setup requires pam_howdy.so"
grep -F 'polkit-agent-helper@.service.d/10-howdy.conf' "$setup" >/dev/null ||
  fail "face setup requires the Howdy polkit helper drop-in"
grep -F 'omarchy-apply-polkit-pam add face' "$setup" >/dev/null ||
  fail "face setup adds face through the polkit compiler"
grep -F 'omarchy-apply-howdy-compare install' "$setup" >/dev/null ||
  fail "face setup pins howdy-compare"
grep -F 'omarchy-pam-pair-add /etc/pam.d/sudo pam_howdy.so' "$setup" >/dev/null ||
  fail "face setup pair-adds sudo howdy"
grep -F '/etc/pam.d/omarchy-lock-face' "$setup" >/dev/null ||
  fail "face setup writes omarchy-lock-face"
grep -F 'auth       required                    pam_howdy.so' "$setup" >/dev/null ||
  fail "lock face is a required howdy conversation"
grep -F 'auth       optional                    pam_exec.so quiet /usr/local/bin/omarchy-hw-ir-emitter' "$setup" >/dev/null ||
  fail "lock face fires the IR emitter"
emitter_line=$(grep -nF 'pam_exec.so quiet /usr/local/bin/omarchy-hw-ir-emitter' "$setup" | head -n1)
howdy_line=$(grep -nF 'auth       required                    pam_howdy.so' "$setup" | head -n1)
(( ${howdy_line%%:*} == ${emitter_line%%:*} + 1 )) ||
  fail "lock face emitter sits on the line before pam_howdy.so"
grep -F 'chmod 644' "$setup" >/dev/null ||
  fail "lock face is mode 0644"

if grep -E 'howdy[[:space:]]+(enroll|add)' "$setup" >/dev/null; then
  fail "face setup does not enroll"
fi
if grep -F 'system-auth' "$setup" >/dev/null; then
  fail "face setup does not edit system-auth"
fi
if grep -F '/etc/howdy' "$setup" >/dev/null; then
  fail "face setup does not inspect /etc/howdy"
fi
if grep -nE '(^|[[:space:]])as_root[[:space:]]' "$setup" >/dev/null; then
  fail "face setup does not wrap writes in as_root"
fi
if grep -nE '(^|[[:space:]])sudo[[:space:]]+"' "$setup" >/dev/null; then
  fail "face setup does not elevate through sudo Howdy"
fi
grep -F 'pkexec' "$setup" >/dev/null ||
  fail "face setup elevates through pkexec"
pass "face setup checks Howdy and writes lock, sudo, and polkit"

grep -F 'omarchy-apply-polkit-pam remove face' "$remove" >/dev/null ||
  fail "face remove goes through the polkit compiler"
grep -F 'omarchy-apply-howdy-compare remove' "$remove" >/dev/null ||
  fail "face remove unpins howdy-compare"
grep -F 'omarchy-pam-pair-drop /etc/pam.d/sudo pam_howdy.so' "$remove" >/dev/null ||
  fail "face remove pair-drops sudo howdy"
grep -F '/etc/pam.d/omarchy-lock-face' "$remove" >/dev/null ||
  fail "face remove deletes omarchy-lock-face"
if grep -F 'omarchy-pkg-drop' "$remove" >/dev/null; then
  fail "face remove does not drop howdy packages"
fi
if grep -F '/etc/howdy' "$remove" >/dev/null; then
  fail "face remove does not inspect /etc/howdy"
fi
if grep -nE '(^|[[:space:]])as_root[[:space:]]' "$remove" >/dev/null; then
  fail "face remove does not wrap writes in as_root"
fi
if grep -nE '(^|[[:space:]])sudo[[:space:]]+"' "$remove" >/dev/null; then
  fail "face remove does not elevate through sudo Howdy"
fi
grep -F 'pkexec' "$remove" >/dev/null ||
  fail "face remove elevates through pkexec"
pass "face remove drops lock, sudo, and polkit face"

run_unprivileged_elevation() {
  local script=$1
  local label=$2
  local test_tmp stub_bin status

  test_tmp=$(mktemp -d)
  stub_bin="$test_tmp/bin"
  mkdir -p "$stub_bin"

  cat >"$stub_bin/sudo" <<STUB
#!/bin/bash
printf 'sudo %s\n' "\$*" >>"$test_tmp/elev.out"
exit 42
STUB
  cat >"$stub_bin/pkexec" <<STUB
#!/bin/bash
printf 'pkexec %s\n' "\$*" >>"$test_tmp/elev.out"
exit 42
STUB
  chmod +x "$stub_bin/sudo" "$stub_bin/pkexec"

  status=0
  PATH="$stub_bin:$PATH" "$script" >"$test_tmp/out" 2>&1 || status=$?
  (( status == 42 )) ||
    fail "$label elevates and stops at the stub" "$(cat "$test_tmp/out")"
  [[ -f $test_tmp/elev.out ]] || fail "$label records an elevation"
  grep -q '^pkexec ' "$test_tmp/elev.out" ||
    fail "$label elevates through pkexec" "$(cat "$test_tmp/elev.out")"
  if grep -q '^sudo ' "$test_tmp/elev.out"; then
    fail "$label does not elevate through sudo" "$(cat "$test_tmp/elev.out")"
  fi
  if grep -Eq '(/usr/bin/env|OMARCHY_PATH=)' "$test_tmp/elev.out"; then
    fail "$label does not pass a caller environment into pkexec" "$(cat "$test_tmp/elev.out")"
  fi
  rm -rf "$test_tmp"
}

howdy_module=/usr/lib/security/pam_howdy.so
howdy_dropin=/usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf
howdy_present=1
[[ -f $howdy_module && -f $howdy_dropin ]] || howdy_present=0

setup_howdy_check=$(grep -nF 'howdy-next is not installed' "$setup" | head -n1)
setup_pkexec=$(grep -nF 'exec pkexec' "$setup" | head -n1)
[[ -n $setup_howdy_check && -n $setup_pkexec ]] ||
  fail "face setup keeps a Howdy presence check and a pkexec re-exec"
(( ${setup_howdy_check%%:*} < ${setup_pkexec%%:*} )) ||
  fail "face setup fails closed before pkexec when Howdy is missing"
pass "face setup checks Howdy before asking polkit"

run_setup_without_howdy() {
  local isolate=$1
  local test_tmp stub_bin status

  test_tmp=$(mktemp -d)
  stub_bin="$test_tmp/bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/sudo" <<STUB
#!/bin/bash
printf 'sudo %s\n' "\$*" >>"$test_tmp/elev.out"
exit 42
STUB
  cat >"$stub_bin/pkexec" <<STUB
#!/bin/bash
printf 'pkexec %s\n' "\$*" >>"$test_tmp/elev.out"
exit 42
STUB
  chmod +x "$stub_bin/sudo" "$stub_bin/pkexec"

  status=0
  if (( isolate )); then
    PATH="$stub_bin:$PATH" bwrap --ro-bind / / --dev /dev --proc /proc \
      --bind "$test_tmp" "$test_tmp" \
      --tmpfs /usr/lib/security \
      --tmpfs /usr/lib/systemd/system/polkit-agent-helper@.service.d \
      -- "$setup" >"$test_tmp/out" 2>&1 || status=$?
  else
    PATH="$stub_bin:$PATH" "$setup" >"$test_tmp/out" 2>&1 || status=$?
  fi
  (( status == 1 )) ||
    fail "face setup without Howdy exits 1 before elevation" "$(cat "$test_tmp/out")"
  if [[ -e $test_tmp/elev.out ]]; then
    fail "face setup without Howdy does not ask polkit" "$(cat "$test_tmp/elev.out")"
  fi
  grep -F 'howdy-next is not installed' "$test_tmp/out" >/dev/null ||
    fail "face setup without Howdy says Howdy is missing" "$(cat "$test_tmp/out")"
  rm -rf "$test_tmp"
}

if (( EUID == 0 )); then
  pass "running as root; skipping unprivileged elevation, which would rewrite this machine's PAM"
else
  if (( howdy_present == 0 )); then
    run_setup_without_howdy 0
    pass "unprivileged face setup without Howdy exits before elevation"
  else
    run_unprivileged_elevation "$setup" "face setup"
    pass "unprivileged face setup asks polkit"
    if command -v bwrap >/dev/null &&
      bwrap --ro-bind / / --dev /dev --proc /proc \
        --tmpfs /usr/lib/security \
        --tmpfs /usr/lib/systemd/system/polkit-agent-helper@.service.d \
        true 2>/dev/null; then
      run_setup_without_howdy 1
      pass "unprivileged face setup without Howdy exits before elevation"
    else
      pass "user namespaces unavailable; skipping isolated missing-Howdy setup"
    fi
  fi
  run_unprivileged_elevation "$remove" "face remove"
  pass "unprivileged face remove asks polkit"
fi

write_helper_stub() {
  local path=$1
  local log=$2

  cat >"$path" <<STUB
#!/bin/bash
printf '%s %s\n' "\$(basename "\$0")" "\$*" >>"$log"
exit 0
STUB
  chmod +x "$path"
}

run_isolated_privileged_tree() {
  local script=$1
  local label=$2
  shift 2
  local test_tmp bin pam_overlay status helper

  test_tmp=$(mktemp -d)
  bin="$test_tmp/bin"
  pam_overlay="$test_tmp/pam.d"
  mkdir -p "$bin" "$pam_overlay" "$test_tmp/lock" "$test_tmp/localbin"
  cp -a /etc/pam.d/. "$pam_overlay/"
  if [[ ! -f $pam_overlay/polkit-1 ]]; then
    printf '%s\n' '#%PAM-1.0' 'auth      include    system-auth' >"$pam_overlay/polkit-1"
  fi
  if ! grep -q pam_howdy.so "$pam_overlay/sudo" 2>/dev/null; then
    printf '%s\n' '#%PAM-1.0' 'auth      sufficient pam_howdy.so' 'auth      include    system-auth' >"$pam_overlay/sudo"
  fi
  cp "$script" "$bin/$(basename "$script")"
  cp "$ROOT/bin/omarchy-hw-ir-emitter" "$bin/omarchy-hw-ir-emitter"
  for helper in "$@"; do
    write_helper_stub "$bin/$helper" "$test_tmp/helpers.out"
  done

  status=0
  if command -v bwrap >/dev/null &&
    bwrap --ro-bind / / --dev /dev --proc /proc \
      --bind "$test_tmp" "$test_tmp" \
      --bind "$pam_overlay" /etc/pam.d \
      --bind "$test_tmp/lock" /run/lock \
      --bind "$test_tmp/localbin" /usr/local/bin \
      --uid 0 --gid 0 \
      true 2>/dev/null; then
    bwrap --ro-bind / / --dev /dev --proc /proc \
      --bind "$test_tmp" "$test_tmp" \
      --bind "$pam_overlay" /etc/pam.d \
      --bind "$test_tmp/lock" /run/lock \
      --bind "$test_tmp/localbin" /usr/local/bin \
      --uid 0 --gid 0 \
      -- "$bin/$(basename "$script")" >"$test_tmp/out" 2>&1 || status=$?
  elif command -v unshare >/dev/null && unshare --user --map-root-user true 2>/dev/null; then
    unshare --user --map-root-user --mount bash -c '
      set -euo pipefail
      mount --bind "$1" /etc/pam.d
      mkdir -p /run/lock
      mount --bind "$2" /run/lock
      mount --bind "$5" /usr/local/bin
      status=0
      "$3" >"$4" 2>&1 || status=$?
      exit "$status"
    ' bash "$pam_overlay" "$test_tmp/lock" "$bin/$(basename "$script")" "$test_tmp/out" "$test_tmp/localbin" || status=$?
  else
    rm -rf "$test_tmp"
    pass "user namespaces unavailable; skipping isolated privileged $label"
    return 0
  fi

  if grep -q 'command not found' "$test_tmp/out"; then
    fail "privileged $label runs helpers from the authorized tree" "$(cat "$test_tmp/out")"
  fi
  [[ -f $test_tmp/helpers.out ]] ||
    fail "privileged $label runs helpers from the authorized tree" "$(cat "$test_tmp/out")"
  for helper in "$@"; do
    grep -q "^$helper " "$test_tmp/helpers.out" ||
      fail "privileged $label runs $helper from the authorized tree" "$(cat "$test_tmp/out"; echo '---'; cat "$test_tmp/helpers.out")"
  done
  (( status == 0 )) ||
    fail "privileged $label completes from a checkout tree" "$(cat "$test_tmp/out")"
  if [[ $label == "face setup" ]]; then
    [[ -x $test_tmp/localbin/omarchy-hw-ir-emitter ]] ||
      fail "privileged face setup installs the emitter helper under /usr/local/bin" "$(ls -la "$test_tmp/localbin")"
    cmp -s "$ROOT/bin/omarchy-hw-ir-emitter" "$test_tmp/localbin/omarchy-hw-ir-emitter" ||
      fail "the installed emitter helper is the checkout copy"
  fi
  rm -rf "$test_tmp"
}

if (( EUID != 0 )) && (( howdy_present == 1 )); then
  run_isolated_privileged_tree "$setup" "face setup" \
    omarchy-pam-pair-add omarchy-apply-polkit-pam omarchy-apply-howdy-compare
  pass "privileged face setup runs checkout pair-add and the polkit compiler"
fi

if (( EUID != 0 )); then
  run_isolated_privileged_tree "$remove" "face remove" \
    omarchy-pam-pair-drop omarchy-apply-polkit-pam omarchy-apply-howdy-compare
  pass "privileged face remove runs checkout pair-drop and the polkit compiler"
fi

grep -F 'omarchy-pam-pair-add /etc/pam.d/sudo pam_fprintd.so' "$fingerprint_setup" >/dev/null ||
  fail "fingerprint setup pair-adds sudo fprintd"
if grep -E "sed[[:space:]].*pam_fprintd" "$fingerprint_setup" >/dev/null; then
  fail "fingerprint setup no longer sed-inserts sudo fprintd"
fi
pass "fingerprint setup pair-adds sudo fprintd"
grep -F 'omarchy-pam-pair-drop' "$fingerprint_remove" >/dev/null ||
  fail "fingerprint remove pair-drops sudo fprintd"
if grep -E "sed[[:space:]].*omarchy-hw-laptop-closed" "$fingerprint_remove" >/dev/null; then
  fail "fingerprint remove no longer globally deletes lid-gate lines"
fi
grep -F 'omarchy-apply-polkit-pam remove fingerprint' "$fingerprint_remove" >/dev/null ||
  fail "fingerprint remove drops polkit fingerprint through the compiler"
pass "fingerprint remove pair-drops sudo and compiles polkit"
