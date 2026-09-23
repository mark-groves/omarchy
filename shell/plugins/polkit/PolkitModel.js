function promptLooksFingerprint(text) {
  var s = String(text || "").toLowerCase()
  return s.indexOf("finger") !== -1 || s.indexOf("fprint") !== -1 || s.indexOf("swipe") !== -1
}

var CHROME_BY_MODULE = {
  "pam_howdy.so": { method: "face", lidGated: true },
  "pam_fprintd.so": { method: "fingerprint", lidGated: true }
}

var CHROME_KIND = "polkit-chrome"

var CARD = {
  password: { glyph: "\uf023", hint: "Enter password", square: false, slot: "", extraSpace: 0 },
  face: { glyph: "\uDB80\uDE08", hint: "Look at the camera", square: false, slot: "polkitFace", extraSpace: 150 },
  fingerprint: { glyph: "\uDB80\uDE37", hint: "", square: true, slot: "polkitFingerprint", extraSpace: 0 }
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

function pamStepsFromConfig(raw) {
  var steps = []
  var lines = String(raw || "").split("\n")
  var i
  for (i = 0; i < lines.length; i++) {
    var line = lines[i].replace(/^\s+|\s+$/g, "")
    if (!line || line.charAt(0) === "#") continue
    if (!line.match(/^auth\s+/)) continue
    if (isGateLine(line)) continue
    var chrome = chromeForModule(line)
    if (!chrome) continue
    steps.push({ method: chrome.method, lidGated: chrome.lidGated })
  }
  return steps
}

function cardModeFor(steps, waitingOnPam, laptopClosed) {
  if (!waitingOnPam) return { kind: "password" }
  if (!steps) return { kind: "password" }
  var i
  for (i = 0; i < steps.length; i++) {
    var step = steps[i]
    if (!step || (step.lidGated && laptopClosed)) continue
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

function chromeKindFor(steps, laptopClosed) {
  return cardModeFor(steps, true, laptopClosed).kind
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
    if (!Array.isArray(manifest.kinds) || manifest.kinds.indexOf(CHROME_KIND) === -1) continue
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
    chromeGlyph: chromeSpec.glyph,
    chromeHint: chromeSpec.hint,
    square: slot ? !!chromeSpec.square : !!spec.square,
    extraSpace: slot ? chromeSpec.extraSpace : 0,
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

function authorizationLabel(message) {
  var text = String(message || "")
  var match = text.match(/^Authentication is (?:needed|required) to run [`']([^`']+)[`'] as /i)
  return match ? "Authorize running '" + match[1] + "'" : text
}

// FaceChrome.sourceUrl is shared with lock and is set whenever a face plugin
// is installed. It is not "this polkit request is a face scan".
function isFaceAuthRequest(presentation) {
  return !!(presentation && presentation.chromeKind === "face")
}

function faceSlotResolved(presentation) {
  return !!(presentation && presentation.slot && presentation.slot.entryPointKey === "polkitFace")
}

function shouldNoteFaceMiss(presentation, faceState) {
  return isFaceAuthRequest(presentation) && faceState === "scanning"
}

function shouldHoldFaceSuccess(presentation) {
  return isFaceAuthRequest(presentation) && !!presentation && presentation.kind === "face"
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
function shouldRestartFaceOnUnlock(wasLocked, sessionLocked, agentActive, resolvedUnderLock) {
  return !!wasLocked && !sessionLocked && !!agentActive && !resolvedUnderLock
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
    isFaceAuthRequest: isFaceAuthRequest,
    faceSlotResolved: faceSlotResolved,
    shouldNoteFaceMiss: shouldNoteFaceMiss,
    shouldHoldFaceSuccess: shouldHoldFaceSuccess,
    polkitCardVisible: polkitCardVisible,
    shouldArmFaceHold: shouldArmFaceHold,
    shouldRestartFaceOnUnlock: shouldRestartFaceOnUnlock
  }
}
