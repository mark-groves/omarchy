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
"$signal" scanning --runtime-dir /dev/null/nope >/dev/null 2>"$runtime/err" || status=$?
(( status == 0 )) || fail "an unwritable runtime dir still exits 0" "exit $status $(cat "$runtime/err")"
pass "an unwritable runtime dir does not fail the caller"
