#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1789975457.sh"

[[ $(stat -c %a "$migration") == "644" ]] || fail "migration is mode 0644"
if head -n1 "$migration" | grep -q '^#!'; then
  fail "migration has no shebang"
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

etc="$test_tmp/etc/pam.d"
howdy="$test_tmp/usr/lib/howdy"
calls="$test_tmp/calls.log"
copy="$test_tmp/migration.sh"
mkdir -p "$etc" "$howdy" "$test_tmp/bin"
: >"$calls"

for assignment in 'sudo_pam=/etc/pam.d/sudo' 'lock_pam=/etc/pam.d/omarchy-lock-face' \
  'polkit_pam=/etc/pam.d/polkit-1' 'compare=/usr/lib/howdy/howdy-compare'; do
  count=$(grep -Fxc "$assignment" "$migration")
  (( count == 1 )) || fail "migration assigns $assignment exactly once" "found $count"
done
sed -e "s#^\(sudo_pam\|lock_pam\|polkit_pam\)=/etc/pam.d/#\1=$etc/#" \
  -e "s#^compare=/usr/lib/howdy/#compare=$howdy/#" "$migration" >"$copy"
grep -q '=/etc/\|=/usr/lib/howdy/' "$copy" && fail "retargeted copy still names a system path"
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

printf '%s\n' '#%PAM-1.0' 'auth       required                    pam_howdy.so' \
  'account    include                     system-local-login' >"$etc/omarchy-lock-face"
run_migration
[[ ! -s $calls ]] || fail "face without howdy-compare on disk never escalates" "$(cat "$calls")"
pass "a face stack with no howdy-compare is left alone"

printf '#!/bin/bash -p\nexec /usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real "$@"\n' >"$howdy/howdy-compare"
run_migration
[[ $(cat "$calls") == "$ROOT/bin/omarchy-apply-howdy-compare install" ]] ||
  fail "an old pin without the overlay signal reapplies the wrapper" "$(cat "$calls")"
pass "an old howdy-compare pin is replaced through sudo"

printf '#!/bin/bash -p\nexport OPENCV_LOG_LEVEL=ERROR\nsignal_face() { /usr/share/omarchy/bin/omarchy-face-auth-signal "\$1"; }\n' >"$howdy/howdy-compare"
run_migration
[[ ! -s $calls ]] || fail "a host that already signals never escalates again" "$(cat "$calls")"
pass "a wrapper that already quiets OpenCV and signals the overlay is left alone"
