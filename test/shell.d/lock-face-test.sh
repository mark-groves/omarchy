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
  /wasClosed/.test(lidHandler[0]) && /else if \(wasClosed && root\.lockRequested\)/.test(lidHandler[0]),
  'an already-open lid poll does not start a new Howdy scan'
)
assert(
  /root\.handleResume\("lid-open"\)/.test(lidHandler[0]),
  'opening the lid goes through the shared resume path'
)
const settle = serviceQml.match(/id:\s*resumeSettleTimer[\s\S]*?onTriggered:\s*\{[\s\S]*?\n    \}/)
assert(settle, 'lock has a resume settle timer')
assert(
  /if \(root\.faceConfigured\) root\.startFace\(\)/.test(settle[0]),
  'a resume starts a face scan only when face is configured'
)
assert(
  /root\.runWake\(\)/.test(settle[0]) && /resumePresentTimer\.restart\(\)/.test(settle[0]) &&
    /resumeWakeRetryTimer\.restart\(\)/.test(settle[0]),
  'the settled resume wakes the panel, keeps committing lock buffers, and wakes it once more later'
)
assert(
  /function runWake\(\) \{[\s\S]*?root\.rearmLockPresentation\(\)/.test(serviceQml),
  'every wake commits a new lock buffer, including a resume without a lid or output change'
)
assert(
  /onWakeRequested:\s*root\.runWake\(\)/.test(serviceQml),
  'a pointer or key wake goes through runWake'
)
const resume = serviceQml.match(/function handleResume\(why\) \{[\s\S]*?\n  \}/)
assert(resume, 'lock has handleResume')
assert(
  !/runWake\(\)/.test(resume[0]) && /resumeSettleTimer\.restart\(\)/.test(resume[0]),
  'the first tick after a suspend does not wake the panel: a DPMS request then is lost in the compositor DRM restore'
)
assert(
  /function requestWake\(\) \{\s*if \(wakeProcess\.running\) wakeProcess\.again = true/.test(serviceQml) &&
    /id:\s*wakeProcess[\s\S]*?onExited:[\s\S]*?wakeProcess\.running = true/.test(serviceQml) &&
    !/if \(!wakeProcess\.running\) wakeProcess\.running = true/.test(serviceQml),
  'a wake asked for while one runs is queued, so keys and clicks during a stalled wake are not dropped'
)
assert(
  /function holdFaceForSleep\(\) \{[\s\S]*?idleBlankTimer\.stop\(\)/.test(serviceQml) &&
    /if \(sleepResumeWatch\.running \|\| root\.laptopClosed\) return\s*\n\s*if \(root\.lockRequested && !root\.authenticatingPassword/.test(serviceQml),
  'the panel is not blanked once a suspend is announced or while the lid is shut, so it is still on at resume'
)
assert(
  /root\.runWake\(\)\s*\n\s*root\.nudgePointer\(\)/.test(settle[0]) &&
    /id:\s*pointerNudgeProcess[\s\S]*?hl\.dsp\.cursor\.move\(\{ x = \$\(\(x \+ 1\)\)[\s\S]*?hl\.dsp\.cursor\.move\(\{ x = \$x, y = \$y \}\)/.test(serviceQml),
  'a settled resume moves the pointer a pixel and back, the nudge that unfreezes the lock surface'
)
const ceiling = serviceQml.match(/id:\s*faceUnlockCeiling[\s\S]*?onTriggered:\s*\{[\s\S]*?\n    \}/)
assert(
  ceiling && /root\.faceState !== "recognized"/.test(ceiling[0]) && /root\.completeFacePlayback\(\)/.test(ceiling[0]) &&
    /faceUnlockCeiling\.interval = Math\.max\(1, Playback\.presentedCeilingMs\(FaceChrome\.holdMs\(state\)\)/.test(serviceQml),
  'a recognised match unlocks within one presented hold of wall time even when the surface is not presenting'
)
assert(
  /refreshLidState\(\)/.test(resume[0]),
  'a resume reads the lid at once instead of waiting for the next poll'
)
assert(
  /if \(faceAwaitingResume \|\| resumeSettleTimer\.running\) return/.test(serviceQml),
  'no scan starts between a suspend being announced and the resume settling'
)

// Lid close: the lock and the suspend land together. A scan that froze
// inside the suspend failed on resume with the camera still gone, and that
// failure played as a miss on a surface that was not presenting yet.
const sleepHold = serviceQml.match(/function holdFaceForSleep\(\) \{[\s\S]*?\n  \}/)
assert(sleepHold, 'lock has holdFaceForSleep')
assert(
  /faceAwaitingResume = true/.test(sleepHold[0]) && /facePam\.abort\(\)/.test(sleepHold[0]) &&
    /faceAuthenticating = false/.test(sleepHold[0]),
  'an announced suspend drops the in-flight scan and holds new ones'
)
assert(
  /function noteSleepRequested\(\) \{\s*if \(!lockRequested\) return\s*holdFaceForSleep\(\)/.test(serviceQml),
  'every pre-suspend lock request holds face, with or without a fingerprint reader'
)
const watch = serviceQml.match(/id:\s*sleepResumeWatch[\s\S]*?onTriggered:\s*\{[\s\S]*?\n    \}/)
assert(
  watch && /root\.handleResume\("sleep"\)/.test(watch[0]) && /faceAwaitingResume = false/.test(watch[0]),
  'the wall-clock jump after a suspend resumes face, and a sleep that never comes releases it'
)

// A fast match used to cut straight from a barely started scan to the
// result. PAM's answer waits, display-only, for the plugin's scanMs() (its
// boot) or a ceiling.
const finished = serviceQml.match(/function handleFaceFinished\([\s\S]*?\n  \}/)
assert(
  finished && /if \(!faceScanSeen && scanMs > 0 && faceConfigured && !fingerprintConfigured\) \{[\s\S]*?facePendingMatch = true[\s\S]*?faceMatchWaitTimer\.restart\(\)/.test(finished[0]),
  'a match that beats the scan waits for the scan to play before the recognised card'
)
assert(
  /onFaceScanShown:\s*root\.noteFaceScanShown\(\)/.test(serviceQml) &&
    /function noteFaceScanShown\(\) \{\s*faceScanSeen = true\s*if \(facePendingMatch\) playFaceMatch\(\)/.test(serviceQml),
  'the card reports when its scan has presented, and a waiting match plays then'
)
const matchWait = serviceQml.match(/id:\s*faceMatchWaitTimer[\s\S]*?onTriggered:\s*\{[\s\S]*?\n    \}/)
assert(
  matchWait && /root\.playFaceMatch\(\)/.test(matchWait[0]) && /faceMatchWaitTimer\.interval = scanMs \+ 1500/.test(serviceQml),
  'a card that never finishes its scan cannot hold an approved unlock past a wall-clock ceiling'
)
assert(/if \(facePendingMatch\) return/.test(serviceQml), 'no new scan starts over a match that is waiting to play')
assert(
  /root\.faceScanSeen = false\s*\n\s*root\.facePlaybackEpoch \+= 1/.test(settle[0]),
  'a resume replays the scan from its boot instead of counting what played before the suspend'
)
assert(
  /onScanShown:\s*root\.faceScanShown\(\)/.test(viewQml),
  'the lock view forwards the card scan signal'
)

const quiet = serviceQml.match(/function retryFaceQuietly\(\) \{[\s\S]*?\n  \}/)
assert(quiet, 'lock has retryFaceQuietly')
assert(
  /took >= faceNoLookMs && took <= faceSpannedSleepMs/.test(quiet[0]) &&
    /faceQuietRetries >= faceQuietRetryLimit/.test(quiet[0]) &&
    /faceState = "scanning"/.test(quiet[0]),
  'a failure too fast to be a look, or one that spanned a suspend, retries under the scan card a bounded number of times'
)
const unmatched = serviceQml.match(/function releaseUnmatchedFace\(\) \{[\s\S]*?\n  \}/)
assert(
  unmatched && /if \(root\.retryFaceQuietly\(\)\) return[\s\S]*holdFaceResult\("notRecognized"\)/.test(unmatched[0]),
  'only a real miss plays the not-recognised card'
)
assert(
  /LockCover\.covered = locked/.test(serviceQml),
  'lock publishes the session cover for polkit without handing over the shell'
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
const playMatch = serviceQml.match(/function playFaceMatch\(\) \{[\s\S]*?\n  \}/)
assert(
  /root\.playFaceMatch\(\)/.test(faceFinished[0]) && playMatch && /holdFaceResult\("recognized"\)/.test(playMatch[0]),
  'a match holds the recognised frame for as long as the plugin declares'
)
assert(
  /if \(root\.holdFaceResult\("recognized"\)\) return\s*\n\s*finishUnlock\(\)/.test(playMatch[0]),
  'with no card to play a match still unlocks immediately'
)
assert(
  /function completeFacePlayback\(\)[\s\S]*?finishUnlock\(\)/.test(serviceQml),
  'a played-out match ends in an unlock'
)
assert(
  /releaseUnmatchedFace\(\)/.test(faceFinished[0]) && /holdFaceResult\("notRecognized"\)/.test(serviceQml),
  'a miss holds the not-recognised frame for as long as the plugin declares'
)
assert(
  /faceScanning:\s*root\.faceAuthenticating \|\| root\.faceHolding/.test(serviceQml),
  'the lock canvas keeps animating while a result is held'
)
assert(
  /if \(faceHolding\) return/.test(serviceQml),
  'a new scan does not cancel a result that is still playing'
)
assert(
  /onFaceResultPlayed:\s*root\.completeFacePlayback\(\)/.test(serviceQml),
  'lock completes the hold from the canvas, after frames have been presented'
)
assert(
  !/faceHoldTimer/.test(serviceQml) && !/faceMissHoldTimer/.test(serviceQml),
  'lock does not run the face hold on a wall-clock timer; only the recognised unlock has a ceiling'
)

const teardown = serviceQml.match(/function resetAuthenticationState\(\) \{[\s\S]*?\n  \}/)
assert(
  teardown && /faceHolding = false/.test(teardown[0]) && /faceRetryTimer\.stop\(\)/.test(teardown[0]),
  'tearing the lock down clears a display hold so it cannot unlock later'
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
  /width:\s*Style\.space\(FaceChrome\.cardSide\)/.test(viewQml),
  'the lock card is the shared large card size, not the 26 px in-field glyph slot'
)
assert(
  /face\.lookAtTheCamera/.test(viewQml) && /face\.orTypeYourPassword/.test(viewQml),
  'the lock card keeps the scan hint and the password fallback'
)
assert(
  /id: faceIcon[\s\S]*?visible:[\s\S]{0,200}?\(root\.faceRequestAvailable \|\| \(root\.faceCardActive && !root\.faceCardPainting\)\)/.test(viewQml),
  'the glyph is the face button while face can be asked for, and yields to the card once it paints'
)

// On request (the default) the camera stays off and the card hidden until
// the user asks: the face button, or Space / Enter on an empty field.
assert(
  /readonly property bool faceOnRequest: String\(lockConfig\.face \|\| "request"\) !== "automatic"/.test(serviceQml),
  'lock.face defaults to on request; only "automatic" scans by itself'
)
assert(
  /function startFace\(\) \{\s*if \(!lockRequested \|\| !sessionLock\.secure \|\| !faceConfigured\) return\s*if \(faceOnRequest && !faceRequested\) return/.test(serviceQml),
  'no scan starts on request until the user has asked'
)
const request = serviceQml.match(/function requestFace\(\) \{[\s\S]*?\n  \}/)
assert(
  request && /faceRequested = true/.test(request[0]) && /facePlaybackEpoch \+= 1/.test(request[0]) && /startFace\(\)/.test(request[0]),
  'asking for face starts a fresh scan cycle'
)
const cancel = serviceQml.match(/function cancelFaceRequest\(why\) \{[\s\S]*?\n  \}/)
assert(
  cancel && /if \(faceHolding \|\| facePendingMatch\) return/.test(cancel[0]) && /facePam\.abort\(\)/.test(cancel[0]) && /faceRequested = false/.test(cancel[0]),
  'cancelling stops the scan but never withdraws an approved match'
)
assert(
  /if \(password\.length > 0\) root\.cancelFaceRequest\("typing"\)/.test(serviceQml) &&
    /function runBlank\(\) \{\s*root\.displaysBlank = true\s*cancelFaceRequest\("blank"\)/.test(serviceQml) &&
    /function holdFaceForSleep\(\) \{\s*cancelFaceRequest\("sleep"\)/.test(serviceQml),
  'typing, a blank or a suspend take the scan back'
)
assert(
  /On request, a miss hands back to the button[\s\S]*?if \(faceOnRequest\) \{\s*faceRequested = false\s*return/.test(serviceQml),
  'on request a miss hands back to the face button instead of retrying'
)
assert(
  /readonly property bool faceCardPainting: faceConfigured && !fingerprintConfigured && FaceChrome\.ready && faceCardActive/.test(viewQml),
  'the card is hidden until the service says it belongs on screen'
)
assert(
  /id: faceIcon[\s\S]*?text: String\.fromCodePoint\(0xF0C7B\)/.test(viewQml),
  'the face button is the face-recognition mark, not an eye'
)
assert(
  /objectName:\s*"faceButton"[\s\S]*?enabled:\s*root\.faceRequestAvailable[\s\S]*?onClicked:\s*\{\s*root\.faceRequested\(\)/.test(viewQml),
  'the face glyph is a button that asks for a scan'
)
assert(
  /root\.faceRequestAvailable && passwordInput\.text\.length === 0\s*&& \(event\.key === Qt\.Key_Space \|\| event\.key === Qt\.Key_Return \|\| event\.key === Qt\.Key_Enter\)/.test(viewQml),
  'Space or Enter on an empty field asks for a scan'
)
assert(
  /objectName:\s*"faceRequestHint"[\s\S]*?face\.requestHint/.test(viewQml),
  'a hint under the field says how to start face unlock'
)
assert(
  /opacity: root\.faceCardRevealed \? 1 : 0/.test(viewQml) &&
    /onCyclePresentedChanged: if \(cyclePresented && glassLit\) root\.faceCardRevealed = true/.test(viewQml),
  'the card fades in on its first presented frame, so a stuck frame is never shown'
)
assert(
  /onFaceRequested:\s*root\.requestFace\(\)/.test(serviceQml) && /onFaceCancelRequested:\s*root\.cancelFaceRequest\("escape"\)/.test(serviceQml),
  'the lock surface wires the button, shortcut and Esc to the service'
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
  !/chrome\s*=/.test(viewQml) &&
    !/source:\s*FaceChrome/.test(viewQml) &&
    !/FaceChromeCanvas[\s\S]{0,80}Loader/.test(viewQml),
  'lock never loads a plugin Item next to its password field'
)
assert(
  /id:\s*feedLoader/.test(viewQml) && /source:\s*"LockFeedSurface\.qml"/.test(viewQml),
  'the lock Loader is the isolated OWE video feed, not face chrome'
)
assert(
  /faceScanning:\s*root\.previewVisible\s*&&\s*root\.faceConfigured/.test(serviceQml),
  'lock preview keeps the scan animation running only while the preview is shown'
)
JS
