#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

apply="$ROOT/bin/omarchy-apply-howdy-compare"

[[ -x $apply ]] || fail "omarchy-apply-howdy-compare is executable"

file_mode() {
  stat -c '%a' -- "$1"
}

checksum() {
  sha256sum -- "$1" | awk '{print $1}'
}

run_apply() {
  local status=0
  "$apply" "$@" >"$out" 2>"$err" || status=$?
  printf '%s\n' "$status"
}

assert_wrapper_text() {
  local path=$1
  local first

  IFS= read -r first <"$path"
  [[ $first == "#!/bin/bash -p" ]] ||
    fail "howdy-compare first line is #!/bin/bash -p" "$first"
  grep -Fx 'exec /usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real "$@"' "$path" >/dev/null ||
    fail "wrapper execs howdy-compare.real pinned to one CPU" "$(cat "$path")"
  grep -F 'OPENCV_LOG_LEVEL=ERROR' "$path" >/dev/null ||
    fail "wrapper sets OPENCV_LOG_LEVEL=ERROR" "$(cat "$path")"
  if grep -E 'OPENCV_LOG_LEVEL=(SILENT|OFF|0|FATAL)' "$path" >/dev/null; then
    fail "wrapper does not hide OpenCV errors" "$(cat "$path")"
  fi
  # Compare runs as root before authentication, so nothing from the Omarchy
  # tree may run here: on a linked checkout that tree is user-writable.
  if grep -i -E 'omarchy' "$path" >/dev/null; then
    fail "wrapper runs nothing from the Omarchy tree" "$(cat "$path")"
  fi
  bash -n "$path" || fail "wrapper passes bash -n"
}

# The hook that earlier installs wrote, byte for byte.
write_legacy_hook() {
  mkdir -p "$(dirname -- "$1")"
  cat >"$1" <<'EOF'
[Trigger]
Operation = Install
Operation = Upgrade
Operation = Remove
Type = Path
Target = usr/lib/howdy/howdy-compare

[Action]
Description = Pinning howdy-compare to one CPU...
When = PostTransaction
# The command is resolved through the same file the rest of the system uses to
# find the Omarchy tree, because a linked checkout does not ship it in /usr/bin.
# Only a root-owned conf that nobody else can write may pick a root-run binary.
Exec = /usr/bin/bash -c 'conf=/etc/omarchy.conf; if [[ -e $conf || -L $conf ]]; then [[ -f $conf && ! -L $conf && $(stat -c %u:%a -- "$conf") =~ ^0:[0-7][0145][0145]$ ]] || { echo "$conf must be a root-owned file that only root can write" >&2; exit 1; }; . "$conf"; fi; exec "${OMARCHY_PATH:-/usr/share/omarchy}/bin/omarchy-apply-howdy-compare" install'
EOF
}

root=$(mktemp -d)
out=$root/out
err=$root/err
compare=$root/usr/lib/howdy/howdy-compare
real=$root/usr/lib/howdy/howdy-compare.real
hook=$root/etc/pacman.d/hooks/omarchy-howdy-compare.hook
trap 'rm -rf "$root"' EXIT

mkdir -p "$root/usr/lib/howdy"
printf '\x7fELF-fake-v1' >"$compare"
chmod 750 "$compare"

status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install on vendor exits 0" "$(cat "$err"; echo '---'; cat "$out")"
cmp -s -- "$real" <(printf '\x7fELF-fake-v1') ||
  fail "install copies the vendor ELF to .real"
assert_wrapper_text "$compare"
[[ $(file_mode "$compare") == "755" ]] ||
  fail "howdy-compare is mode 755" "$(file_mode "$compare")"
[[ $(file_mode "$real") == "750" ]] ||
  fail "howdy-compare.real keeps the vendor mode" "$(file_mode "$real")"
[[ ! -e $hook ]] || fail "install writes no pacman hook" "$(cat "$hook")"
pass "install pins a vendor ELF and writes no upgrade hook"

write_legacy_hook "$hook"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install with the old hook exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ ! -e $hook && ! -e $hook.retired ]] || fail "install deletes the hook earlier installs wrote"
write_legacy_hook "$hook"
printf '# edited by hand\n' >>"$hook"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install with an edited hook exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ ! -e $hook ]] || fail "install takes an edited hook out of pacman's hook directory"
grep -F '# edited by hand' "$hook.retired" >/dev/null || fail "install keeps an edited hook under an inactive name"
rm -f -- "$hook.retired"
pass "install retires the old upgrade hook, keeping an edited one inactive"

real_sum=$(checksum "$real")
wrapper_sum=$(checksum "$compare")
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "second install exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ $(checksum "$real") == "$real_sum" ]] || fail "second install leaves .real unchanged"
[[ $(checksum "$compare") == "$wrapper_sum" ]] || fail "second install leaves the wrapper unchanged"
pass "install is idempotent on an already pinned slot"

printf '\x7fELF-fake-v2' >"$compare"
chmod 750 "$compare"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install after upgrade exits 0" "$(cat "$err"; echo '---'; cat "$out")"
cmp -s -- "$real" <(printf '\x7fELF-fake-v2') ||
  fail "upgrade install replaces .real with the new ELF"
assert_wrapper_text "$compare"
pass "install after an upgrade adopts the new ELF and restores the wrapper"

real_sum=$(checksum "$real")
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install on pinned v2 exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ $(checksum "$real") == "$real_sum" ]] ||
  fail "pinned install leaves .real at v2"
cmp -s -- "$real" <(printf '\x7fELF-fake-v2') ||
  fail "pinned install keeps the v2 ELF in .real"
pass "install on a pinned slot leaves .real at v2"

printf '#!/bin/bash\nexec /usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real "$@"\n' >"$compare"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install over a hand-written wrapper exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ $(checksum "$real") == "$real_sum" ]] ||
  fail "install over a hand-written wrapper leaves .real alone"
assert_wrapper_text "$compare"
pass "install replaces an earlier wrapper that lacks -p and keeps the ELF"

printf '#!/bin/bash -p\nsignal_face() { . /etc/omarchy.conf; "$OMARCHY_PATH/bin/omarchy-face-auth-signal" "$1"; }\nsignal_face scanning\n/usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real "$@"\n' >"$compare"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install over the signalling wrapper exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ $(checksum "$real") == "$real_sum" ]] ||
  fail "install over the signalling wrapper leaves .real alone"
assert_wrapper_text "$compare"
pass "install replaces the wrapper that ran omarchy-face-auth-signal as root"

unknown_root=$(mktemp -d)
unknown_compare=$unknown_root/usr/lib/howdy/howdy-compare
unknown_real=$unknown_root/usr/lib/howdy/howdy-compare.real
unknown_hook=$unknown_root/etc/pacman.d/hooks/omarchy-howdy-compare.hook
mkdir -p "$unknown_root/usr/lib/howdy"
printf 'not-an-elf\n' >"$unknown_compare"
unknown_sum=$(checksum "$unknown_compare")
status=$(run_apply install --root "$unknown_root")
(( status == 1 )) ||
  fail "install on unknown exits 1" "exit $status $(cat "$err"; echo '---'; cat "$out")"
[[ $(checksum "$unknown_compare") == "$unknown_sum" ]] ||
  fail "unknown install does not rewrite howdy-compare"
[[ ! -e $unknown_real ]] || fail "unknown install does not create .real"
[[ ! -e $unknown_hook ]] || fail "unknown install writes no hook"
rm -rf "$unknown_root"
pass "install refuses an unknown howdy-compare and changes nothing"

# A signalling wrapper whose .real is gone cannot be pinned, but what it runs
# is the hole: install still replaces it and retires the hook before refusing.
unknown_root=$(mktemp -d)
unknown_compare=$unknown_root/usr/lib/howdy/howdy-compare
unknown_hook=$unknown_root/etc/pacman.d/hooks/omarchy-howdy-compare.hook
mkdir -p "$unknown_root/usr/lib/howdy"
printf '#!/bin/bash -p\nsignal_face() { . /etc/omarchy.conf; "$OMARCHY_PATH/bin/omarchy-face-auth-signal" "$1"; }\nsignal_face scanning\n' >"$unknown_compare"
write_legacy_hook "$unknown_hook"
status=$(run_apply install --root "$unknown_root")
(( status == 1 )) ||
  fail "install on a signalling wrapper without .real exits 1" "exit $status $(cat "$err"; echo '---'; cat "$out")"
assert_wrapper_text "$unknown_compare"
[[ ! -e $unknown_hook ]] || fail "install retires the hook even when it refuses the slot"
write_legacy_hook "$unknown_hook"
status=$(run_apply remove --root "$unknown_root")
(( status == 1 )) || fail "remove on an unknown slot exits 1" "exit $status $(cat "$err")"
[[ ! -e $unknown_hook ]] || fail "remove retires the hook even when it refuses the slot"
rm -rf "$unknown_root"
pass "a signalling wrapper without .real is replaced and the hook retired before install refuses"

status=$(run_apply remove --root "$root")
(( status == 0 )) || fail "remove on pinned exits 0" "$(cat "$err"; echo '---'; cat "$out")"
cmp -s -- "$compare" <(printf '\x7fELF-fake-v2') ||
  fail "remove restores the v2 ELF to howdy-compare"
[[ $(file_mode "$compare") == "750" ]] ||
  fail "remove restores the vendor mode" "$(file_mode "$compare")"
[[ ! -e $real ]] || fail "remove deletes .real"
[[ ! -e $hook ]] || fail "remove deletes the hook"
status=$(run_apply remove --root "$root")
(( status == 0 )) || fail "second remove exits 0" "$(cat "$err"; echo '---'; cat "$out")"
cmp -s -- "$compare" <(printf '\x7fELF-fake-v2') ||
  fail "second remove leaves the vendor ELF in place"
[[ ! -e $real ]] || fail "second remove leaves .real absent"
[[ ! -e $hook ]] || fail "second remove leaves the hook absent"
pass "remove restores the vendor ELF and is idempotent"

printf '\x7fELF-stale' >"$real"
rm -f -- "$compare"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install on absent exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ ! -e $real ]] || fail "absent install removes a leftover .real"
[[ ! -e $hook ]] || fail "absent install writes no hook"
[[ ! -e $compare ]] || fail "absent install does not invent howdy-compare"
pass "install on an absent slot removes a leftover .real and writes no hook"

printf '\x7fELF-fake-v1' >"$compare"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "reinstall for wrapper checks exits 0" "$(cat "$err"; echo '---'; cat "$out")"
assert_wrapper_text "$compare"
pass "wrapper content pins compare to one CPU"

# Run the generated wrapper with the pinned compare swapped for a stub: it
# hands over its arguments and leaves compare's exit status to Howdy.
args_log=$root/args.log
stub=$root/stub.real
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >%q\nexit 14\n' "$args_log" >"$stub"
chmod 755 "$stub"
sed "s|/usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real|$stub|" "$compare" >"$root/wrap"
chmod 755 "$root/wrap"
status=0
"$root/wrap" --user grovr "two words" || status=$?
(( status == 14 )) || fail "wrapper keeps compare's exit status" "exit $status"
[[ $(paste -sd '|' "$args_log") == "--user|grovr|two words" ]] ||
  fail "wrapper passes compare its arguments unchanged" "$(cat "$args_log")"
pass "wrapper hands compare its arguments and keeps its status"

if (( EUID == 0 )); then
  pass "running as root; skipping the unprivileged live-path refuse"
else
  live_sentinel=$root/usr-lib-howdy-untouched
  printf 'sentinel\n' >"$live_sentinel"
  status=$(run_apply install)
  (( status == 1 )) ||
    fail "unprivileged install without --root exits 1" "exit $status $(cat "$err"; echo '---'; cat "$out")"
  grep -F 'run as root' "$err" >/dev/null ||
    fail "unprivileged install says run as root" "$(cat "$err")"
  [[ ! -s $out ]] || fail "unprivileged install writes nothing to stdout" "$(cat "$out")"
  [[ -f $live_sentinel ]] || fail "unprivileged install does not write under the test root"
  pass "unprivileged install without --root refuses and writes nothing"
fi
