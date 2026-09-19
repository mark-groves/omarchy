#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1789859359.sh"

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
mkdir -p "$etc" "$localbin" "$security" "$test_tmp/bin"
: >"$calls"

# The migration repairs fixed system paths. Retarget a scratch copy and require
# each literal exactly once so the copy keeps standing for the shipped file.
for literal in /etc/pam.d/sudo /etc/pam.d/omarchy-lock-face /etc/pam.d/polkit-1 \
  /usr/local/bin/omarchy-hw-ir-emitter /usr/lib/security/pam_howdy.so; do
  count=$(grep -Fo "$literal" "$migration" | wc -l)
  (( count == 1 )) || fail "migration names $literal exactly once" "found $count"
done
sed -e "s|=/etc/pam.d/|=$etc/|" \
  -e "s|=/usr/local/bin/|=$localbin/|" \
  -e "s|=/usr/lib/security/|=$security/|" "$migration" >"$copy"
pass "migration names its system paths once and the test drives a retargeted copy"

cat >"$test_tmp/bin/sudo" <<SH
#!/bin/bash
printf '%s\n' "\$*" >>"$calls"
exit 0
SH
chmod +x "$test_tmp/bin/sudo"

run_migration() {
  : >"$calls"
  PATH="$test_tmp/bin:$PATH" OMARCHY_PATH="$ROOT" bash -euo pipefail "$copy" >/dev/null
}

run_migration
[[ ! -s $calls ]] || fail "a host without face never escalates" "$(cat "$calls")"
pass "a host without face exits without a password prompt"

printf '%s\n' '#%PAM-1.0' \
  'auth      [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed' \
  'auth      sufficient pam_howdy.so' 'auth		include		system-auth' >"$etc/sudo"
run_migration
[[ ! -s $calls ]] || fail "face without the Howdy module never escalates" "$(cat "$calls")"
pass "a face stack without pam_howdy.so installed is left alone"

: >"$security/pam_howdy.so"
run_migration
[[ $(cat "$calls") == "$ROOT/bin/omarchy-setup-security-face" ]] ||
  fail "an old face pair re-runs Setup Face as root" "$(cat "$calls")"
pass "an old sudo face pair re-runs Setup Face through sudo"

rm -f "$etc/sudo"
printf '%s\n' '#%PAM-1.0' 'auth       required                    pam_howdy.so' \
  'account    include                     system-local-login' >"$etc/omarchy-lock-face"
run_migration
[[ $(cat "$calls") == "$ROOT/bin/omarchy-setup-security-face" ]] ||
  fail "an old lock face file re-runs Setup Face as root" "$(cat "$calls")"
pass "an old lock face file re-runs Setup Face through sudo"

cp "$ROOT/test/shell.d/fixtures/polkit-pam/sudo-howdy-only.pam" "$etc/sudo"
: >"$localbin/omarchy-hw-ir-emitter"
chmod 755 "$localbin/omarchy-hw-ir-emitter"
run_migration
[[ ! -s $calls ]] || fail "a repaired host never escalates again" "$(cat "$calls")"
pass "a host with the triple and the helper exits without a password prompt"
