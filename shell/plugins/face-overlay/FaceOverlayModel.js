function knownState(state) {
  return state === "scanning" || state === "recognized" || state === "notRecognized" || state === "cancelled"
}

function isHideState(state) {
  return state === "cancelled"
}

// Howdy's compare sandbox is 15 s of CPU. The wrapper pins that to one core,
// so wall time matches. Twenty seconds is long enough for a real scan and
// short enough that a killed wrapper cannot leave Look at the camera up.
function scanTimeoutMs() {
  return 20000
}

function signalPath(runtimeDir) {
  var dir = String(runtimeDir || "")
  if (!dir) return ""
  return dir + "/omarchy/face-auth.json"
}

function parseSignal(raw) {
  var text = String(raw || "").trim()
  if (!text) return null
  try {
    var data = JSON.parse(text)
    var state = data && data.state !== undefined ? String(data.state) : ""
    if (!knownState(state)) return null
    var ts = Number(data.ts)
    return { state: state, ts: isFinite(ts) ? ts : 0 }
  } catch (e) {
    return null
  }
}

function parseShowPayload(raw) {
  var text = String(raw || "").trim()
  if (knownState(text)) return { state: text, ts: 0 }
  if (!text) return null
  return parseSignal(text)
}

function isStaleSignal(next, startedTs) {
  if (!next) return true
  var ts = Number(next.ts)
  if (!isFinite(ts) || ts <= 0) return true
  var started = Number(startedTs)
  if (!isFinite(started) || started <= 0) return false
  return ts < started
}

function isNewerSignal(next, current) {
  if (!next) return false
  if (!current) return true
  if (!next.ts) return true
  if (!current.ts) return true
  return next.ts >= current.ts
}

function shouldSuppress(lockLocked, polkitVisible) {
  return !!(lockLocked || polkitVisible)
}

function resultHoldMs(state, holdMs) {
  if (state !== "recognized" && state !== "notRecognized") return 0
  var ms = Number(holdMs)
  if (!isFinite(ms) || ms <= 0) return 0
  return Math.min(ms, 2000)
}

function hintFor(state) {
  if (state === "recognized") return "Face recognized"
  if (state === "notRecognized") return "Face not recognized"
  if (state === "cancelled") return ""
  return "Look at the camera"
}

if (typeof module !== "undefined") {
  module.exports = {
    knownState: knownState,
    isHideState: isHideState,
    scanTimeoutMs: scanTimeoutMs,
    signalPath: signalPath,
    parseSignal: parseSignal,
    parseShowPayload: parseShowPayload,
    isStaleSignal: isStaleSignal,
    isNewerSignal: isNewerSignal,
    shouldSuppress: shouldSuppress,
    resultHoldMs: resultHoldMs,
    hintFor: hintFor
  }
}
