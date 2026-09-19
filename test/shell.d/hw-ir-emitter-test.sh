#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

emitter="$ROOT/bin/omarchy-hw-ir-emitter"

[[ -x $emitter ]] || fail "omarchy-hw-ir-emitter is executable"

sysfs=$(mktemp -d)
mkdir -p \
  "$sysfs/class/video4linux/video2" \
  "$sysfs/class/video4linux/video0" \
  "$sysfs/devices/usb/3-8/3-8:1.2" \
  "$sysfs/devices/usb/other/other:1.0"
ln -s ../../../devices/usb/3-8/3-8:1.2 "$sysfs/class/video4linux/video2/device"
ln -s ../../../devices/usb/other/other:1.0 "$sysfs/class/video4linux/video0/device"
printf '5986\n' >"$sysfs/devices/usb/3-8/idVendor"
printf '1195\n' >"$sysfs/devices/usb/3-8/idProduct"
printf '04f2\n' >"$sysfs/devices/usb/other/idVendor"
printf 'b7c1\n' >"$sysfs/devices/usb/other/idProduct"

got=$("$emitter" --sysfs "$sysfs" --print)
[[ $got == "video2 unit=14 selector=6 value=1,3,2,0,0,0,0,0,0" ]] ||
  fail "--sysfs --print prints the one video2 line" "$got"
pass "--sysfs --print prints the one video2 line"

empty=$(mktemp -d)
got=$("$emitter" --sysfs "$empty" --print)
[[ -z $got ]] || fail "empty sysfs prints nothing" "$got"
pass "empty sysfs prints nothing and exits 0"

set +e
"$emitter" --sysfs "$sysfs" >/dev/null 2>&1
status=$?
set -e
(( status == 64 )) || fail "--sysfs without --print exits 64" "exit $status"
pass "--sysfs without --print exits 64"

set +e
"$emitter" >/dev/null 2>&1
status=$?
set -e
(( status == 0 )) || fail "no arguments exits 0" "exit $status"
pass "no arguments exits 0"

rm -rf "$sysfs" "$empty"
