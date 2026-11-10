#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

# A lossless clip with a known pace: a box moves on every other refresh (30
# presented fps at 60) and each move flips a quadrant. The refresh in between
# brightens half the picture by 2 levels, the way the encoder refines a still
# picture after a big change: spread out, low, and a small fraction of the
# change before it. From frame 88 the picture holds until frame 96.
step='if(lt(N,90),floor(N/2),if(lt(N,96),44,floor(N/2)-3))'
residue='if(lt(N,90),mod(N,2),if(lt(N,96),1,mod(N,2)))'
box="between(X,40+mod(7*$step,200),87+mod(7*$step,200))*between(Y,60,107)"
lum="if($box,220,if(lt(X,160)*lt(Y,120),40+100*mod($step,2),16+2*$residue*gte(Y,120)))"
ffmpeg -v error -nostdin -f lavfi -i "color=black:s=320x240:r=60:d=3" -vf "format=gray,geq=lum='$lum',format=yuv420p" \
  -c:v libx264 -qp 0 -bf 0 -g 30 "$test_tmp/clip.mp4"

"$ROOT/bin/omarchy-dev-face-record" analyze "$test_tmp/clip.mp4" --region 320x240+0+0 --no-sheets \
  --phase steady=0.4-1.4 --phase freeze=1.3-1.8 --out "$test_tmp/analysis" >"$test_tmp/analyze.log" 2>&1 ||
  fail "analyze runs on a clip with no sidecar" "$(cat "$test_tmp/analyze.log")"

summary=$test_tmp/analysis/summary.json
steady=$(jq -c '.phases[] | select(.name == "steady")' "$summary")
jq -e '.presentedFps >= 28 and .presentedFps <= 32' <<<"$steady" >/dev/null ||
  fail "refinement-like residue is not counted as a presented frame" "$steady"
pass "refinement-like residue is not counted as a presented frame"

jq -e '.anyChangeFps >= 55 and .longestHoldRefreshes == 2' <<<"$steady" >/dev/null ||
  fail "a steady 30 fps pace holds each frame for 2 refreshes" "$steady"
pass "a steady 30 fps pace holds each frame for 2 refreshes"

freeze=$(jq -c '.phases[] | select(.name == "freeze")' "$summary")
jq -e '.longestHoldRefreshes == 8 and (.longestHoldAt - 88 / 60 | fabs) < 0.002' <<<"$freeze" >/dev/null ||
  fail "a stall is measured from the last presented frame" "$freeze"
pass "a stall is measured from the last presented frame"

# The probe lines and PAM verdicts are read from the journal by their shape.
OMARCHY_TEST_SCRIPT="$ROOT/bin/omarchy-dev-face-record" python3 -I - <<'PY' || fail "probe lines and verdicts are read from the journal"
import importlib.machinery, importlib.util, os

loader = importlib.machinery.SourceFileLoader("face_record", os.environ["OMARCHY_TEST_SCRIPT"])
spec = importlib.util.spec_from_loader(loader.name, loader)
record = importlib.util.module_from_spec(spec)
loader.exec_module(record)

origin = 1794262776.6
entries = [
  (1794262789.210, "omarchy-shell[1]", ' DEBUG qml: face-probe-event {"surface":"lock","state":"scanning","t":1794262789196,'
   '"rect":{"x":690,"y":177,"w":220,"h":220},"window":"lock"}'),
  (1794262790.900, "quickshell[2]", "pam_howdy(omarchy-lock-face:auth): Face verification succeeded"),
  (1794262791.000, "omarchy-shell[1]", ' DEBUG qml: face-probe {"surface":"lock","shownAt":1794262789190,"moved":false}'),
  (1794262791.100, "sudo[3]", "pam_warn(sudo:setcred): function=[pam_sm_setcred] flags=0x8"),
]
events = record.journal_events(entries, origin)
kinds = [event["kind"] for event in events]
assert kinds == ["probe-event", "pam", "probe"], kinds
assert abs(events[0]["t"] - (1794262789.196 - origin)) < 1e-3, events[0]
assert events[1]["data"]["verdict"] == "match" and events[1]["data"]["service"] == "omarchy-lock-face", events[1]
PY
pass "probe lines and verdicts are read from the journal"
