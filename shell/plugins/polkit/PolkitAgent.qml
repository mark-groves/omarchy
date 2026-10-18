import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PolkitModel.js" as PolkitModel
import "../../Commons/FacePlayback.js" as Playback

Item {
  id: root

  property string fontFamily: Style.font.menuFamily
  // Bound to the central [polkit] section in shell.toml via Commons.Color.qml.
  property color accent: Commons.Color.polkit.accent
  property color background: Commons.Color.polkit.background
  property color foreground: Commons.Color.polkit.text
  property color border: Commons.Color.polkit.border
  property color borderError: Commons.Color.polkit.borderError
  property var borderSpec: Border.surfaceSpec("polkit", errorFlash ? "border-error" : "border", errorFlash ? borderError : border, Math.max(1, Style.space(2)), "border-alpha")
  property color scrim: Commons.Color.polkit.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int fieldHeight: Math.max(Style.space(42), Style.spacing.controlHeight)

  property bool closing: false
  property bool submitted: false
  property string currentMessage: ""
  property string currentPrompt: ""
  property string currentSupplementary: ""
  property bool responseRequired: false
  property bool responseVisible: false
  property bool failed: false
  property bool errorFlash: false
  property string pamRaw: ""
  property bool laptopClosed: false
  property int shakeOffset: 0

  // LockCover is a host singleton the lock service writes. Polkit does not
  // take a shell property: that injection is the host, and this file owns
  // the password field.
  readonly property bool sessionLocked: LockCover.covered
  // Set when a request finishes while the session lock is covering this card.
  // Unlock must not reveal a prompt that already completed underneath it.
  property bool resolvedUnderLock: false

  property var pluginRegistry: null
  property var failedSlotUrls: ({})
  property int failedSlotRevision: 0
  property string lastChromeLog: ""

  readonly property bool dialogVisible: polkitAgent.isActive || closing || resultHold
  readonly property bool cardVisible: PolkitModel.polkitCardVisible(dialogVisible, sessionLocked, resolvedUnderLock)
  readonly property var pamSteps: PolkitModel.pamStepsFromConfig(pamRaw)
  readonly property bool waitingOnPam: dialogVisible && !responseRequired && !submitted && !errorFlash
  readonly property int registryRevision: root.pluginRegistry ? root.pluginRegistry.registryRevision : 0
  readonly property var slotSource: ({
    registry: root.pluginRegistry,
    revision: root.registryRevision,
    failedUrls: root.failedSlotUrls,
    failedRevision: root.failedSlotRevision
  })
  readonly property var presentation: PolkitModel.cardPresentationFor(pamSteps, waitingOnPam, laptopClosed, slotSource)
  readonly property string cardKind: presentation && presentation.kind ? presentation.kind : "password"
  readonly property string slotUrl: presentation && presentation.slot ? presentation.slot.url : ""
  readonly property bool slotPainting: FaceChrome.ready && root.slotUrl !== ""
  // A miss holds the not-recognized frame before the password row replaces it.
  property bool missHold: false
  property bool resultHold: false
  property string faceState: "scanning"
  // Howdy often matches within a second, before the card has shown its scan.
  // The approval stands; the match card waits, display-only, until the scan
  // has played (faceScanSeen) or faceMatchWait runs out.
  property bool faceScanSeen: false
  property bool facePendingMatch: false
  // Whether the face card was what the user saw while the request was live.
  // Only updated while the request is active, so it still holds the last live
  // answer if the success path runs after the flow has ended and the
  // presentation has fallen back to a password card.
  property bool faceCardLive: false
  onShowFaceChromeChanged: if (polkitAgent.isActive) faceCardLive = showFaceChrome && cardKind === "face" && !missHold
  onCardKindChanged: if (polkitAgent.isActive) faceCardLive = showFaceChrome && cardKind === "face" && !missHold
  property int facePlaybackEpoch: 0
  readonly property bool showFaceChrome: root.slotPainting && (root.cardKind !== "password" || root.missHold || root.resultHold)
  readonly property bool showPasswordRow: root.cardKind === "password" && !root.missHold && !root.resultHold
  readonly property int slotExtra: root.showFaceChrome && presentation && presentation.extraSpace ? Style.space(presentation.extraSpace) : 0
  readonly property int cardHeight: panel.height > 0 ? Math.min(fieldHeight + contentMargin * 2 + slotExtra, panel.height - Style.gapsOut * 2) : fieldHeight + contentMargin * 2 + slotExtra
  readonly property int cardWidth: presentation && presentation.square ? cardHeight : Math.min(Style.space(312), Math.max(Style.space(260), panel.width - Style.gapsOut * 2))

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

  onPresentationChanged: {
    var line = PolkitModel.chromeSlotDiagnostic(presentation)
    if (!line || !presentation || !presentation.slot) return
    var key = presentation.slot.pluginId + "@" + presentation.slot.revision
    if (key === lastChromeLog) return
    lastChromeLog = key
    console.log(line)
  }

  function loadPamConfig(raw) {
    pamRaw = String(raw || "")
  }

  function refreshLidState() {
    if (!laptopClosedProc.running) laptopClosedProc.running = true
  }

  // Howdy has no "not recognized" exit; PAM simply falls through to asking for
  // a password. That fall-through is the miss, so the card holds the
  // not-recognized frame before the password row takes over.
  //
  // FaceChrome.sourceUrl is shared with lock and is set whenever a face plugin
  // is installed. A password or fingerprint prompt must not inherit a miss or
  // match hold from that global URL. The hold is presented frames, not a timer.
  function faceResultHoldMs(state) {
    return FaceChrome.holdMs(state)
  }

  function armFacePlayback(state) {
    if (!PolkitModel.shouldArmFaceHold(root.sessionLocked)) return false
    var expected = PolkitModel.faceSlotResolved(presentation)
    var action = Playback.playbackAction(state, FaceChrome.ready, root.faceResultHoldMs(state), expected, FaceChrome.failure !== "")
    if (action === "immediate") return false
    facePlaybackEpoch += 1
    if (state === "recognized") {
      faceState = "recognized"
      missHold = false
      root.resultHold = true
    } else {
      faceState = "notRecognized"
      missHold = true
    }
    return true
  }

  // True when the match card should wait for the scan to finish first.
  // Called only for an approval that came in while the face card was live.
  function deferFaceMatch() {
    var ms = FaceChrome.ready ? FaceChrome.scanMs() : 0
    if (root.faceScanSeen || ms <= 0) return false
    root.facePendingMatch = true
    // Keeps the dialog and its scanning card up while the scan finishes.
    root.resultHold = true
    faceMatchWait.interval = ms + 1500
    faceMatchWait.restart()
    return true
  }

  function playPendingMatch() {
    if (!root.facePendingMatch) return
    root.facePendingMatch = false
    faceMatchWait.stop()
    if (root.armFacePlayback("recognized")) return
    // closing first: dialogVisible is isActive || closing || resultHold, and
    // the request has already ended, so clearing the hold first hid the
    // dialog for a moment before closing brought it back.
    root.closing = true
    root.resultHold = false
    closeTimer.restart()
  }

  function noteFaceScanShown() {
    root.faceScanSeen = true
    root.playPendingMatch()
  }

  function clearPendingMatch() {
    root.facePendingMatch = false
    faceMatchWait.stop()
  }

  function completeFacePlayback() {
    if (resultHold) {
      // closing first, so the dialog stays up through the handover (see
      // playPendingMatch).
      closing = true
      resultHold = false
      missHold = false
      closeTimer.restart()
      return
    }
    if (missHold) {
      missHold = false
      faceState = "scanning"
      faceScanSeen = false
      Qt.callLater(refocus)
    }
  }

  function settleFacePlayback() {
    if (!resultHold && !missHold) return
    // A match still waiting on the scan is not a hold the card is playing.
    if (facePendingMatch) {
      if (!FaceChrome.ready) playPendingMatch()
      return
    }
    var state = resultHold ? "recognized" : faceState
    var expected = PolkitModel.faceSlotResolved(presentation)
    if (FaceChrome.ready) {
      if (Playback.playbackAction(state, true, root.faceResultHoldMs(state), expected) === "immediate") completeFacePlayback()
      return
    }
    if (expected && FaceChrome.sourceUrl !== "" && FaceChrome.failure === "") return
    completeFacePlayback()
  }

  function noteFaceMiss() {
    if (!PolkitModel.shouldNoteFaceMiss(presentation, faceState)) return
    root.armFacePlayback("notRecognized")
  }

  function resetSnapshot() {
    currentMessage = ""
    currentPrompt = ""
    currentSupplementary = ""
    responseRequired = false
    responseVisible = false
    failed = false
    errorFlash = false
    submitted = false
    passwordInput.text = ""
  }

  function syncFromFlow() {
    var flow = polkitAgent.flow
    if (!flow) return

    currentMessage = String(flow.message || "")
    currentPrompt = String(flow.inputPrompt || "")
    currentSupplementary = String(flow.supplementaryMessage || "")
    responseRequired = !!flow.isResponseRequired
    responseVisible = !!flow.responseVisible
    failed = !!flow.failed

    if (responseRequired) submitted = false
  }

  function beginFlow() {
    closeTimer.stop()
    resolvedUnderLock = false
    missHold = false
    resultHold = false
    faceState = "scanning"
    faceScanSeen = false
    faceCardLive = false
    authSuccessHandled = false
    clearPendingMatch()
    closing = false
    submitted = false
    passwordInput.text = ""
    refreshLidState()
    syncFromFlow()
    Qt.callLater(refocus)
  }

  function refocus() {
    // dialogVisible stays true while the card is hidden under the lock.
    // Focusing then does not stick, so wait until the window is shown.
    if (!root.cardVisible) return
    if (root.showPasswordRow) passwordInput.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  function submitResponse() {
    var flow = polkitAgent.flow
    if (!flow || !flow.isResponseRequired) return
    submitted = true
    errorFlash = false
    flow.submit(passwordInput.text)
    passwordInput.text = ""
    keyCatcher.forceActiveFocus()
  }

  function cancelRequest() {
    var flow = polkitAgent.flow
    passwordInput.text = ""
    submitted = false
    closing = true
    resultHold = false
    missHold = false
    clearPendingMatch()
    closeTimer.restart()
    if (flow) flow.cancelAuthenticationRequest()
  }

  function triggerFailureFeedback() {
    submitted = false
    errorFlash = true
    passwordInput.text = ""
    errorTimer.restart()
    shakeAnimation.restart()
    Qt.callLater(refocus)
  }

  // Only transitions reach this, so an unlock here always follows a lock,
  // including one that was already up when this agent was created.
  onSessionLockedChanged: {
    if (root.sessionLocked) {
      // A hold already on screen cannot finish while this window is hidden.
      // The PAM result stands; don't bring the card back at unlock.
      if (root.resultHold) {
        root.resolvedUnderLock = true
        root.resultHold = false
        root.missHold = false
        root.clearPendingMatch()
      }
      return
    }
    if (!PolkitModel.shouldRestartFaceOnUnlock(root.sessionLocked, polkitAgent.isActive, root.resolvedUnderLock)) return
    root.faceState = "scanning"
    root.missHold = false
    root.resultHold = false
    root.faceScanSeen = false
    root.clearPendingMatch()
    root.facePlaybackEpoch += 1
    // beginFlow's focus ran while this window was hidden. Ask again now
    // that the card is allowed to show, including a password row that
    // became required under the lock.
    Qt.callLater(root.refocus)
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() { root.settleFacePlayback() }
  }

  // Bounds the wait for the scan in wall time, so a card that is not
  // presenting never keeps an approved dialog up.
  Timer {
    id: faceMatchWait
    interval: 4000
    repeat: false
    onTriggered: root.playPendingMatch()
  }

  Timer {
    id: closeTimer
    interval: 300
    repeat: false
    onTriggered: {
      closing = false
      resetSnapshot()
    }
  }

  // A successful face match closes the dialog after the card has played.
  // PAM has already succeeded, so this delays pixels, not authorization.
  Timer {
    id: errorTimer
    interval: 1200
    repeat: false
    onTriggered: root.errorFlash = false
  }

  SequentialAnimation {
    id: shakeAnimation
    NumberAnimation { target: root; property: "shakeOffset"; to: -8; duration: Style.duration(35); easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 8; duration: Style.duration(50); easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 0; duration: Style.duration(55); easing.type: Easing.OutQuad }
  }
  FileView {
    path: "/etc/pam.d/polkit-1"
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
    onExited: root.laptopClosed = String(laptopClosedOut.text || "").trim() === "closed"
  }

  PolkitAgent {
    id: polkitAgent
    path: "/org/omarchy/PolkitAgent"

    onAuthenticationRequestStarted: root.beginFlow()
    onIsActiveChanged: {
      if (isActive) root.syncFromFlow()
      else if (!root.closing && !root.resultHold) root.resetSnapshot()
    }
    onIsRegisteredChanged: {
      if (isRegistered) console.log("omarchy polkit agent registered")
      else console.warn("omarchy polkit agent is not registered; another agent may be running")
    }
  }

  // Quickshell hands the result to polkit, which ends the flow and drops
  // polkitAgent.flow, before it emits authenticationSucceeded, so that signal
  // never reached this dialog and an approved request closed mid-scan with no
  // match played. isSuccessful changes before the handover, while the flow is
  // still ours; both lead here, once per request.
  property bool authSuccessHandled: false
  function handleAuthSucceeded() {
    if (root.authSuccessHandled) return
    root.authSuccessHandled = true
    if (!PolkitModel.shouldArmFaceHold(root.sessionLocked)) {
      root.resolvedUnderLock = true
      root.resultHold = false
      root.missHold = false
      root.clearPendingMatch()
      return
    }
    var faceLive = root.faceCardLive || PolkitModel.shouldHoldFaceSuccess(presentation)
    root.faceCardLive = false
    if (faceLive) {
      if (root.deferFaceMatch()) return
      if (root.armFacePlayback("recognized")) return
    }
    root.closing = true
    closeTimer.restart()
  }

  Connections {
    target: polkitAgent.flow

    function onIsResponseRequiredChanged() {
      if (polkitAgent.flow && polkitAgent.flow.isResponseRequired) root.noteFaceMiss()
      root.syncFromFlow()
      if (!polkitAgent.flow || !polkitAgent.flow.isResponseRequired) passwordInput.text = ""
      Qt.callLater(root.refocus)
    }

    function onInputPromptChanged() { root.syncFromFlow() }
    function onResponseVisibleChanged() { root.syncFromFlow() }
    function onSupplementaryMessageChanged() { root.syncFromFlow() }
    function onFailedChanged() { root.syncFromFlow() }

    function onAuthenticationFailed() {
      root.syncFromFlow()
      root.triggerFailureFeedback()
    }

    function onIsSuccessfulChanged() {
      if (polkitAgent.flow && polkitAgent.flow.isSuccessful) root.handleAuthSucceeded()
    }

    function onAuthenticationSucceeded() { root.handleAuthSucceeded() }

    function onAuthenticationRequestCancelled() {
      if (!root.sessionLocked) root.closing = true
      root.resultHold = false
      root.missHold = false
      root.clearPendingMatch()
      if (root.sessionLocked) {
        root.resolvedUnderLock = true
        return
      }
      closeTimer.restart()
    }
  }

  PanelWindow {
    id: panel
    // Right-to-left languages read this window mirrored.
    Binding { target: panel.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
    Binding { target: panel.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

    visible: root.cardVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-polkit"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.refocus()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: root.shakeOffset
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: root.refocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.cancelRequest()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.responseRequired) root.submitResponse()
            event.accepted = true
          }
        }
      }

      // Host-owned. The chrome plugin supplies numbers and never sees this
      // item, this window, or the field beside it.
      Column {
        id: faceChrome
        anchors.centerIn: parent
        spacing: Style.space(10)
        width: parent.width - card.contentLeftInset - card.contentRightInset
        opacity: root.showFaceChrome ? 1 : 0
        visible: opacity > 0
        enabled: false

        Behavior on opacity {
          NumberAnimation { duration: Style.duration(160) }
        }

        FaceChromeCanvas {
          id: faceCanvas
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(parent.width, Style.space(FaceChrome.cardSide))
          height: width
          visible: parent.visible
          cardState: root.faceState
          playbackEpoch: root.facePlaybackEpoch
          active: root.cardVisible && parent.visible
          onResultPlayed: root.completeFacePlayback()
          onScanShown: root.noteFaceScanShown()
          accent: root.accent
          foreground: root.foreground
          errorColor: Commons.Color.polkit.textError
          surface: root.background
        }

        Text {
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.faceState === "notRecognized" ? Commons.I18n.t("face.notRecognized")
            : (root.faceState === "recognized" ? Commons.I18n.t("face.recognized") : root.presentation.chromeHint)
          color: root.faceState === "notRecognized" ? Commons.Color.polkit.textError : root.foreground
          opacity: 0.86
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.faceState === "notRecognized" ? Commons.I18n.t("face.typeYourPassword")
            : (root.faceState === "scanning" ? Commons.I18n.t("face.escCancels") : "")
          visible: text !== ""
          color: root.foreground
          opacity: 0.44
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
      }

      Row {
        id: defaultChrome
        anchors.centerIn: parent
        spacing: Style.space(10)
        opacity: root.cardKind !== "password" && !root.showFaceChrome ? 1 : 0
        visible: opacity > 0
        enabled: visible

        Behavior on opacity {
          NumberAnimation { duration: Style.duration(160) }
        }

        OpticalGlyph {
          width: Math.round(root.fieldHeight * 0.7)
          height: width
          text: root.presentation.glyph
          fontFamily: root.fontFamily
          fontSize: Math.round(root.fieldHeight * 0.7)
          color: root.errorFlash ? Commons.Color.polkit.textError : root.accent
        }

        Text {
          textFormat: Text.PlainText
          text: root.presentation.hint
          visible: text !== ""
          color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
          opacity: 0.72
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }
      }

      Row {
        id: cardRow
        opacity: root.showPasswordRow ? 1 : 0
        visible: opacity > 0
        enabled: root.showPasswordRow
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(14)

        Behavior on opacity {
          NumberAnimation { duration: Style.duration(160) }
        }

        Text {
          textFormat: Text.PlainText
          text: root.presentation.glyph
          color: root.errorFlash ? Commons.Color.polkit.textError : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
          width: Style.space(26)
          height: root.fieldHeight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        Item {
          width: parent.width - Style.space(40)
          height: root.fieldHeight

          TextInput {
            id: passwordInput
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            activeFocusOnPress: true
            clip: true
            selectionColor: Util.alpha(root.accent, 0.45)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            echoMode: root.responseVisible ? TextInput.Normal : TextInput.Password
            passwordCharacter: "\u2022"
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            cursorVisible: activeFocus && !root.submitted && !root.errorFlash
            readOnly: root.submitted || root.errorFlash
            enabled: root.dialogVisible
            onAccepted: root.submitResponse()
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.cancelRequest()
                event.accepted = true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.errorFlash ? I18n.t("polkit.wrong") : (root.submitted ? I18n.t("polkit.checking") : I18n.t("polkit.enterPassword"))
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            opacity: root.errorFlash ? 1 : 0.36
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            elide: Text.ElideRight
            visible: passwordInput.text.length === 0
          }

          Rectangle {
            width: Math.max(1, Style.space(2))
            height: Style.space(24)
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            visible: passwordInput.visible && passwordInput.activeFocus && passwordInput.text.length === 0 && !root.submitted && !root.errorFlash
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            enabled: passwordInput.visible
            onClicked: passwordInput.forceActiveFocus()
          }
        }
      }
    }

    Rectangle {
      width: Math.min(justificationText.implicitWidth + Style.space(24), panel.width - Style.gapsOut * 2)
      height: Style.space(28)
      anchors.horizontalCenter: card.horizontalCenter
      anchors.bottom: card.top
      anchors.bottomMargin: Style.space(10)
      radius: root.cornerRadius
      color: root.background

      Text {
        id: justificationText
        textFormat: Text.PlainText
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        text: root.authorizationLabel(root.currentMessage)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideMiddle
      }
    }
  }
}
