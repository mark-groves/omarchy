// Face result timing.
//
// Recognized and not-recognized are drawn by the card. A QML Timer counts
// wall time, including while the panel is blank and while the frame clock is
// still stopped after wake, so the hold can end before a result frame is
// presented. Count presented frames only. Cap each one: the first callback
// after wake reports the whole gap since the previous frame, and that gap
// must not finish the hold.

var maxPresentedStepMs = 50

function presentedStepMs(frameTimeSeconds) {
  var ms = Number(frameTimeSeconds) * 1000
  if (!isFinite(ms) || ms <= 0) return 0
  return Math.min(ms, maxPresentedStepMs)
}

// `presenting` is false while the canvas is inactive, hidden, or not yet
// painting. Elapsed stays put, so a frozen wake cannot spend the hold.
function advancePresented(elapsedMs, frameTimeSeconds, presenting) {
  var elapsed = Number(elapsedMs)
  if (!isFinite(elapsed) || elapsed < 0) elapsed = 0
  if (!presenting) return elapsed
  return elapsed + presentedStepMs(frameTimeSeconds)
}

// A FrameAnimation tick is not a presented frame. After resume Qt's animation
// driver keeps ticking on its internal timer while the lock surface is not
// swapping buffers, and those ticks finish a 1050 ms hold on a frozen card.
// Credit only the gap between frameSwapped signals. A gap longer than one
// frame is the surface catching up, not time the user saw.
function presentedSwapMs(gapMs) {
  var ms = Number(gapMs)
  if (!isFinite(ms) || ms <= 0 || ms > maxPresentedStepMs) return 0
  return ms
}

function creditSwap(elapsedMs, gapMs, presenting) {
  var elapsed = Number(elapsedMs)
  if (!isFinite(elapsed) || elapsed < 0) elapsed = 0
  if (!presenting) return elapsed
  return elapsed + presentedSwapMs(gapMs)
}

function isHeldState(state) {
  return state === "recognized" || state === "notRecognized"
}

// "play" when the plugin hold can run on the canvas.
// "wait" when chrome is expected and has neither loaded nor failed, so the
// surface does not start a clock before the first frame exists.
// "immediate" when there is nothing to show, including a module that has
// already been rejected. The PAM result stays as it was.
function playbackAction(state, pluginReady, pluginHoldMs, chromeExpected, chromeFailed) {
  if (!isHeldState(state)) return "immediate"
  if (!pluginReady) {
    if (chromeFailed) return "immediate"
    return chromeExpected ? "wait" : "immediate"
  }
  var ms = Number(pluginHoldMs)
  if (!isFinite(ms) || ms <= 0) return "immediate"
  return "play"
}

function resultComplete(state, elapsedMs, holdMs) {
  if (!isHeldState(state)) return false
  var hold = Number(holdMs)
  var elapsed = Number(elapsedMs)
  if (!isFinite(hold) || hold <= 0) return false
  if (!isFinite(elapsed)) return false
  return elapsed >= hold
}

if (typeof module !== "undefined") {
  module.exports = {
    maxPresentedStepMs: maxPresentedStepMs,
    presentedStepMs: presentedStepMs,
    advancePresented: advancePresented,
    presentedSwapMs: presentedSwapMs,
    creditSwap: creditSwap,
    isHeldState: isHeldState,
    playbackAction: playbackAction,
    resultComplete: resultComplete
  }
}
