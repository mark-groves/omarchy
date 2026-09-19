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
  grep -F '/usr/lib/howdy/howdy-compare.real "$@"' "$path" >/dev/null ||
    fail "wrapper execs howdy-compare.real with \"\$@\"" "$(cat "$path")"
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

status=$(run_apply install --root "$root")
(( status == 0 )) || fail "install on vendor exits 0" "$(cat "$err"; echo '---'; cat "$out")"
cmp -s -- "$real" <(printf '\x7fELF-fake-v1') ||
  fail "install copies the vendor ELF to .real"
assert_wrapper_text "$compare"
[[ $(file_mode "$compare") == "755" ]] ||
  fail "howdy-compare is mode 755" "$(file_mode "$compare")"
[[ $(file_mode "$real") == "755" ]] ||
  fail "howdy-compare.real is mode 755" "$(file_mode "$real")"
[[ -f $hook ]] || fail "install writes the pacman hook"
[[ $(file_mode "$hook") == "644" ]] ||
  fail "hook is mode 644" "$(file_mode "$hook")"
grep -F 'Target = usr/lib/howdy/howdy-compare' "$hook" >/dev/null ||
  fail "hook targets howdy-compare" "$(cat "$hook")"
grep -F 'Exec = /usr/bin/omarchy-apply-howdy-compare install' "$hook" >/dev/null ||
  fail "hook re-runs apply install" "$(cat "$hook")"
pass "install pins a vendor ELF and writes the upgrade hook"

real_sum=$(checksum "$real")
wrapper_sum=$(checksum "$compare")
status=$(run_apply install --root "$root")
(( status == 0 )) || fail "second install exits 0" "$(cat "$err"; echo '---'; cat "$out")"
[[ $(checksum "$real") == "$real_sum" ]] || fail "second install leaves .real unchanged"
[[ $(checksum "$compare") == "$wrapper_sum" ]] || fail "second install leaves the wrapper unchanged"
pass "install is idempotent on an already pinned slot"

printf '\x7fELF-fake-v2' >"$compare"
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
