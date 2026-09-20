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
  /if \(root\.lockRequested && !root\.authenticatingPassword && !root\.faceAuthenticating\) root\.runBlank\(\)/.test(serviceQml),
  'a password or face check in flight stops the blank timer'
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
  /faceState = "notRecognized"/.test(serviceQml),
  'a miss is shown rather than being silent'
)

const faceFinished = serviceQml.match(/function handleFaceFinished\([\s\S]*?\n  \}/)
assert(faceFinished, 'lock has a handleFaceFinished')
assert(
  /FaceChrome\.holdMs\("recognized"\)/.test(faceFinished[0]),
  'a match holds the recognised frame for as long as the plugin declares'
)
assert(
  /if \(hold > 0\)[\s\S]*?faceHoldTimer\.restart\(\)[\s\S]*?\n      \}\n      finishUnlock\(\)/.test(faceFinished[0]),
  'with no chrome installed a match still unlocks immediately'
)
assert(
  /id: faceHoldTimer[\s\S]{0,200}?onTriggered: root\.finishUnlock\(\)/.test(serviceQml),
  'the hold always ends in an unlock'
)

const teardown = serviceQml.match(/fingerprintRetryTimer\.stop\(\)[\s\S]{0,200}/)
assert(
  teardown && /faceHoldTimer\.stop\(\)/.test(teardown[0]),
  'tearing the lock down never leaves an unlock waiting on a display hold'
)

assert(
  /FaceChromeCanvas/.test(viewQml) && /objectName:\s*"faceCardIndicator"/.test(viewQml),
  'the lock field paints the shared card in the face slot'
)
assert(
  /id: faceIcon[\s\S]*?visible:[^\n]*!root\.faceCardPainting/.test(viewQml),
  'the static glyph yields to the card rather than drawing under it'
)
const canvasBlock = viewQml.match(/FaceChromeCanvas\s*\{[\s\S]*?\n      \}/)
assert(canvasBlock && /enabled:\s*false/.test(canvasBlock[0]),
  'the card beside the password field cannot take focus')
assert(
  !/chrome\s*=/.test(viewQml) && !/Loader/.test(viewQml),
  'lock never loads a plugin Item next to its password field'
)
JS
