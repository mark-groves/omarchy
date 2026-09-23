#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Runs the real FaceChromeCanvas under plain Qt, with FaceChrome stubbed, to
# prove the result hold follows frameSwapped on the window it is drawn in.
# Source checks cannot see a signal that the target object does not have.

qml_bin=""
for candidate in /usr/lib/qt6/bin/qml qml6; do
  if command -v "$candidate" >/dev/null 2>&1; then
    qml_bin=$(command -v "$candidate")
    break
  fi
done

if [[ -z $qml_bin ]]; then
  pass "no Qt 6 qml runtime; skipping face canvas runtime test"
  exit 0
fi

fixture="$SHELL_TEST_DIR/fixtures/face-canvas-runtime"
output=$(cd "$fixture" && XDG_RUNTIME_DIR=$(mktemp -d) QT_QPA_PLATFORM=offscreen timeout 30 "$qml_bin" -I . Harness.qml 2>&1) \
  || fail "face canvas harness runs" "$output"

field() {
  local phase="$1"
  local name="$2"
  local line

  line=$(grep -m1 "RESULT $phase " <<<"$output") || fail "harness reports the $phase phase" "$output"
  sed -E "s/.* $name=(-?[0-9]+).*/\1/" <<<"$line"
}

if grep -q "no signal of the target matches" <<<"$output"; then
  fail "the canvas connects to a window that emits frameSwapped" "$output"
fi
pass "the canvas connects to a window that emits frameSwapped"

(( $(field frozen ticks) > 0 )) || fail "animation ticks run while the window is not presenting" "$output"
pass "animation ticks run while the window is not presenting"

(( $(field frozen swaps) == 0 )) || fail "a window that is not presenting swaps no frames" "$output"
(( $(field frozen played) == 0 )) || fail "ticks without swaps do not finish the recognized hold" "$output"
pass "ticks without swaps do not finish the recognized hold"

(( $(field presented played) == 1 )) || fail "the recognized hold finishes once frames are presented" "$output"
pass "the recognized hold finishes once frames are presented"

(( $(field presented afterShowMs) >= 300 )) || fail "the hold lasts at least its 300 ms of presented frames" "$output"
pass "the hold lasts at least its 300 ms of presented frames"

(( $(field inactive played) == 1 && $(field inactive elapsed) == 0 )) \
  || fail "an inactive card credits no swaps to a new cycle" "$output"
pass "an inactive card credits no swaps to a new cycle"
