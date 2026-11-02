#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

emitter="$ROOT/bin/omarchy-hw-ir-emitter"
test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

[[ -x $emitter ]] || fail "omarchy-hw-ir-emitter is executable"

# Nothing here runs the emitter against the real /sys and /dev: that fires this
# machine's camera.
sysfs=$test_tmp/sys
mkdir -p \
  "$sysfs/class/video4linux/video0" \
  "$sysfs/class/video4linux/video2" \
  "$sysfs/class/video4linux/video4" \
  "$sysfs/devices/usb/3-8/3-8:1.0" \
  "$sysfs/devices/usb/3-8/3-8:1.2" \
  "$sysfs/devices/usb/other/other:1.0"
ln -s ../../../devices/usb/3-8/3-8:1.0 "$sysfs/class/video4linux/video0/device"
ln -s ../../../devices/usb/3-8/3-8:1.2 "$sysfs/class/video4linux/video2/device"
ln -s ../../../devices/usb/other/other:1.0 "$sysfs/class/video4linux/video4/device"
printf '5986\n' >"$sysfs/devices/usb/3-8/idVendor"
printf '1195\n' >"$sysfs/devices/usb/3-8/idProduct"
printf '00\n' >"$sysfs/devices/usb/3-8/3-8:1.0/bInterfaceNumber"
printf '02\n' >"$sysfs/devices/usb/3-8/3-8:1.2/bInterfaceNumber"
printf '04f2\n' >"$sysfs/devices/usb/other/idVendor"
printf 'b7c1\n' >"$sysfs/devices/usb/other/idProduct"
printf '00\n' >"$sysfs/devices/usb/other/other:1.0/bInterfaceNumber"

got=$("$emitter" --sysfs "$sysfs" --print)
[[ $got == "video2 unit=14 selector=6 value=1,3,2,0,0,0,0,0,0" ]] ||
  fail "--sysfs --print prints only the IR interface of the Bison camera" "$got"
pass "--sysfs --print prints only the IR interface of the Bison camera"

empty=$test_tmp/empty
mkdir "$empty"
got=$("$emitter" --sysfs "$empty" --print)
[[ -z $got ]] || fail "empty sysfs prints nothing" "$got"
pass "empty sysfs prints nothing and exits 0"

# A fake sysfs never reaches the real /dev. These use an empty sysfs or a fake
# --dev, and the emitter never swaps a given --dev for the real one, so if a
# refusal regresses it opens nothing instead of this machine's camera.
refuses() {
  local description=$1 status=0
  shift
  "$emitter" "$@" >/dev/null 2>&1 || status=$?
  (( status == 64 )) || fail "$description" "exit $status"
  pass "$description"
}
ln -s /dev "$test_tmp/dev-link"
refuses "--sysfs without --print or --dev exits 64" --sysfs "$empty"
refuses "--dev without --sysfs exits 64" --dev "$empty"
refuses "--dev /dev/ is still the real /dev and exits 64" --sysfs "$empty" --dev /dev/
refuses "--dev through a link to /dev exits 64" --sysfs "$empty" --dev "$test_tmp/dev-link"

# PAM runs this as root. A glob.py planted beside the script or on PYTHONPATH
# must not load.
plant=$test_tmp/plant
mkdir -p "$plant/path"
cp "$emitter" "$plant/emitter"
for dir in "$plant" "$plant/path"; do
  printf 'open("%s", "w").write(__file__)\n' "$plant/imported" >"$dir/glob.py"
done
PYTHONPATH="$plant/path" "$plant/emitter" --sysfs "$sysfs" --print >/dev/null 2>&1 || true
[[ ! -e $plant/imported ]] ||
  fail "the emitter imports nothing from its own directory or PYTHONPATH" "imported $(<"$plant/imported")"
pass "the emitter imports nothing from its own directory or PYTHONPATH"

# Run the emitter through the --sysfs/--dev seam with fcntl.ioctl standing in
# for the driver: it prints the ids each ioctl runs under, or stalls like a
# driver that never answers.
dev=$test_tmp/dev
mkdir "$dev"
: >"$dev/video2"
chmod 600 "$dev/video2"
cat >"$test_tmp/drive.py" <<'PY'
import importlib.machinery, importlib.util, os, sys, time

path, sysfs, dev, mode = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("emitter", path)
emitter = importlib.util.module_from_spec(importlib.util.spec_from_loader("emitter", loader))
loader.exec_module(emitter)


def ioctl(fd, request, query):
    if mode == "stall":
        print("stalled", flush=True)
        time.sleep(8)
    print(*os.getresuid(), len(os.getgroups()), flush=True)
    query.data[0] = 9


emitter.fcntl.ioctl = ioctl
print("exit", emitter.main(["--sysfs", sysfs, "--dev", dev]))
PY
drive() {
  local mode=$1
  shift
  "$@" python3 -I -B "$test_tmp/drive.py" "$emitter" "$sysfs" "$dev" "$mode" 2>&1
}

# The node is 0600 and its owner is root in the namespace, so nobody could not
# open it: both ioctls landing as nobody means the open came before the drop.
if unshare --user --map-auto --map-root-user setpriv --reuid=65534 --regid=65534 --clear-groups true 2>/dev/null; then
  got=$(drive record unshare --user --map-auto --map-root-user) || true
  [[ $got == $'65534 65534 65534 0\n65534 65534 65534 0\nexit 0' ]] ||
    fail "as root the emitter opens the node, then fires only as nobody with no groups" "$got"
  pass "as root the emitter opens the node, then fires only as nobody with no groups"
else
  skip "no user namespace with a mapped nobody; skipping the privilege drop"
fi

# With only root mapped, setgroups is denied and nobody does not exist.
if unshare --user --map-root-user true 2>/dev/null; then
  got=$(drive record unshare --user --map-root-user) || true
  [[ $got == "exit 0" ]] || fail "a drop that cannot land fires nothing and exits 0" "$got"
  pass "a drop that cannot land fires nothing and exits 0"
else
  skip "no unprivileged user namespace; skipping the failed privilege drop"
fi

# Cut inside the ioctl, the run ends before anything after "stalled" prints.
start=$SECONDS
status=0
got=$(drive stall) || status=$?
elapsed=$(( SECONDS - start ))
(( status == 0 && elapsed < 5 )) && [[ $got == "stalled" ]] ||
  fail "a stalled ioctl is cut by the watchdog and still exits 0" "exit $status after ${elapsed}s: $got"
pass "a stalled ioctl is cut by the watchdog and still exits 0"
