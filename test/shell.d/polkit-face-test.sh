#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')

const polkit = requireFromRoot('shell/plugins/polkit/PolkitModel.js')
const fixtures = path.join(root, 'test/shell.d/fixtures/polkit-pam')

function readPam(name) {
  return fs.readFileSync(path.join(fixtures, name), 'utf8')
}

const faceOnly = readPam('face-only.pam')
const fingerprintIsland = readPam('fingerprint-island.pam')
const islandPlusFace = readPam('fingerprint-island-plus-face.pam')
const fido2Island = readPam('fido2-island.pam')
const vendor = readPam('vendor-includes.pam')
const facePlusFingerprint = readPam('face-plus-fingerprint.pam')

assertDeepEqual(
  polkit.pamStepsFromConfig(faceOnly),
  [{ method: 'face', lidGated: true }],
  'face-only PAM is one lid-gated face step'
)
assertDeepEqual(
  polkit.pamStepsFromConfig(fingerprintIsland),
  [{ method: 'fingerprint', lidGated: true }],
  'fingerprint island PAM is one lid-gated fingerprint step'
)
assertDeepEqual(
  polkit.pamStepsFromConfig(islandPlusFace),
  [
    { method: 'face', lidGated: true },
    { method: 'fingerprint', lidGated: true }
  ],
  'island plus face walks Howdy then fprintd'
)
assertDeepEqual(
  polkit.pamStepsFromConfig(fido2Island),
  [],
  'fido2 is not a chromed polkit step'
)
assertDeepEqual(
  polkit.pamStepsFromConfig(vendor),
  [],
  'vendor includes have no chromed steps'
)

assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(faceOnly), true, false),
  { kind: 'face' },
  'open lid waiting on face-only is the face card'
)
assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(faceOnly), true, true),
  { kind: 'password' },
  'closed lid skips the face step'
)
assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(faceOnly), false, false),
  { kind: 'password' },
  'PAM asking for a response is the password card'
)
assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(fingerprintIsland), true, false),
  { kind: 'fingerprint' },
  'open lid waiting on fingerprint is the fingerprint card'
)
assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(islandPlusFace), true, false),
  { kind: 'face' },
  'face wins when it is the first runnable chromed step'
)
assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(islandPlusFace), true, true),
  { kind: 'password' },
  'closed lid skips both gated steps'
)
assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(facePlusFingerprint), true, false),
  { kind: 'face' },
  'vendor face plus fingerprint still starts on face'
)
assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(fido2Island), true, false),
  { kind: 'password' },
  'fido2-only polkit stays on the password card'
)
assertDeepEqual(
  polkit.cardModeFor(polkit.pamStepsFromConfig(vendor), true, false),
  { kind: 'password' },
  'vendor polkit stays on the password card'
)

assertEqual(polkit.glyphFor('face').codePointAt(0), 0xF0208, 'face glyph is U+F0208')
assertEqual(polkit.glyphFor('face'), '\uDB80\uDE08', 'face card uses the lock face glyph')
assertEqual(polkit.hintFor('face'), 'Look at the camera', 'face card asks the user to look')
assertEqual(polkit.hintFor('password'), 'Enter password', 'password card keeps the field hint')
assertEqual(polkit.hintFor('fingerprint'), '', 'fingerprint card has no hint')
assert(!polkit.cardIsSquare('face'), 'face card is wide')
assert(!polkit.cardIsSquare('password'), 'password card is wide')
assert(polkit.cardIsSquare('fingerprint'), 'fingerprint card stays square')

const agentQml = fs.readFileSync(path.join(root, 'shell/plugins/polkit/PolkitAgent.qml'), 'utf8')
const ringQml = fs.readFileSync(path.join(root, 'shell/plugins/polkit/FaceScanRing.qml'), 'utf8')

assert(
  /cardModeFor\(pamSteps,\s*waitingOnPam,\s*laptopClosed\)/.test(agentQml),
  'polkit agent binds the card from cardModeFor'
)
assert(
  !/fingerprintMode/.test(agentQml),
  'polkit agent no longer has a fingerprintMode boolean'
)
assert(
  /FaceScanRing/.test(agentQml) && /Look at the camera/.test(agentQml) === false,
  'polkit agent hosts FaceScanRing and reads the hint from the model'
)
assert(
  /cardKind === "face"/.test(agentQml) && /cardKind === "fingerprint"/.test(agentQml),
  'polkit agent switches chrome on card.kind'
)
assert(
  /RotationAnimation/.test(ringQml) || /on rotation/.test(ringQml),
  'FaceScanRing is an indeterminate rotating ring'
)
JS
