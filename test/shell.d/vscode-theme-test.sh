#!/bin/bash

source "$(dirname "$0")/base-test.sh"

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

FAKE_BIN="$TEST_HOME/bin"
CURRENT_THEME="$TEST_HOME/.local/state/omarchy/current/theme"
mkdir -p "$FAKE_BIN" "$CURRENT_THEME"

cat >"$FAKE_BIN/omarchy-cmd-present" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >>"$EDITOR_PROBE_LOG"
# Succeed for VS Code-family editors so their set_theme path runs. Fail for
# anything else so a leftover Cursor set_theme cannot exec /usr/bin/cursor.
case "$1" in
  code|code-insiders|codium) exit 0 ;;
  *) exit 1 ;;
esac
EOF

cat >"$FAKE_BIN/omarchy-toggle-enabled" <<'EOF'
#!/bin/bash
exit 1
EOF

cat >"$FAKE_BIN/code" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$CODE_INVOKE_LOG"
exit 0
EOF

cat >"$FAKE_BIN/cursor" <<'EOF'
#!/bin/bash
touch "$CURSOR_SHIM_CALLED"
exit 1
EOF

chmod +x "$FAKE_BIN"/*
printf '{"name":"Hackerman","extension":"akamud.vscode-theme-onedark"}\n' >"$CURRENT_THEME/vscode.json"

EDITOR_PROBE_LOG="$TEST_HOME/editor-probes.log" \
  CODE_INVOKE_LOG="$TEST_HOME/code-invokes.log" \
  CURSOR_SHIM_CALLED="$TEST_HOME/cursor-shim-called" \
  PATH="$FAKE_BIN:$ROOT/bin:$PATH" \
  HOME="$TEST_HOME" \
  "$ROOT/bin/omarchy-theme-set-vscode"

[[ -f $TEST_HOME/editor-probes.log ]] || fail "VS Code theme sync probes installed editors"
! grep -qi 'cursor' "$TEST_HOME/editor-probes.log" || fail "VS Code theme sync does not probe a Cursor editor binary"
[[ ! -e $TEST_HOME/cursor-shim-called ]] || fail "VS Code theme sync does not invoke a PATH Cursor binary"
[[ ! -e $TEST_HOME/.config/Cursor/User/settings.json ]] || fail "VS Code theme sync does not write Cursor settings"
grep -Fxq 'code' "$TEST_HOME/editor-probes.log" || fail "VS Code theme sync still probes the VS Code executable"
grep -Fq -- '--list-extensions' "$TEST_HOME/code-invokes.log" || fail "VS Code theme sync still lists VS Code extensions"
grep -Fq -- '--install-extension akamud.vscode-theme-onedark' "$TEST_HOME/code-invokes.log" || fail "VS Code theme sync still installs the theme's VS Code extension"
grep -q '"workbench.colorTheme": "Hackerman"' "$TEST_HOME/.config/Code/User/settings.json" || fail "VS Code theme sync still writes the VS Code color theme"
pass "VS Code theme sync skips Cursor and still themes VS Code"
