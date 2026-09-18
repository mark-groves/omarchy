#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/powerprofilesctl" <<'EOF'
#!/bin/bash
echo "powerprofilesctl must not run: $*" >&2
exit 1
EOF
chmod +x "$tmp_dir/bin/powerprofilesctl"

cat >"$tmp_dir/bin/busctl" <<'EOF'
#!/bin/bash

if [[ $1 == --json=short && $2 == get-property && $6 == Profiles ]]; then
  printf '%s\n' '{"type":"aa{sv}","data":[{"Profile":{"type":"s","data":"power-saver"}},{"Profile":{"type":"s","data":"balanced"}},{"Profile":{"type":"s","data":"performance"}}]}'
  exit 0
fi

if [[ $1 == --json=short && $2 == get-property && $6 == ActiveProfile ]]; then
  printf '%s\n' '{"type":"s","data":"power-saver"}'
  exit 0
fi

exit 1
EOF
chmod +x "$tmp_dir/bin/busctl"

export PATH="$tmp_dir/bin:$PATH"

list_out=$("$ROOT/bin/omarchy-powerprofiles-list")
[[ $list_out == $'power-saver\nbalanced\nperformance' ]] ||
  fail "powerprofiles-list prints daemon profile names" "$list_out"
pass "powerprofiles-list prints daemon profile names"

state_out=$("$ROOT/bin/omarchy-powerprofiles-list" --active-state)
[[ $state_out == $'power-saver\t1\nbalanced\t0\nperformance\t0' ]] ||
  fail "powerprofiles-list marks the active profile" "$state_out"
pass "powerprofiles-list marks the active profile"
