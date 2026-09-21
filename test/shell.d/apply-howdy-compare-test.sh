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
  grep -F 'taskset -c 0' "$path" >/dev/null ||
    fail "wrapper pins with taskset -c 0" "$(cat "$path")"
  grep -F 'OMP_NUM_THREADS=1' "$path" >/dev/null ||
    fail "wrapper sets OMP_NUM_THREADS=1" "$(cat "$path")"
  grep -F 'OPENCV_LOG_LEVEL=ERROR' "$path" >/dev/null ||
    fail "wrapper sets OPENCV_LOG_LEVEL=ERROR" "$(cat "$path")"
  if grep -E 'OPENCV_LOG_LEVEL=(SILENT|OFF|0|FATAL)' "$path" >/dev/null; then
    fail "wrapper does not hide OpenCV errors" "$(cat "$path")"
  fi
  grep -F '/usr/lib/howdy/howdy-compare.real "$@" &' "$path" >/dev/null ||
    fail "wrapper backgrounds howdy-compare.real so INT/TERM can stop it" "$(cat "$path")"
  if grep -E '^exec /usr/bin/taskset' "$path" >/dev/null; then
    fail "wrapper does not exec compare so it can signal the result" "$(cat "$path")"
  fi
  grep -F 'omarchy-face-auth-signal' "$path" >/dev/null ||
    fail "wrapper signals the face overlay" "$(cat "$path")"
  grep -F 'signal_face scanning' "$path" >/dev/null ||
    fail "wrapper signals scanning before compare" "$(cat "$path")"
  grep -F 'signal_result recognized' "$path" >/dev/null ||
    fail "wrapper signals recognized after a match" "$(cat "$path")"
  grep -F 'signal_result notRecognized' "$path" >/dev/null ||
    fail "wrapper signals notRecognized after a miss" "$(cat "$path")"
  grep -F 'signal_face cancelled' "$path" >/dev/null ||
    fail "wrapper signals cancelled when compare never returns a result" "$(cat "$path")"
  grep -F 'trap on_exit EXIT' "$path" >/dev/null ||
    fail "wrapper traps EXIT so a killed sudo hides the card" "$(cat "$path")"
  grep -F "trap 'stop_compare INT; exit 130' INT" "$path" >/dev/null ||
    fail "INT stops compare and exits 130" "$(cat "$path")"
  grep -F "trap 'stop_compare TERM; exit 143' TERM" "$path" >/dev/null ||
    fail "TERM stops compare and exits 143" "$(cat "$path")"
  grep -F 'compare_pid=$!' "$path" >/dev/null ||
    fail "wrapper records compare's pid so the trap can stop it" "$(cat "$path")"
  grep -F 'wait "$compare_pid"' "$path" >/dev/null ||
    fail "wrapper waits for the background compare" "$(cat "$path")"
  if grep -E '^/usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real "\$@"$' "$path" >/dev/null; then
    fail "a foreground compare defers INT/TERM until Howdy finishes" "$(cat "$path")"
  fi
  grep -F 'signaled_result=1' "$path" >/dev/null ||
    fail "wrapper marks a normal result so EXIT does not hide a match" "$(cat "$path")"
  if grep -E 'signal_face cancelled' "$path" >/dev/null && ! grep -F 'if (( signaled_result == 0 )); then' "$path" >/dev/null; then
    fail "cancelled must not replace a recognized or notRecognized write" "$(cat "$path")"
  fi
  bash -n "$path" || fail "wrapper passes bash -n"
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
[[ -f $hook ]] || fail "install writes the pacman hook"
[[ $(file_mode "$hook") == "644" ]] ||
  fail "hook is mode 644" "$(file_mode "$hook")"
grep -F 'Target = usr/lib/howdy/howdy-compare' "$hook" >/dev/null ||
  fail "hook targets howdy-compare" "$(cat "$hook")"
grep -F 'omarchy-apply-howdy-compare" install' "$hook" >/dev/null ||
  fail "hook re-runs apply install" "$(cat "$hook")"
grep -F 'conf=/etc/omarchy.conf' "$hook" >/dev/null ||
  fail "hook resolves the tree through /etc/omarchy.conf" "$(cat "$hook")"
grep -F '^0:[0-7][0145][0145]$' "$hook" >/dev/null ||
  fail "hook only trusts a root-owned conf that only root can write" "$(cat "$hook")"
if grep -F '2>/dev/null' "$hook" >/dev/null; then
  fail "hook does not hide conf failures" "$(cat "$hook")"
fi
pass "install pins a vendor ELF and writes the upgrade hook"

# Run the hook's Exec script against a scratch conf and a stub tree. Only the
# fail-closed branches and the no-conf default are reachable without root.
hook_exec=$(sed -n "s/^Exec = \/usr\/bin\/bash -c '\(.*\)'$/\1/p" "$hook")
[[ -n $hook_exec ]] || fail "hook Exec is a single bash -c script" "$(cat "$hook")"
tree=$(mktemp -d)
mkdir -p "$tree/bin"
printf '#!/bin/bash\nprintf %%s "$*" >"%s/ran"\n' "$tree" >"$tree/bin/omarchy-apply-howdy-compare"
chmod 755 "$tree/bin/omarchy-apply-howdy-compare"
scratch_conf=$tree/omarchy.conf
hook_exec=${hook_exec/conf=\/etc\/omarchy.conf/conf=$scratch_conf}

set +e
OMARCHY_PATH=$tree bash -c "$hook_exec" >/dev/null 2>"$err"
status=$?
set -e
(( status == 0 )) && [[ $(cat "$tree/ran") == "install" ]] ||
  fail "hook Exec without a conf runs the resolved command" "exit $status $(cat "$err")"
rm -f "$tree/ran"

printf 'export OMARCHY_PATH=%s\n' "$tree" >"$scratch_conf"
chmod 644 "$scratch_conf"
set +e
bash -c "$hook_exec" >/dev/null 2>"$err"
status=$?
set -e
(( status == 1 )) && [[ ! -e $tree/ran ]] ||
  fail "hook Exec refuses a conf that root does not own" "exit $status $(cat "$err")"
grep -F 'only root can write' "$err" >/dev/null ||
  fail "hook Exec names the refused conf" "$(cat "$err")"

chmod 664 "$scratch_conf"
set +e
bash -c "$hook_exec" >/dev/null 2>"$err"
status=$?
set -e
(( status == 1 )) && [[ ! -e $tree/ran ]] ||
  fail "hook Exec refuses a group-writable conf" "exit $status $(cat "$err")"
rm -rf "$tree"
pass "hook Exec runs without a conf and fails closed on an untrusted one"

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
[[ ! -e $unknown_hook ]] || fail "unknown install does not write the hook"
rm -rf "$unknown_root"
pass "install refuses an unknown howdy-compare and changes nothing"

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

signals=$root/signals.log
fake_helper=$root/record-signal
cat >"$fake_helper" <<SH
#!/bin/bash
printf '%s\n' "\$1" >>"$signals"
exit 0
SH
chmod 755 "$fake_helper"

rewrite_wrapper() {
  local dest=$1
  local fake_real=$2
  cp -- "$compare" "$dest"
  chmod 755 "$dest"
  sed -i \
    -e "s|/usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real|$fake_real|" \
    -e "s|helper=\$omarchy_path/bin/omarchy-face-auth-signal|helper=$fake_helper|" \
    "$dest"
}

: >"$signals"
fast0=$root/fast0.real
printf '#!/bin/bash\nexit 0\n' >"$fast0"
chmod 755 "$fast0"
rewrite_wrapper "$root/wrap0" "$fast0"
status=0
"$root/wrap0" || status=$?
(( status == 0 )) || fail "wrapper match exits 0" "exit $status $(cat "$signals")"
[[ $(paste -sd, "$signals") == "scanning,recognized" ]] ||
  fail "wrapper match signals scanning then recognized" "$(cat "$signals")"
pass "wrapper match keeps compare's status and does not cancel"

: >"$signals"
fast1=$root/fast1.real
printf '#!/bin/bash\nexit 14\n' >"$fast1"
chmod 755 "$fast1"
rewrite_wrapper "$root/wrap1" "$fast1"
status=0
"$root/wrap1" || status=$?
(( status == 14 )) || fail "wrapper miss keeps compare's status" "exit $status $(cat "$signals")"
[[ $(paste -sd, "$signals") == "scanning,notRecognized" ]] ||
  fail "wrapper miss signals scanning then notRecognized" "$(cat "$signals")"
pass "wrapper miss keeps compare's status and does not cancel"

: >"$signals"
slow=$root/slow.real
slow_pid_file=$root/slow.pid
printf '#!/bin/bash\necho $$ >%q\nexec sleep 30\n' "$slow_pid_file" >"$slow"
chmod 755 "$slow"
rewrite_wrapper "$root/wrap-int" "$slow"
status=0
# Background bash ignores keyboard SIGINT. timeout sends INT to a new
# process group, which is the sudo Ctrl-C path.
timeout --preserve-status --signal=INT --kill-after=2s 0.4 "$root/wrap-int" || status=$?
(( status == 130 )) || fail "INT wrapper exits 130" "exit $status $(cat "$signals")"
[[ $(paste -sd, "$signals") == "scanning,cancelled" ]] ||
  fail "INT wrapper signals cancelled" "$(cat "$signals")"
pass "cancelled sudo hides the overlay without changing compare's status"

: >"$signals"
rewrite_wrapper "$root/wrap-term" "$slow"
status=0
"$root/wrap-term" &
wpid=$!
for _ in {1..40}; do
  if grep -qx scanning "$signals" 2>/dev/null; then
    break
  fi
  sleep 0.05
done
grep -qx scanning "$signals" || fail "TERM wrapper signals scanning before cancel" "$(cat "$signals")"
# TERM the wrapper only. A foreground compare would ignore this until Howdy
# finished; the trap must stop compare so PAM is not blocked.
kill -TERM "$wpid"
wait "$wpid" || status=$?
(( status == 143 )) || fail "TERM wrapper exits 143" "exit $status $(cat "$signals")"
[[ $(paste -sd, "$signals") == "scanning,cancelled" ]] ||
  fail "TERM wrapper signals cancelled" "$(cat "$signals")"
if [[ -f $slow_pid_file ]]; then
  slow_pid=$(<"$slow_pid_file")
  if [[ $slow_pid =~ ^[0-9]+$ ]]; then
    kill -TERM "$slow_pid" 2>/dev/null || true
  fi
fi
pass "TERM to the wrapper stops compare and hides the overlay"

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
