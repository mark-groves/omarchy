#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

setup="$ROOT/bin/omarchy-setup-security-face"
remove="$ROOT/bin/omarchy-remove-security-face"
fixtures="$ROOT/test/shell.d/fixtures/face-pam"

test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT

write_elevation_stubs() {
  local dir=$1 tool
  mkdir -p "$dir"
  for tool in sudo pkexec; do
    cat >"$dir/$tool" <<STUB
#!/bin/bash
printf '%s %s\n' "$tool" "\$*" >>"$dir/elev.out"
exit 42
STUB
    chmod +x "$dir/$tool"
  done
}

run_unprivileged_elevation() {
  local script=$1 label=$2 dir status=0
  dir=$(mktemp -d -p "$test_tmp")
  write_elevation_stubs "$dir"

  PATH="$dir:$PATH" "$script" >"$dir/out" 2>&1 || status=$?
  (( status == 42 )) ||
    fail "$label elevates and stops at the stub" "$(cat "$dir/out")"
  [[ -f $dir/elev.out ]] || fail "$label records an elevation"
  grep -q '^sudo ' "$dir/elev.out" ||
    fail "$label elevates through sudo" "$(cat "$dir/elev.out")"
  if grep -q '^pkexec ' "$dir/elev.out"; then
    fail "$label does not elevate through pkexec" "$(cat "$dir/elev.out")"
  fi
  if grep -Eq '(/usr/bin/env|OMARCHY_PATH=)' "$dir/elev.out"; then
    fail "$label does not pass a caller environment into sudo" "$(cat "$dir/elev.out")"
  fi
}

run_setup_without_howdy() {
  local isolate=$1 dir status=0
  dir=$(mktemp -d -p "$test_tmp")
  write_elevation_stubs "$dir"

  if (( isolate )); then
    PATH="$dir:$PATH" bwrap --ro-bind / / --dev /dev --proc /proc \
      --bind "$dir" "$dir" \
      --tmpfs /usr/lib/security \
      --tmpfs /usr/lib/systemd/system/polkit-agent-helper@.service.d \
      -- "$setup" >"$dir/out" 2>&1 || status=$?
  else
    PATH="$dir:$PATH" "$setup" >"$dir/out" 2>&1 || status=$?
  fi
  (( status == 1 )) ||
    fail "face setup without Howdy exits 1 before elevation" "$(cat "$dir/out")"
  if [[ -e $dir/elev.out ]]; then
    fail "face setup without Howdy does not ask for a password" "$(cat "$dir/elev.out")"
  fi
  grep -F 'howdy-next is not installed' "$dir/out" >/dev/null ||
    fail "face setup without Howdy says Howdy is missing" "$(cat "$dir/out")"
}

howdy_present=1
[[ -f /usr/lib/security/pam_howdy.so && -f /usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf ]] ||
  howdy_present=0

if (( EUID == 0 )); then
  skip "running as root; setup and remove would rewrite this machine's PAM"
  exit 0
fi

if (( howdy_present == 0 )); then
  run_setup_without_howdy 0
  pass "unprivileged face setup without Howdy exits before elevation"
else
  run_unprivileged_elevation "$setup" "face setup"
  pass "unprivileged face setup asks sudo"
  if command -v bwrap >/dev/null &&
    bwrap --ro-bind / / --dev /dev --proc /proc \
      --tmpfs /usr/lib/security \
      --tmpfs /usr/lib/systemd/system/polkit-agent-helper@.service.d \
      true 2>/dev/null; then
    run_setup_without_howdy 1
    pass "unprivileged face setup without Howdy exits before elevation"
  else
    skip "user namespaces unavailable; isolated missing-Howdy setup"
  fi
fi
run_unprivileged_elevation "$remove" "face remove"
pass "unprivileged face remove asks sudo"

# Setup and remove run as root over a test tree: a user namespace maps this
# user to root, and the PAM, Howdy, helper, state and lock directories are
# test-owned binds over the real ones. Where this machine has no Howdy, a
# read-only overlay stands in for its module, polkit drop-in and config
# directory, so the cases run there too. setpriv, journalctl, sudo and pkexec
# are stubs that play the owner's side of the live checks.
uid=$(id -u)
gid=$(id -g)

# What Ask first must leave, spelled out here rather than read back through the
# writer: the vendor text with the block directly above its system-auth include.
cat >"$test_tmp/sudo-block" <<'EOF'
auth   [default=ignore]                         pam_exec.so quiet quiet_log stdout /usr/local/lib/omarchy-face/ask-hint tty
auth   [success=ignore conv_err=die default=4]  pam_exec.so quiet quiet_log expose_authtok /usr/local/lib/omarchy-face/authtok-empty
auth   [success=ignore default=die]             pam_succeed_if.so quiet tty =~ /dev/*
auth   [default=ignore]                         pam_warn.so
auth   [default=ignore]                         pam_exec.so quiet quiet_log /usr/local/lib/omarchy-face/omarchy-hw-ir-emitter
-auth  [success=done default=die]               pam_howdy.so
EOF
cat >"$test_tmp/polkit-1-block" <<'EOF'
auth   [default=ignore]                         pam_exec.so quiet quiet_log stdout /usr/local/lib/omarchy-face/ask-hint
auth   [success=ignore conv_err=die default=3]  pam_exec.so quiet quiet_log expose_authtok /usr/local/lib/omarchy-face/authtok-empty
auth   [default=ignore]                         pam_warn.so
auth   [default=ignore]                         pam_exec.so quiet quiet_log /usr/local/lib/omarchy-face/omarchy-hw-ir-emitter
-auth  [success=done default=die]               pam_howdy.so
EOF
cat >"$test_tmp/lane.expected" <<'EOF'
#%PAM-1.0
auth   [default=ignore]  pam_exec.so quiet quiet_log /usr/local/lib/omarchy-face/omarchy-hw-ir-emitter
-auth  sufficient        pam_howdy.so
auth   required          pam_deny.so
account include system-local-login
EOF
{
  head -n 1 "$fixtures/sudo-vendor.pam"
  cat "$test_tmp/sudo-block"
  tail -n +2 "$fixtures/sudo-vendor.pam"
} >"$test_tmp/sudo.expected"
{
  head -n 2 "$fixtures/polkit-1-vendor.pam"
  cat "$test_tmp/polkit-1-block"
  tail -n +3 "$fixtures/polkit-1-vendor.pam"
} >"$test_tmp/polkit-1.expected"

# Today's stacks, the vendor polkit-1, Howdy's config and the old emitter. The
# layer holds what an overlay adds where this machine lacks it: Howdy's module
# and drop-in, which setup only looks for, and mount points for the tree's
# Howdy and state directories.
make_tree() {
  local tree=$1
  mkdir -p "$tree/etc/pam.d" "$tree/etc/howdy" "$tree/usr/local/bin" "$tree/usr/local/lib" \
    "$tree/usr/lib/pam.d" "$tree/var/lib/omarchy" "$tree/run/lock" \
    "$tree/layer/etc/howdy" "$tree/layer/var/lib/omarchy" "$tree/layer/usr/lib/security" \
    "$tree/layer/usr/lib/systemd/system/polkit-agent-helper@.service.d"
  chmod 755 "$tree/etc/pam.d" "$tree/usr/local" "$tree/usr/local/lib" "$tree/var/lib/omarchy"
  cp "$fixtures/sudo-legacy.pam" "$tree/etc/pam.d/sudo"
  cp "$fixtures/polkit-1-legacy.pam" "$tree/etc/pam.d/polkit-1"
  cp "$fixtures/lane-legacy.pam" "$tree/etc/pam.d/omarchy-lock-face"
  cp "$fixtures/polkit-1-vendor.pam" "$tree/usr/lib/pam.d/polkit-1"
  printf '%s\n' '[core]' 'abort_if_lid_closed = true' >"$tree/etc/howdy/config.ini"
  cp "$ROOT/bin/omarchy-hw-ir-emitter" "$tree/usr/local/bin/omarchy-hw-ir-emitter"
  : >"$tree/layer/usr/lib/security/pam_howdy.so"
  : >"$tree/layer/usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf"
}

write_stub() {
  cat >"$1"
  chmod +x "$1"
}

# A copy of the command, so its own bin directory is where the stubs are; the
# writer and the face library are links to this checkout's.
make_bin() {
  local bin=$1 script=$2
  mkdir -p "$bin"
  cp "$script" "$bin/"
  ln -s "$ROOT/bin/omarchy-apply-face-pam" "$ROOT/bin/omarchy-security-face-functions" "$bin/"

  # The owner's commands run with these stubs first on PATH, and setpriv marks
  # what it starts. No passwordless grant is active.
  write_stub "$bin/setpriv" <<'STUB'
#!/bin/bash
here=${BASH_SOURCE[0]%/*}
printf 'setpriv %s\n' "$*" >>"$here/../calls"
while (( $# > 0 )) && [[ $1 != "--" ]]; do
  shift
done
shift
if [[ ${1##*/} == "omarchy-sudo-passwordless" ]]; then
  exit 1
fi
exec env -i PATH="$here:/usr/bin:/bin" FACE_TEST_AS_USER=1 "$@"
STUB
  # Only the owner's sudo and polkit are under test: root's own sudo takes no
  # password and polkit lets root through, so a check that skipped setpriv
  # would prove nothing, and these refuse it. sudo with no terminal cannot ask,
  # and refuses an empty -S password, unless the case lets a terminal-less
  # program through. A case can also have terminal-less sudo reach the camera,
  # which logs a scan on its own PID, have the typed password refused, or
  # stand in for a Ctrl+C at the password prompt.
  write_stub "$bin/sudo" <<'STUB'
#!/bin/bash
here=${BASH_SOURCE[0]%/*}
printf 'sudo %s\n' "$*" >>"$here/../calls"
if [[ ${FACE_TEST_AS_USER:-} != 1 ]]; then
  echo "sudo: not started as the invoking user" >&2
  exit 99
fi
if [[ $* == "-k true" ]]; then
  if [[ -e $here/../sudo-scans-without-terminal ]]; then
    printf '%s - %s\n' "$$" 'pam_warn(sudo:auth): function=[pam_sm_authenticate] flags=0 service=<sudo>' >>"$here/../journal"
  fi
  if [[ -e $here/../sudo-without-terminal-works ]]; then
    exit 0
  fi
elif [[ $* == "-k -v" ]]; then
  if [[ -e $here/../interrupt-at-password ]]; then
    kill -INT "$PPID"
  fi
  if [[ ! -e $here/../sudo-refuses-password ]]; then
    exit 0
  fi
fi
exit 1
STUB
  write_stub "$bin/pkexec" <<'STUB'
#!/bin/bash
here=${BASH_SOURCE[0]%/*}
printf 'pkexec %s\n' "$*" >>"$here/../calls"
if [[ ${FACE_TEST_AS_USER:-} != 1 ]]; then
  echo "pkexec: not started as the invoking user" >&2
  exit 99
fi
STUB
  # The case's journal holds "PID UNIT MESSAGE" lines. Like journalctl, a query
  # gets the lines that match its _PID= and --unit=, and every line without them.
  write_stub "$bin/journalctl" <<'STUB'
#!/bin/bash
here=${BASH_SOURCE[0]%/*}
printf 'journalctl %s\n' "$*" >>"$here/../calls"
pid=""
unit=""
for arg in "$@"; do
  case $arg in
    --sync) exit 0 ;;
    _PID=*) pid=${arg#_PID=} ;;
    --unit=*) unit=${arg#--unit=} ;;
  esac
done
if [[ -e $here/../journal ]]; then
  while read -r entry_pid entry_unit message; do
    if [[ (-z $pid || $entry_pid == $pid) && (-z $unit || $entry_unit == $unit) ]]; then
      printf '%s\n' "$message"
    fi
  done <"$here/../journal"
fi
STUB
  write_stub "$bin/sleep" <<'STUB'
#!/bin/bash
STUB
  write_stub "$bin/omarchy-apply-howdy-compare" <<'STUB'
#!/bin/bash
printf 'omarchy-apply-howdy-compare %s\n' "$*" >>"${BASH_SOURCE[0]%/*}/../calls"
STUB
}

# Runs a command as root over a tree. A path this machine lacks first gets an
# overlay on its parent, with the tree's layer on top.
in_tree() {
  local tree=$1
  shift
  SUDO_UID=$uid SUDO_GID=$gid unshare --user --map-root-user --mount bash -c '
    set -euo pipefail
    tree=$1
    shift
    for path in /etc/howdy /var/lib/omarchy /usr/lib/security/pam_howdy.so \
      /usr/lib/systemd/system/polkit-agent-helper@.service.d \
      /usr/lib/systemd/system/polkit-agent-helper@.service.d/10-howdy.conf; do
      if [[ ! -e $path ]]; then
        mount -t overlay overlay -o "lowerdir=$tree/layer${path%/*}:${path%/*}" "${path%/*}"
      fi
    done
    for dir in etc/pam.d etc/howdy usr/local usr/lib/pam.d var/lib/omarchy run/lock; do
      mount --bind "$tree/$dir" "/$dir"
    done
    exec "$@"
  ' bash "$tree" "$@"
}

# Runs a command as root over its case's tree; the status lands in run_status.
run_status=0
run_as_root() {
  local case_dir=$1 script=$2
  run_status=0
  in_tree "$case_dir/tree" "$case_dir/bin/${script##*/}" >"$case_dir/out" 2>&1 || run_status=$?
}

new_case() {
  local case_dir=$test_tmp/$1 script=$2
  make_tree "$case_dir/tree"
  make_bin "$case_dir/bin" "$script"
  : >"$case_dir/calls"
}

assert_same() {
  local expected=$1 got=$2 description=$3
  cmp -s -- "$expected" "$got" || fail "$description" "$(diff -u -- "$expected" "$got" 2>&1 || true)"
}

make_tree "$test_tmp/probe"
if ! in_tree "$test_tmp/probe" true 2>/dev/null; then
  skip "user namespaces or mounts over a test tree unavailable; setup and remove over a test tree"
  exit 0
fi

new_case setup "$setup"
tree=$test_tmp/setup/tree
# Lines the checks must not count: another sudo's scan, and polkit-1 logged
# outside the helper units.
printf '%s\n' \
  '1 - pam_warn(sudo:auth): function=[pam_sm_authenticate] flags=0 service=<sudo>' \
  '1 other.service pam_warn(polkit-1:auth): function=[pam_sm_authenticate] flags=0 service=<polkit-1>' \
  >"$test_tmp/setup/journal"
run_as_root "$test_tmp/setup" "$setup"
(( run_status == 0 )) || fail "face setup converts today's stacks" "$(cat "$test_tmp/setup/out")"
assert_same "$test_tmp/sudo.expected" "$tree/etc/pam.d/sudo" "setup leaves sudo Ask first"
assert_same "$test_tmp/polkit-1.expected" "$tree/etc/pam.d/polkit-1" "setup leaves polkit-1 Ask first"
assert_same "$test_tmp/lane.expected" "$tree/etc/pam.d/omarchy-lock-face" "setup writes the lock screen lane"
for name in ask-hint authtok-empty omarchy-hw-ir-emitter; do
  [[ $(stat -c %a "$tree/usr/local/lib/omarchy-face/$name") == "755" ]] ||
    fail "setup installs $name with mode 755" "$(ls -la "$tree/usr/local/lib/omarchy-face" 2>&1)"
done
[[ ! -e $tree/usr/local/bin/omarchy-hw-ir-emitter ]] ||
  fail "setup deletes the old emitter once no stack runs it"
[[ ! -e $tree/var/lib/omarchy/face-pam/sudo.untested && ! -e $tree/var/lib/omarchy/face-pam/polkit-1.untested ]] ||
  fail "a stack that passed is no longer marked untested" "$(ls -la "$tree/var/lib/omarchy/face-pam")"
if grep '^setpriv ' "$test_tmp/setup/calls" | grep -vq "^setpriv --reuid=$uid --regid=$gid --init-groups --reset-env -- "; then
  fail "setup runs every check as the invoking user" "$(cat "$test_tmp/setup/calls")"
fi
pass "setup turns today's sudo and polkit-1 into Ask first, installs the helpers and drops the old emitter"

# A terminal-less sudo that gets through fails sudo's first check.
new_case sudo-fails "$setup"
tree=$test_tmp/sudo-fails/tree
touch "$test_tmp/sudo-fails/sudo-without-terminal-works"
run_as_root "$test_tmp/sudo-fails" "$setup"
(( run_status != 0 )) || fail "setup fails when a sudo check fails" "$(cat "$test_tmp/sudo-fails/out")"
assert_same "$fixtures/sudo-legacy.pam" "$tree/etc/pam.d/sudo" "a failed sudo check puts sudo back byte for byte"
assert_same "$fixtures/polkit-1-legacy.pam" "$tree/etc/pam.d/polkit-1" "a failed sudo check leaves polkit-1 alone"
[[ -e $tree/usr/local/bin/omarchy-hw-ir-emitter ]] || fail "a failed sudo check keeps the old emitter"
pass "a failed sudo check restores sudo, stops before polkit-1 and keeps the old emitter"

# A terminal-less sudo that is refused but still reached the camera.
new_case sudo-scans "$setup"
tree=$test_tmp/sudo-scans/tree
touch "$test_tmp/sudo-scans/sudo-scans-without-terminal"
run_as_root "$test_tmp/sudo-scans" "$setup"
(( run_status != 0 )) || fail "setup fails when sudo with no terminal starts a scan" "$(cat "$test_tmp/sudo-scans/out")"
assert_same "$fixtures/sudo-legacy.pam" "$tree/etc/pam.d/sudo" "a scan without a terminal puts sudo back byte for byte"
pass "a scan from sudo with no terminal fails the check and restores sudo"

# Ctrl+C at the password prompt puts sudo back, and ends in 1 rather than 130,
# so the floating terminal stays open on the result.
new_case interrupt "$setup"
tree=$test_tmp/interrupt/tree
touch "$test_tmp/interrupt/interrupt-at-password"
run_as_root "$test_tmp/interrupt" "$setup"
(( run_status == 1 )) || fail "setup interrupted at a check exits 1" "status $run_status: $(cat "$test_tmp/interrupt/out")"
assert_same "$fixtures/sudo-legacy.pam" "$tree/etc/pam.d/sudo" "Ctrl+C at a check puts sudo back byte for byte"
[[ ! -e $tree/var/lib/omarchy/face-pam/sudo.untested ]] || fail "a sudo put back is no longer marked untested"
pass "Ctrl+C at a sudo check restores sudo and exits 1"

# A run that died before sudo passed left it Ask first and marked untested. The
# next run tests it rather than skipping it, and a typed password that does
# not get through puts back what that run replaced.
new_case untested "$setup"
tree=$test_tmp/untested/tree
cp "$test_tmp/sudo.expected" "$tree/etc/pam.d/sudo"
mkdir -m 700 "$tree/var/lib/omarchy/face-pam"
cp "$fixtures/sudo-legacy.pam" "$tree/var/lib/omarchy/face-pam/sudo.previous"
: >"$tree/var/lib/omarchy/face-pam/sudo.untested"
touch "$test_tmp/untested/sudo-refuses-password"
run_as_root "$test_tmp/untested" "$setup"
(( run_status != 0 )) || fail "setup tests a sudo an earlier run never finished testing" "$(cat "$test_tmp/untested/out")"
assert_same "$fixtures/sudo-legacy.pam" "$tree/etc/pam.d/sudo" "an untested sudo that fails puts back what it replaced"
assert_same "$fixtures/polkit-1-legacy.pam" "$tree/etc/pam.d/polkit-1" "an untested sudo that fails leaves polkit-1 alone"
pass "setup tests a sudo an earlier run left untested, and puts it back when the typed password fails"

# Every system prompt starts a scan, so polkit-1 never shows the typed path.
new_case polkit-fails "$setup"
tree=$test_tmp/polkit-fails/tree
echo '- polkit-agent-helper@1.service pam_warn(polkit-1:auth): function=[pam_sm_authenticate] flags=0 service=<polkit-1>' >"$test_tmp/polkit-fails/journal"
run_as_root "$test_tmp/polkit-fails" "$setup"
(( run_status != 0 )) || fail "setup fails when the polkit check fails" "$(cat "$test_tmp/polkit-fails/out")"
assert_same "$fixtures/polkit-1-legacy.pam" "$tree/etc/pam.d/polkit-1" "a failed polkit check puts polkit-1 back byte for byte"
assert_same "$test_tmp/sudo.expected" "$tree/etc/pam.d/sudo" "a failed polkit check keeps the tested sudo"
pass "a failed polkit check restores polkit-1 and keeps the tested sudo"

# Howdy reads its config with inih: a BOM, any case in names, text after a
# section's ] and a : for = all still turn the lid check off.
new_case lid "$setup"
tree=$test_tmp/lid/tree
lid_configs=(
  $'[core]\nabort_if_lid_closed = False\n'
  $'\xef\xbb\xbf[Core] ; IR camera\nAbort_If_Lid_Closed: off\n'
)
for config in "${lid_configs[@]}"; do
  printf '%s' "$config" >"$tree/etc/howdy/config.ini"
  run_as_root "$test_tmp/lid" "$setup"
  if (( run_status != 1 )) || ! grep -qF 'abort_if_lid_closed is off' "$test_tmp/lid/out"; then
    fail "setup refuses while Howdy scans with the lid shut" "$(cat -v "$tree/etc/howdy/config.ini"; cat "$test_tmp/lid/out")"
  fi
  assert_same "$fixtures/sudo-legacy.pam" "$tree/etc/pam.d/sudo" "a refused setup leaves sudo alone"
  [[ ! -e $tree/usr/local/lib/omarchy-face ]] || fail "a refused setup installs no helpers"
done
pass "setup refuses before writing anything while abort_if_lid_closed is off, in any spelling Howdy reads"

# A sudo with no face lines reads as off, but a jump above its system-auth
# include would land inside the block, so Ask first refuses it up front.
new_case foreign-jump "$setup"
tree=$test_tmp/foreign-jump/tree
sed '/^auth[[:space:]]*include[[:space:]]*system-auth/i auth [success=1 default=ignore] pam_permit.so' \
  "$fixtures/sudo-vendor.pam" >"$tree/etc/pam.d/sudo"
cp "$tree/etc/pam.d/sudo" "$test_tmp/foreign-jump/sudo.before"
run_as_root "$test_tmp/foreign-jump" "$setup"
if (( run_status != 1 )) || ! grep -qF 'is not a stack this can rewrite, so nothing was changed' "$test_tmp/foreign-jump/out" ||
  ! grep -qF 'a jump above the system-auth include' "$test_tmp/foreign-jump/out"; then
  fail "setup refuses a face-free sudo that Ask first cannot be written over, with the reason" "$(cat "$test_tmp/foreign-jump/out")"
fi
assert_same "$test_tmp/foreign-jump/sudo.before" "$tree/etc/pam.d/sudo" "a refused setup leaves the foreign jump's sudo alone"
[[ ! -e $tree/usr/local/lib/omarchy-face ]] || fail "a refused setup installs no helpers"
pass "setup refuses a face-free sudo that Ask first cannot be written over, before writing anything"

# Remove from what setup just wrote.
mkdir -p "$test_tmp/remove-ask"
mv "$test_tmp/setup/tree" "$test_tmp/remove-ask/tree"
make_bin "$test_tmp/remove-ask/bin" "$remove"
: >"$test_tmp/remove-ask/calls"

new_case remove-legacy "$remove"
for case_name in remove-ask remove-legacy; do
  tree=$test_tmp/$case_name/tree
  run_as_root "$test_tmp/$case_name" "$remove"
  (( run_status == 0 )) || fail "$case_name: face remove completes" "$(cat "$test_tmp/$case_name/out")"
  assert_same "$fixtures/sudo-vendor.pam" "$tree/etc/pam.d/sudo" "$case_name: remove puts back the vendor sudo"
  [[ ! -e $tree/etc/pam.d/polkit-1 ]] || fail "$case_name: remove deletes the polkit-1 override" "$(cat "$tree/etc/pam.d/polkit-1")"
  [[ ! -e $tree/etc/pam.d/omarchy-lock-face ]] || fail "$case_name: remove deletes the lock screen lane"
  [[ ! -e $tree/usr/local/lib/omarchy-face ]] || fail "$case_name: remove deletes the helpers"
  [[ ! -e $tree/usr/local/bin/omarchy-hw-ir-emitter ]] || fail "$case_name: remove deletes the old emitter"
  pass "$case_name: remove leaves the vendor sudo and polkit-1, with no lane or helpers"
done

# Ask first refuses an include above the system-auth one, since its jumps are
# hidden, but taking face out of that stack is still safe.
new_case remove-include "$remove"
other_include='/^auth[[:space:]]*include[[:space:]]*system-auth/i auth include omarchy-face-test-other'
sed -i "$other_include" "$test_tmp/remove-include/tree/etc/pam.d/sudo"
sed "$other_include" "$fixtures/sudo-vendor.pam" >"$test_tmp/remove-include/sudo.expected"
run_as_root "$test_tmp/remove-include" "$remove"
(( run_status == 0 )) || fail "remove takes face out of a stack Ask first would refuse" "$(cat "$test_tmp/remove-include/out")"
assert_same "$test_tmp/remove-include/sudo.expected" "$test_tmp/remove-include/tree/etc/pam.d/sudo" \
  "remove keeps the other include and leaves the vendor lines"
pass "remove takes face out of a stack Ask first would refuse"

fingerprint_setup="$ROOT/bin/omarchy-setup-security-fingerprint"
fingerprint_remove="$ROOT/bin/omarchy-remove-security-fingerprint"
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
