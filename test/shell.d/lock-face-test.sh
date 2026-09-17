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

assert(
  /faceConfigured/.test(viewQml) && /objectName:\s*"faceIndicator"/.test(viewQml),
  'the lock field shows a face glyph when face is configured'
)
JS
