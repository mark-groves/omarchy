import QtQuick
import qs.Commons
import "../../Commons/FacePlayback.js" as Playback

// The face lane of the lock preview window (`lock previewFace`), for
// recording the card without a face. It walks the preview's LockView through
// what the lock does on a face request: the scan, a match or a miss, the
// result hold and, after a match, the fade before unlock; then it returns to
// idle. Timers stand in for PAM. Display only: it has no PAM context and no
// way to the session lock, and the lock service binds only the preview
// window to it.
Item {
  id: root

  // How long the lock's content fades before a face unlock.
  property int unlockFadeMs: 150
  // Idle on screen before the pretend request, so a recording has both.
  readonly property int leadMs: 600
  // Pretend time from the request to the verdict when none is given: a match
  // that beats the card's boot, one as slow as the slowest scans measured on
  // the lock, and a miss that runs out Howdy's timeout.
  readonly property var defaultScanMs: ({ "match": 400, "match-slow": 2300, "miss": 4300 })

  // The preview shows the face lane instead of the bare scan loop.
  property bool driven: false
  // The scenario still running; "" once it is back at idle.
  property string scenario: ""
  property int scanMs: 0

  // The lock service's own names for the same steps.
  property bool faceRequested: false
  property string faceState: "scanning"
  property int facePlaybackEpoch: 0
  property bool faceAuthenticating: false
  property bool faceHolding: false
  property bool facePendingMatch: false
  property bool faceScanSeen: false
  property bool faceUnlocking: false
  readonly property bool faceCardActive: faceRequested || faceHolding || facePendingMatch

  function log(step) {
    console.log("omarchy lock " + new Date().toISOString() + " preview-face " + step)
  }

  // "ok", or why the scenario cannot run.
  function run(name, scan) {
    var ms = 0
    if (name !== "idle") {
      if (!defaultScanMs.hasOwnProperty(name)) return "unknown scenario " + name + ": match, miss, match-slow or idle"
      ms = String(scan) === "" ? defaultScanMs[name] : Number(scan)
      if (!isFinite(ms) || ms < 0 || ms > 20000 || Math.floor(ms) !== ms) return "scanMs must be whole milliseconds from 0 to 20000"
    }
    reset()
    driven = true
    log("run " + name + (name === "idle" ? "" : " scan=" + ms + "ms"))
    if (name === "idle") return "ok"
    scenario = name
    scanMs = ms
    leadTimer.restart()
    return "ok"
  }

  // Back to the bare preview.
  function stop() {
    reset()
    driven = false
  }

  function reset() {
    leadTimer.stop()
    verdictTimer.stop()
    matchWait.stop()
    resultCeiling.stop()
    unlockFade.stop()
    scenario = ""
    faceAuthenticating = false
    facePendingMatch = false
    faceHolding = false
    faceRequested = false
    faceUnlocking = false
    faceScanSeen = false
  }

  // The face button, Space or Enter on an empty field.
  function request() {
    faceRequested = true
    faceScanSeen = false
    faceState = "scanning"
    // A fresh cycle, so the card boots and sweeps from the start.
    facePlaybackEpoch += 1
    faceAuthenticating = true
    log("request")
    verdictTimer.interval = Math.max(1, scanMs)
    verdictTimer.restart()
  }

  function verdict() {
    faceAuthenticating = false
    log("verdict " + (scenario === "miss" ? "miss" : "match"))
    if (scenario === "miss") {
      if (!hold("notRecognized")) finish()
      return
    }
    // As on the lock, a match that beats the scan waits for it to have
    // played, or for a wall-clock ceiling.
    var scan = FaceChrome.ready ? FaceChrome.scanMs() : 0
    if (!faceScanSeen && scan > 0) {
      facePendingMatch = true
      matchWait.interval = scan + 1500
      matchWait.restart()
      return
    }
    playMatch()
  }

  function playMatch() {
    facePendingMatch = false
    matchWait.stop()
    if (!hold("recognized")) beginUnlock()
  }

  function scanShown() {
    if (!driven) return
    faceScanSeen = true
    if (facePendingMatch) playMatch()
  }

  // True when the card plays the result before the lane moves on.
  function hold(result) {
    var holdMs = FaceChrome.holdMs(result)
    var action = Playback.playbackAction(result, FaceChrome.ready, holdMs, FaceChrome.sourceUrl !== "", FaceChrome.failure !== "")
    faceState = result
    faceScanSeen = false
    if (action === "immediate") {
      faceHolding = false
      return false
    }
    // The lock bounds only a recognized hold. Here both are bounded, so a
    // card that never presents cannot strand the preview.
    resultCeiling.interval = Math.max(1, Playback.presentedCeilingMs(holdMs) || 3000)
    resultCeiling.restart()
    faceHolding = true
    facePlaybackEpoch += 1
    log("hold " + result)
    return true
  }

  function resultPlayed() {
    resultCeiling.stop()
    if (!driven || !faceHolding || faceUnlocking) return
    log("played " + faceState)
    if (faceState === "recognized") beginUnlock()
    else finish()
  }

  function beginUnlock() {
    var fadeMs = Style.duration(unlockFadeMs)
    if (fadeMs <= 0) {
      finish()
      return
    }
    faceUnlocking = true
    log("unlock-fade")
    unlockFade.interval = fadeMs
    unlockFade.restart()
  }

  // Back at idle, as a miss on request hands back to the face button. After
  // a match the real lock would be gone by now; the preview drops the card
  // while its content is still faded out, then brings the idle lock back.
  function finish() {
    faceHolding = false
    faceRequested = false
    faceUnlocking = false
    scenario = ""
    log("idle")
  }

  Timer {
    id: leadTimer
    interval: root.leadMs
    repeat: false
    onTriggered: root.request()
  }

  Timer {
    id: verdictTimer
    interval: 400
    repeat: false
    onTriggered: root.verdict()
  }

  Timer {
    id: matchWait
    interval: 2120
    repeat: false
    onTriggered: if (root.facePendingMatch) root.playMatch()
  }

  Timer {
    id: resultCeiling
    interval: 3000
    repeat: false
    onTriggered: root.resultPlayed()
  }

  Timer {
    id: unlockFade
    interval: 150
    repeat: false
    onTriggered: if (root.faceUnlocking) root.finish()
  }
}
