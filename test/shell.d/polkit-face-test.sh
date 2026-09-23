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
assertEqual(filled.chromeKind, 'face', 'chrome kind stays on the configured face step')
assertEqual(filled.slot.pluginId, 'markgroves.polkit-face', 'enabled chrome plugin fills the face slot')
assertEqual(filled.slot.url, 'file:///plugins/markgroves.polkit-face/FaceCardFrame.js', 'slot url stays inside the plugin dir')
assertEqual(filled.extraSpace, 150, 'filled face slot adds room for the shared face card')
assertEqual(filled.hint, 'Look at the camera', 'first-party face hint stays when the slot paints')
assertEqual(filled.chromeHint, 'Look at the camera', 'the resolved slot keeps the face hint')

const duringError = polkit.cardPresentationFor(faceSteps, false, false, source(plugins, ['markgroves.polkit-face']))
assertEqual(duringError.kind, 'password', 'a miss still shows the password card')
assertEqual(duringError.chromeKind, 'face', 'chrome kind does not follow waitingOnPam')
assertEqual(duringError.slot.pluginId, 'markgroves.polkit-face', 'the face slot stays resolved through the error flash')
assertEqual(duringError.extraSpace, 150, 'geometry does not collapse while the slot stays resolved')
assertEqual(duringError.hint, 'Enter password', 'the password row keeps its own hint')
assertEqual(duringError.chromeHint, 'Look at the camera', 'the held face card keeps the face hint')

assert(polkit.isFaceAuthRequest(filled), 'an open-lid face request is a face scan')
assert(polkit.faceSlotResolved(filled), 'an open-lid face request resolves polkitFace')
assert(polkit.shouldHoldFaceSuccess(filled), 'a face card still showing holds a match')
assert(polkit.shouldNoteFaceMiss(filled, 'scanning'), 'Howdy falling through to a password is a miss')
assert(!polkit.shouldNoteFaceMiss(filled, 'recognized'), 'a match is not a miss')
assert(polkit.isFaceAuthRequest(duringError), 'chromeKind stays face after Howdy asks for a password')
assert(!polkit.shouldHoldFaceSuccess(duringError), 'a typed password is not Face recognized')
assert(polkit.shouldNoteFaceMiss(duringError, 'scanning'), 'the password fall-through still notes the miss')

const passwordOnly = polkit.cardPresentationFor(polkit.pamStepsFromConfig(vendor), true, false, source(plugins, ['markgroves.polkit-face']))
assertEqual(passwordOnly.kind, 'password', 'vendor polkit is a password card')
assert(!polkit.isFaceAuthRequest(passwordOnly), 'an installed face plugin does not make a password prompt a face scan')
assert(!polkit.faceSlotResolved(passwordOnly), 'a password prompt does not resolve polkitFace')
assert(!polkit.shouldHoldFaceSuccess(passwordOnly), 'password success does not hold Face recognized')
assert(!polkit.shouldNoteFaceMiss(passwordOnly, 'scanning'), 'password required is not a face miss')

const closedLid = polkit.cardPresentationFor(faceSteps, true, true, source(plugins, ['markgroves.polkit-face']))
assert(!polkit.isFaceAuthRequest(closedLid), 'a closed lid never ran the face step')
assert(!polkit.shouldHoldFaceSuccess(closedLid), 'closed-lid success is not a face hold')

const fingerprintWaiting = polkit.cardPresentationFor(fingerprintSteps, true, false, source(plugins, ['acme.polkit-fingerprint', 'markgroves.polkit-face']))
assertEqual(fingerprintWaiting.chromeKind, 'fingerprint', 'fingerprint PAM stays on fingerprint chrome')
assert(!polkit.isFaceAuthRequest(fingerprintWaiting), 'a fingerprint prompt is not a face scan')
assert(!polkit.faceSlotResolved(fingerprintWaiting), 'a fingerprint slot is not polkitFace')
assert(!polkit.shouldHoldFaceSuccess(fingerprintWaiting), 'fingerprint success does not hold Face recognized')
assert(!polkit.shouldNoteFaceMiss(fingerprintWaiting, 'scanning'), 'fingerprint asking for a response is not a face miss')

const disabled = polkit.cardPresentationFor(faceSteps, true, false, source(plugins, []))
assertEqual(disabled.slot, null, 'installed but disabled chrome is an empty slot')
assertEqual(disabled.extraSpace, 0, 'empty face slot collapses extra space')
assertEqual(disabled.hint, 'Look at the camera', 'empty face slot keeps the first-party hint')

const missing = polkit.cardPresentationFor(faceSteps, true, false, source({}, []))
assertEqual(missing.slot, null, 'no chrome plugin is the same empty slot as disabled')
assertEqual(missing.extraSpace, 0, 'missing chrome collapses extra space')
assertEqual(missing.hint, 'Look at the camera', 'missing chrome keeps the first-party hint')
assert(polkit.isFaceAuthRequest(missing), 'first-party face with no plugin is still a face request')
assert(!polkit.faceSlotResolved(missing), 'no plugin means no polkitFace slot')
assert(polkit.shouldHoldFaceSuccess(missing), 'the first-party face card can still hold a match')

const failedUrl = 'file:///plugins/markgroves.polkit-face/FaceCardFrame.js'
const broken = polkit.cardPresentationFor(faceSteps, true, false, source(plugins, ['markgroves.polkit-face'], { [failedUrl]: true }))
assertEqual(broken.slot, null, 'a failed Loader url is an empty slot')
assertEqual(broken.extraSpace, 0, 'a failed Loader url collapses extra space')

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

const noKind = polkit.cardPresentationFor(faceSteps, true, false, source({
  'acme.sneaky': { ...facePlugin, kinds: ['overlay'] }
}, ['acme.sneaky']))
assertEqual(noKind.slot, null, 'the extra key without polkit-chrome does not attach')

const passwordSlot = polkit.cardPresentationFor(faceSteps, false, false, source({
  'acme.password': {
    kinds: ['polkit-chrome'],
    entryPoints: { polkitPassword: 'Password.qml' },
    __sourceDir: '/plugins/acme.password'
  }
}, ['acme.password']))
assertEqual(passwordSlot.kind, 'password', 'response-required stays on the password card')
assertEqual(passwordSlot.slot, null, 'password card rejects a chrome plugin')
assertEqual(passwordSlot.extraSpace, 0, 'password card never gains extra space')

const collision = polkit.cardPresentationFor(faceSteps, true, false, source({
  'zeta.face': facePlugin,
  'alpha.face': { ...facePlugin, __sourceDir: '/plugins/alpha.face' }
}, ['zeta.face', 'alpha.face']))
assertEqual(collision.slot.pluginId, 'alpha.face', 'the lower plugin id wins a chrome collision')
assertDeepEqual(collision.slot.shadowed, ['zeta.face'], 'the losing chrome plugin is named')
assertEqual(
  polkit.cardPresentationFor(faceSteps, true, false, source({
    'zeta.face': facePlugin,
    'alpha.face': { ...facePlugin, __sourceDir: '/plugins/alpha.face' }
  }, ['zeta.face', 'alpha.face'])).slot.url,
  collision.slot.url,
  'chrome collision resolution is stable'
)
assertEqual(
  polkit.chromeSlotDiagnostic(collision),
  'polkit chrome: face painted by alpha.face; ignoring zeta.face',
  'collision diagnostic names the winner and the loser'
)
assertEqual(polkit.chromeSlotDiagnostic(disabled), '', 'empty slots are not logged')

const fingerprintFilled = polkit.cardPresentationFor(
  fingerprintSteps,
  true,
  false,
  source(plugins, ['acme.polkit-fingerprint'])
)
assertEqual(fingerprintFilled.slot.pluginId, 'acme.polkit-fingerprint', 'fingerprint slot resolves when declared')
assert(fingerprintFilled.square, 'fingerprint card stays square when a slot paints')
assertEqual(fingerprintFilled.extraSpace, 0, 'fingerprint slot adds no extra space')

const agentQml = fs.readFileSync(path.join(root, 'shell/plugins/polkit/PolkitAgent.qml'), 'utf8')

assert(
  /cardPresentationFor\(pamSteps,\s*waitingOnPam,\s*laptopClosed,\s*slotSource\)/.test(agentQml),
  'polkit agent binds the card from cardPresentationFor'
)
assert(
  /property var pluginRegistry/.test(agentQml),
  'polkit agent declares pluginRegistry so ensureService injects the real registry'
)
assert(
  !/property\s+\S+\s+shell\b/.test(agentQml),
  'polkit agent does not declare shell'
)
assert(
  !/Loader/.test(agentQml) && !/slotLoader/.test(agentQml) && !/FaceScanRing/.test(agentQml),
  'the agent does not load sibling QML into the card'
)
assert(
  !/chromeContext/.test(agentQml),
  'chromeContext is gone: a QtObject parented to the agent root is a walk back to the field'
)
assert(
  /FaceChromeCanvas/.test(agentQml),
  'the agent paints chrome itself through the host canvas'
)
assert(
  /entryPointKey\s*===\s*"polkitFace"/.test(agentQml) && /FaceChrome\.sourceUrl = root\.slotUrl/.test(agentQml),
  'only a face slot may replace the shared face module'
)
assert(
  !/if \(root\.slotUrl !== ""\) FaceChrome\.sourceUrl = root\.slotUrl/.test(agentQml),
  'a non-empty fingerprint slot does not overwrite FaceChrome'
)
assert(
  !/onSlotUrlChanged:\s*FaceChrome\.sourceUrl\s*=\s*root\.slotUrl/.test(agentQml),
  'an empty polkit slot does not unload chrome out from under lock'
)
assert(
  !/item\.chrome/.test(agentQml) && !/item\.flow/.test(agentQml),
  'nothing host-owned is handed to a chrome plugin'
)
assert(
  /id: faceChrome[\s\S]{0,600}?enabled:\s*false/.test(agentQml),
  'the chrome column cannot take focus'
)
assert(
  /function faceResultHoldMs\(/.test(agentQml) && /FaceChrome\.holdMs\(state\)/.test(agentQml),
  'the agent holds a result for as long as the plugin declares'
)
assert(
  /PolkitModel\.shouldHoldFaceSuccess\(presentation\)/.test(agentQml),
  'a match hold requires this request to still be on the face card'
)
assert(
  /PolkitModel\.shouldNoteFaceMiss\(presentation,\s*faceState\)/.test(agentQml),
  'a miss hold requires this request to be a face scan'
)
assert(
  /PolkitModel\.faceSlotResolved\(presentation\)/.test(agentQml),
  'the ready-or-not hold fallback uses this request\'s polkitFace slot'
)
assert(
  !/showFaceChrome \|\| FaceChrome\.sourceUrl/.test(agentQml),
  'an installed face plugin URL is not treated as a face result'
)
assert(
  !/\(!slotPainting && FaceChrome\.sourceUrl === ""\)/.test(agentQml),
  'a global chrome URL does not authorize a miss hold'
)
assert(
  !/!FaceChrome\.ready && FaceChrome\.sourceUrl !== ""/.test(agentQml),
  'the hold fallback does not use the shared FaceChrome URL'
)
assert(
  /function completeFacePlayback\(\)[\s\S]*?closing = true/.test(agentQml) && /onResultPlayed:\s*root\.completeFacePlayback\(\)/.test(agentQml),
  'a held success still closes the dialog after the card plays'
)
assert(
  /function onAuthenticationRequestCancelled\(\) \{\s*root\.resultHold = false/.test(agentQml),
  'cancel clears the success hold without waiting for playback'
)
assert(
  !/successTimer/.test(agentQml) && !/missTimer/.test(agentQml),
  'polkit does not run face holds on wall-clock timers'
)
assert(
  /property bool resultHold/.test(agentQml) && /dialogVisible:.*resultHold/.test(agentQml),
  'an instant match keeps the dialog visible while the card finishes'
)
assert(!polkit.polkitCardVisible(true, true, false), 'a polkit card does not render while the session is locked')
assert(!polkit.polkitCardVisible(true, false, true), 'a request resolved under the lock stays hidden after unlock')
assert(polkit.polkitCardVisible(true, false, false), 'a pending request renders once the session is unlocked')
assert(!polkit.shouldArmFaceHold(true), 'a face result under the lock does not arm a hold')
assert(polkit.shouldArmFaceHold(false), 'a face result on the unlocked session still plays')
assert(polkit.shouldRestartFaceOnUnlock(true, false, true, false), 'a request still pending at unlock starts its card over')
assert(!polkit.shouldRestartFaceOnUnlock(true, false, true, true), 'a request already resolved under the lock does not replay')
assert(!polkit.shouldRestartFaceOnUnlock(true, false, false, false), 'an idle agent does not open a card at unlock')
assert(
  /cardVisible:/.test(agentQml) && /visible:\s*root\.cardVisible/.test(agentQml),
  'the polkit window follows cardVisible, not the raw dialog flag'
)
assert(/LockCover\.covered/.test(agentQml), 'polkit reads the lock cover instead of the shell')
assert(!/property\s+\S+\s+shell\b/.test(agentQml), 'polkit still does not declare shell')
assert(
  /resolvedUnderLock = true/.test(agentQml) && /shouldArmFaceHold\(root\.sessionLocked\)/.test(agentQml),
  'success while locked records the request and does not arm playback'
)
assert(
  /showPasswordRow:.*!root\.resultHold/.test(agentQml),
  'the password row does not replace a held match'
)
assert(
  /Look at the camera/.test(agentQml) === false,
  'the agent still reads the face hint from the model'
)
assert(
  !fs.existsSync(path.join(root, 'shell/plugins/polkit/FaceScanRing.qml')),
  'first-party FaceScanRing is gone'
)

const painter = fs.readFileSync(path.join(root, 'shell/Commons/FaceCardPainter.js'), 'utf8')
assert(
  /function paint\(ctx, size, ops, palette\)/.test(painter),
  'the host owns the painter and takes ops, not a plugin item'
)
assert(
  /MAX_OPS/.test(painter) && /MAX_CMDS/.test(painter) && /isFinite/.test(painter),
  'the painter treats a returned frame as hostile input'
)

const chrome = fs.readFileSync(path.join(root, 'shell/Commons/FaceChrome.qml'), 'utf8')
assert(
  /new Function\(/.test(chrome) && !/\beval\(/.test(chrome),
  'the plugin module is evaluated without capturing local scope'
)
assert(
  /Math\.min\(ms, 2000\)/.test(chrome),
  'a plugin cannot pin a credential dialog open'
)
assert(
  /function bindFromRegistry\(/.test(chrome) && /function urlFromRegistry\(/.test(chrome),
  'FaceChrome discovers an enabled polkitFace module from the registry'
)
assert(
  /property Connections registryConnections/.test(chrome),
  'registry listeners are a property; QtObject has no default child slot'
)
assert(
  /entryPoints\.polkitFace/.test(chrome) && /polkit-chrome/.test(chrome),
  'chrome discovery uses the same kind and slot key as the polkit resolver'
)
const shellQml = fs.readFileSync(path.join(root, 'shell/shell.qml'), 'utf8')
assert(
  /FaceChrome\.pluginRegistry\s*=\s*pluginRegistry/.test(shellQml),
  'the shell binds face chrome at startup so lock does not wait for polkit'
)
JS
