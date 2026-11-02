#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

apply="$ROOT/bin/omarchy-apply-face-pam"
pair_add="$ROOT/bin/omarchy-pam-pair-add"
pair_drop="$ROOT/bin/omarchy-pam-pair-drop"
compiler="$ROOT/bin/omarchy-apply-polkit-pam"
fixtures="$ROOT/test/shell.d/fixtures/face-pam"

[[ -x $apply ]] || fail "omarchy-apply-face-pam is executable"

test_tmp=$(mktemp -d)
trap 'rm -rf -- "$test_tmp"' EXIT

# polkit-1 with no /etc copy, or one the compiler reduces to nothing, renders
# from the vendor file under the root it is given.
render_root=$test_tmp/render-root
mkdir -p "$render_root/usr/lib/pam.d"
cp "$fixtures/polkit-1-vendor.pam" "$render_root/usr/lib/pam.d/polkit-1"

render() {
  local target=$1 mode=$2 input=$3 output=$4
  "$apply" --root "$render_root" --from "$input" --print "$target" "$mode" >"$output" 2>"$test_tmp/render.err" ||
    fail "$target $mode renders from $(basename "$input")" "$(cat "$test_tmp/render.err")"
}

assert_same() {
  local expected=$1 got=$2 description=$3
  cmp -s -- "$expected" "$got" || fail "$description" "$(diff -u -- "$expected" "$got" || true)"
}

assert_refused() {
  local target=$1 input=$2 description=$3
  if "$apply" --root "$render_root" --from "$input" --print "$target" ask >"$test_tmp/refused" 2>/dev/null; then
    fail "$description" "$(cat "$test_tmp/refused")"
  fi
  [[ ! -s $test_tmp/refused ]] || fail "$description prints no stack" "$(cat "$test_tmp/refused")"
}

expect_shape() {
  local target=$1 input=$2 expected=$3 got
  got=$("$apply" --root "$render_root" --from "$input" shape "$target")
  [[ $got == "$expected" ]] || fail "shape of $target $(basename "$input") is $expected" "got $got"
}

# Today's stacks become Ask first: the old gate and emitter go, and the block
# lands where it lands on the vendor text. Off takes it all out again.
for target in sudo polkit-1; do
  legacy=$fixtures/$target-legacy.pam
  vendor=$fixtures/$target-vendor.pam
  out=$test_tmp/$target
  render "$target" ask "$legacy" "$out.ask"
  render "$target" ask "$vendor" "$out.vendor-ask"
  assert_same "$out.vendor-ask" "$out.ask" "$target: Ask first from the live legacy stack is Ask first from the vendor text"
  render "$target" ask "$out.ask" "$out.ask-again"
  assert_same "$out.ask" "$out.ask-again" "$target: Ask first over Ask first changes nothing"
  render "$target" off "$out.ask" "$out.ask-off"
  render "$target" off "$legacy" "$out.off"
  assert_same "$vendor" "$out.ask-off" "$target: off after Ask first is the vendor text"
  assert_same "$vendor" "$out.off" "$target: off from the live legacy stack is the vendor text"
  pass "$target: legacy becomes Ask first once, and off(ask(x)) == off(x) == vendor"
done

# The vendor polkit-1 is read, not spelled out, so vendor changes keep arriving.
other_root=$test_tmp/other-root
mkdir -p "$other_root/usr/lib/pam.d"
{
  cat "$fixtures/polkit-1-vendor.pam"
  printf '%s\n' 'session    optional     pam_permit.so'
} >"$other_root/usr/lib/pam.d/polkit-1"
"$apply" --root "$other_root" --from "$fixtures/polkit-1-legacy.pam" --print polkit-1 off >"$test_tmp/other.off"
assert_same "$other_root/usr/lib/pam.d/polkit-1" "$test_tmp/other.off" "polkit-1 off falls back to /usr/lib/pam.d/polkit-1"
"$apply" --root "$other_root" --from "$test_tmp/absent" --print polkit-1 ask >"$test_tmp/other.absent-ask"
"$apply" --root "$other_root" --from "$other_root/usr/lib/pam.d/polkit-1" --print polkit-1 ask >"$test_tmp/other.vendor-ask"
assert_same "$test_tmp/other.vendor-ask" "$test_tmp/other.absent-ask" "polkit-1 with no /etc copy renders from /usr/lib/pam.d/polkit-1"
pass "polkit-1 renders from the vendor file when there is no /etc copy left"

# The compiler's shared [success=3] gate over face and fingerprint. Taking the
# face lines out by hand leaves it, and the lid-closed jump then lands past the
# system-auth include; the compiler rebuilds fingerprint's own gate.
fingerprint_fixture=$fixtures/polkit-1-legacy-face-fingerprint.pam
for mode in off ask; do
  render polkit-1 "$mode" "$fingerprint_fixture" "$test_tmp/fingerprint.$mode"
  gates=$(grep -c 'omarchy-hw-laptop-closed' "$test_tmp/fingerprint.$mode" || true)
  (( gates == 1 )) || fail "polkit-1 $mode keeps one lid gate" "$(cat "$test_tmp/fingerprint.$mode")"
  grep -A1 'omarchy-hw-laptop-closed' "$test_tmp/fingerprint.$mode" >"$test_tmp/fingerprint.gate"
  if ! grep -q '\[success=1 default=ignore\]' "$test_tmp/fingerprint.gate" ||
    ! grep -q 'pam_fprintd.so' "$test_tmp/fingerprint.gate"; then
    fail "polkit-1 $mode keeps fingerprint's own success=1 gate over pam_fprintd.so" "$(cat "$test_tmp/fingerprint.$mode")"
  fi
done
fingerprint_line=$(grep -n 'pam_fprintd.so' "$test_tmp/fingerprint.ask" | cut -d: -f1)
face_line=$(grep -n 'pam_howdy.so' "$test_tmp/fingerprint.ask" | cut -d: -f1)
(( fingerprint_line < face_line )) || fail "Ask first goes below fingerprint" "$(cat "$test_tmp/fingerprint.ask")"
pass "the shared face and fingerprint gate becomes fingerprint's own success=1 gate"

# Old setup re-run over the block puts its gate and emitter inside it.
"$pair_add" --from "$test_tmp/sudo.vendor-ask" --print pam_howdy.so >"$test_tmp/sudo.rerun"
"$compiler" --from "$test_tmp/polkit-1.vendor-ask" --print add face >"$test_tmp/polkit-1.rerun"
for target in sudo polkit-1; do
  ! cmp -s -- "$test_tmp/$target.vendor-ask" "$test_tmp/$target.rerun" ||
    fail "$target: old setup changes an Ask first stack"
  render "$target" ask "$test_tmp/$target.rerun" "$test_tmp/$target.repaired"
  assert_same "$test_tmp/$target.vendor-ask" "$test_tmp/$target.repaired" "$target: Ask first repairs old setup run over the block"
done
pass "Ask first repairs a stack where old setup ran over the block"

sed -E '/authtok-empty/s/default=[0-9]+\]/default=2]/' "$test_tmp/sudo.vendor-ask" >"$test_tmp/sudo.edited"
! cmp -s -- "$test_tmp/sudo.vendor-ask" "$test_tmp/sudo.edited" || fail "the hand edit changes the gate"
assert_refused sudo "$test_tmp/sudo.edited" "a gate edited by hand is refused"
printf '%s\n' '#%PAM-1.0' \
  'auth      [success=3 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed' \
  'auth      sufficient pam_fprintd.so' \
  'auth      include    system-auth' >"$test_tmp/polkit-1.bare-gate"
assert_refused polkit-1 "$test_tmp/polkit-1.bare-gate" "a bare shared gate is refused"
# A jump above the include would count across the new lines once they are in;
# libpam reads the type in any case, and an include brings in jumps unseen.
sed '/^auth[[:space:]]*include/i auth [success=1 default=ignore] pam_systemd_home.so' "$fixtures/sudo-vendor.pam" >"$test_tmp/sudo.jump"
assert_refused sudo "$test_tmp/sudo.jump" "a foreign jump above the include is refused"
sed '/^auth[[:space:]]*include/i AUTH [success=1 default=ignore] pam_systemd_home.so' "$fixtures/sudo-vendor.pam" >"$test_tmp/sudo.jump-upper"
assert_refused sudo "$test_tmp/sudo.jump-upper" "a foreign jump typed AUTH above the include is refused"
sed '/^auth[[:space:]]*include/i auth include omarchy-face-test-other' "$fixtures/sudo-vendor.pam" >"$test_tmp/sudo.include"
assert_refused sudo "$test_tmp/sudo.include" "another include above the system-auth include is refused"
# A face line that is no jump, which only the leftover check catches.
sed '/^auth[[:space:]]*include/i auth optional pam_exec.so quiet /usr/local/lib/omarchy-face/omarchy-hw-ir-emitter' "$fixtures/sudo-legacy.pam" >"$test_tmp/sudo.stray"
assert_refused sudo "$test_tmp/sudo.stray" "a face line no shape accounts for is refused"
pass "hand-edited gates, bare shared gates, stray face lines, and jumps or includes above the block are refused"

# Fingerprint setup and removal around the block, through the tools that do
# them: their output must stay a stack the writer reads as Ask first.
"$pair_add" --from "$test_tmp/sudo.vendor-ask" --print pam_fprintd.so >"$test_tmp/sudo.ask-fingerprint"
"$pair_drop" --from "$test_tmp/sudo.ask-fingerprint" --print pam_fprintd.so >"$test_tmp/sudo.ask-fingerprint-dropped"
assert_same "$test_tmp/sudo.vendor-ask" "$test_tmp/sudo.ask-fingerprint-dropped" "sudo: pair-drop of pam_fprintd.so gives Ask first back"
"$pair_add" --from "$fixtures/sudo-vendor.pam" --print pam_fprintd.so >"$test_tmp/sudo.fingerprint"
render sudo ask "$test_tmp/sudo.fingerprint" "$test_tmp/sudo.fingerprint-ask"
assert_same "$test_tmp/sudo.ask-fingerprint" "$test_tmp/sudo.fingerprint-ask" "sudo: Ask first and fingerprint commute"
expect_shape sudo "$test_tmp/sudo.ask-fingerprint" ask
pass "sudo: pair-add and pair-drop of pam_fprintd.so round-trip around the block"

for method in fingerprint fido2; do
  "$compiler" --from "$test_tmp/polkit-1.vendor-ask" --print add "$method" >"$test_tmp/polkit-1.ask-$method"
  "$compiler" --from "$test_tmp/polkit-1.ask-$method" --print remove "$method" >"$test_tmp/polkit-1.ask-$method-removed"
  assert_same "$test_tmp/polkit-1.vendor-ask" "$test_tmp/polkit-1.ask-$method-removed" "polkit-1: the compiler's remove $method gives Ask first back"
  "$compiler" --from "$fixtures/polkit-1-vendor.pam" --print add "$method" >"$test_tmp/polkit-1.$method"
  render polkit-1 ask "$test_tmp/polkit-1.$method" "$test_tmp/polkit-1.$method-ask"
  assert_same "$test_tmp/polkit-1.ask-$method" "$test_tmp/polkit-1.$method-ask" "polkit-1: Ask first and $method commute"
  expect_shape polkit-1 "$test_tmp/polkit-1.ask-$method" ask
  pass "polkit-1: the compiler's add and remove $method round-trip around the block"
done

# Setup converts only what shape reads as legacy, ask or off, and asks
# --print for the reason when it reads unknown. Old remove's pair-drop over
# the block leaves five of its lines, which ask puts right.
"$pair_drop" --from "$test_tmp/sudo.ask" --print pam_howdy.so >"$test_tmp/sudo.dropped"
! cmp -s -- "$test_tmp/sudo.ask" "$test_tmp/sudo.dropped" || fail "old remove changes an Ask first stack"
expect_shape sudo "$fixtures/sudo-legacy.pam" legacy
expect_shape sudo "$fixtures/sudo-vendor.pam" off
expect_shape sudo "$test_tmp/sudo.ask" ask
expect_shape sudo "$test_tmp/sudo.rerun" legacy
expect_shape sudo "$test_tmp/sudo.dropped" legacy
expect_shape sudo "$test_tmp/sudo.edited" unknown
expect_shape sudo "$test_tmp/sudo.stray" unknown
expect_shape polkit-1 "$fingerprint_fixture" legacy
expect_shape polkit-1 "$test_tmp/absent" off
expect_shape polkit-1 "$test_tmp/polkit-1.ask" ask
expect_shape polkit-1 "$test_tmp/polkit-1.bare-gate" unknown
expect_shape lane "$fixtures/lane-legacy.pam" legacy
expect_shape lane "$test_tmp/absent" off
pass "shape reads ask, off, legacy and unknown back from the stacks"

# Writes need root, and the root-directory checks need files owned by root:
# a user namespace maps this user to root over a test root.
if ! unshare --user --map-root-user true 2>/dev/null; then
  skip "user namespaces unavailable; writes, helpers and PAM outcomes"
  exit 0
fi

as_root() {
  unshare --user --map-root-user "$@"
}

test_root=$test_tmp/root
state=$test_root/var/lib/omarchy/face-pam
helpers=$test_root/usr/local/lib/omarchy-face
# No /var/lib/omarchy: no package owns it, so the first write makes it.
mkdir -p "$test_root/etc/pam.d" "$test_root/usr/lib/pam.d" "$test_root/usr/local/lib" "$test_root/var/lib" "$test_root/run/lock"
chmod 755 "$test_root/etc/pam.d" "$test_root/usr/local" "$test_root/usr/local/lib" "$test_root/var/lib"
cp "$fixtures/sudo-legacy.pam" "$test_root/etc/pam.d/sudo"
cp "$fixtures/polkit-1-legacy.pam" "$test_root/etc/pam.d/polkit-1"
cp "$fixtures/polkit-1-vendor.pam" "$test_root/usr/lib/pam.d/polkit-1"

chmod 775 "$test_root/usr/local/lib"
if as_root "$apply" --root "$test_root" helpers install 2>/dev/null; then
  fail "helpers install refuses a /usr/local/lib that is not root's alone"
fi
[[ ! -e $helpers ]] || fail "a refused helpers install makes no helper directory"
chmod 755 "$test_root/usr/local/lib"
pass "helpers install checks the directories above the helpers"

as_root "$apply" --root "$test_root" helpers install
[[ $(stat -c %a "$helpers") == "755" ]] || fail "the helper directory is mode 755"
for name in ask-hint authtok-empty omarchy-hw-ir-emitter; do
  [[ $(stat -c %a "$helpers/$name") == "755" ]] || fail "$name is mode 755" "$(stat -c %a "$helpers/$name")"
done
assert_same "$ROOT/bin/omarchy-hw-ir-emitter" "$helpers/omarchy-hw-ir-emitter" "helpers install copies the emitter"
pass "helpers install puts three 755 helpers in a 755 directory"

as_root "$apply" --root "$test_root" sudo ask
assert_same "$test_tmp/sudo.ask" "$test_root/etc/pam.d/sudo" "sudo ask writes the rendered stack"
[[ $(stat -c %a "$test_root/etc/pam.d/sudo") == "644" ]] || fail "sudo is mode 644"
assert_same "$fixtures/sudo-legacy.pam" "$state/sudo.previous" "sudo ask records the stack it replaces"
[[ $(stat -c %a "$state") == "700" ]] || fail "the backup directory is mode 700"
as_root "$apply" --root "$test_root" sudo restore
assert_same "$fixtures/sudo-legacy.pam" "$test_root/etc/pam.d/sudo" "sudo restore puts the old stack back byte for byte"
[[ ! -e $state/sudo.previous ]] || fail "restore consumes the record"
if as_root "$apply" --root "$test_root" sudo restore 2>/dev/null; then
  fail "restore with nothing recorded refuses"
fi
assert_same "$fixtures/sudo-legacy.pam" "$test_root/etc/pam.d/sudo" "a refused restore leaves sudo alone"
pass "sudo ask records what it replaced, and restore puts back exactly that once"

as_root "$apply" --root "$test_root" polkit-1 ask
assert_same "$test_tmp/polkit-1.ask" "$test_root/etc/pam.d/polkit-1" "polkit-1 ask writes the rendered stack"
as_root "$apply" --root "$test_root" polkit-1 off
[[ ! -e $test_root/etc/pam.d/polkit-1 ]] || fail "polkit-1 off that leaves the vendor text deletes the /etc copy"
assert_same "$test_tmp/polkit-1.ask" "$state/polkit-1.previous" "polkit-1 off records the stack it replaces"
as_root "$apply" --root "$test_root" polkit-1 ask
assert_same "$test_tmp/polkit-1.vendor-ask" "$test_root/etc/pam.d/polkit-1" "polkit-1 ask with no /etc copy writes Ask first over the vendor text"
[[ -e $state/polkit-1.absent && ! -e $state/polkit-1.previous ]] ||
  fail "a write over no file records that and drops the older copy" "$(ls -la "$state")"
as_root "$apply" --root "$test_root" polkit-1 restore
[[ ! -e $test_root/etc/pam.d/polkit-1 ]] || fail "restore after a write over no file deletes the /etc copy"
pass "polkit-1 off deletes the /etc copy, and restore never brings back an older backup"

as_root "$apply" --root "$test_root" lane install

# The PAM runs below use copies of what the writer installed, with only the
# install prefix moved into the test directory.
pam=$test_tmp/pam
trace=$pam/trace
mkdir -p "$pam/lib" "$pam/conf" "$pam/tally"
move_prefix() {
  sed -e "s#/usr/local/lib/omarchy-face/#$pam/lib/#g" -e "s#/usr/lib/security/pam_howdy.so#$pam/pam_howdy.so#g" "$1" >"$2"
}
move_prefix "$helpers/ask-hint" "$pam/lib/ask-hint"
move_prefix "$helpers/authtok-empty" "$pam/lib/authtok-empty"
chmod 755 "$pam/lib/ask-hint" "$pam/lib/authtok-empty"
cp "$test_root/etc/pam.d/omarchy-lock-face" "$test_tmp/lane"

if as_root "$apply" --root "$test_root" helpers remove 2>/dev/null; then
  fail "helpers remove refuses while a stack names the helpers"
fi
as_root "$apply" --root "$test_root" lane remove
as_root "$apply" --root "$test_root" helpers remove
[[ ! -e $helpers && ! -e $test_root/etc/pam.d/omarchy-lock-face ]] || fail "lane and helpers remove delete their files"
pass "helpers remove waits until no stack names the helpers"

gate=$pam/lib/authtok-empty
status=0
printf '' | "$gate" || status=$?
(( status == 0 )) || fail "authtok-empty takes an empty answer as the face path" "exit $status"
for answer in x $'\n'; do
  status=0
  printf '%s' "$answer" | "$gate" || status=$?
  (( status == 1 )) || fail "authtok-empty takes any byte as the password path: ${answer@Q}" "exit $status"
done
status=0
"$gate" </dev/null || status=$?
(( status == 1 )) || fail "authtok-empty takes stdin that is not a pipe as the password path" "exit $status"
pass "authtok-empty exits 0 only on an empty pipe"

hint=$pam/lib/ask-hint
[[ -z $("$hint") ]] || fail "ask-hint is silent without pam_howdy.so"
: >"$pam/pam_howdy.so"
[[ -n $("$hint") ]] || fail "ask-hint speaks with the gate helper and pam_howdy.so"
chmod 644 "$gate"
[[ -z $("$hint") ]] || fail "ask-hint is silent without the gate helper"
chmod 755 "$gate"
pass "ask-hint offers face only when the gate helper and pam_howdy.so are there"

# Stand-ins for the camera, Howdy and pam_unix record that they ran; the real
# pam_faillock counts strikes into the test directory.
cat >"$pam/lib/omarchy-hw-ir-emitter" <<EOF
#!/bin/bash
echo emitter >>"$trace"
EOF
cat >"$pam/face" <<EOF
#!/bin/bash
echo face >>"$trace"
[[ \$(<"$pam/face-mode") == "match" ]]
EOF
cat >"$pam/system-auth-start" <<EOF
#!/bin/bash
echo system-auth >>"$trace"
EOF
cat >"$pam/password" <<EOF
#!/bin/bash
echo pw >>"$trace"
IFS= read -r -d '' token
[[ \$token == "correct-horse" ]]
EOF
chmod 755 "$pam/lib/omarchy-hw-ir-emitter" "$pam/face" "$pam/system-auth-start" "$pam/password"

cat >"$pam/conf/system-auth" <<EOF
auth [default=ignore] pam_exec.so quiet quiet_log $pam/system-auth-start
auth required pam_faillock.so preauth silent deny=10 unlock_time=120 dir=$pam/tally
auth [success=1 default=bad] pam_exec.so quiet quiet_log expose_authtok $pam/password
auth [default=die] pam_faillock.so authfail deny=10 unlock_time=120 dir=$pam/tally
auth optional pam_permit.so
auth required pam_faillock.so authsucc deny=10 unlock_time=120 dir=$pam/tally
account required pam_permit.so
session required pam_permit.so
EOF
printf '%s\n' 'account required pam_permit.so' >"$pam/conf/system-local-login"

# The writer's own stacks, with Howdy swapped for the stand-in. Test service
# names keep pam_warn's journal lines apart from real scans.
stand_in() {
  local module=$1
  sed -e "s#/usr/local/lib/omarchy-face/#$pam/lib/#g" -e "s#\([[:space:]]\)pam_howdy\.so#\1$module#"
}
stand_in "pam_exec.so quiet quiet_log $pam/face" <"$test_tmp/sudo.ask" >"$pam/conf/omarchy-face-test-sudo"
stand_in "pam_exec.so quiet quiet_log $pam/face" <"$test_tmp/polkit-1.ask" >"$pam/conf/omarchy-face-test-polkit-1"
stand_in "pam_exec.so quiet quiet_log $pam/face" <"$test_tmp/lane" >"$pam/conf/omarchy-face-test-lane"
stand_in "$pam/missing.so" <"$test_tmp/lane" >"$pam/conf/omarchy-face-test-lane-missing"

user=$(id -un)
pam_case() {
  local service=$1 answer=$2 face=$3 tty=${4:-} result ran strikes prompts hints
  local -a tty_args=()
  if [[ -n $tty ]]; then
    tty_args=(--tty "$tty")
  fi
  : >"$trace"
  rm -f -- "$pam/tally"/*
  printf '%s\n' "$face" >"$pam/face-mode"
  python3 -I "$fixtures/pam-converse.py" "${tty_args[@]}" "$pam/conf" "omarchy-face-test-$service" "$user" "$answer" \
    >"$pam/out" 2>&1 || fail "pam-converse runs" "$(cat "$pam/out")"
  result=$(awk '$1 == "result" { print $2 }' "$pam/out")
  ran=$(paste -sd, "$trace")
  strikes=$(faillock --dir "$pam/tally" --user "$user" | grep -cE '^[0-9]{4}-' || true)
  prompts=$(grep -c '^prompt ' "$pam/out" || true)
  hints=$(grep -c '^info ' "$pam/out" || true)
  printf 'result=%s ran=%s strikes=%s prompts=%s hints=%s\n' "$result" "$ran" "$strikes" "$prompts" "$hints"
}

expect_case() {
  local description=$1 expected=$2 got
  shift 2
  got=$(pam_case "$@")
  [[ $got == "$expected" ]] ||
    fail "$description" "expected $expected"$'\n'"got      $got"$'\n'"$(cat "$pam/out")"
  pass "$description"
}

terminal=/dev/pts/9
expect_case "sudo: an empty answer at a terminal scans the face, with no pam_unix and no strike" \
  "result=0 ran=emitter,face strikes=0 prompts=1 hints=1" sudo empty match "$terminal"
expect_case "sudo: a face miss ends the attempt, with no pam_unix and no strike" \
  "result=4 ran=emitter,face strikes=0 prompts=1 hints=1" sudo empty miss "$terminal"
expect_case "sudo: with no terminal there is no hint, and an empty answer fails before the camera, with no strike" \
  "result=7 ran= strikes=0 prompts=1 hints=0" sudo empty match
expect_case "sudo: a typed password reaches pam_unix after one prompt and never the face" \
  "result=0 ran=system-auth,pw strikes=0 prompts=1 hints=1" sudo typed:correct-horse match "$terminal"
expect_case "sudo: a wrong password is one strike, even when the face would match" \
  "result=4 ran=system-auth,pw strikes=1 prompts=1 hints=1" sudo typed:wrong match "$terminal"
expect_case "sudo: a failed conversation stops at the gate" \
  "result=19 ran= strikes=0 prompts=1 hints=1" sudo conv_err match "$terminal"
mv "$gate" "$gate.away"
expect_case "sudo: without the gate helper the hint is hidden" \
  "result=4 ran=system-auth,pw strikes=1 prompts=1 hints=0" sudo empty match "$terminal"
mv "$gate.away" "$gate"

expect_case "polkit-1: an empty answer scans the face with no terminal" \
  "result=0 ran=emitter,face strikes=0 prompts=1 hints=1" polkit-1 empty match
expect_case "polkit-1: a typed password reaches pam_unix and never the face" \
  "result=0 ran=system-auth,pw strikes=0 prompts=1 hints=1" polkit-1 typed:correct-horse match

expect_case "lane: a face match unlocks" \
  "result=0 ran=emitter,face strikes=0 prompts=0 hints=0" lane empty match
expect_case "lane: a face miss fails through pam_deny" \
  "result=7 ran=emitter,face strikes=0 prompts=0 hints=0" lane empty miss
expect_case "lane: a missing face module fails through pam_deny" \
  "result=7 ran=emitter strikes=0 prompts=0 hints=0" lane-missing empty match
