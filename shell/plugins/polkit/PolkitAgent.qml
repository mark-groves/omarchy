import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "PolkitModel.js" as PolkitModel

Item {
  id: root

  property string fontFamily: Style.font.menuFamily
  // Bound to the central [polkit] section in shell.toml via Color.qml.
  property color accent: Color.polkit.accent
  property color background: Color.polkit.background
  property color foreground: Color.polkit.text
  property color border: Color.polkit.border
  property color borderError: Color.polkit.borderError
  property var borderSpec: Border.surfaceSpec("polkit", errorFlash ? "border-error" : "border", errorFlash ? borderError : border, Math.max(1, Style.space(2)), "border-alpha")
  property color scrim: Color.polkit.scrim
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

  property var pluginRegistry: null
  property var failedSlotUrls: ({})
  property int failedSlotRevision: 0
  property string lastChromeLog: ""

  readonly property bool dialogVisible: polkitAgent.isActive || closing || resultHold
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
    return PolkitModel.authorizationLabel(message)
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
  // match hold from that global URL.
  function faceResultHoldMs(state) {
    var hold = FaceChrome.holdMs(state)
    if (hold <= 0 && !FaceChrome.ready && PolkitModel.faceSlotResolved(presentation)) hold = 800
    return hold
  }

  function noteFaceMiss() {
    if (!PolkitModel.shouldNoteFaceMiss(presentation, faceState)) return
    var hold = root.faceResultHoldMs("notRecognized")
    if (hold <= 0) return
    faceState = "notRecognized"
    missHold = true
    missTimer.interval = hold
    missTimer.restart()
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

    currentMessage = String(flow.message || "Authentication is needed...")
    currentPrompt = String(flow.inputPrompt || "")
    currentSupplementary = String(flow.supplementaryMessage || "")
    responseRequired = !!flow.isResponseRequired
    responseVisible = !!flow.responseVisible
    failed = !!flow.failed

    if (responseRequired) submitted = false
  }

  function beginFlow() {
    closeTimer.stop()
    successTimer.stop()
    missTimer.stop()
    missHold = false
    resultHold = false
    faceState = "scanning"
    closing = false
    submitted = false
    passwordInput.text = ""
    refreshLidState()
    syncFromFlow()
    Qt.callLater(refocus)
  }

  function refocus() {
    if (!dialogVisible) return
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
    resultHold = false
    successTimer.stop()
    closing = true
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

  Timer {
    id: closeTimer
    interval: 300
    repeat: false
    onTriggered: {
      closing = false
      resetSnapshot()
    }
  }

  // A successful face match closes the dialog. Hold it open just long enough
  // for the card to finish, then close exactly as before. PAM has already
  // succeeded by this point, so this delays pixels, not authorization.
  Timer {
    id: successTimer
    repeat: false
    onTriggered: {
      root.resultHold = false
      root.closing = true
      closeTimer.restart()
    }
  }

  Timer {
    id: missTimer
    repeat: false
    onTriggered: {
      root.missHold = false
      root.faceState = "scanning"
      Qt.callLater(root.refocus)
    }
  }

  Timer {
    id: errorTimer
    interval: 1200
    repeat: false
    onTriggered: root.errorFlash = false
  }

  SequentialAnimation {
    id: shakeAnimation
    NumberAnimation { target: root; property: "shakeOffset"; to: -8; duration: 35; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 8; duration: 50; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shakeOffset"; to: 0; duration: 55; easing.type: Easing.OutQuad }
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

    function onAuthenticationSucceeded() {
      if (PolkitModel.shouldHoldFaceSuccess(presentation)) {
        var hold = root.faceResultHoldMs("recognized")
        if (hold > 0) {
          root.faceState = "recognized"
          root.missHold = false
          root.resultHold = true
          missTimer.stop()
          successTimer.interval = hold
          successTimer.restart()
          return
        }
      }
      root.closing = true
      closeTimer.restart()
    }

    function onAuthenticationRequestCancelled() {
      successTimer.stop()
      root.resultHold = false
      root.closing = true
      closeTimer.restart()
    }
  }

  PanelWindow {
    id: panel
    visible: root.dialogVisible
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
          NumberAnimation { duration: 160 }
        }

        FaceChromeCanvas {
          id: faceCanvas
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.min(parent.width, Style.space(116))
          height: width
          cardState: root.faceState
          active: root.dialogVisible
          accent: root.accent
          foreground: root.foreground
          errorColor: Color.polkit.textError
        }

        Text {
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.faceState === "notRecognized"
            ? "Face not recognized"
            : (root.faceState === "recognized" ? "Face recognized" : root.presentation.chromeHint)
          color: root.faceState === "notRecognized" ? Color.polkit.textError : root.foreground
          opacity: 0.86
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.faceState === "notRecognized" ? "Type your password"
            : (root.faceState === "scanning" ? "Esc cancels" : "")
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
          NumberAnimation { duration: 160 }
        }

        OpticalGlyph {
          width: Math.round(root.fieldHeight * 0.7)
          height: width
          text: root.presentation.glyph
          fontFamily: root.fontFamily
          fontSize: Math.round(root.fieldHeight * 0.7)
          color: root.errorFlash ? Color.polkit.textError : root.accent
        }

        Text {
          textFormat: Text.PlainText
          text: root.presentation.hint
          visible: text !== ""
          color: root.errorFlash ? Color.polkit.textError : root.foreground
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
          NumberAnimation { duration: 160 }
        }

        Text {
          textFormat: Text.PlainText
          text: root.presentation.glyph
          color: root.errorFlash ? Color.polkit.textError : root.accent
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
            color: root.errorFlash ? Color.polkit.textError : root.foreground
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
            text: root.errorFlash ? "Wrong" : (root.submitted ? "Checking..." : root.presentation.hint)
            color: root.errorFlash ? Color.polkit.textError : root.foreground
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
            color: root.errorFlash ? Color.polkit.textError : root.foreground
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
