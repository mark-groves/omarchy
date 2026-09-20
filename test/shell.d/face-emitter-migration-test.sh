#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1789859359.sh"
setup="$ROOT/bin/omarchy-setup-security-face"

[[ $(stat -c %a "$migration") == "644" ]] || fail "migration is mode 0644"
if head -n1 "$migration" | grep -q '^#!'; then
  fail "migration has no shebang"
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

etc="$test_tmp/etc/pam.d"
localbin="$test_tmp/usr/local/bin"
security="$test_tmp/usr/lib/security"
calls="$test_tmp/calls.log"
copy="$test_tmp/migration.sh"
fixtures="$ROOT/test/shell.d/fixtures/polkit-pam"
mkdir -p "$etc" "$security" "$test_tmp/bin"
: >"$calls"

# The migration repairs fixed system paths. Retarget a scratch copy through the
# assignment lines and require each exactly once so the copy keeps standing for
# the shipped file.
for assignment in 'sudo_pam=/etc/pam.d/sudo' 'lock_pam=/etc/pam.d/omarchy-lock-face' \
  'polkit_pam=/etc/pam.d/polkit-1' 'emitter_helper=/usr/local/bin/omarchy-hw-ir-emitter' \
  'howdy_module=/usr/lib/security/pam_howdy.so'; do
  count=$(grep -Fxc "$assignment" "$migration")
  (( count == 1 )) || fail "migration assigns $assignment exactly once" "found $count"
done
sed -e "s#^\(sudo_pam\|lock_pam\|polkit_pam\)=/etc/pam.d/#\1=$etc/#" \
  -e "s#^emitter_helper=/usr/local/bin/#emitter_helper=$localbin/#" \
  -e "s#^howdy_module=/usr/lib/security/#howdy_module=$security/#" "$migration" >"$copy"
grep -q '^sudo_pam=/etc' "$copy" && fail "retargeted copy still names /etc/pam.d/sudo"
grep -q '^lock_pam=/etc' "$copy" && fail "retargeted copy still names /etc/pam.d/omarchy-lock-face"
pass "migration names its system paths once and the test drives a retargeted copy"

# The lock file the migration writes is the one Setup Face writes.
migration_lock=$(sed -n "/<<'EOF'/,/^EOF/p" "$migration" | sed '1d;$d')
setup_lock=$(sed -n "/<<'EOF'/,/^EOF/p" "$setup" | sed '1d;$d')
[[ -n $setup_lock && $migration_lock == "$setup_lock" ]] ||
  fail "migration and Setup Face write the same lock face file" "$migration_lock"
pass "migration lock face file matches Setup Face"

# Run the file tools for real inside the scratch tree; log the Omarchy writers
# and stop there so the test can assert which surfaces were touched.
cat >"$test_tmp/bin/sudo" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$calls"
case \$1 in
  mkdir|mktemp|install|mv|tee|chmod) exec "\$@" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$test_tmp/bin/sudo"

run_migration() {
  : >"$calls"
  PATH="$test_tmp/bin:$PATH" OMARCHY_PATH="$ROOT" bash -euo pipefail "$copy" >/dev/null
}

writers_called() {
  grep -E 'omarchy-(pam-pair-add|apply-polkit-pam)' "$calls" | sed "s|$ROOT/bin/||" || true
}

run_migration
[[ ! -s $calls ]] || fail "a host without face never escalates" "$(cat "$calls")"
pass "a host without face exits without a password prompt"

cp "$fixtures/sudo-howdy-pair-legacy.pam" "$etc/sudo"
run_migration
[[ ! -s $calls ]] || fail "face without the Howdy module never escalates" "$(cat "$calls")"
pass "a face stack without pam_howdy.so installed is left alone"

: >"$security/pam_howdy.so"
run_migration
[[ -x $localbin/omarchy-hw-ir-emitter ]] || fail "the helper is installed when any surface has face"
cmp -s "$ROOT/bin/omarchy-hw-ir-emitter" "$localbin/omarchy-hw-ir-emitter" ||
  fail "the installed helper is the checkout copy"
[[ $(writers_called) == "omarchy-pam-pair-add $etc/sudo pam_howdy.so" ]] ||
  fail "an old sudo pair upgrades sudo only" "$(cat "$calls")"
[[ ! -e $etc/omarchy-lock-face ]] || fail "sudo-only face does not create a lock face file"
[[ ! -e $etc/polkit-1 ]] || fail "sudo-only face does not create a polkit stack"
pass "an old sudo pair installs the helper and upgrades sudo only"

cp "$fixtures/sudo-howdy-only.pam" "$etc/sudo"
run_migration
[[ ! -s $calls ]] || fail "a repaired sudo stack never escalates again" "$(cat "$calls")"
pass "a host with the triple and the helper exits without a password prompt"

printf '%s\n' '#%PAM-1.0' 'auth       required                    pam_howdy.so' \
  'account    include                     system-local-login' >"$etc/omarchy-lock-face"
run_migration
[[ $(writers_called) == "" ]] || fail "an old lock file calls no PAM writer" "$(cat "$calls")"
[[ $(cat "$etc/omarchy-lock-face") == "$setup_lock" ]] ||
  fail "the lock face file is rewritten with the emitter line" "$(cat "$etc/omarchy-lock-face")"
[[ $(stat -c %a "$etc/omarchy-lock-face") == "644" ]] || fail "the lock face file is mode 644"
pass "an old lock face file is rewritten in place and nothing else moves"

cp "$fixtures/fingerprint-island.pam" "$etc/polkit-1"
run_migration
[[ ! -s $calls ]] || fail "a polkit stack without face is not touched" "$(cat "$calls")"
pass "a polkit stack without face is left as the user set it"

printf '%s\n' '#%PAM-1.0' \
  'auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed' \
  'auth      sufficient pam_howdy.so' 'auth      include    system-auth' \
  'account   include    system-auth' 'password  include    system-auth' \
  'session   include    system-auth' >"$etc/polkit-1"
run_migration
[[ $(writers_called) == "omarchy-apply-polkit-pam" ]] ||
  fail "an old polkit face pair re-derives the polkit prefix only" "$(cat "$calls")"
pass "an old polkit face pair re-derives through the compiler only"

rm -f "$etc/sudo"
run_migration
[[ $(writers_called) == "omarchy-apply-polkit-pam" ]] ||
  fail "a sudo stack without face is not given face" "$(cat "$calls")"
[[ ! -e $etc/sudo ]] || fail "a missing sudo stack is not created"
pass "face is never added to a surface that does not carry it"
