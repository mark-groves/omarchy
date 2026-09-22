#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const playback = requireFromRoot('shell/Commons/FacePlayback.js')
const canvasQml = fs.readFileSync(path.join(root, 'shell/Ui/FaceChromeCanvas.qml'), 'utf8')
const lockQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')
const lockViewQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/LockView.qml'), 'utf8')
const polkitQml = fs.readFileSync(path.join(root, 'shell/plugins/polkit/PolkitAgent.qml'), 'utf8')
const overlayQml = fs.readFileSync(path.join(root, 'shell/plugins/face-overlay/FaceOverlay.qml'), 'utf8')
const chromeQml = fs.readFileSync(path.join(root, 'shell/Commons/FaceChrome.qml'), 'utf8')

assertEqual(playback.presentedStepMs(0.016), 16, 'a normal frame is credited in full')
assertEqual(playback.presentedStepMs(10), playback.maxPresentedStepMs, 'a wake gap is capped at one presented step')
assertEqual(playback.presentedStepMs(0), 0, 'a zero frame credits nothing')
assertEqual(playback.presentedStepMs(-1), 0, 'a negative frame credits nothing')

assertEqual(playback.advancePresented(100, 10, false), 100, 'a hold does not advance while frames are not presented')
assertEqual(playback.advancePresented(0, 10, true), playback.maxPresentedStepMs, 'the first presented frame after wake credits one step')

let elapsed = 0
let steps = 0
while (!playback.resultComplete('recognized', elapsed, 900) && steps < 200) {
  elapsed = playback.advancePresented(elapsed, 10, false)
  steps += 1
}
assertEqual(elapsed, 0, 'a frozen wake cannot finish a recognized hold')
assert(!playback.resultComplete('recognized', elapsed, 900), 'recognized stays incomplete with no presented frames')

elapsed = playback.advancePresented(0, 10, true)
assert(!playback.resultComplete('recognized', elapsed, 900), 'one wake frame does not finish the plugin hold')
let presented = 1
while (!playback.resultComplete('recognized', elapsed, 900) && presented < 200) {
  elapsed = playback.advancePresented(elapsed, 0.016, true)
  presented += 1
}
assert(playback.resultComplete('recognized', elapsed, 900), 'recognized completes once presented time reaches the plugin hold')
assert(presented > 10, 'the hold lasts more than a single presented frame')

assert(playback.resultComplete('notRecognized', 900, 900), 'a miss completes on the same presented hold')
assert(!playback.resultComplete('notRecognized', 899, 900), 'a miss stays up until the hold is reached')
assert(!playback.resultComplete('scanning', 5000, 900), 'scanning is not a held result')
assert(!playback.resultComplete('cancelled', 5000, 900), 'cancelled is not a held result')
assert(!playback.resultComplete('recognized', 5000, 0), 'a plugin hold of zero does not play')
assert(!playback.resultComplete('recognized', Number.NaN, 900), 'a broken elapsed value does not complete the hold')

assertEqual(playback.playbackAction('recognized', true, 900, true), 'play', 'a ready card plays the plugin hold')
assertEqual(playback.playbackAction('notRecognized', true, 1200, true), 'play', 'a miss plays the plugin hold')
assertEqual(playback.playbackAction('recognized', false, 0, true), 'wait', 'chrome that is still loading does not start a clock')
assertEqual(playback.playbackAction('recognized', false, 900, true, false), 'wait', 'a module that has not failed yet still waits for the first frame')
assertEqual(playback.playbackAction('recognized', false, 900, true, true), 'immediate', 'an already-rejected module does not block unlock')
assertEqual(playback.playbackAction('notRecognized', false, 900, true, true), 'immediate', 'an already-rejected module does not block the password row')
assertEqual(playback.playbackAction('recognized', true, 900, true, true), 'play', 'a card that can still paint keeps the presented-frame hold')
assertEqual(playback.playbackAction('recognized', false, 0, false), 'immediate', 'a match with no card does not delay unlock')
assertEqual(playback.playbackAction('recognized', true, 0, true), 'immediate', 'a plugin that asks for no hold does not delay unlock')
assertEqual(playback.playbackAction('scanning', true, 900, true), 'immediate', 'scanning is not a result hold')
assertEqual(playback.playbackAction('cancelled', true, 900, true), 'immediate', 'cancel is not a result hold')

assert(/advancePresented\(root\.elapsed, frameTime, root\.presenting\)/.test(canvasQml), 'the canvas credits only its own presented frames')
assert(/running:\s*root\.presenting/.test(canvasQml), 'the frame clock stops when the canvas is not presenting')
assert(/signal resultPlayed\(\)/.test(canvasQml), 'the canvas tells the surface when the result has played')
assert(/resultLatched/.test(canvasQml), 'a result completes once per cycle')
assert(/playbackEpoch/.test(canvasQml), 'a repeated result starts a new presented cycle')
assert(!/frameTime \* 1000/.test(canvasQml), 'the canvas does not add raw frame-clock gaps')

assert(/FacePlayback\.js/.test(lockQml) && /playbackAction\(/.test(lockQml), 'lock asks the shared rule before holding a PAM result')
assert(/playbackAction\([\s\S]*?FaceChrome\.failure !== ""\)/.test(lockQml), 'lock finishes a hold when chrome has already failed')
assert(/FaceChrome\.failure === ""/.test(lockQml), 'lock keeps waiting only while a load has not failed')
assert(/facePlaybackEpoch/.test(lockViewQml) && /onResultPlayed:\s*root\.faceResultPlayed\(\)/.test(lockViewQml), 'the lock card forwards the canvas completion')
assert(/active:\s*!root\.displaysBlank/.test(lockViewQml), 'the lock card does not present while the panel is blank')

assert(/FacePlayback\.js/.test(polkitQml) && /armFacePlayback\(/.test(polkitQml), 'polkit asks the shared rule before holding a PAM result')
assert(/playbackAction\([\s\S]*?FaceChrome\.failure !== ""\)/.test(polkitQml), 'polkit finishes a hold when chrome has already failed')
assert(/faceSlotResolved\(presentation\)/.test(polkitQml), 'polkit waits on this request\'s face slot, not the shared chrome URL')
assert(!/!FaceChrome\.ready && FaceChrome\.sourceUrl/.test(polkitQml), 'polkit does not treat the shared chrome URL as this request')
assert(/visible:\s*parent\.visible/.test(polkitQml), 'the polkit card does not present while its column is hidden')

const apply = overlayQml.match(/function applySignal\(next\) \{[\s\S]*?\n  \}/)
assert(apply, 'overlay has applySignal')
assert(apply[0].indexOf('isHideState') < apply[0].indexOf('awaitingPlayback'), 'cancel hides before any result hold is armed')
assert(/playbackEpoch/.test(overlayQml) && /onResultPlayed:/.test(overlayQml), 'the sudo overlay plays a result through the shared canvas')

const finishFailed = overlayQml.match(/function finishHoldIfChromeFailed\(state\) \{[\s\S]*?\n  \}/)
assert(finishFailed, 'overlay can finish a hold when chrome has failed')
assert(/FaceChrome\.failure === ""/.test(finishFailed[0]) && /hideCard\(\)/.test(finishFailed[0]), 'a rejected module hides the overlay instead of waiting for resultPlayed')
assert(/awaitingPlayback/.test(finishFailed[0]), 'a rejection during an armed result hold still hides the overlay')
assert(/finishHoldIfChromeFailed\(next\.state\)/.test(apply[0]), 'a result that arrives after chrome failed hides the overlay')
assert(/finishHoldIfChromeFailed\(pendingState\)/.test(overlayQml), 'a revision that records a failure finishes an armed overlay hold')

const sourceChanged = chromeQml.match(/onSourceUrlChanged: \{[\s\S]*?\n  \}/)
assert(sourceChanged && /api = null[\s\S]*revision\+\+/.test(sourceChanged[0]), 'clearing or swapping the chrome source emits a revision so armed holds re-check')
assert(/if \(FaceChrome\.sourceUrl !== "" && FaceChrome\.failure === ""\) return/.test(lockQml), 'lock finishes a hold whose chrome source was cleared')
assert(/expected && FaceChrome\.sourceUrl !== "" && FaceChrome\.failure === ""/.test(polkitQml), 'polkit finishes a hold whose chrome source was cleared')
assert(/awaitingPlayback && FaceChrome\.sourceUrl === ""/.test(finishFailed[0]), 'a cleared chrome source hides an armed overlay hold')
JS
