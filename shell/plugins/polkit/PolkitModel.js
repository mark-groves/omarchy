function promptLooksFingerprint(text) {
  var s = String(text || "").toLowerCase()
  return s.indexOf("finger") !== -1 || s.indexOf("fprint") !== -1 || s.indexOf("swipe") !== -1
}

var CHROME_BY_MODULE = {
  "pam_howdy.so": { method: "face", lidGated: true },
  "pam_fprintd.so": { method: "fingerprint", lidGated: true }
}

// The kind a card plugin may declare. Discovery does not require it: the
// slot key in entryPoints is the declaration, so a plugin can also carry the
// service and panel kinds the plugin marketplace lists. Kept for manifests
// that declare it and for omarchy-plugin-validate.
var CHROME_KIND = "polkit-chrome"

var CARD = {
  password: { glyph: "\uf023", hint: "Enter password", square: false, slot: "" },
  face: { glyph: "\uDB80\uDE08", hint: "Look at the camera", square: false, slot: "polkitFace" },
  fingerprint: { glyph: "\uDB80\uDE37", hint: "", square: true, slot: "polkitFingerprint" }
}

function chromeForModule(line) {
  var module
  for (module in CHROME_BY_MODULE) {
    if (line.indexOf(module) !== -1) return CHROME_BY_MODULE[module]
  }
  return null
}

function isGateLine(line) {
  return line.indexOf("pam_exec.so") !== -1 && line.indexOf("omarchy-hw-laptop-closed") !== -1
}

// The Ask first gate omarchy-apply-face-pam writes: pam_exec hands the answer
// to the root-owned authtok-empty, which takes the face path only on an
// empty one. Its jump (default=N) skips the N auth lines of the face lane
// when the answer is a password.
var ASK_GATE_HELPER = "/usr/local/lib/omarchy-face/authtok-empty"

function isAskGateLine(line) {
  return line.indexOf("pam_exec.so") !== -1 && line.indexOf("expose_authtok") !== -1
    && line.indexOf(ASK_GATE_HELPER) !== -1
}

function askGateSpan(line) {
  var match = line.match(/\bdefault=(\d+)/)
  return match ? Number(match[1]) : Infinity
}

// Each chromed step, in stack order. trigger is what starts it: "ask" for a
// face step inside an Ask first gate's lane (an empty answer to the prompt),
// "auto" for one PAM runs before it prompts. lidGated: a closed lid stops the
// step, through a gate line or Howdy's own abort_if_lid_closed.
// `-auth` lines count: the face module is loaded that way so a missing module
// costs only the face path.
function pamStepsFromConfig(raw) {
  var steps = []
  var lines = String(raw || "").split("\n")
  var askLeft = 0
  var i
  for (i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (!line || line.charAt(0) === "#") continue
    if (!line.match(/^-?auth\s+/)) continue
    if (isAskGateLine(line)) {
      askLeft = askGateSpan(line)
      continue
    }
    // Every auth line counts toward the gate's jump, chromed or not.
    var asked = askLeft > 0
    if (askLeft > 0) askLeft -= 1
    if (isGateLine(line)) continue
    var chrome = chromeForModule(line)
    if (!chrome) continue
    steps.push({
      method: chrome.method,
      trigger: asked && chrome.method === "face" ? "ask" : "auto",
      lidGated: chrome.lidGated
    })
  }
  return steps
}

function stepRuns(step, laptopClosed) {
  return !!step && !(step.lidGated && laptopClosed)
}

// What the card shows while PAM works with no prompt up. An Ask first face
// step never runs then: it waits for an empty answer, so the gap before the
// prompt is not a face scan.
function cardModeFor(steps, waitingOnPam, laptopClosed) {
  if (!waitingOnPam) return { kind: "password" }
  if (!steps) return { kind: "password" }
  var i
  for (i = 0; i < steps.length; i++) {
    var step = steps[i]
    if (!stepRuns(step, laptopClosed)) continue
    if (step.trigger === "ask") continue
    if (step.method === "face" || step.method === "fingerprint") {
      return { kind: step.method }
    }
  }
  return { kind: "password" }
}

function cardSpec(kind) {
  return CARD[kind] || CARD.password
}

function glyphFor(kind) {
  return cardSpec(kind).glyph
}

function hintFor(kind) {
  return cardSpec(kind).hint
}

function cardIsSquare(kind) {
  return !!cardSpec(kind).square
}

function chromeSlotKeyFor(kind) {
  return cardSpec(kind).slot || ""
}

function chromeSlotKeys() {
  var keys = []
  var kind
  for (kind in CARD) {
    var slot = CARD[kind].slot
    if (slot && keys.indexOf(slot) === -1) keys.push(slot)
  }
  keys.sort()
  return keys
}

// The biometric this request's card is dressed for, whatever starts it.
function chromeKindFor(steps, laptopClosed) {
  if (!steps) return "password"
  var i
  for (i = 0; i < steps.length; i++) {
    var step = steps[i]
    if (!stepRuns(step, laptopClosed)) continue
    if (step.method === "face" || step.method === "fingerprint") return step.method
  }
  return "password"
}

// Which face lane the card carries: "ask", "auto", or "none" when the first
// runnable chromed step is not face (fingerprint keeps its own card) or the
// lid is shut.
function faceLaneTriggerFor(steps, laptopClosed) {
  if (!steps) return "none"
  var i
  for (i = 0; i < steps.length; i++) {
    var step = steps[i]
    if (!stepRuns(step, laptopClosed)) continue
    if (step.method === "face") return step.trigger === "ask" ? "ask" : "auto"
    if (step.method === "fingerprint") return "none"
  }
  return "none"
}

function failedUrlsFor(source) {
  if (!source || !source.failedUrls) return null
  if ((source.failedRevision || 0) !== (source.revision || 0)) return null
  return source.failedUrls
}

function resolveChromeSlot(kind, source) {
  var key = chromeSlotKeyFor(kind)
  if (!key) return null
  if (!source || !source.registry) return null
  var registry = source.registry
  var plugins = registry.installedPlugins
  if (!plugins) return null
  var failedUrls = failedUrlsFor(source)

  var eligible = []
  var id
  for (id in plugins) {
    var manifest = plugins[id]
    if (!manifest || typeof manifest !== "object") continue
    if (manifest.__isFirstParty) continue
    if (!manifest.entryPoints || typeof manifest.entryPoints[key] !== "string" || !manifest.entryPoints[key]) continue
    if (typeof registry.isEnabled !== "function" || !registry.isEnabled(id)) continue
    var url = typeof registry.entryPointUrl === "function" ? registry.entryPointUrl(manifest, key) : ""
    if (!url) continue
    if (failedUrls && failedUrls[url]) continue
    eligible.push({ id: id, url: url })
  }
  if (!eligible.length) return null

  eligible.sort(function(a, b) {
    if (a.id < b.id) return -1
    if (a.id > b.id) return 1
    return 0
  })

  var shadowed = []
  var i
  for (i = 1; i < eligible.length; i++) shadowed.push(eligible[i].id)

  return {
    pluginId: eligible[0].id,
    entryPointKey: key,
    url: eligible[0].url,
    revision: source.revision || 0,
    shadowed: shadowed
  }
}

function cardPresentationFor(steps, waitingOnPam, laptopClosed, source) {
  var kind = cardModeFor(steps, waitingOnPam, laptopClosed).kind
  var chromeKind = chromeKindFor(steps, laptopClosed)
  var spec = cardSpec(kind)
  var chromeSpec = cardSpec(chromeKind)
  var slot = resolveChromeSlot(chromeKind, source)
  return {
    kind: kind,
    chromeKind: chromeKind,
    glyph: spec.glyph,
    hint: spec.hint,
    square: slot ? !!chromeSpec.square : !!spec.square,
    slot: slot
  }
}

function chromeSlotDiagnostic(presentation) {
  if (!presentation || !presentation.slot) return ""
  var slot = presentation.slot
  var painted = presentation.chromeKind || presentation.kind
  var line = "polkit chrome: " + painted + " painted by " + slot.pluginId
  if (slot.shadowed && slot.shadowed.length) line += "; ignoring " + slot.shadowed.join(", ")
  return line
}

function fingerprintConfiguredFromPamConfig(raw) {
  var steps = pamStepsFromConfig(raw)
  var i
  for (i = 0; i < steps.length; i++) {
    if (steps[i].method === "fingerprint") return true
  }
  return false
}

function authorizationLabel(message, tr) {
  var t = typeof tr === "function" ? tr : function(key, english) { return english }
  var text = String(message || "")
  var match = text.match(/^Authentication is (?:needed|required) to run [`']([^`']+)[`'] as /i)
  return match ? t("polkit.authorizeRunning", "Authorize running '%1'").replace("%1", match[1]) : text
}

// FaceChrome.sourceUrl is shared with lock and is set whenever a face plugin
// is installed. It is not "this polkit request is a face scan": only this
// request's resolved polkitFace slot says a face card is expected.
function faceSlotResolved(presentation) {
  return !!(presentation && presentation.slot && presentation.slot.entryPointKey === "polkitFace")
}

// ---------------------------------------------------------------- face lane
//
// One request's face lane as a pure reducer. faceLaneStep(lane, event, env)
// returns a new lane and never changes the one it is given. The card binds to
// the lane; the agent turns flow signals and card callbacks into events and
// runs the effects a change asks for (the shake, the scan-wait ceiling, the
// exit fade). The lane is display state only: PAM decides, the lane shows.
//
// trigger, from the stack when the request opens:
//   "ask"  Ask first: an empty answer to the prompt starts the scan, so the
//          scan shows from the user's Enter, and a failed session during it
//          is the miss. A new session's prompt is never a miss.
//   "auto" Automatic: PAM scans before it prompts, so the prompt is the miss.
//   "none" No face lane: a password or fingerprint card, or the lid is shut,
//          where an empty Enter is an ordinary password answer.
//
// env, read by the agent at each dispatch:
//   locked         the session lock covers the card, so no result plays
//   ready          a face chrome module is loaded
//   scanMs         how much scan to present before a match may replace it
//   recognized,    FacePlayback.playbackAction for that result:
//   notRecognized  "play" | "wait" | "immediate"
//
// Events: open, hint, info, error, prompt, submitEmpty, submitTyped,
// succeeded, failed, cancelled, ended (the flow is gone), scanShown (also the
// wall-clock ceiling on that wait), resultPlayed, chrome (the face module
// changed), locked, unlocked, closed (the exit fade finished).

function faceLaneInitial() {
  return {
    phase: "closed",      // "closed" | "open" | "closing"
    trigger: "none",
    prompt: false,        // PAM is waiting for an answer
    pending: "",          // "" | "face" | "password": an answer PAM has not judged
    attempt: false,       // a face scan is running in PAM
    faceState: "idle",    // "idle" | "scanning" | "recognized" | "notRecognized"
    epoch: 0,             // bumped whenever the face card starts a new cycle
    scanSeen: false,      // the card has presented env.scanMs of this scan
    pendingMatch: false,  // a match waits for the scan to have shown
    hold: "",             // "" | "recognized" | "notRecognized": a result playing
    retry: false,         // the field is back after a face miss
    wrong: 0,             // typed answers PAM refused (each one shakes the field)
    hinted: false,        // PAM offered face in this request
    outcome: "",          // "" | "succeeded" | "cancelled" | "ended"
    reason: ""            // PAM's error text during the last attempt
  }
}

function copyLane(lane) {
  var next = faceLaneInitial()
  var key
  if (!lane) return next
  for (key in next) {
    if (lane[key] !== undefined) next[key] = lane[key]
  }
  return next
}

function sameLane(a, b) {
  if (a === b) return true
  if (!a || !b) return false
  var key
  for (key in faceLaneInitial()) {
    if (a[key] !== b[key]) return false
  }
  return true
}

function laneEnv(env) {
  var e = env || {}
  var scanMs = Number(e.scanMs)
  return {
    locked: !!e.locked,
    ready: !!e.ready,
    scanMs: isFinite(scanMs) && scanMs > 0 ? scanMs : 0,
    recognized: e.recognized === "play" || e.recognized === "wait" ? e.recognized : "immediate",
    notRecognized: e.notRecognized === "play" || e.notRecognized === "wait" ? e.notRecognized : "immediate"
  }
}

function isAskHint(text) {
  return /\buse your face\b/i.test(String(text || ""))
}

function startScan(next) {
  next.attempt = true
  next.faceState = "scanning"
  next.epoch += 1
  next.scanSeen = false
  next.pendingMatch = false
  next.hold = ""
  next.retry = false
  next.reason = ""
}

function backToField(next) {
  next.hold = ""
  next.faceState = "idle"
  next.retry = next.trigger === "ask"
}

function playMatch(next, env) {
  next.pendingMatch = false
  if (env.locked || env.recognized === "immediate") {
    next.hold = ""
    next.phase = "closing"
    return
  }
  next.hold = "recognized"
  next.faceState = "recognized"
  next.epoch += 1
}

function playMiss(next, env) {
  next.attempt = false
  next.pendingMatch = false
  if (env.locked || env.notRecognized === "immediate") {
    backToField(next)
    return
  }
  next.hold = "notRecognized"
  next.faceState = "notRecognized"
  next.epoch += 1
}

function closeLane(next) {
  next.attempt = false
  next.pendingMatch = false
  next.hold = ""
  next.prompt = false
  next.pending = ""
  next.phase = "closing"
}

// Whether an empty Enter may be sent now. Automatic stacks never send one:
// there it would reach pam_unix as an empty password and cost a strike.
function faceLaneAcceptsEmpty(lane) {
  return !!lane && lane.phase === "open" && !!lane.prompt && lane.pending === ""
    && lane.outcome === "" && lane.trigger !== "auto"
}

// Whether the card should hold the keyboard. Once PAM has approved or the
// card is leaving, what remains is display only.
function faceLaneWantsKeyboard(lane) {
  return !!lane && lane.outcome === "" && lane.phase !== "closing"
}

function faceLaneStep(lane, event, env) {
  var type = event && event.type ? String(event.type) : ""
  var e = laneEnv(env)
  var next = copyLane(lane)

  if (type === "open") {
    next = faceLaneInitial()
    next.epoch = (lane && lane.epoch > 0 ? lane.epoch : 0) + 1
    next.phase = "open"
    next.trigger = event.trigger === "ask" || event.trigger === "auto" ? event.trigger : "none"
    next.prompt = !!event.prompt
    // Automatic stacks scan as soon as PAM starts, before any prompt.
    if (next.trigger === "auto" && !next.prompt) startScan(next)
    return next
  }

  if (type === "closed") {
    if (next.phase === "closed") return next
    closeLane(next)
    next.phase = "closed"
    next.faceState = "idle"
    return next
  }

  if (next.phase !== "open") return next

  switch (type) {
  case "hint":
    next.hinted = true
    break

  case "info":
    if (isAskHint(event.text)) next.hinted = true
    break

  case "error":
    if (next.attempt) next.reason = String(event.text || "")
    break

  case "prompt":
    next.prompt = true
    next.pending = ""
    // Automatic: PAM moved on to the password, which is the miss. On an Ask
    // first stack a prompt only means the next session is ready.
    if (next.trigger === "auto" && next.attempt) playMiss(next, e)
    break

  case "submitEmpty":
    if (!faceLaneAcceptsEmpty(next)) break
    next.prompt = false
    if (next.trigger === "ask") {
      startScan(next)
      next.pending = "face"
    } else {
      next.pending = "password"
    }
    break

  case "submitTyped":
    if (!next.prompt || next.pending !== "" || next.outcome !== "") break
    next.prompt = false
    next.pending = "password"
    // A password typed over a miss ends it.
    if (next.hold === "notRecognized") backToField(next)
    next.retry = false
    break

  case "succeeded":
    if (next.outcome === "succeeded") break
    var faceLive = next.attempt
    next.outcome = "succeeded"
    next.prompt = false
    next.pending = ""
    next.attempt = false
    if (faceLive && !e.locked) {
      // Howdy often matches before the card has drawn its scan. PAM has
      // approved; the match waits, display only, for the scan to show.
      if (!next.scanSeen && e.scanMs > 0) next.pendingMatch = true
      else playMatch(next, e)
    } else {
      next.hold = ""
      next.phase = "closing"
    }
    break

  case "failed":
    next.prompt = false
    if (next.pending === "face" || (next.attempt && next.pending === "")) {
      // The scan ended without a match: not recognized, not a wrong password.
      next.pending = ""
      playMiss(next, e)
    } else {
      next.pending = ""
      next.wrong += 1
      if (next.hold === "notRecognized") backToField(next)
      next.retry = false
      // Automatic: the new session scans again before it prompts.
      if (next.trigger === "auto") startScan(next)
    }
    break

  case "cancelled":
    if (next.outcome === "") next.outcome = "cancelled"
    closeLane(next)
    break

  case "ended":
    // A match still plays once the flow is gone: PAM approved already.
    if (next.outcome === "succeeded") break
    if (next.outcome === "") next.outcome = "ended"
    closeLane(next)
    break

  case "scanShown":
    next.scanSeen = true
    if (next.pendingMatch) playMatch(next, e)
    break

  case "resultPlayed":
    if (next.hold === "recognized") {
      next.hold = ""
      next.phase = "closing"
    } else if (next.hold === "notRecognized") {
      backToField(next)
    }
    break

  case "chrome":
    // The face module went away or failed: nothing will finish the scan or
    // the hold on screen, so they end here.
    if (next.pendingMatch && !e.ready) {
      next.scanSeen = true
      playMatch(next, e)
    } else if (next.hold === "recognized" && e.recognized === "immediate") {
      next.hold = ""
      next.phase = "closing"
    } else if (next.hold === "notRecognized" && e.notRecognized === "immediate") {
      backToField(next)
    }
    break

  case "locked":
    // A result cannot play under the lock. PAM's answer stands; a match
    // closes the card rather than coming back at unlock.
    if (next.pendingMatch || next.hold === "recognized") {
      next.pendingMatch = false
      next.hold = ""
      next.phase = "closing"
    } else if (next.hold === "notRecognized") {
      backToField(next)
    }
    break

  case "unlocked":
    // A scan still running starts its card over, so it plays from frames
    // the user sees.
    if (next.attempt) {
      next.faceState = "scanning"
      next.epoch += 1
      next.scanSeen = false
    }
    break
  }
  return next
}

// The caption keys for the face card's two fixed slots. The card maps each
// key to a catalog string; "" leaves the slot empty but keeps its height.
function faceLaneCaptions(lane) {
  var l = lane || {}
  if (l.trigger !== "ask" && l.trigger !== "auto") return { primary: "", secondary: "", error: false }
  if (l.faceState === "scanning") return { primary: "look", secondary: "escCancels", error: false }
  if (l.faceState === "recognized") return { primary: "recognized", secondary: "", error: false }
  if (l.faceState === "notRecognized") return { primary: "notRecognized", secondary: "typePassword", error: true }
  if (l.trigger === "auto") return { primary: "typePassword", secondary: "", error: false }
  return { primary: l.retry ? "retry" : "offer", secondary: "orType", error: false }
}

// The state a face-probe-event line reports.
function faceLaneProbeState(lane) {
  var l = lane || {}
  if (l.phase === "closed" || !l.phase) return "hidden"
  if (l.phase === "closing") return "closing"
  if (l.trigger !== "ask" && l.trigger !== "auto") return "password"
  return l.faceState || "idle"
}

// The session lock covers every other surface. A polkit card opened under it
// is what shows up as a stray "authenticating" card the moment the lock drops.
function polkitCardVisible(dialogVisible, sessionLocked, resolvedUnderLock) {
  return !!dialogVisible && !sessionLocked && !resolvedUnderLock
}

// A result that lands while the card cannot be seen must not arm a hold.
// PAM has already decided, and playing it after unlock is a card for a
// request the user never had in front of them.
function shouldArmFaceHold(sessionLocked) {
  return !sessionLocked
}

// The request is still in progress when the lock lifts. Restart the card so
// the scan and the result each play from a presented frame, not from ticks
// that ran underneath the lock.
function shouldRestartFaceOnUnlock(sessionLocked, agentActive, resolvedUnderLock) {
  return !sessionLocked && !!agentActive && !resolvedUnderLock
}

// On an Ask first stack an empty answer starts a face scan, so an Enter that
// was not aimed at the card must not send one: a key still held or repeating
// from the terminal or launcher that raised the prompt, or one pressed in the
// instant the card appears. An empty answer counts only once the field has
// had focus for the current prompt this long, and never from autorepeat.
// armedAtMs is 0 until the field has taken focus for the prompt.
var EMPTY_SUBMIT_ARM_MS = 600

function emptySubmitArmed(armedAtMs, nowMs, isAutoRepeat) {
  if (isAutoRepeat || !(armedAtMs > 0)) return false
  return nowMs - armedAtMs >= EMPTY_SUBMIT_ARM_MS
}

if (typeof module !== "undefined") {
  module.exports = {
    promptLooksFingerprint: promptLooksFingerprint,
    pamStepsFromConfig: pamStepsFromConfig,
    cardModeFor: cardModeFor,
    chromeSlotKeyFor: chromeSlotKeyFor,
    chromeSlotKeys: chromeSlotKeys,
    chromeKindFor: chromeKindFor,
    failedUrlsFor: failedUrlsFor,
    resolveChromeSlot: resolveChromeSlot,
    cardPresentationFor: cardPresentationFor,
    chromeSlotDiagnostic: chromeSlotDiagnostic,
    CHROME_KIND: CHROME_KIND,
    glyphFor: glyphFor,
    hintFor: hintFor,
    cardIsSquare: cardIsSquare,
    fingerprintConfiguredFromPamConfig: fingerprintConfiguredFromPamConfig,
    authorizationLabel: authorizationLabel,
    faceSlotResolved: faceSlotResolved,
    isAskGateLine: isAskGateLine,
    faceLaneTriggerFor: faceLaneTriggerFor,
    faceLaneInitial: faceLaneInitial,
    faceLaneStep: faceLaneStep,
    sameLane: sameLane,
    faceLaneAcceptsEmpty: faceLaneAcceptsEmpty,
    faceLaneWantsKeyboard: faceLaneWantsKeyboard,
    faceLaneCaptions: faceLaneCaptions,
    faceLaneProbeState: faceLaneProbeState,
    isAskHint: isAskHint,
    polkitCardVisible: polkitCardVisible,
    shouldArmFaceHold: shouldArmFaceHold,
    shouldRestartFaceOnUnlock: shouldRestartFaceOnUnlock,
    emptySubmitArmed: emptySubmitArmed
  }
}
