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
pin_hook=$root/etc/pacman.d/hooks/omarchy-howdy-compare-pin.hook
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
[[ ! -e $hook ]] || fail "install does not write the retired hook" "$(cat "$hook")"
[[ -f $pin_hook ]] || fail "install writes the pin hook"
[[ $(file_mode "$pin_hook") == "644" ]] ||
  fail "pin hook is mode 644" "$(file_mode "$pin_hook")"
pass "install pins a vendor ELF and writes the pin hook"

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

# Hosts pinned before the pin hook existed are the migration's main population.
pin_hook_sum=$(checksum "$pin_hook")
rm -f -- "$pin_hook"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install on a pinned slot without the hook exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ -f $pin_hook && $(checksum "$pin_hook") == "$pin_hook_sum" ]] ||
  fail "install on a pinned slot writes a missing pin hook"
printf '# stale\n' >"$pin_hook"
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install over a stale pin hook exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ $(checksum "$pin_hook") == "$pin_hook_sum" ]] || fail "install rewrites a stale pin hook"
pass "install on a pinned slot writes a missing pin hook and refreshes a stale one"

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
[[ -f $unknown_root/etc/pacman.d/hooks/omarchy-howdy-compare-pin.hook ]] ||
  fail "unknown install still writes the pin hook, so the next howdy-next install is pinned"
rm -rf "$unknown_root"
pass "install refuses an unknown howdy-compare, leaving it as it is, and writes the pin hook"

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
[[ ! -e $pin_hook ]] || fail "remove deletes the pin hook"
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
[[ -f $pin_hook ]] || fail "absent install writes the pin hook, so a later howdy-next install is pinned"
[[ ! -e $compare ]] || fail "absent install does not invent howdy-compare"
pass "install on an absent slot removes a leftover .real and writes the pin hook"

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

# -p in the shebang is what keeps BASH_ENV and exported functions out, so an
# ordinary Bash launch with a decoy -p argument is refused before compare runs.
printf 'untouched\n' >"$args_log"
status=0
/usr/bin/bash "$root/wrap" -p 2>"$err" || status=$?
(( status == 126 )) || fail "wrapper refuses an ordinary Bash launch" "exit $status"
grep -Fq "Refusing an unsafe Bash startup" "$err" || fail "wrapper explains the refusal" "$(cat "$err")"
[[ $(cat "$args_log") == "untouched" ]] || fail "a refused launch never reaches compare" "$(cat "$args_log")"
pass "wrapper refuses an ordinary Bash launch with a decoy -p"

# pacman splits Exec like a shell but passes a single-quoted word through as
# it is, so the hook's script reaches bash unchanged only while it holds no
# single quote. Run that script on a second root, with only its compare path
# redirected, through each slot state an upgrade or removal leaves.
exec_line=$(grep '^Exec = ' "$pin_hook")
exec_prefix="Exec = /usr/bin/bash -p -c '"
[[ $exec_line == "$exec_prefix"*"'" ]] ||
  fail "pin hook runs one single-quoted bash -p script" "$exec_line"
(( ${#exec_line} < 4096 )) ||
  fail "pin hook Exec fits pacman's 4096-byte line buffer" "${#exec_line} bytes"
hook_script=${exec_line#"$exec_prefix"}
hook_script=${hook_script%"'"}
[[ $hook_script != *"'"* ]] || fail "pin hook script holds no single quote" "$hook_script"
if grep -i -E 'omarchy' <<<"$hook_script" >/dev/null; then
  fail "pin hook runs nothing from the Omarchy tree" "$hook_script"
fi
hook_root=$(mktemp -d)
hook_compare=$hook_root/usr/lib/howdy/howdy-compare
compare_assignment="c=/usr/lib/howdy/howdy-compare;"
local_script=${hook_script/"$compare_assignment"/"c=$hook_compare;"}
wrapper_exec="exec /usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real"
unredirected=${hook_script/"$compare_assignment"/}
unredirected=${unredirected//"$wrapper_exec"/}
[[ $local_script != "$hook_script" && $unredirected != */usr/lib/howdy* ]] ||
  fail "pin hook script reaches the system only through its compare path" "$hook_script"
mkdir -p "$hook_root/usr/lib/howdy"
# An upgrade leaves the new ELF in compare beside the previous version's
# .real. GNU tools parse options strictly under POSIXLY_CORRECT, which root's
# environment may carry into pacman.
printf '\x7fELF-fake-v2' >"$hook_compare.real"
printf '\x7fELF-fake-v3' >"$hook_compare"
chmod 750 "$hook_compare"
POSIXLY_CORRECT=1 bash -p -c "$local_script" || fail "pin hook script exits 0 after an upgrade"
cmp -s -- "$hook_compare.real" <(printf '\x7fELF-fake-v3') ||
  fail "pin hook moves the upgraded ELF to .real"
[[ -z $(find "$hook_root/usr/lib/howdy" -name '*.new.*') ]] ||
  fail "pin hook leaves no temporary files" "$(ls -a "$hook_root/usr/lib/howdy")"
[[ $(file_mode "$hook_compare.real") == "750" ]] ||
  fail "pin hook keeps the vendor mode on .real" "$(file_mode "$hook_compare.real")"
cmp -s -- "$hook_compare" "$compare" ||
  fail "pin hook writes the same wrapper as install" "$(diff -- "$compare" "$hook_compare")"
[[ $(file_mode "$hook_compare") == "755" ]] ||
  fail "pin hook wrapper is mode 755" "$(file_mode "$hook_compare")"
wrapper_sum=$(checksum "$hook_compare")
bash -p -c "$local_script" || fail "pin hook script exits 0 on a pinned slot"
[[ $(checksum "$hook_compare") == "$wrapper_sum" ]] ||
  fail "pin hook leaves a pinned wrapper alone"
cmp -s -- "$hook_compare.real" <(printf '\x7fELF-fake-v3') ||
  fail "pin hook leaves .real alone on a pinned slot"
rm -f -- "$hook_compare"
bash -p -c "$local_script" || fail "pin hook script exits 0 after howdy-next is removed"
[[ ! -e $hook_compare.real ]] || fail "pin hook clears the leftover .real after a removal"
[[ ! -e $hook_root/usr/lib/howdy ]] ||
  fail "pin hook removes the directory howdy-next left empty" "$(ls -a "$hook_root/usr/lib/howdy")"
rm -rf "$hook_root"
pass "pin hook script re-pins an upgraded compare, leaves a pinned one, and clears up after a removal"

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
