#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')
const viewQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockView.qml'), 'utf8')
const applyLock = fs.readFileSync(path.join(root, 'bin/omarchy-apply-lock'), 'utf8')

assert(
  /config:\s*"omarchy-lock-face"/.test(serviceQml),
  'lock starts a third PamContext on omarchy-lock-face'
)

assert(
  !/omarchy-lock-password[\s\S]*pam_howdy/.test(applyLock),
  'apply-lock does not put Howdy inside the password PAM heredoc'
)

assert(
  /omarchy-hw-laptop-closed/.test(serviceQml),
  'lock face asks omarchy-hw-laptop-closed before opening the camera'
)

assert(
  /if \([^)]*laptopClosed[^)]*displaysBlank[^)]*\) return/.test(serviceQml) ||
    /if \(laptopClosed \|\| displaysBlank\) return/.test(serviceQml),
  'lock face does not start while the lid is closed or the panel is blank'
)

assert(
  /id:\s*faceRetryTimer[\s\S]*?interval:\s*2000/.test(serviceQml),
  'lock face retries every 2000 ms, not the 250 ms fingerprint loop'
)

assert(
  /if \(root\.lockRequested && !root\.authenticatingPassword && !root\.faceAuthenticating && !root\.faceHolding\) root\.runBlank\(\)/.test(serviceQml),
  'a password, face check, or face hold in flight stops the blank timer'
)

assert(
  /onFaceAuthenticatingChanged/.test(serviceQml) &&
    /if \(faceAuthenticating\) idleBlankTimer\.stop\(\)/.test(serviceQml),
  'face authentication holds the idle blank timer'
)

const blankHandler = serviceQml.match(/onDisplaysBlankChanged:\s*\{[\s\S]*?\n  \}/)
assert(blankHandler, 'lock has an onDisplaysBlankChanged handler')
assert(
  !/facePam\.abort\(\)/.test(blankHandler[0]),
  'blanking the panel does not abort an in-flight Howdy scan'
)
assert(
  !/faceAuthenticating\s*=\s*false/.test(blankHandler[0]),
  'blanking the panel does not clear faceAuthenticating'
)

const lidHandler = serviceQml.match(/id:\s*laptopClosedProc[\s\S]*?onExited:\s*\{[\s\S]*?\n    \}/)
assert(lidHandler, 'lock has a laptopClosedProc onExited handler')
assert(
  /wasClosed/.test(lidHandler[0]) && /else if \(wasClosed && root\.lockRequested && root\.faceConfigured\)/.test(lidHandler[0]),
  'an already-open lid poll does not start a new Howdy scan'
)
assert(
  !/else if \(root\.lockRequested && root\.faceConfigured\) \{\s*root\.startFace\(\)/.test(lidHandler[0]),
  'lid poll no longer starts face on every open reading'
)

assert(
  /faceConfigured/.test(viewQml) && /objectName:\s*"faceIndicator"/.test(viewQml),
  'the lock field shows a face glyph when face is configured'
)

// The shared face card on lock. Before this, a scan and a miss were both
// silent: nothing face-related was bound into the view at all.

assert(
  /property string faceState/.test(serviceQml) && /faceState:\s*root\.faceState/.test(serviceQml),
  'the lock service tells the view what the face scan is doing'
)
assert(
  /faceState = "scanning"/.test(serviceQml),
  'starting a scan puts the card in the scanning state'
)
assert(
  /holdFaceResult\("notRecognized"\)/.test(serviceQml),
  'a miss is shown rather than being silent'
)

const faceFinished = serviceQml.match(/function handleFaceFinished\([\s\S]*?\n  \}/)
assert(faceFinished, 'lock has a handleFaceFinished')
assert(
  /holdFaceResult\("recognized"\)/.test(faceFinished[0]),
  'a match holds the recognised frame for as long as the plugin declares'
)
assert(
  /if \(hold > 0\)[\s\S]*?faceHoldTimer\.restart\(\)[\s\S]*?\n      \}\n      finishUnlock\(\)/.test(faceFinished[0]),
  'with no chrome installed a match still unlocks immediately'
)
assert(
  /id: faceHoldTimer[\s\S]{0,240}?root\.finishUnlock\(\)/.test(serviceQml),
  'the hold always ends in an unlock'
)
assert(
  /holdFaceResult\("notRecognized"\)/.test(faceFinished[0]),
  'a miss holds the not-recognised frame for as long as the plugin declares'
)
assert(
  /faceScanning:\s*root\.faceAuthenticating \|\| root\.faceHolding/.test(serviceQml),
  'the lock canvas keeps animating while a result is held'
)
assert(
  /if \(faceHoldTimer\.running\) return/.test(serviceQml),
  'a new scan does not cancel a recognised hold that is already unlocking'
)

const teardown = serviceQml.match(/fingerprintRetryTimer\.stop\(\)[\s\S]{0,280}/)
assert(
  teardown && /faceHoldTimer\.stop\(\)/.test(teardown[0]) && /faceMissHoldTimer\.stop\(\)/.test(teardown[0]),
  'tearing the lock down never leaves an unlock waiting on a display hold'
)

assert(
  /property var pluginRegistry/.test(serviceQml),
  'lock declares pluginRegistry so ensureService injects the real registry'
)
assert(
  /FaceChrome\.pluginRegistry\s*=\s*pluginRegistry/.test(serviceQml),
  'lock points the shared chrome loader at the registry, not at a polkit slot'
)
assert(
  /FaceChromeCanvas/.test(viewQml) && /objectName:\s*"faceCardIndicator"/.test(viewQml),
  'lock paints the shared card above the password field'
)
assert(
  /width:\s*Style\.space\(116\)/.test(viewQml),
  'the lock card is the 116 px mesh size, not the 26 px in-field glyph slot'
)
assert(
  /Look at the camera/.test(viewQml) && /or type your password/.test(viewQml),
  'the lock card keeps the scan hint and the password fallback'
)
assert(
  /id: faceIcon[\s\S]*?visible:[^\n]*!root\.faceCardPainting/.test(viewQml),
  'the static glyph yields to the card rather than drawing under it'
)
assert(
  /id: faceCard[\s\S]*?enabled:\s*false/.test(viewQml),
  'the card above the password field cannot take focus'
)
assert(
  /objectName:\s*"faceCardIndicator"[\s\S]*?visible:\s*faceCard\.visible/.test(viewQml),
  'the lock canvas follows the card so FrameAnimation stops when the card hides'
)
assert(
  !/chrome\s*=/.test(viewQml) && !/Loader/.test(viewQml),
  'lock never loads a plugin Item next to its password field'
)
assert(
  /faceScanning:\s*root\.previewVisible\s*&&\s*root\.faceConfigured/.test(serviceQml),
  'lock preview keeps the scan animation running only while the preview is shown'
)
JS
