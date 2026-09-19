#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

migration="$ROOT/migrations/1789860450.sh"

[[ $(stat -c %a "$migration") == "644" ]] || fail "migration is mode 0644"
if head -n1 "$migration" | grep -q '^#!'; then
  fail "migration has no shebang"
fi

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

etc="$test_tmp/etc/pam.d"
howdy="$test_tmp/usr/lib/howdy"
hooks="$test_tmp/etc/pacman.d/hooks"
calls="$test_tmp/calls.log"
copy="$test_tmp/migration.sh"
mkdir -p "$etc" "$howdy" "$hooks" "$test_tmp/bin"
: >"$calls"

for literal in /etc/pam.d/sudo /usr/lib/howdy/howdy-compare /etc/pacman.d/hooks/omarchy-howdy-compare.hook; do
  count=$(grep -Fo "$literal" "$migration" | wc -l)
  (( count == 1 )) || fail "migration names $literal exactly once" "found $count"
done
sed -e "s|=/etc/pam.d/|=$etc/|" \
  -e "s|=/usr/lib/howdy/|=$howdy/|" \
  -e "s|=/etc/pacman.d/hooks/|=$hooks/|" "$migration" >"$copy"
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

cp "$ROOT/test/shell.d/fixtures/polkit-pam/sudo-howdy-only.pam" "$etc/sudo"
run_migration
[[ ! -s $calls ]] || fail "face without howdy-compare on disk never escalates" "$(cat "$calls")"
pass "a face stack with no howdy-compare is left alone"

printf '\x7fELF-fake' >"$howdy/howdy-compare"
run_migration
[[ $(cat "$calls") == "$ROOT/bin/omarchy-apply-howdy-compare install" ]] ||
  fail "an unpinned vendor compare applies the pin as root" "$(cat "$calls")"
pass "an unpinned vendor howdy-compare applies the pin through sudo"

printf '#!/bin/bash\nexec /usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real "$@"\n' >"$howdy/howdy-compare"
: >"$hooks/omarchy-howdy-compare.hook"
run_migration
[[ $(cat "$calls") == "$ROOT/bin/omarchy-apply-howdy-compare install" ]] ||
  fail "a hand-written wrapper without -p applies the pin as root" "$(cat "$calls")"
pass "an earlier wrapper without -p is replaced through sudo"

printf '#!/bin/bash -p\nexec /usr/bin/taskset -c 0 /usr/lib/howdy/howdy-compare.real "$@"\n' >"$howdy/howdy-compare"
run_migration
[[ ! -s $calls ]] || fail "a pinned host with the hook never escalates again" "$(cat "$calls")"
pass "a pinned host with the hook exits without a password prompt"
