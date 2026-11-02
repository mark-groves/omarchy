#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mock_path="$test_tmp/bin"
mkdir -p "$mock_path" "$test_tmp/aur"
: >"$test_tmp/notifications"

# pacman reads the installed AUR packages and their package base from a fake
# local database. curl answers as the AUR RPC does: multiinfo, with only the
# requested names it knows, so a request that loses its names lists nothing.
cat >"$mock_path/pacman" <<'EOF'
#!/bin/bash
case $1 in
  -Qmq) cat "$TEST_TMP/installed" ;;
  -Qem) head -n1 "$TEST_TMP/installed" ;;
  -Q) echo "$2 1-1" ;;
esac
EOF

cat >"$mock_path/pacman-conf" <<'EOF'
#!/bin/bash
echo "$TEST_TMP/db/"
EOF

cat >"$mock_path/curl" <<'EOF'
#!/bin/bash
if [[ -n ${TEST_AUR_DOWN:-} ]]; then
  exit 7
elif [[ -v TEST_AUR_REPLY ]]; then
  printf '%s' "$TEST_AUR_REPLY"
else
  results=()
  for arg in "$@"; do
    if [[ $arg == "arg[]="* && -f $TEST_TMP/aur/${arg#arg[]=}.json ]]; then
      results+=("$(<"$TEST_TMP/aur/${arg#arg[]=}.json")")
    fi
  done
  printf '{"type":"multiinfo","version":5,"results":[%s]}\n' "$(IFS=,; echo "${results[*]}")"
fi
EOF

cat >"$mock_path/yay" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >"$TEST_TMP/yay-args"
EOF

# Fails like a session with no notification daemon when TEST_NOTIFY_FAIL is set.
cat >"$mock_path/omarchy-notification-send" <<'EOF'
#!/bin/bash
if [[ -n ${TEST_NOTIFY_FAIL:-} ]]; then
  exit 1
fi
printf '%s\n' "$*" >>"$TEST_TMP/notifications"
EOF

cat >"$mock_path/omarchy-pkg-aur-accessible" <<'EOF'
#!/bin/bash
exit 0
EOF

chmod +x "$mock_path"/*

state=$test_tmp/state/omarchy/aur-maintainers

# installed <name> <base>
installed() {
  echo "$1" >>"$test_tmp/installed"
  mkdir -p "$test_tmp/db/local/$1-1-1"
  printf '%%NAME%%\n%s\n\n%%BASE%%\n%s\n' "$1" "$2" >"$test_tmp/db/local/$1-1-1/desc"
}

uninstalled() {
  grep -vx -- "$1" "$test_tmp/installed" >"$test_tmp/installed.new" || true
  mv -- "$test_tmp/installed.new" "$test_tmp/installed"
}

# aur <name> <base> <maintainer JSON> [co-maintainers JSON] [depends JSON] [version] [provides JSON]
aur() {
  printf '{"Name":"%s","PackageBase":"%s","Version":"%s","Maintainer":%s,"CoMaintainers":%s,"Depends":%s,"Provides":%s}' \
    "$1" "$2" "${6:-1-1}" "$3" "${4:-null}" "${5:-[]}" "${7:-[]}" >"$test_tmp/aur/$1.json"
}

run() {
  PATH="$mock_path:$ROOT/bin:$PATH" OMARCHY_PATH="$ROOT" XDG_STATE_HOME="$test_tmp/state" TEST_TMP="$test_tmp" "$@"
}

# The held packages on one line. A failed check prints a line no assertion
# expects, so a crash never reads as "nothing held".
held() {
  if run omarchy-pkg-aur-maintainer held >"$test_tmp/out" 2>"$test_tmp/err"; then
    paste -sd ' ' "$test_tmp/out"
  else
    echo "held failed: $(cat "$test_tmp/err")"
  fi
}

trust() {
  run omarchy-pkg-aur-maintainer trust "$1" >/dev/null
}

notifications() {
  wc -l <"$test_tmp/notifications"
}

installed howdy-next howdy-next
installed howdy-next-debug howdy-next
aur howdy-next howdy-next '"nathawatc"'

[[ -z $(held) ]] || fail "packages seen for the first time are not held" "$(cat "$test_tmp/err")"
[[ $(<"$state") == $'howdy-next\thowdy-next\tnathawatc\t-\tok\t1-1\nhowdy-next-debug\t!absent\t-\t-\tok\t-' ]] ||
  fail "first sight records who controls each package, and that the AUR lacks the debug package" "$(cat "$state")"
aur howdy-next howdy-next '"nathawatc"' null '[]' 1-2
[[ -z $(held) ]] || fail "a new build from the same maintainer is not held" "$(cat "$test_tmp/err")"
pass "the first state seen is trusted, and a new build from the same maintainer updates"

aur howdy-next howdy-next '"stranger"'
[[ $(held) == "howdy-next" ]] || fail "a changed maintainer holds the package"
grep -Fq "from nathawatc to stranger" "$test_tmp/err" || fail "the hold names both maintainers" "$(cat "$test_tmp/err")"
(( $(notifications) == 1 )) || fail "a new hold notifies once" "$(cat "$test_tmp/notifications")"
aur howdy-next howdy-next '"nathawatc"'
[[ $(held) == "howdy-next" ]] || fail "a hold stays until trusted, even if the maintainer name comes back"
(( $(notifications) == 1 )) || fail "a standing hold does not notify again"
trust howdy-next
[[ -z $(held) ]] || fail "a trusted package updates again" "$(cat "$test_tmp/err")"
pass "a changed maintainer holds the package, notified once, until trusted"

aur howdy-next howdy-next '"stranger"'
[[ $(TEST_NOTIFY_FAIL=1 held) == "howdy-next" ]] || fail "a hold still holds when the notification cannot be shown"
grep -Fq "tried again" "$test_tmp/err" || fail "a failed notification is reported" "$(cat "$test_tmp/err")"
[[ $(held) == "howdy-next" ]] || fail "the hold stands on the next update"
(( $(notifications) == 2 )) || fail "a notification that could not be shown is sent on the next update"
trust howdy-next
pass "a notification that cannot be shown neither stops the check nor gets lost"

aur howdy-next howdy-next '"stranger"' '["alice"]'
trust howdy-next
aur howdy-next howdy-next '"alice"'
[[ -z $(held) ]] || fail "a co-maintainer taking over is not held" "$(cat "$test_tmp/err")"
aur howdy-next howdy-next '"alice"' '["trudy"]'
[[ $(held) == "howdy-next" ]] || fail "a new co-maintainer holds the package"
grep -Fq "co-maintainer: trudy" "$test_tmp/err" || fail "the hold names the new co-maintainer" "$(cat "$test_tmp/err")"
trust howdy-next
aur howdy-next howdy-next '"alice"'
[[ -z $(held) ]] || fail "a co-maintainer leaving does not hold the package" "$(cat "$test_tmp/err")"
aur howdy-next howdy-next null
[[ $(held) == "howdy-next" ]] || fail "an orphaned package is held"
grep -Fq "to nobody (orphaned)" "$test_tmp/err" || fail "the hold says the package is orphaned" "$(cat "$test_tmp/err")"
trust howdy-next
aur howdy-next howdy-next null null '[]' 2-1
[[ $(held) == "howdy-next" ]] || fail "an orphan with a new build is held"
trust howdy-next
aur howdy-next howdy-next '"mallory"' null '[]' 2-1
[[ $(held) == "howdy-next" ]] || fail "an adoption is held"
trust howdy-next
pass "maintainer and co-maintainer changes, orphaning and an orphan's new build hold the package; a handover to a co-maintainer does not"

# Someone registers the name of a package that was not on the AUR, and a
# package is seen for the first time under a different AUR package base.
aur howdy-next-debug squatter '"mallory"'
installed geant4-debug geant4
aur geant4-debug geant4-debug '"gipert"'
[[ $(held) == "geant4-debug howdy-next-debug" ]] ||
  fail "a name taken by a different AUR package is held, on first sight or later" "$(cat "$test_tmp/err")"
if run omarchy-pkg-aur-maintainer trust geant4-debug 2>"$test_tmp/err"; then
  fail "trust refuses to switch a package to a different AUR package base"
fi
grep -Fq "remove geant4-debug and install it from the AUR again" "$test_tmp/err" || fail "the refusal says how to switch" "$(cat "$test_tmp/err")"
pass "a name taken by a different AUR package is held, and trust will not switch to it"

installed needs-debug needs-debug
aur needs-debug needs-debug '"nathawatc"' null '["howdy-next-debug>=3"]'
installed foo-git foo-git
aur foo-git foo-git '"alice"' null '[]' 1-1 '["foo=1.0"]'
installed bar bar
aur bar bar '"alice"' null '["foo>=2"]'
[[ $(held) == "geant4-debug howdy-next-debug needs-debug" ]] ||
  fail "a package that needs a held one is held, and new packages are trusted on sight" "$(cat "$test_tmp/err")"
aur foo-git foo-git '"mallory"' null '[]' 1-1 '["foo=1.0"]'
[[ $(held) == "bar foo-git geant4-debug howdy-next-debug needs-debug" ]] ||
  fail "a package that needs a held one, by name or by what it provides, is held with it" "$(cat "$test_tmp/err")"
run omarchy-pkg-aur-maintainer trust bar >"$test_tmp/out"
grep -Fq "trust that one instead" "$test_tmp/out" || fail "trust explains a hold that comes from a dependency" "$(cat "$test_tmp/out")"
pass "a package that needs a held one waits with it"

for reply in '' '{"type":"error","error":"Incorrect request type specified."}'; do
  if TEST_AUR_REPLY=$reply run omarchy-pkg-aur-maintainer held >/dev/null 2>&1; then
    fail "held fails on an AUR reply that is not multiinfo" "$reply"
  fi
done
if TEST_AUR_DOWN=1 run omarchy-pkg-aur-maintainer held >/dev/null 2>&1; then
  fail "held fails when the AUR cannot be reached"
fi
if run omarchy-pkg-aur-maintainer trust not-installed 2>/dev/null; then
  fail "trust refuses a package that is not installed"
fi
if TEST_AUR_DOWN=1 run omarchy-pkg-aur-maintainer trust howdy-next 2>"$test_tmp/err"; then
  fail "trust fails when the AUR cannot be reached"
fi
grep -Fq "Could not reach the AUR" "$test_tmp/err" || fail "trust says why it failed" "$(cat "$test_tmp/err")"
pass "held and trust fail when the AUR cannot be checked, and trust refuses what is not installed"

run omarchy-update-aur-pkgs >/dev/null 2>&1
[[ $(<"$test_tmp/yay-args") == "-Sua --noconfirm --cleanafter --ignore gcc14,gcc14-libs,bar,foo-git,geant4-debug,howdy-next-debug,needs-debug" ]] ||
  fail "the update skips every held package" "$(cat "$test_tmp/yay-args")"
rm -f -- "$test_tmp/yay-args"
TEST_AUR_DOWN=1 run omarchy-update-aur-pkgs >/dev/null 2>&1 || fail "an unreachable maintainer check does not fail the update"
[[ ! -e $test_tmp/yay-args ]] || fail "an unchecked update installs nothing from the AUR"
pass "the AUR update skips held packages, and installs nothing it could not check"

trust foo-git
for name in geant4-debug howdy-next-debug; do
  uninstalled "$name"
done
run omarchy-update-aur-pkgs >"$test_tmp/update" 2>&1
[[ -f $test_tmp/yay-args && $(<"$test_tmp/yay-args") == "-Sua --noconfirm --cleanafter --ignore gcc14,gcc14-libs" ]] ||
  fail "the update installs packages once nothing is held" "$(cat "$test_tmp/update")"
if grep -E -q '^(geant4-debug|howdy-next-debug)'$'\t' "$state"; then
  fail "records of packages that are no longer installed are dropped" "$(cat "$state")"
fi
pass "packages update once nothing is held, and records of removed packages are dropped"
