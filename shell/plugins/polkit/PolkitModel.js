function promptLooksFingerprint(text) {
  var s = String(text || "").toLowerCase()
  return s.indexOf("finger") !== -1 || s.indexOf("fprint") !== -1 || s.indexOf("swipe") !== -1
}

var CHROME_BY_MODULE = {
  "pam_howdy.so": { method: "face", lidGated: true },
  "pam_fprintd.so": { method: "fingerprint", lidGated: true }
}

var CARD = {
  password: { glyph: "\uf023", hint: "Enter password", square: false },
  face: { glyph: "\uDB80\uDE08", hint: "Look at the camera", square: false },
  fingerprint: { glyph: "\uDB80\uDE37", hint: "", square: true }
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

if (typeof module !== "undefined") {
  module.exports = {
    promptLooksFingerprint: promptLooksFingerprint,
    pamStepsFromConfig: pamStepsFromConfig,
    cardModeFor: cardModeFor,
    glyphFor: glyphFor,
    hintFor: hintFor,
    cardIsSquare: cardIsSquare,
    fingerprintConfiguredFromPamConfig: fingerprintConfiguredFromPamConfig,
    authorizationLabel: authorizationLabel
  }
}
