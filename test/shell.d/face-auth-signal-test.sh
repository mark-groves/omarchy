#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

signal="$ROOT/bin/omarchy-face-auth-signal"

[[ -x $signal ]] || fail "omarchy-face-auth-signal is executable"
bash -n "$signal" || fail "omarchy-face-auth-signal passes bash -n"

if grep -nE '(^|[[:space:]])(sudo|pkexec)[[:space:]]' "$signal" >/dev/null; then
  fail "face-auth-signal does not escalate"
fi
pass "face-auth-signal is a display-only helper"

runtime=$(mktemp -d)
trap 'rm -rf "$runtime"' EXIT

status=0
"$signal" >/dev/null 2>"$runtime/err" || status=$?
(( status == 64 )) || fail "missing state exits 64" "exit $status $(cat "$runtime/err")"
pass "missing state is a usage error"

status=0
"$signal" quiet --runtime-dir "$runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 64 )) || fail "unknown state exits 64" "exit $status $(cat "$runtime/err")"
pass "unknown state is a usage error"

status=0
"$signal" scanning --runtime-dir "$runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "scanning exits 0" "exit $status $(cat "$runtime/err")"
[[ -f $runtime/omarchy/face-auth.json ]] || fail "scanning writes the signal file"
payload=$(cat "$runtime/omarchy/face-auth.json")
[[ $payload == '{"state":"scanning","ts":'* ]] ||
  fail "scanning payload names the state" "$payload"
pass "scanning writes an atomic signal file"

first=$payload
status=0
"$signal" recognized --runtime-dir "$runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "recognized exits 0" "exit $status $(cat "$runtime/err")"
payload=$(cat "$runtime/omarchy/face-auth.json")
[[ $payload == '{"state":"recognized","ts":'* ]] ||
  fail "recognized payload names the state" "$payload"
[[ $payload != "$first" ]] || fail "a later signal replaces the file" "$payload"
pass "recognized replaces the signal file"

status=0
"$signal" notRecognized --runtime-dir "$runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "notRecognized exits 0" "exit $status $(cat "$runtime/err")"
payload=$(cat "$runtime/omarchy/face-auth.json")
[[ $payload == '{"state":"notRecognized","ts":'* ]] ||
  fail "notRecognized payload names the state" "$payload"
pass "notRecognized writes the miss state"

status=0
"$signal" cancelled --runtime-dir "$runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "cancelled exits 0" "exit $status $(cat "$runtime/err")"
payload=$(cat "$runtime/omarchy/face-auth.json")
[[ $payload == '{"state":"cancelled","ts":'* ]] ||
  fail "cancelled payload names the state" "$payload"
pass "cancelled writes the hide state"

drop_runtime=$(mktemp -d)
status=0
/usr/bin/setpriv --reuid="$EUID" --regid="$(id -g)" --clear-groups -- \
  /usr/bin/bash -- "$signal" scanning --runtime-dir "$drop_runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "setpriv re-exec of the helper exits 0" "exit $status $(cat "$runtime/err")"
payload=$(cat "$drop_runtime/omarchy/face-auth.json")
[[ $payload == '{"state":"scanning","ts":'* ]] ||
  fail "setpriv re-exec still writes the signal" "$payload"
rm -rf -- "$drop_runtime"
pass "the session-owner write path still publishes the signal"

status=0
"$signal" scanning --runtime-dir /dev/null/nope >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "an unwritable runtime dir still exits 0" "exit $status $(cat "$runtime/err")"
pass "an unwritable runtime dir does not fail the caller"

if grep -F 'for dir in /run/user/*' "$signal" >/dev/null; then
  fail "root does not walk /run/user/* when loginuid is unset"
fi
if grep -E 'wayland-\[' "$signal" >/dev/null; then
  fail "root does not pick a session by a Wayland socket glob"
fi
grep -F 'login_uid' "$signal" >/dev/null || fail "root session lookup is loginuid-only"
grep -F 'owned_dir_ok' "$signal" >/dev/null || fail "privileged writes check ownership and mode"
grep -F '[[ -L $dir ]]' "$signal" >/dev/null || fail "the helper refuses an omarchy symlink"
grep -F 'setpriv --reuid="$expected_owner"' "$signal" >/dev/null ||
  fail "root writes the signal as the session owner" "$(grep -n setpriv "$signal" || true)"
awk '
  /EUID == 0 && expected_owner != 0/ { drop=1 }
  drop && /setpriv/ { saw=1 }
  drop && saw && /exit 0/ { closed=1 }
  drop && /mktemp/ {
    if (!closed) { print "root still reaches mktemp before dropping"; exit 1 }
    exit 0
  }
  END { if (!closed) { print "root drop never fail-closes"; exit 1 } }
' "$signal" || fail "root never writes through the mktemp name" "$(cat "$signal")"
if grep -E 'mkdir -p -- "\$dir"' "$signal" >/dev/null; then
  fail "mkdir -p follows a planted omarchy symlink"
fi
pass "root writes stay in the loginuid runtime dir"

victim=$runtime/victim
mkdir -p -- "$victim"
printf 'canary\n' >"$victim/canary"
rm -rf -- "$runtime/omarchy"
ln -s -- "$victim" "$runtime/omarchy"
status=0
"$signal" scanning --runtime-dir "$runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "a planted omarchy symlink still exits 0" "exit $status $(cat "$runtime/err")"
[[ -L $runtime/omarchy ]] || fail "a planted omarchy symlink is left in place"
[[ $(cat "$victim/canary") == "canary" ]] || fail "a planted omarchy symlink does not clobber the target"
[[ ! -e $victim/face-auth.json ]] || fail "a planted omarchy symlink does not receive face-auth.json"
shopt -s nullglob
leftovers=("$victim"/face-auth.json*)
shopt -u nullglob
(( ${#leftovers[@]} == 0 )) || fail "a planted omarchy symlink does not receive a temp write" "${leftovers[*]}"
pass "a planted omarchy symlink is not written through"

rm -f -- "$runtime/omarchy"
link_parent=$runtime/link-parent
real_runtime=$runtime/real-runtime
mkdir -p -- "$link_parent" "$real_runtime"
ln -s -- "$real_runtime" "$link_parent/runtime"
status=0
"$signal" scanning --runtime-dir "$link_parent/runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "a runtime-dir symlink still exits 0" "exit $status $(cat "$runtime/err")"
[[ ! -e $real_runtime/omarchy/face-auth.json ]] ||
  fail "a runtime-dir symlink is not followed" "$(find "$real_runtime" -type f)"
pass "a runtime-dir symlink is not followed"

rm -rf -- "$runtime/omarchy"
printf 'not-a-dir\n' >"$runtime/omarchy"
status=0
"$signal" scanning --runtime-dir "$runtime" >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "a non-directory omarchy still exits 0" "exit $status $(cat "$runtime/err")"
[[ $(cat "$runtime/omarchy") == "not-a-dir" ]] || fail "a non-directory omarchy is left alone"
pass "a non-directory omarchy is not replaced"
