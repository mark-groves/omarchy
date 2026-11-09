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
const noGate = readPam('sudo-howdy-no-gate.pam')
// /etc/pam.d/polkit-1 as omarchy-apply-face-pam writes Ask first.
const askFirst = readPam('ask-first.pam')

assertDeepEqual(
  polkit.pamStepsFromConfig(faceOnly),
  [{ method: 'face', trigger: 'auto', lidGated: true }],
  'face-only PAM is one lid-gated automatic face step'
)
assertDeepEqual(
  polkit.pamStepsFromConfig(fingerprintIsland),
  [{ method: 'fingerprint', trigger: 'auto', lidGated: true }],
  'fingerprint island PAM is one lid-gated fingerprint step'
)
assertDeepEqual(
  polkit.pamStepsFromConfig(islandPlusFace),
  [
    { method: 'face', trigger: 'auto', lidGated: true },
    { method: 'fingerprint', trigger: 'auto', lidGated: true }
  ],
  'island plus face walks Howdy then fprintd'
)
assertDeepEqual(polkit.pamStepsFromConfig(fido2Island), [], 'fido2 is not a chromed polkit step')
assertDeepEqual(polkit.pamStepsFromConfig(vendor), [], 'vendor includes have no chromed steps')

// Ask first: the face line is `-auth`, behind the authtok-empty gate.
const askSteps = polkit.pamStepsFromConfig(askFirst)
assertDeepEqual(askSteps, [{ method: 'face', trigger: 'ask', lidGated: true }], 'the Ask first stack is one face step started by an empty answer')
assertEqual(polkit.faceLaneTriggerFor(askSteps, false), 'ask', 'an open lid offers face on Enter')
assertEqual(polkit.faceLaneTriggerFor(askSteps, true), 'none', 'a closed lid takes the face offer away')
assertEqual(polkit.cardModeFor(askSteps, true, false).kind, 'password', 'the gap before the prompt is not a face scan')
assertEqual(polkit.chromeKindFor(askSteps, false), 'face', 'an Ask first card is still dressed for face')
assertEqual(polkit.chromeKindFor(askSteps, true), 'password', 'a closed lid has no chrome kind')
assertEqual(polkit.faceLaneTriggerFor(polkit.pamStepsFromConfig(faceOnly), false), 'auto', 'a gateless face step stays automatic')
assertEqual(polkit.faceLaneTriggerFor(polkit.pamStepsFromConfig(noGate), false), 'auto', 'sufficient Howdy with no gate scans before the prompt')
assertEqual(polkit.faceLaneTriggerFor(polkit.pamStepsFromConfig(fingerprintIsland), false), 'none', 'fingerprint keeps its own card')
assertEqual(polkit.faceLaneTriggerFor(polkit.pamStepsFromConfig(vendor), false), 'none', 'a password stack has no face lane')
assertDeepEqual(
  polkit.pamStepsFromConfig('-auth sufficient pam_howdy.so\nauth include system-auth\n'),
  [{ method: 'face', trigger: 'auto', lidGated: true }],
  'an -auth face line counts'
)
const sudoAsk = `
auth   [default=ignore]                         pam_exec.so quiet quiet_log stdout /usr/local/lib/omarchy-face/ask-hint tty
auth   [success=ignore conv_err=die default=4]  pam_exec.so quiet quiet_log expose_authtok /usr/local/lib/omarchy-face/authtok-empty
auth   [success=ignore default=die]             pam_succeed_if.so quiet tty =~ /dev/*
auth   [default=ignore]                         pam_warn.so
auth   [default=ignore]                         pam_exec.so quiet quiet_log /usr/local/lib/omarchy-face/omarchy-hw-ir-emitter
-auth  [success=done default=die]               pam_howdy.so
auth   include                                  system-auth
`
assertEqual(polkit.faceLaneTriggerFor(polkit.pamStepsFromConfig(sudoAsk), false), 'ask', 'the gate covers a face line at the end of its jump')
const shortGate = `
auth   [success=ignore conv_err=die default=1]  pam_exec.so quiet quiet_log expose_authtok /usr/local/lib/omarchy-face/authtok-empty
auth   [default=ignore]                         pam_warn.so
auth   sufficient                               pam_howdy.so
`
assertEqual(polkit.faceLaneTriggerFor(polkit.pamStepsFromConfig(shortGate), false), 'auto', 'a face line past the gate\'s jump is not asked for')
assert(!polkit.isAskGateLine('auth [default=ignore] pam_exec.so quiet stdout /usr/local/lib/omarchy-face/ask-hint'), 'the hint is not the gate')

assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(faceOnly), true, false), { kind: 'face' }, 'open lid waiting on face-only is the face card')
assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(faceOnly), true, true), { kind: 'password' }, 'closed lid skips the face step')
assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(faceOnly), false, false), { kind: 'password' }, 'PAM asking for a response is the password card')
assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(fingerprintIsland), true, false), { kind: 'fingerprint' }, 'open lid waiting on fingerprint is the fingerprint card')
assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(islandPlusFace), true, false), { kind: 'face' }, 'face wins when it is the first runnable chromed step')
assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(islandPlusFace), true, true), { kind: 'password' }, 'closed lid skips both gated steps')
assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(facePlusFingerprint), true, false), { kind: 'face' }, 'vendor face plus fingerprint still starts on face')
assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(fido2Island), true, false), { kind: 'password' }, 'fido2-only polkit stays on the password card')
assertDeepEqual(polkit.cardModeFor(polkit.pamStepsFromConfig(vendor), true, false), { kind: 'password' }, 'vendor polkit stays on the password card')

assertEqual(polkit.glyphFor('face').codePointAt(0), 0xF0208, 'face glyph is U+F0208')
assertEqual(polkit.hintFor('face'), 'Look at the camera', 'face card asks the user to look')
assertEqual(polkit.hintFor('password'), 'Enter password', 'password card keeps the field hint')
assertEqual(polkit.hintFor('fingerprint'), '', 'fingerprint card has no hint')
assert(!polkit.cardIsSquare('face') && !polkit.cardIsSquare('password') && polkit.cardIsSquare('fingerprint'), 'only the fingerprint card is square')
assertEqual(polkit.chromeSlotKeyFor('password'), '', 'password card is not replaceable')
assertEqual(polkit.chromeSlotKeyFor('face'), 'polkitFace', 'face card loads the polkitFace slot')
assertDeepEqual(polkit.chromeSlotKeys(), ['polkitFace', 'polkitFingerprint'], 'validate and discovery share the card slot keys')
assertEqual(polkit.CHROME_KIND, 'polkit-chrome', 'chrome plugins declare the unrecognized kind')
assertEqual(polkit.chromeKindFor(polkit.pamStepsFromConfig(faceOnly), false), 'face', 'chrome kind follows the configured biometric')
assertEqual(polkit.chromeKindFor(polkit.pamStepsFromConfig(faceOnly), true), 'password', 'closed lid has no chrome kind')

function fakeRegistry(plugins, enabled) {
  return {
    installedPlugins: plugins,
    isEnabled: (id) => enabled.indexOf(id) !== -1,
    entryPointUrl: (m, key) => (m && m.entryPoints[key] && m.__sourceDir)
      ? 'file://' + m.__sourceDir + '/' + m.entryPoints[key] : ''
  }
}

function source(plugins, enabled, failed, revision) {
  const rev = revision === undefined ? 1 : revision
  return {
    registry: fakeRegistry(plugins, enabled),
    revision: rev,
    failedUrls: failed || {},
    failedRevision: failed ? rev : 0
  }
}

const facePlugin = {
  kinds: ['polkit-chrome'],
  entryPoints: { polkitFace: 'FaceCardFrame.js' },
  __sourceDir: '/plugins/markgroves.polkit-face',
  __isFirstParty: false
}
const fingerprintPlugin = {
  kinds: ['polkit-chrome'],
  entryPoints: { polkitFingerprint: 'PolkitFingerprintCard.qml' },
  __sourceDir: '/plugins/acme.polkit-fingerprint',
  __isFirstParty: false
}
const plugins = {
  'markgroves.polkit-face': facePlugin,
  'acme.polkit-fingerprint': fingerprintPlugin
}
const faceSteps = polkit.pamStepsFromConfig(faceOnly)
const fingerprintSteps = polkit.pamStepsFromConfig(fingerprintIsland)

const filled = polkit.cardPresentationFor(faceSteps, true, false, source(plugins, ['markgroves.polkit-face']))
assertEqual(filled.kind, 'face', 'open lid waiting on face still picks the face card')
assertEqual(filled.slot.pluginId, 'markgroves.polkit-face', 'enabled chrome plugin fills the face slot')
assertEqual(filled.slot.url, 'file:///plugins/markgroves.polkit-face/FaceCardFrame.js', 'slot url stays inside the plugin dir')
assert(polkit.faceSlotResolved(filled), 'an open-lid face request resolves polkitFace')

const askFilled = polkit.cardPresentationFor(askSteps, true, false, source(plugins, ['markgroves.polkit-face']))
assertEqual(askFilled.kind, 'password', 'an Ask first card waits on the prompt, not on a scan')
assert(polkit.faceSlotResolved(askFilled), 'an Ask first card resolves the polkitFace slot from the start')
const askClosed = polkit.cardPresentationFor(askSteps, true, true, source(plugins, ['markgroves.polkit-face']))
assert(!polkit.faceSlotResolved(askClosed), 'a closed lid resolves no face slot')

const duringError = polkit.cardPresentationFor(faceSteps, false, false, source(plugins, ['markgroves.polkit-face']))
assertEqual(duringError.kind, 'password', 'a miss still shows the password card')
assertEqual(duringError.chromeKind, 'face', 'chrome kind does not follow waitingOnPam')
assertEqual(duringError.slot.pluginId, 'markgroves.polkit-face', 'the face slot stays resolved through the error flash')

const passwordOnly = polkit.cardPresentationFor(polkit.pamStepsFromConfig(vendor), true, false, source(plugins, ['markgroves.polkit-face']))
assertEqual(passwordOnly.kind, 'password', 'vendor polkit is a password card')
assert(!polkit.faceSlotResolved(passwordOnly), 'an installed face plugin does not make a password prompt a face card')

const fingerprintWaiting = polkit.cardPresentationFor(fingerprintSteps, true, false, source(plugins, ['acme.polkit-fingerprint', 'markgroves.polkit-face']))
assertEqual(fingerprintWaiting.chromeKind, 'fingerprint', 'fingerprint PAM stays on fingerprint chrome')
assert(!polkit.faceSlotResolved(fingerprintWaiting), 'a fingerprint slot is not polkitFace')

const disabled = polkit.cardPresentationFor(faceSteps, true, false, source(plugins, []))
assertEqual(disabled.slot, null, 'installed but disabled chrome is an empty slot')
const missing = polkit.cardPresentationFor(faceSteps, true, false, source({}, []))
assertEqual(missing.slot, null, 'no chrome plugin is the same empty slot as disabled')
assert(!polkit.faceSlotResolved(missing), 'no plugin means no polkitFace slot')

const failedUrl = 'file:///plugins/markgroves.polkit-face/FaceCardFrame.js'
const broken = polkit.cardPresentationFor(faceSteps, true, false, source(plugins, ['markgroves.polkit-face'], { [failedUrl]: true }))
assertEqual(broken.slot, null, 'a failed Loader url is an empty slot')
const retried = polkit.cardPresentationFor(
  faceSteps,
  true,
  false,
  Object.assign(source(plugins, ['markgroves.polkit-face'], { [failedUrl]: true }), { revision: 2, failedRevision: 1 })
)
assertEqual(retried.slot.pluginId, 'markgroves.polkit-face', 'a registry rescan retries a previously failed slot')
assertEqual(polkit.failedUrlsFor({ failedUrls: { [failedUrl]: true }, failedRevision: 1, revision: 2 }), null, 'stale failed urls do not apply after a rescan')

const firstParty = polkit.cardPresentationFor(faceSteps, true, false, source({
  'omarchy.polkit': { ...facePlugin, __isFirstParty: true }
}, ['omarchy.polkit']))
assertEqual(firstParty.slot, null, 'first-party manifests cannot fill the chrome slot')

const keyOnly = polkit.cardPresentationFor(faceSteps, true, false, source({
  'markgroves.polkit-face': { ...facePlugin, kinds: ['service', 'panel'] }
}, ['markgroves.polkit-face']))
assertEqual(keyOnly.slot && keyOnly.slot.pluginId, 'markgroves.polkit-face', 'the polkitFace key attaches without the polkit-chrome kind')

const passwordSlot = polkit.cardPresentationFor(faceSteps, false, false, source({
  'acme.password': {
    kinds: ['polkit-chrome'],
    entryPoints: { polkitPassword: 'Password.qml' },
    __sourceDir: '/plugins/acme.password'
  }
}, ['acme.password']))
assertEqual(passwordSlot.slot, null, 'password card rejects a chrome plugin')

const collision = polkit.cardPresentationFor(faceSteps, true, false, source({
  'zeta.face': facePlugin,
  'alpha.face': { ...facePlugin, __sourceDir: '/plugins/alpha.face' }
}, ['zeta.face', 'alpha.face']))
assertEqual(collision.slot.pluginId, 'alpha.face', 'the lower plugin id wins a chrome collision')
assertDeepEqual(collision.slot.shadowed, ['zeta.face'], 'the losing chrome plugin is named')
assertEqual(
  polkit.chromeSlotDiagnostic(collision),
  'polkit chrome: face painted by alpha.face; ignoring zeta.face',
  'collision diagnostic names the winner and the loser'
)
assertEqual(polkit.chromeSlotDiagnostic(disabled), '', 'empty slots are not logged')

const fingerprintFilled = polkit.cardPresentationFor(fingerprintSteps, true, false, source(plugins, ['acme.polkit-fingerprint']))
assertEqual(fingerprintFilled.slot.pluginId, 'acme.polkit-fingerprint', 'fingerprint slot resolves when declared')
assert(fingerprintFilled.square, 'fingerprint card stays square when a slot paints')

assert(!polkit.polkitCardVisible(true, true, false), 'a polkit card does not render while the session is locked')
assert(!polkit.polkitCardVisible(true, false, true), 'a request resolved under the lock stays hidden after unlock')
assert(polkit.polkitCardVisible(true, false, false), 'a pending request renders once the session is unlocked')
assert(!polkit.shouldArmFaceHold(true), 'a face result under the lock does not arm a hold')
assert(polkit.shouldArmFaceHold(false), 'a face result on the unlocked session still plays')
assert(polkit.shouldRestartFaceOnUnlock(false, true, false), 'a request still pending at unlock starts its card over')
assert(!polkit.shouldRestartFaceOnUnlock(false, true, true), 'a request already resolved under the lock does not replay')
assert(!polkit.shouldRestartFaceOnUnlock(false, false, false), 'an idle agent does not open a card at unlock')
// Ask first scans on an empty answer, so a stray Enter must not send one.
assert(!polkit.emptySubmitArmed(10000, 10100, false), 'an empty Enter 100ms after the field took focus is refused')
assert(polkit.emptySubmitArmed(10000, 10700, false), 'an empty Enter 700ms after the field took focus is accepted')
assert(!polkit.emptySubmitArmed(10000, 10700, true), 'an autorepeated empty Enter is refused')
assert(!polkit.emptySubmitArmed(0, 10700, false), 'an empty Enter before the field took focus for the prompt is refused')

// --- The face lane, whole requests at a time --------------------------------
//
// Timings from this host's journal: the hint and prompt land about 0.1 s
// after the request, the plugin presents 620 ms of scan before a match may
// replace it, and holds a match 1.9 s and a miss 1.8 s.
const SCAN_MS = 620
const env = { ready: true, scanMs: SCAN_MS, recognized: 'play', notRecognized: 'play' }

function play(trigger, events, envOverride) {
  const timeline = [{ t: 0, type: 'open', trigger }].concat(events).sort((a, b) => a.t - b.t)
  let lane = polkit.faceLaneInitial()
  const trace = []
  for (const event of timeline) {
    lane = polkit.faceLaneStep(lane, event, Object.assign({}, env, envOverride || {}, event.env || {}))
    trace.push({ t: event.t, type: event.type, lane })
  }
  const after = (type, nth) => trace.filter((step) => step.type === type)[nth || 0].lane
  const faceStates = trace.map((step) => step.lane.faceState).filter((state, i, all) => i === 0 || all[i - 1] !== state)
  return { lane, trace, after, faceStates }
}

const ask = (t) => [
  { t: 80, type: 'hint' },
  { t: 110, type: 'prompt' },
  { t, type: 'submitEmpty' }
]

for (const matchMs of [500, 1100, 2100]) {
  const enter = 1000
  const run = play('ask', ask(enter).concat([
    { t: enter + SCAN_MS, type: 'scanShown' },
    { t: enter + matchMs - 90, type: 'info', text: 'Face matched user someone' },
    { t: enter + matchMs, type: 'succeeded' },
    { t: enter + matchMs + 1, type: 'ended' },
    { t: enter + Math.max(matchMs, SCAN_MS) + 1900, type: 'resultPlayed' },
    { t: enter + Math.max(matchMs, SCAN_MS) + 2030, type: 'closed' }
  ]))
  const label = `a match at ${matchMs / 1000} s`
  assertEqual(run.after('open').faceState, 'idle', `${label}: the card opens on the idle face area`)
  assertDeepEqual(polkit.faceLaneCaptions(run.after('prompt')), { primary: 'offer', secondary: 'orType', error: false }, `${label}: the card offers face at the prompt`)
  const scanning = run.after('submitEmpty')
  assert(scanning.faceState === 'scanning' && scanning.attempt && scanning.pending === 'face', `${label}: the accepted Enter is already a scan`)
  assertDeepEqual(run.faceStates, ['idle', 'scanning', 'recognized', 'idle'], `${label}: idle, scanning, recognized, then gone`)
  const approved = run.after('succeeded')
  assert(!polkit.faceLaneWantsKeyboard(approved), `${label}: the keyboard goes back once PAM approves`)
  if (matchMs < SCAN_MS) {
    assert(approved.pendingMatch && approved.faceState === 'scanning', `${label}: the match waits for the scan to show`)
    assertEqual(run.after('scanShown').faceState, 'recognized', `${label}: the match plays once the scan has shown`)
  } else {
    assertEqual(approved.faceState, 'recognized', `${label}: the match plays at once`)
  }
  assertEqual(run.after('ended').phase, 'open', `${label}: the flow ending does not cut the match`)
  assertEqual(run.after('resultPlayed').phase, 'closing', `${label}: the card leaves once the match has played`)
  assertEqual(run.lane.wrong, 0, `${label}: nothing flashes wrong`)
  assertEqual(run.lane.phase, 'closed', `${label}: the card is gone after its fade`)
}

{
  const enter = 1000
  const verdict = enter + 4300
  const run = play('ask', ask(enter).concat([
    { t: enter + SCAN_MS, type: 'scanShown' },
    { t: verdict - 30, type: 'error', text: 'Face verification timed out' },
    { t: verdict, type: 'failed' },
    { t: verdict + 80, type: 'hint' },
    { t: verdict + 110, type: 'prompt' },
    { t: verdict + 1800, type: 'resultPlayed' },
    { t: verdict + 3000, type: 'submitEmpty' }
  ]))
  const missed = run.after('failed')
  assert(missed.faceState === 'notRecognized' && missed.hold === 'notRecognized', 'a miss at 4.3 s plays not recognized')
  assert(missed.wrong === 0, 'a face miss is not a wrong password')
  assertEqual(missed.reason, 'Face verification timed out', 'the lane keeps Howdy\'s reason')
  assert(polkit.faceLaneWantsKeyboard(missed), 'the request keeps the keyboard through a miss')
  const reprompted = run.after('prompt', 1)
  assert(reprompted.faceState === 'notRecognized' && reprompted.epoch === missed.epoch, 'the next session\'s prompt is not another miss')
  const back = run.after('resultPlayed')
  assert(back.faceState === 'idle' && back.retry, 'the field comes back after the miss has played')
  assertDeepEqual(polkit.faceLaneCaptions(back), { primary: 'retry', secondary: 'orType', error: false }, 'the field offers another try or a password')
  assert(polkit.faceLaneAcceptsEmpty(back), 'Enter can try again')
  const again = run.after('submitEmpty', 1)
  assert(again.faceState === 'scanning' && again.epoch > back.epoch && !again.retry, 'a second try starts a new scan')
  assertDeepEqual(run.faceStates, ['idle', 'scanning', 'notRecognized', 'idle', 'scanning'], 'a miss reads idle, scanning, not recognized, idle')
}

{
  const run = play('ask', [
    { t: 80, type: 'hint' },
    { t: 110, type: 'prompt' },
    { t: 1500, type: 'submitTyped' },
    { t: 1750, type: 'succeeded' },
    { t: 1751, type: 'ended' }
  ])
  assertEqual(run.after('submitTyped').pending, 'password', 'a typed password is checked as a password')
  assertDeepEqual(run.faceStates, ['idle'], 'a typed password never scans')
  assertEqual(run.after('succeeded').phase, 'closing', 'a typed password closes the card with no face hold')
}

{
  const run = play('ask', [
    { t: 110, type: 'prompt' },
    { t: 1500, type: 'submitTyped' },
    { t: 1800, type: 'failed' },
    { t: 1900, type: 'prompt' }
  ])
  const refused = run.after('failed')
  assert(refused.wrong === 1 && refused.faceState === 'idle' && refused.hold === '', 'a wrong password shakes and is not a face miss')
  assert(polkit.faceLaneAcceptsEmpty(run.lane), 'face is still offered after a wrong password')
}

{
  const run = play('ask', ask(1000).concat([
    { t: 1800, type: 'cancelled' },
    { t: 1801, type: 'ended' },
    { t: 1900, type: 'succeeded' }
  ]))
  const cancelled = run.after('cancelled')
  assert(cancelled.phase === 'closing' && cancelled.outcome === 'cancelled' && !cancelled.attempt, 'Esc mid-scan fades the card out')
  assert(run.lane.phase === 'closing' && run.lane.hold === '' && run.lane.outcome === 'cancelled', 'nothing plays after Esc')
}

{
  const run = play('ask', ask(1000).concat([
    { t: 1500, type: 'failed' },
    { t: 1600, type: 'cancelled' }
  ]))
  assert(run.after('failed').hold === 'notRecognized', 'the miss hold is playing')
  const ended = run.after('cancelled')
  assert(ended.phase === 'closing' && ended.hold === '', 'a request cancelled mid-hold closes the card at once')
}

{
  const run = play('ask', ask(1000).concat([
    { t: 1500, type: 'failed' },
    { t: 1600, type: 'ended' }
  ]))
  assert(run.after('ended').phase === 'closing', 'a flow that ends mid-miss closes the card')
}

{
  const run = play('ask', ask(1000).concat([
    { t: 1620, type: 'scanShown' },
    { t: 1800, type: 'succeeded' },
    { t: 1801, type: 'ended' }
  ]))
  assert(run.lane.phase === 'open' && run.lane.hold === 'recognized', 'a flow that ends mid-match keeps playing the match')
}

{
  // Automatic: PAM scans first; falling through to the password is the miss.
  const run = play('auto', [
    { t: 900, type: 'scanShown' },
    { t: 4300, type: 'prompt' },
    { t: 6100, type: 'resultPlayed' },
    { t: 7000, type: 'submitTyped' },
    { t: 7300, type: 'failed' }
  ])
  assertEqual(run.after('open').faceState, 'scanning', 'an Automatic card scans from the start')
  assertEqual(run.after('prompt').faceState, 'notRecognized', 'the password prompt is the Automatic miss')
  const back = run.after('resultPlayed')
  assert(back.faceState === 'idle' && !back.retry && !polkit.faceLaneAcceptsEmpty(back), 'an Automatic stack never sends an empty answer')
  const refused = run.after('failed')
  assert(refused.wrong === 1 && refused.faceState === 'scanning', 'a wrong password on Automatic flashes, and the new session scans again')
  const matched = play('auto', [{ t: 900, type: 'scanShown' }, { t: 1000, type: 'succeeded' }])
  assertEqual(matched.lane.hold, 'recognized', 'an Automatic match plays')
}

{
  // The lid is shut: an empty Enter is a password like any other.
  const run = play('none', [
    { t: 110, type: 'prompt' },
    { t: 1000, type: 'submitEmpty' },
    { t: 1300, type: 'failed' }
  ])
  assertEqual(run.after('submitEmpty').pending, 'password', 'with no face lane an empty Enter is a password answer')
  assertDeepEqual(run.faceStates, ['idle'], 'with no face lane nothing scans')
  assertEqual(run.lane.wrong, 1, 'and its failure is a wrong password')
  assertDeepEqual(polkit.faceLaneCaptions(run.lane), { primary: '', secondary: '', error: false }, 'a password card has no face captions')
}

{
  // No face module: nothing can play, so results do not hold the card.
  const none = { ready: false, scanMs: 0, recognized: 'immediate', notRecognized: 'immediate' }
  const matched = play('ask', ask(1000).concat([{ t: 1400, type: 'succeeded' }]), none)
  assertEqual(matched.lane.phase, 'closing', 'a match with no face module closes at once')
  const missed = play('ask', ask(1000).concat([{ t: 1400, type: 'failed' }]), none)
  assert(missed.lane.faceState === 'idle' && missed.lane.retry, 'a miss with no face module goes straight back to the field')
  const lost = play('ask', ask(1000).concat([
    { t: 1400, type: 'succeeded' },
    { t: 1450, type: 'chrome', env: none }
  ]))
  assertEqual(lost.after('succeeded').pendingMatch, true, 'a match waits on the scan')
  assertEqual(lost.lane.phase, 'closing', 'a face module that goes away stops the wait')
}

{
  const locked = play('ask', ask(1000).concat([{ t: 1700, type: 'succeeded', env: { locked: true } }]))
  assertEqual(locked.lane.phase, 'closing', 'a match under the lock does not play')
  const lockedMidHold = play('ask', ask(1000).concat([
    { t: 1700, type: 'succeeded' },
    { t: 1800, type: 'locked' }
  ]))
  assertEqual(lockedMidHold.lane.phase, 'closing', 'the lock coming over a match closes the card')
  const unlocked = play('ask', ask(1000).concat([{ t: 1500, type: 'unlocked' }]))
  assert(unlocked.lane.faceState === 'scanning' && unlocked.lane.epoch > unlocked.after('submitEmpty').epoch, 'a scan still running at unlock starts its card over')
}

assertEqual(polkit.faceLaneProbeState(polkit.faceLaneInitial()), 'hidden', 'a closed lane probes as hidden')
assertDeepEqual(polkit.parsePreviewSpec('match'), { scenario: 'match', scanMs: 510 }, 'a preview defaults to the journal\'s median match')
assertDeepEqual(polkit.parsePreviewSpec('miss:4300'), { scenario: 'miss', scanMs: 4300 }, 'a preview takes a scan time')
assertEqual(polkit.parsePreviewSpec('match:0'), null, 'a zero scan time is refused')
assertEqual(polkit.parsePreviewSpec('unlock'), null, 'an unknown preview is refused')

// --- What the agent may and may not hold ------------------------------------

const pluginDir = path.join(root, 'shell/plugins/polkit')
const agentQml = fs.readFileSync(path.join(pluginDir, 'PolkitAgent.qml'), 'utf8')
const controllerQml = fs.readFileSync(path.join(pluginDir, 'PolkitController.qml'), 'utf8')
const cardQml = fs.readFileSync(path.join(pluginDir, 'PolkitCard.qml'), 'utf8')
const fakeQml = fs.readFileSync(path.join(pluginDir, 'FakeFlow.qml'), 'utf8')
const pluginQml = fs.readdirSync(pluginDir).filter((name) => name.endsWith('.qml'))
  .map((name) => fs.readFileSync(path.join(pluginDir, name), 'utf8')).join('\n')

assert(/property var pluginRegistry/.test(agentQml), 'polkit agent declares pluginRegistry so ensureService injects the real registry')
assert(!/property\s+\S+\s+shell\b/.test(pluginQml), 'nothing in the polkit plugin declares shell')
assert(!/\bsource:/.test(pluginQml) && !/setSource\(/.test(pluginQml) && !/FaceScanRing/.test(pluginQml), 'no QML is loaded from a URL into the polkit windows')
assert(!fs.existsSync(path.join(pluginDir, 'FaceScanRing.qml')), 'first-party FaceScanRing is gone')
assert(!/chromeContext/.test(pluginQml), 'chromeContext is gone: a QtObject parented to the agent root is a walk back to the field')
assert(!/item\.chrome/.test(pluginQml) && !/item\.flow/.test(pluginQml), 'nothing host-owned is handed to a chrome plugin')
assert(/FaceChromeCanvas \{/.test(cardQml), 'the card paints chrome itself through the host canvas')
assert(/id: faceArea[\s\S]{0,400}?enabled:\s*false/.test(cardQml), 'the face area cannot take focus')
assert(
  /entryPointKey\s*===\s*"polkitFace"/.test(controllerQml) && /FaceChrome\.sourceUrl = root\.slotUrl/.test(controllerQml),
  'only a face slot may replace the shared face module'
)
assert(/LockCover\.covered/.test(controllerQml), 'polkit reads the lock cover instead of the shell')
assert(/function refocus\(\) \{[\s\S]*?if \(!root\.cardVisible\) return/.test(controllerQml), 'refocus waits until the polkit card is actually shown')

// Quickshell drops polkitAgent.flow as a request completes, before it emits
// authenticationSucceeded; the flow is held from the request's start.
assert(/onAuthenticationRequestStarted:\s*polkitController\.beginRealFlow\(polkitAgent\.flow\)/.test(agentQml), 'the agent hands over each request\'s flow as it starts')
assert(!/polkitAgent/.test(controllerQml.replace(/\/\/.*$/gm, '')) && /target:\s*root\.flow\b/.test(controllerQml), 'the controller follows the flow it was handed, not polkitAgent.flow')

// The preview draws the card and nothing else.
const previewWindow = agentQml.slice(agentQml.indexOf('LazyLoader'), agentQml.indexOf('ShellIpc'))
assert(/"omarchy-polkit-preview"/.test(previewWindow) && /keyboardFocus:\s*WlrKeyboardFocus\.None/.test(previewWindow) && /mask:\s*Region \{\}/.test(previewWindow),
  'the preview window never takes the keyboard or the pointer')
assert(/preview:\s*true/.test(previewWindow), 'the preview window draws the preview card')
assert(/function submit\(\) \{/.test(fakeQml) && !/TextInput|function submit\(\w/.test(fakeQml), 'the fake flow takes no answer')
assert(/readOnly:\s*!root\.interactive/.test(cardQml) && /activeFocusOnPress:\s*root\.interactive/.test(cardQml), 'the preview card\'s field takes no text')
assert(/function submitResponse\(isAutoRepeat\) \{\s*if \(root\.previewing/.test(controllerQml) && /function previewUserAction\(kind\) \{\s*if \(!root\.previewing \|\| root\.flow !== fakeFlow\) return/.test(controllerQml),
  'a preview never answers a real flow, and a real answer never reaches the preview')
assert(/if \(root\.realBusy\) return "busy"/.test(controllerQml) && /function beginRealFlow\(flow\) \{\s*if \(root\.previewing\) root\.stopPreview\(\)/.test(controllerQml),
  'a real request ends a preview, and a preview waits for a real request')

const painter = fs.readFileSync(path.join(root, 'shell/Commons/FaceCardPainter.js'), 'utf8')
assert(
  /function paint\(ctx, size, ops, palette, scale\)/.test(painter) && /function paintGlow\(ctx, size, ops, palette, scale\)/.test(painter),
  'the host owns the painter and takes ops, not a plugin item'
)
assert(
  /MAX_OPS/.test(painter) && /MAX_CMDS/.test(painter) && /MAX_GLOW_OPS/.test(painter) && /isFinite/.test(painter),
  'the painter treats a returned frame as hostile input'
)

const chrome = fs.readFileSync(path.join(root, 'shell/Commons/FaceChrome.qml'), 'utf8')
assert(/new Function\(/.test(chrome) && !/\beval\(/.test(chrome), 'the plugin module is evaluated without capturing local scope')
assert(/Math\.min\(ms, 2000\)/.test(chrome), 'a plugin cannot pin a credential dialog open')
assert(
  /function bindFromRegistry\(/.test(chrome) && /function urlFromRegistry\(/.test(chrome),
  'FaceChrome discovers an enabled polkitFace module from the registry'
)
assert(
  /entryPoints\.polkitFace/.test(chrome) && !/polkit-chrome/.test(chrome.replace(/\/\/.*$/gm, '')),
  'chrome discovery uses the same slot key as the polkit resolver, without requiring a kind'
)
const shellQml = fs.readFileSync(path.join(root, 'shell/shell.qml'), 'utf8')
assert(/FaceChrome\.bindFromRegistry\(pluginRegistry\)/.test(shellQml), 'the shell binds face chrome at startup so lock does not wait for polkit')
JS

# The real controller and card, offscreen: no compositor, no polkitd, no
# display. PanelWindow has no backend there, so the fixture draws the cards
# in plain windows and plays requests through a recording stand-in for
# AuthFlow, then the preview through its own FakeFlow.
if ! command -v quickshell >/dev/null 2>&1; then
  skip "quickshell not installed; skipping the offscreen polkit card"
  exit 0
fi
require_command jq

qml_fixture_scratch
mkdir -p "$QML_FIXTURE_TMP/run" "$QML_FIXTURE_TMP/lid/LID0" "$QML_FIXTURE_TMP/input"
printf 'state:      open\n' >"$QML_FIXTURE_TMP/lid/LID0/state"

WAYLAND_DISPLAY="" HYPRLAND_INSTANCE_SIGNATURE="" DBUS_SESSION_BUS_ADDRESS="unix:path=$QML_FIXTURE_TMP/run/no-bus" \
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software QT_FORCE_STDERR_LOGGING=1 QML_DISABLE_DISK_CACHE=1 \
XDG_RUNTIME_DIR="$QML_FIXTURE_TMP/run" OMARCHY_ACPI_LID_PATH="$QML_FIXTURE_TMP/lid" OMARCHY_INPUT_CLASS_PATH="$QML_FIXTURE_TMP/input" \
  run_qml_fixture polkit-card "the polkit card plays a match, a miss, a password and the preview in one place" Ui Commons
