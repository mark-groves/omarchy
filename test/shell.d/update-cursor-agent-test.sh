#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command tar

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
test_home="$test_tmp/home"
fixture="$test_tmp/fixture"
curl_urls="$test_tmp/curl-urls"
outcome="$test_tmp/outcome"
mkdir -p "$stub_bin" "$test_home/.local/bin" "$fixture/dist-package"

printf '#!/bin/bash\necho fake-cursor-agent\n' >"$fixture/dist-package/cursor-agent"
chmod +x "$fixture/dist-package/cursor-agent"
tar -czf "$fixture/agent-cli-package.tar.gz" -C "$fixture" dist-package

write_install_script() {
  local version=$1
  cat >"$fixture/install-script" <<EOF
#!/bin/bash
OS=linux
ARCH=x64
DOWNLOAD_URL="https://downloads.cursor.com/lab/${version}/\${OS}/\${ARCH}/agent-cli-package.tar.gz"
EOF
}

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash
if [[ $1 == -m ]]; then
  echo "${OMARCHY_TEST_UNAME_M:-x86_64}"
  exit 0
fi
exec /usr/bin/uname "$@"
SH

cat >"$stub_bin/curl" <<'SH'
#!/bin/bash
output=""
args=("$@")
i=0
while (( i < ${#args[@]} )); do
  case ${args[i]} in
  -o | --output)
    output=${args[i + 1]}
    i=$((i + 2))
    continue
    ;;
  esac
  i=$((i + 1))
done
url=${args[-1]}
printf '%s\n' "$url" >>"$TEST_CURL_URLS"

if [[ $url == https://cursor.com/install ]]; then
  if [[ -n $output ]]; then
    cat "$TEST_INSTALL_SCRIPT" >"$output"
  else
    cat "$TEST_INSTALL_SCRIPT"
  fi
  exit 0
fi

if [[ $url == https://downloads.cursor.com/lab/*/linux/*/agent-cli-package.tar.gz ]]; then
  [[ -n $output ]] || exit 22
  cat "$TEST_TARBALL" >"$output"
  exit 0
fi

exit 22
SH

cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash
exit 0
SH

chmod +x "$stub_bin"/*

agent_home="$test_home"

run_agent() {
  : >"$curl_urls"
  : >"$outcome"
  HOME="$agent_home" \
    XDG_DATA_HOME="$agent_home/.local/share" \
    PATH="$test_home/.local/bin:$stub_bin:$ROOT/bin:/usr/bin:/bin" \
    OMARCHY_VENDOR_OUTCOME="$outcome" \
    TEST_CURL_URLS="$curl_urls" \
    TEST_INSTALL_SCRIPT="$fixture/install-script" \
    TEST_TARBALL="$fixture/agent-cli-package.tar.gz" \
    "$ROOT/bin/omarchy-update-cursor-agent" "$@" >"$test_tmp/out" 2>"$test_tmp/err"
}

assert_outcome() {
  local expected=$1 description=$2
  local got
  got=$(<"$outcome")
  [[ $got == "$expected" ]] || fail "$description" "$got"
}

write_install_script 2026.08.11-e8db854
set +e
run_agent --install
rc=$?
set -e
(( rc == 0 )) || fail "first agent install exits 0" "$(cat "$test_tmp/err")"
assert_outcome $'cursor-agent\tupdated\t--\t2026.08.11-e8db854' "first agent install records updated"
[[ -x $test_home/.local/share/cursor-agent/versions/2026.08.11-e8db854/cursor-agent ]] ||
  fail "first agent install writes the versions dir"
[[ -L $test_home/.local/bin/cursor-agent ]] || fail "first agent install links cursor-agent"
[[ ! -e $test_home/.local/bin/agent ]] || fail "first agent install does not create an agent symlink"
pass "first agent install writes the Omarchy layout"

write_install_script 2026.09.08-6caf4ff
set +e
run_agent
rc=$?
set -e
(( rc == 0 )) || fail "newer agent resolve applies" "$(cat "$test_tmp/err")"
assert_outcome $'cursor-agent\tupdated\t2026.08.11-e8db854\t2026.09.08-6caf4ff' "newer agent resolve records updated"
[[ -x $test_home/.local/share/cursor-agent/versions/2026.09.08-6caf4ff/cursor-agent ]] ||
  fail "newer agent resolve writes the new versions dir"
[[ $(readlink -f "$test_home/.local/bin/cursor-agent") == "$test_home/.local/share/cursor-agent/versions/2026.09.08-6caf4ff/cursor-agent" ]] ||
  fail "newer agent resolve relinks cursor-agent"
[[ ! -e $test_home/.local/bin/agent ]] || fail "agent update does not create an agent symlink"
pass "second resolve newer applies"

write_install_script 2026.09.08-e8db854
set +e
run_agent --check
rc=$?
set -e
(( rc == 0 )) || fail "same-day rebuild --check exits 0" "$(cat "$test_tmp/err")"
assert_outcome $'cursor-agent\tstale\t2026.09.08-6caf4ff\t2026.09.08-e8db854' "same-day rebuild --check records stale"
set +e
run_agent
rc=$?
set -e
(( rc == 0 )) || fail "same-day rebuild exits 0" "$(cat "$test_tmp/err")"
assert_outcome $'cursor-agent\tupdated\t2026.09.08-6caf4ff\t2026.09.08-e8db854' "same-day rebuild records updated"
[[ -x $test_home/.local/share/cursor-agent/versions/2026.09.08-e8db854/cursor-agent ]] ||
  fail "same-day rebuild writes the new versions dir"
pass "a same-day rebuild with a lower commit hash is newer"

home_link="$test_tmp/home-link"
ln -sfn "$test_home" "$home_link"
agent_home="$home_link"
write_install_script 2026.09.09-4d5e6f7
set +e
run_agent
rc=$?
set -e
(( rc == 0 )) || fail "symlinked HOME exits 0" "$(cat "$test_tmp/err")"
assert_outcome $'cursor-agent\tupdated\t2026.09.08-e8db854\t2026.09.09-4d5e6f7' "symlinked HOME keeps the install owned"
[[ -x $test_home/.local/share/cursor-agent/versions/2026.09.09-4d5e6f7/cursor-agent ]] ||
  fail "symlinked HOME writes the new versions dir"
agent_home="$test_home"
pass "a symlinked HOME still resolves to Omarchy's install"

rm -rf "$test_home/.local/share/cursor-agent" "$test_home/.local/bin/cursor-agent"
mkdir -p "$test_home/.local/share/mise/shims"
printf '#!/bin/bash\necho mise-shim\n' >"$test_home/.local/share/mise/shims/cursor-agent"
chmod +x "$test_home/.local/share/mise/shims/cursor-agent"
ln -s "$test_home/.local/share/mise/shims/cursor-agent" "$test_home/.local/bin/cursor-agent"
set +e
run_agent
rc=$?
set -e
(( rc == 0 )) || fail "foreign agent exits 0"
assert_outcome $'cursor-agent\tforeign\t--\t--' "foreign agent is left alone"
[[ ! -d $test_home/.local/share/cursor-agent ]] || fail "foreign agent does not apply"
grep -q 'agent-cli-package.tar.gz' "$curl_urls" && fail "foreign agent does not fetch"
pass "foreign agent is left alone"
