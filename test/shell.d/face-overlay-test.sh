#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')

const model = requireFromRoot('shell/plugins/face-overlay/FaceOverlayModel.js')
const overlayQml = fs.readFileSync(path.join(root, 'shell/plugins/face-overlay/FaceOverlay.qml'), 'utf8')
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'shell/plugins/face-overlay/manifest.json'), 'utf8'))
const wrapper = fs.readFileSync(path.join(root, 'bin/omarchy-apply-howdy-compare'), 'utf8')
const signal = fs.readFileSync(path.join(root, 'bin/omarchy-face-auth-signal'), 'utf8')
const lockQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')
const polkitQml = fs.readFileSync(path.join(root, 'shell/plugins/polkit/PolkitAgent.qml'), 'utf8')

assertEqual(manifest.id, 'omarchy.face-overlay', 'face overlay uses the first-party namespace')
assert(manifest.keepLoaded === true, 'face overlay stays loaded so PAM signals are received')
assertDeepEqual(manifest.kinds, ['panel'], 'face overlay is a keepLoaded panel')
assertEqual(manifest.entryPoints.panel, 'FaceOverlay.qml', 'face overlay entry point is the host card')

assertEqual(model.signalPath('/run/user/1000'), '/run/user/1000/omarchy/face-auth.json', 'signal path sits in the session runtime dir')
assertEqual(model.signalPath(''), '', 'an empty runtime dir has no signal path')

assertDeepEqual(
  model.parseSignal('{"state":"scanning","ts":12}'),
  { state: 'scanning', ts: 12 },
  'parseSignal reads a scanning write'
)
assertDeepEqual(
  model.parseSignal('{"state":"recognized","ts":13}'),
  { state: 'recognized', ts: 13 },
  'parseSignal reads a match'
)
assertDeepEqual(
  model.parseSignal('{"state":"notRecognized","ts":14}'),
  { state: 'notRecognized', ts: 14 },
  'parseSignal reads a miss'
)
assertDeepEqual(
  model.parseSignal('{"state":"cancelled","ts":15}'),
  { state: 'cancelled', ts: 15 },
  'parseSignal reads a cancelled scan'
)
assertEqual(model.parseSignal('{"state":"idle"}'), null, 'unknown states are ignored')
assert(model.isHideState('cancelled'), 'cancelled hides the card')
assert(!model.isHideState('scanning'), 'scanning does not hide the card')
assertEqual(model.resultHoldMs('cancelled', 900), 0, 'cancelled is not a held result')
assertEqual(model.scanTimeoutMs(), 20000, 'a scanning card times out if compare never returns')
assertEqual(model.hintFor('cancelled'), '', 'a cancelled card has no hint')
assertDeepEqual(model.parseShowPayload('cancelled'), { state: 'cancelled', ts: 0 }, 'IPC accepts a cancelled hide')
assertEqual(model.parseSignal(''), null, 'empty writes are ignored')
assertDeepEqual(model.parseShowPayload('scanning'), { state: 'scanning', ts: 0 }, 'IPC accepts a bare state')
assertEqual(model.parseShowPayload('{"state":"recognized","ts":9}').state, 'recognized', 'IPC accepts JSON')

assert(model.isNewerSignal({ state: 'recognized', ts: 2 }, { state: 'scanning', ts: 1 }), 'a later timestamp wins')
assert(!model.isNewerSignal({ state: 'scanning', ts: 1 }, { state: 'recognized', ts: 2 }), 'a stale scan does not replace a result')
assert(model.shouldSuppress(true, false), 'lock suppresses the sudo overlay')
assert(model.shouldSuppress(false, true), 'polkit suppresses the sudo overlay')
assert(!model.shouldSuppress(false, false), 'terminal sudo is not suppressed')

assertEqual(model.resultHoldMs('scanning', 900), 0, 'scanning is not a held result')
assertEqual(model.resultHoldMs('recognized', 900), 900, 'recognized uses the plugin hold')
assertEqual(model.resultHoldMs('notRecognized', 2500), 2000, 'a plugin cannot pin the overlay open')
assertEqual(model.resultHoldMs('recognized', 0), 0, 'no chrome means no hold')
assertEqual(model.hintFor('scanning'), 'Look at the camera', 'scanning hint matches lock')
assertEqual(model.hintFor('recognized'), 'Face recognized', 'recognized hint matches lock')
assertEqual(model.hintFor('notRecognized'), 'Face not recognized', 'miss hint matches lock')

assert(/FaceChromeCanvas/.test(overlayQml), 'overlay paints through the host canvas')
assert(/objectName:\s*"faceOverlayCard"/.test(overlayQml), 'overlay card is named for tests')
assert(/target:\s*"omarchy\.face-overlay"/.test(overlayQml), 'overlay registers its own IPC target')
assert(/function show\(payloadJson: string\)/.test(overlayQml), 'overlay can be shown over IPC')
assert(/FaceChrome\.holdMs\(next\.state\)/.test(overlayQml), 'overlay holds a result for as long as the plugin declares')
assert(/Model\.isHideState\(next\.state\)/.test(overlayQml) && /root\.hideCard\(\)/.test(overlayQml), 'cancelled hides the overlay without a hold')
assert(/Model\.scanTimeoutMs\(\)/.test(overlayQml), 'scanning starts a timeout so a killed wrapper cannot stick')
assert(/firstPartyServiceFor\("omarchy\.lock"\)/.test(overlayQml) && /firstPartyServiceFor\("omarchy\.polkit"\)/.test(overlayQml), 'overlay asks lock and polkit whether they already own the card')
assert(/WlrKeyboardFocus\.None/.test(overlayQml) && /mask:\s*Region \{\}/.test(overlayQml), 'overlay is click-through and does not steal the terminal')
assert(!/Loader/.test(overlayQml) && !/passwordInput/.test(overlayQml) && !/PamContext/.test(overlayQml), 'overlay never loads a plugin item or owns PAM')
assert(/FileView/.test(overlayQml) && /root\.signalPath/.test(overlayQml), 'overlay watches the PAM signal file')
assert(/property bool primed/.test(overlayQml) && /setText\("\{\}\\n"\)/.test(overlayQml), 'overlay starts the watch without showing a leftover scan')

assert(/OPENCV_LOG_LEVEL=ERROR/.test(wrapper), 'howdy-compare wrapper quiets OpenCV WARNs')
assert(/signal_face scanning/.test(wrapper) && /signal_face recognized/.test(wrapper), 'wrapper signals scan start and match')
assert(/signal_face cancelled/.test(wrapper) && /trap on_exit EXIT/.test(wrapper), 'wrapper hides the card if compare never returns a result')
assert(/trap 'exit 130' INT/.test(wrapper) && /trap 'exit 143' TERM/.test(wrapper), 'INT and TERM still exit with their usual statuses')
assert(/signaled_result=1/.test(wrapper), 'a normal compare exit does not overwrite the result with cancelled')
assert(/face-auth\.json/.test(signal), 'helper writes the signal file')
assert(/cancelled/.test(signal), 'helper accepts a cancelled hide')
assert(!/\bsudo\b/.test(signal) && !/\bpkexec\b/.test(signal), 'helper never escalates')

assert(/property bool faceHolding/.test(lockQml), 'lock tracks a display-only hold')
assert(/faceScanning:\s*root\.faceAuthenticating \|\| root\.faceHolding/.test(lockQml), 'lock keeps the card animating through the hold')
assert(/function holdFaceResult\(/.test(lockQml), 'lock holds recognized and miss through one helper')
assert(/!root\.faceHolding/.test(lockQml), 'lock does not blank the panel during a face hold')
assert(/id: faceMissHoldTimer/.test(lockQml), 'lock holds a miss long enough for the card to play out')

assert(/property bool resultHold/.test(polkitQml), 'polkit keeps the dialog up after PAM succeeds')
assert(/dialogVisible:.*resultHold/.test(polkitQml), 'polkit visibility includes the result hold')
assert(/function faceResultHoldMs\(/.test(polkitQml), 'polkit reuses holdMs for instant success and miss')
assert(/root\.resultHold = true/.test(polkitQml), 'a match holds the polkit card before close')
assert(/!root\.resultHold/.test(polkitQml), 'the password row stays hidden during a held match')
JS
