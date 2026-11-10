import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "PolkitModel.js" as PolkitModel
import "../../Commons/FacePlayback.js" as Playback

// One polkit request at a time: the flow it came on, the face lane
// (PolkitModel.faceLaneStep), the field's submit rules and the cards' state.
// PolkitAgent.qml feeds it Quickshell's flows; the display-only preview feeds
// it a FakeFlow instead and draws it in a window that takes no input. Both
// go through the same code, so a preview shows what a request would.
Item {
  id: root
  visible: false

  // ---- From PolkitAgent.qml ------------------------------------------------
  property var pluginRegistry: null
  // Quickshell's PolkitAgent.isActive.
  property bool agentActive: false
  property string pamPath: "/etc/pam.d/polkit-1"

  // Each card registers itself (PolkitCard.qml).
  property Item realCard: null
  property Item previewCard: null

  // ---- The flow ------------------------------------------------------------
  // Captured when the request starts. Quickshell drops polkitAgent.flow as a
  // request completes and emits authenticationSucceeded only after that, so
  // a card following polkitAgent.flow lost the success signal.
  property QtObject trackedFlow: null
  property bool previewing: false
  readonly property QtObject flow: previewing ? fakeFlow : trackedFlow
  readonly property bool flowLive: !!root.flow && !root.flow.isCompleted
  // Bumped for every request and preview, so a deferred callback for one
  // never lands on the next.
  property int requestSerial: 0
  // A request has started and the card waits for the lid check, which
  // decides its layout, before it shows: the layout never changes after.
  property bool starting: false

  property string currentMessage: ""
  property string currentPrompt: ""
  property string currentSupplementary: ""
  property bool responseRequired: false
  property bool responseVisible: false
  property bool failed: false

  // ---- The lane and its effects ---------------------------------------------
  property var lane: PolkitModel.faceLaneInitial()
  property bool errorFlash: false
  property int shakeOffset: 0

  property string previewScenario: ""
  property int previewScanMs: 0
  // The preview's typed scenario: a count of dots, never text.
  property int previewDots: 0
  // The preview window is built on first use and kept.
  property bool previewLoaded: false

  // When the field took keyboard focus for the prompt on screen, in ms; 0
  // while it has not. An empty answer counts only once this is old enough
  // (PolkitModel.emptySubmitArmed). Each prompt rearms it: Quickshell clears
  // isResponseRequired on submit and sets it again for the next prompt,
  // including the one a new session asks after a miss.
  property real emptySubmitArmedAt: 0
  readonly property bool promptFieldFocused: !root.previewing && !!root.realCard && root.realCard.fieldFocused
    && root.responseRequired && root.cardVisible
  onPromptFieldFocusedChanged: rearmEmptySubmit()

  // LockCover is a host singleton the lock service writes. Polkit does not
  // take a shell property: that injection is the host, and this plugin owns
  // the password field.
  readonly property bool sessionLocked: LockCover.covered
  // Set when a request finishes while the session lock is covering this card.
  // Unlock must not reveal a prompt that already completed underneath it.
  property bool resolvedUnderLock: false

  property var failedSlotUrls: ({})
  property int failedSlotRevision: 0
  property string lastChromeLog: ""
  property string pamRaw: ""
  property bool laptopClosed: false

  readonly property bool dialogVisible: root.starting || root.lane.phase !== "closed"
  readonly property bool cardVisible: PolkitModel.polkitCardVisible(dialogVisible, sessionLocked, resolvedUnderLock)
  readonly property bool realShown: root.cardVisible && !root.previewing
  readonly property bool previewShown: root.cardVisible && root.previewing
  // Exclusive only while a real request can still take an answer. Once PAM
  // has approved, or the card is leaving, what is left is display only.
  readonly property bool wantsKeyboard: root.realShown && root.flowLive && PolkitModel.faceLaneWantsKeyboard(root.lane)
  readonly property bool realBusy: root.agentActive || root.starting || (!root.previewing && root.lane.phase !== "closed")

  readonly property var pamSteps: PolkitModel.pamStepsFromConfig(pamRaw)
  readonly property bool waitingOnPam: dialogVisible && !responseRequired && root.lane.pending === "" && !errorFlash
  readonly property int registryRevision: root.pluginRegistry ? root.pluginRegistry.registryRevision : 0
  readonly property var slotSource: ({
    registry: root.pluginRegistry,
    revision: root.registryRevision,
    failedUrls: root.failedSlotUrls,
    failedRevision: root.failedSlotRevision
  })
  readonly property var presentation: PolkitModel.cardPresentationFor(pamSteps, waitingOnPam, laptopClosed, slotSource)
  readonly property string slotUrl: presentation && presentation.slot ? presentation.slot.url : ""

  readonly property string surfaceName: root.previewing ? "polkit-preview" : "polkit"
  readonly property string windowName: root.previewing ? "omarchy-polkit-preview" : "omarchy-polkit"

  onSlotUrlChanged: {
    // FaceChrome is the face module. An empty slot is a missing dialog.
    // A fingerprint slot is a different entry point. Either write would
    // drop the shared face module out from under the lock screen.
    if (root.slotUrl !== "" && presentation && presentation.slot
        && presentation.slot.entryPointKey === "polkitFace") {
      FaceChrome.sourceUrl = root.slotUrl
    }
  }

  onRegistryRevisionChanged: {
    if (failedSlotRevision === registryRevision) return
    failedSlotUrls = ({})
    failedSlotRevision = registryRevision
  }

  onPresentationChanged: {
    var line = PolkitModel.chromeSlotDiagnostic(presentation)
    if (!line || !presentation || !presentation.slot) return
    var key = presentation.slot.pluginId + "@" + presentation.slot.revision
    if (key === lastChromeLog) return
    lastChromeLog = key
    console.log(line)
  }

  function authorizationLabel(message) {
    return message ? PolkitModel.authorizationLabel(message, I18n.t) : I18n.t("polkit.authenticationNeeded")
  }

  function noteSlotFailure(url) {
    var key = String(url || "")
    if (!key || (root.failedSlotUrls && root.failedSlotUrls[key])) return
    var next = {}
    var existing
    for (existing in root.failedSlotUrls) next[existing] = root.failedSlotUrls[existing]
    next[key] = true
    root.failedSlotUrls = next
    root.failedSlotRevision = root.registryRevision
    console.warn("polkit chrome failed to load, keeping first-party card:", key)
  }

  function loadPamConfig(raw) {
    pamRaw = String(raw || "")
  }

  function refreshLidState() {
    if (!laptopClosedProc.running) laptopClosedProc.running = true
  }

  // What the face card can play now. FaceChrome.sourceUrl is shared with the
  // lock and set whenever a face plugin is installed, so only this request's
  // resolved polkitFace slot says a face card is expected; the preview
  // always draws the installed one.
  function faceEnv() {
    var expected = root.previewing ? FaceChrome.sourceUrl !== "" : PolkitModel.faceSlotResolved(presentation)
    // A cleared source never loads or fails, so a hold does not wait on it.
    var waits = expected && FaceChrome.sourceUrl !== "" && FaceChrome.failure === ""
    return {
      locked: !PolkitModel.shouldArmFaceHold(root.sessionLocked),
      ready: FaceChrome.ready,
      scanMs: FaceChrome.ready ? FaceChrome.scanMs() : 0,
      recognized: Playback.playbackAction("recognized", FaceChrome.ready, FaceChrome.holdMs("recognized"), waits, FaceChrome.failure !== ""),
      notRecognized: Playback.playbackAction("notRecognized", FaceChrome.ready, FaceChrome.holdMs("notRecognized"), waits, FaceChrome.failure !== "")
    }
  }

  function dispatch(event) {
    var before = root.lane
    var env = root.faceEnv()
    var after = PolkitModel.faceLaneStep(before, event, env)
    if (PolkitModel.sameLane(before, after)) return
    root.lane = after
    root.noteProbe(false)

    if (after.wrong !== before.wrong) root.showWrong()
    if (after.pendingMatch !== before.pendingMatch) {
      if (after.pendingMatch) {
        // Bounds the wait for the scan in wall time, so a card that is not
        // presenting never keeps an approved dialog up.
        faceMatchWait.interval = env.scanMs + 1500
        faceMatchWait.restart()
      } else {
        faceMatchWait.stop()
      }
    }
    if (before.phase === "open" && after.phase !== "open" && root.sessionLocked) root.resolvedUnderLock = true
    if (before.faceState !== "idle" && after.faceState === "idle" && after.phase === "open") Qt.callLater(root.refocus)
    if (before.phase !== "closed" && after.phase === "closed") root.finishClose()
  }

  // ---- Probe lines -------------------------------------------------------
  //
  // One face-probe-event line per state the card shows, for the recording
  // harness to line frames up with: the state, when, and where the card is
  // in its window.
  property string probeState: "hidden"
  property var probeLog: []

  function rectJson(r) {
    return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) }
  }

  function activeCard() {
    return root.previewing ? root.previewCard : root.realCard
  }

  function noteProbe(force) {
    var state = PolkitModel.faceLaneProbeState(root.lane)
    if (state === root.probeState && !force) return
    root.probeState = state
    var card = root.activeCard()
    var line = {
      surface: root.surfaceName,
      state: state,
      t: Date.now(),
      rect: root.rectJson(card ? card.cardRect() : Qt.rect(0, 0, 0, 0)),
      window: root.windowName,
      part: "card"
    }
    var log = root.probeLog.slice(-15)
    log.push({ state: state, t: line.t })
    root.probeLog = log
    console.log("face-probe-event " + JSON.stringify(line))
  }

  // ---- Flow mirror ------------------------------------------------------------

  function resetSnapshot() {
    currentMessage = ""
    currentPrompt = ""
    currentSupplementary = ""
    responseRequired = false
    responseVisible = false
    failed = false
    if (root.realCard) root.realCard.clearField()
  }

  function syncFromFlow() {
    var flow = root.flow
    if (!flow) return
    currentMessage = String(flow.message || "")
    currentPrompt = String(flow.inputPrompt || "")
    currentSupplementary = String(flow.supplementaryMessage || "")
    responseRequired = !!flow.isResponseRequired
    responseVisible = !!flow.responseVisible
    failed = !!flow.failed
  }

  // Drops whatever the last request or preview left, without an exit.
  function resetLane() {
    faceMatchWait.stop()
    errorTimer.stop()
    shakeAnimation.stop()
    lidWait.stop()
    root.errorFlash = false
    root.shakeOffset = 0
    root.previewDots = 0
    var closed = PolkitModel.faceLaneInitial()
    closed.epoch = root.lane.epoch
    root.lane = closed
    root.resetSnapshot()
  }

  function finishClose() {
    faceMatchWait.stop()
    errorTimer.stop()
    shakeAnimation.stop()
    root.errorFlash = false
    root.shakeOffset = 0
    root.resetSnapshot()
    if (root.previewing) {
      fakeFlow.stop()
      root.previewing = false
      root.previewDots = 0
    }
  }

  // ---- A real request --------------------------------------------------------

  function beginRealFlow(flow) {
    if (root.previewing) root.stopPreview()
    root.requestSerial += 1
    // Starting before the reset, so a card still up from the request before
    // (Quickshell starts a queued one as the last completes) keeps its window
    // mapped: dialogVisible never reads false in between.
    root.starting = true
    root.resetLane()
    root.trackedFlow = flow
    root.resolvedUnderLock = false
    root.probeLog = []
    root.syncFromFlow()
    root.refreshLidState()
    lidWait.restart()
    // A new request is a new prompt, even when the field kept focus from
    // the one before it.
    root.rearmEmptySubmit()
    Qt.callLater(root.refocus)
  }

  // The lid check came back (or took too long): open the card in the layout
  // the stack and the lid call for, and keep it for the whole request.
  function lidSettled() {
    lidWait.stop()
    if (!root.starting) return
    // The lane opens before starting clears. The other way round,
    // dialogVisible reads false for a moment and the window unmaps and maps
    // again, taking the keyboard with it, just as the card fades in.
    var opening = root.flowLive && !root.previewing
    if (opening) {
      root.dispatch({
        type: "open",
        trigger: PolkitModel.faceLaneTriggerFor(root.pamSteps, root.laptopClosed),
        prompt: root.responseRequired
      })
    }
    root.starting = false
    if (!opening) return
    root.rearmEmptySubmit()
    Qt.callLater(root.refocus)
  }

  function noteRealFlowGone() {
    if (!root.previewing) root.noteFlowEnded()
  }

  // The flow has ended. Success and cancel signals all land before this
  // runs, so a result still to play is never cut short.
  function noteFlowEnded() {
    var serial = root.requestSerial
    Qt.callLater(function() {
      if (serial !== root.requestSerial) return
      if (root.starting) root.lidSettled()
      root.dispatch({ type: "ended" })
    })
  }

  onFlowChanged: if (!root.flow && root.lane.phase === "open") root.noteFlowEnded()

  function rearmEmptySubmit() {
    emptySubmitArmedAt = promptFieldFocused ? Date.now() : 0
  }

  function refocus() {
    if (root.previewing || !root.realCard) return
    // dialogVisible stays true while the card is hidden under the lock.
    // Focusing then does not stick, so wait until the window is shown.
    if (!root.cardVisible) return
    if (root.realCard.showField && root.lane.pending === "") root.realCard.focusField()
    else root.realCard.focusCatcher()
  }

  // Every Enter, from the field or from the card, arrives here with its
  // autorepeat flag. A typed answer goes through as before. An empty one
  // starts a face scan on an Ask first stack, so it is dropped until armed,
  // and an Automatic stack never sends one.
  function submitResponse(isAutoRepeat) {
    if (root.previewing || !root.realCard) return
    var flow = root.trackedFlow
    if (!flow || !flow.isResponseRequired) return
    if (root.starting) root.lidSettled()
    // Approved, cancelled or leaving: a key that beat the keyboard's release
    // answers nothing.
    if (root.lane.phase !== "open" || root.lane.outcome !== "") return
    // PAM is asking, whether or not the lane heard it.
    if (!root.lane.prompt) root.dispatch({ type: "prompt" })
    if (root.realCard.fieldEmpty) {
      if (!PolkitModel.emptySubmitArmed(root.emptySubmitArmedAt, Date.now(), isAutoRepeat)) {
        // Date.now() is the wall clock. Should it step back past the arm, start
        // the arm again from now rather than hold empty Enter shut until the
        // clock catches up.
        if (Date.now() < root.emptySubmitArmedAt) rearmEmptySubmit()
        return
      }
      if (!PolkitModel.faceLaneAcceptsEmpty(root.lane)) return
      // The scan starts with this answer, so the card shows it from this
      // frame, before PAM has read the answer.
      root.dispatch({ type: "submitEmpty" })
      root.errorFlash = false
      flow.submit("")
    } else {
      var answer = root.realCard.takeAnswer()
      root.dispatch({ type: "submitTyped" })
      root.errorFlash = false
      flow.submit(answer)
    }
    root.realCard.focusCatcher()
  }

  function cancelRequest() {
    if (root.previewing) return
    if (root.starting) root.lidSettled()
    var flow = root.trackedFlow
    if (root.realCard) root.realCard.clearField()
    root.dispatch({ type: "cancelled" })
    if (flow && !flow.isCompleted) flow.cancelAuthenticationRequest()
  }

  function showWrong() {
    root.errorFlash = true
    if (root.realCard && !root.previewing) root.realCard.clearField()
    errorTimer.restart()
    shakeAnimation.restart()
    Qt.callLater(root.refocus)
  }

  // The face card's callbacks, from whichever card is on screen.
  function cardScanShown() {
    root.dispatch({ type: "scanShown" })
  }

  function cardResultPlayed() {
    root.dispatch({ type: "resultPlayed" })
  }

  function cardExitFinished() {
    root.dispatch({ type: "closed" })
  }

  // ---- The preview -------------------------------------------------------------

  function startPreview(spec) {
    var parsed = PolkitModel.parsePreviewSpec(spec)
    if (!parsed) return "unknown scenario: use match, miss, typed or cancel, then a scan time in ms or \"\""
    // A real request owns the card, and the lock covers everything.
    if (root.realBusy) return "busy"
    if (root.sessionLocked) return "locked"
    if (root.previewing) root.stopPreview()
    root.requestSerial += 1
    root.resetLane()
    root.resolvedUnderLock = false
    root.probeLog = []
    root.previewLoaded = true
    root.previewScenario = parsed.scenario
    root.previewScanMs = parsed.scanMs
    root.previewing = true
    fakeFlow.start(parsed.scenario, parsed.scanMs)
    root.syncFromFlow()
    // The preview is always the Ask first card a face stack would show.
    root.dispatch({ type: "open", trigger: "ask", prompt: false })
    return "ok"
  }

  function stopPreview() {
    if (!root.previewing) return
    fakeFlow.stop()
    root.resetLane()
    root.noteProbe(false)
    root.previewing = false
  }

  // The scripted user. Nothing here reads a field: the preview has none.
  function previewUserAction(kind) {
    if (!root.previewing || root.flow !== fakeFlow) return
    if (kind === "type") {
      root.previewDots += 1
      return
    }
    if (kind === "cancel") {
      root.dispatch({ type: "cancelled" })
      fakeFlow.cancelAuthenticationRequest()
      return
    }
    if (!fakeFlow.isResponseRequired) return
    if (kind === "submitEmpty") {
      root.dispatch({ type: "submitEmpty" })
      fakeFlow.submit()
    } else if (kind === "submitTyped") {
      root.previewDots = 0
      root.dispatch({ type: "submitTyped" })
      fakeFlow.submit()
    }
  }

  function statusJson() {
    var card = root.activeCard()
    return JSON.stringify({
      surface: root.surfaceName,
      window: root.windowName,
      previewing: root.previewing,
      scenario: root.previewing ? root.previewScenario : "",
      scanMs: root.previewing ? root.previewScanMs : 0,
      visible: root.cardVisible,
      starting: root.starting,
      phase: root.lane.phase,
      faceState: root.lane.faceState,
      trigger: root.lane.trigger,
      prompt: root.lane.prompt,
      pending: root.lane.pending,
      hold: root.lane.hold,
      pendingMatch: root.lane.pendingMatch,
      retry: root.lane.retry,
      outcome: root.lane.outcome,
      keyboard: root.wantsKeyboard ? "exclusive" : "none",
      rect: root.rectJson(card ? card.cardRect() : Qt.rect(0, 0, 0, 0)),
      faceRect: root.rectJson(card ? card.faceRect() : Qt.rect(0, 0, 0, 0)),
      t: Date.now(),
      events: root.probeLog
    })
  }

  // ---- Session lock --------------------------------------------------------------

  // Only transitions reach this, so an unlock here always follows a lock,
  // including one that was already up when this agent was created.
  onSessionLockedChanged: {
    if (root.sessionLocked) {
      if (root.previewing) {
        root.stopPreview()
        return
      }
      root.dispatch({ type: "locked" })
      return
    }
    if (!PolkitModel.shouldRestartFaceOnUnlock(root.sessionLocked, root.agentActive, root.resolvedUnderLock)) return
    root.dispatch({ type: "unlocked" })
    // beginRealFlow's focus ran while this window was hidden. Ask again now
    // that the card is allowed to show, including a password row that
    // became required under the lock.
    Qt.callLater(root.refocus)
  }

  FakeFlow {
    id: fakeFlow
    onUserAction: function(kind) { root.previewUserAction(kind) }
  }

  Connections {
    target: root.flow
    ignoreUnknownSignals: true

    function onIsResponseRequiredChanged() {
      root.syncFromFlow()
      if (root.responseRequired) root.dispatch({ type: "prompt" })
      else if (root.realCard && !root.previewing) root.realCard.clearField()
      Qt.callLater(root.refocus)
    }

    function onInputPromptChanged() { root.syncFromFlow() }
    function onResponseVisibleChanged() { root.syncFromFlow() }
    function onFailedChanged() { root.syncFromFlow() }

    function onSupplementaryMessageChanged() {
      root.syncFromFlow()
      var text = root.currentSupplementary
      if (!text) return
      if (root.flow && root.flow.supplementaryIsError) root.dispatch({ type: "error", text: text })
      else if (PolkitModel.isAskHint(text)) root.dispatch({ type: "hint" })
      else root.dispatch({ type: "info", text: text })
    }

    function onAuthenticationFailed() {
      root.syncFromFlow()
      root.dispatch({ type: "failed" })
    }

    // isSuccessful changes before Quickshell lets go of the flow and
    // authenticationSucceeded after; the lane takes whichever comes first.
    function onIsSuccessfulChanged() {
      if (root.flow && root.flow.isSuccessful) root.dispatch({ type: "succeeded" })
    }

    function onAuthenticationSucceeded() { root.dispatch({ type: "succeeded" }) }

    function onAuthenticationRequestCancelled() {
      if (root.sessionLocked) root.resolvedUnderLock = true
      root.dispatch({ type: "cancelled" })
    }

    function onIsCompletedChanged() {
      if (root.flow && root.flow.isCompleted) root.noteFlowEnded()
    }
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() { root.dispatch({ type: "chrome" }) }
  }

  // Bounds the wait for the scan in wall time, so a card that is not
  // presenting never keeps an approved dialog up.
  Timer {
    id: faceMatchWait
    interval: 4000
    repeat: false
    onTriggered: root.dispatch({ type: "scanShown" })
  }

  Timer {
    id: errorTimer
    interval: 1200
    repeat: false
    onTriggered: root.errorFlash = false
  }

  // The lid decides the layout; a stuck check must not hold the card back.
  Timer {
    id: lidWait
    interval: 200
    repeat: false
    onTriggered: root.lidSettled()
  }

  SequentialAnimation {
    id: shakeAnimation
    NumberAnimation { target: root; property: "shakeOffset"; to: -8; duration: Style.duration(35); easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 8; duration: Style.duration(50); easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 0; duration: Style.duration(55); easing.type: Easing.OutQuad }
  }

  FileView {
    path: root.pamPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadPamConfig(text())
    onLoadFailed: root.pamRaw = ""
    onFileChanged: reload()
  }

  Process {
    id: laptopClosedProc
    command: ["bash", "-c", "omarchy-hw-laptop-closed && echo closed || echo open"]
    stdout: StdioCollector { id: laptopClosedOut; waitForEnd: true }
    onExited: {
      root.laptopClosed = String(laptopClosedOut.text || "").trim() === "closed"
      root.lidSettled()
    }
  }
}
