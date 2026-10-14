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

# Whether the theme's extension is installed comes from the editor's extension
# registry, so a theme switch doesn't boot Electron for --list-extensions.
EDITOR_BIN="$TEST_HOME/editor-bin"
EXTENSIONS="$TEST_HOME/.vscode/extensions"
EDITOR_LOG="$TEST_HOME/editor.log"
mkdir -p "$EDITOR_BIN"

cat >"$EDITOR_BIN/omarchy-cmd-present" <<'EOF'
#!/bin/bash
[[ $1 == "code" ]]
EOF

cat >"$EDITOR_BIN/omarchy-toggle-enabled" <<'EOF'
#!/bin/bash
exit 1
EOF

cat >"$EDITOR_BIN/code" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$EDITOR_LOG"
[[ $1 == "--list-extensions" ]] && printf '%s\n' "$LISTED_EXTENSIONS"
exit 0
EOF

chmod +x "$EDITOR_BIN"/*
printf '{"name":"Hackerman","extension":"Bjarne.hackerman-omarchy"}\n' >"$CURRENT_THEME/vscode.json"

run_vscode_sync() {
  rm -f "$EDITOR_LOG"
  EDITOR_LOG="$EDITOR_LOG" \
    LISTED_EXTENSIONS="${LISTED_EXTENSIONS:-}" \
    PATH="$EDITOR_BIN:$ROOT/bin:$PATH" \
    HOME="$TEST_HOME" \
    "$ROOT/bin/omarchy-theme-set-vscode"
}

editor_calls() {
  [[ -f $EDITOR_LOG ]] && cat "$EDITOR_LOG"
}

mkdir -p "$EXTENSIONS/bjarne.hackerman-omarchy-1.0.0"
printf '[{"identifier":{"id":"bjarne.hackerman-omarchy"},"version":"1.0.0","relativeLocation":"bjarne.hackerman-omarchy-1.0.0"}]\n' >"$EXTENSIONS/extensions.json"
run_vscode_sync
[[ -z $(editor_calls) ]] || fail "VS Code theme sync finds a registered extension without starting the editor" "$(editor_calls)"
grep -q '"workbench.colorTheme": "Hackerman"' "$TEST_HOME/.config/Code/User/settings.json" || fail "VS Code theme sync selects the theme of a registered extension"
pass "VS Code theme sync finds a registered extension without starting the editor"

printf '{"bjarne.hackerman-omarchy-1.0.0":true}\n' >"$EXTENSIONS/.obsolete"
run_vscode_sync
[[ $(editor_calls) == "--install-extension Bjarne.hackerman-omarchy" ]] || fail "VS Code theme sync reinstalls an extension marked obsolete" "$(editor_calls)"
rm -f "$EXTENSIONS/.obsolete"
pass "VS Code theme sync reinstalls an extension marked obsolete"

rm -rf "$EXTENSIONS/bjarne.hackerman-omarchy-1.0.0"
run_vscode_sync
[[ $(editor_calls) == "--install-extension Bjarne.hackerman-omarchy" ]] || fail "VS Code theme sync reinstalls a registered extension whose directory is gone" "$(editor_calls)"
pass "VS Code theme sync reinstalls a registered extension whose directory is gone"

printf '[]\n' >"$EXTENSIONS/extensions.json"
run_vscode_sync
[[ $(editor_calls) == "--install-extension Bjarne.hackerman-omarchy" ]] || fail "VS Code theme sync installs an unregistered extension" "$(editor_calls)"
pass "VS Code theme sync installs an unregistered extension"

rm -f "$EXTENSIONS/extensions.json"
LISTED_EXTENSIONS="bjarne.hackerman-omarchy" run_vscode_sync
[[ $(editor_calls) == "--list-extensions" ]] || fail "VS Code theme sync asks the editor when it has no extension registry" "$(editor_calls)"
pass "VS Code theme sync asks the editor when it has no extension registry"

# omarchy-theme-set reports a retint that exits non-zero, so skipping an
# editor by its toggle must still succeed.
SKIP_BIN="$TEST_HOME/skip-bin"
mkdir -p "$SKIP_BIN"
cat >"$SKIP_BIN/omarchy-toggle-enabled" <<'EOF2'
#!/bin/bash
[[ $1 == "skip-cursor-theme-changes" ]]
EOF2
chmod +x "$SKIP_BIN/omarchy-toggle-enabled"
EDITOR_PROBE_LOG="$TEST_HOME/editor-probes.log" PATH="$SKIP_BIN:$FAKE_BIN:$ROOT/bin:$PATH" HOME="$TEST_HOME" \
  "$ROOT/bin/omarchy-theme-set-vscode" || fail "VS Code theme sync succeeds when the last editor is skipped by its toggle"
pass "VS Code theme sync succeeds when the last editor is skipped by its toggle"
