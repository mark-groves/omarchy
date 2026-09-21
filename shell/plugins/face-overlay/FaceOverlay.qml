import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "FaceOverlayModel.js" as Model

Item {
  id: root

  property var shell: null

  property bool opened: false
  property string cardState: "scanning"
  property bool awaitingPlayback: false
  property int playbackEpoch: 0
  property var lastSignal: null
  property var pendingSignal: null

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  readonly property string signalPath: Model.signalPath(root.runtimeDir)
  readonly property var watchStartedTs: Date.now() * 1000

  readonly property var lockService: root.shell && root.shell.firstPartyServiceFor
    ? root.shell.firstPartyServiceFor("omarchy.lock") : null
  readonly property var polkitService: root.shell && root.shell.firstPartyServiceFor
    ? root.shell.firstPartyServiceFor("omarchy.polkit") : null
  readonly property bool suppress: Model.shouldSuppress(
    !!(root.lockService && root.lockService.locked),
    !!(root.polkitService && root.polkitService.dialogVisible)
  )

  readonly property int pad: Style.space(16)
  readonly property int cardSide: Style.space(116)
  readonly property bool painting: FaceChrome.ready && root.opened && !root.suppress

  onSuppressChanged: {
    if (root.suppress) root.hideCard()
  }

  function ingest(raw) {
    var next = Model.parseSignal(raw)
    if (!next) return "ignored"
    return root.applySignal(next)
  }

  function open(payloadJson) {
    var next = Model.parseShowPayload(payloadJson)
    if (!next) return "ignored"
    return root.applySignal(next)
  }

  function close() {
    root.hideCard()
    return "ok"
  }

  function hideCard() {
    holdTimer.stop()
    root.awaitingPlayback = false
    root.opened = false
  }

  // A rejected module will not paint, and it will not emit another revision
  // after the one that stored the failure. Finish the result now. A module
  // that is still loading, or still ready to paint, keeps the presented hold.
  function finishHoldIfChromeFailed(state) {
    if (FaceChrome.ready || FaceChrome.failure === "") return false
    var held = state === "recognized" || state === "notRecognized" || root.awaitingPlayback
    if (!held) return false
    root.pendingSignal = null
    root.hideCard()
    return true
  }

  function applySignal(next) {
    if (!Model.isNewerSignal(next, root.lastSignal)) return "stale"
    root.lastSignal = next
    // Cancelled sudo never writes recognized or notRecognized. Hide now.
    // Scanning also starts a timeout so SIGKILL cannot leave the card up.
    if (Model.isHideState(next.state)) {
      root.pendingSignal = null
      root.hideCard()
      return root.suppress ? "suppressed" : "ok"
    }
    if (root.suppress) return "suppressed"
    if (!FaceChrome.ready) {
      if (root.finishHoldIfChromeFailed(next.state)) return "ok"
      root.pendingSignal = next
      return "no-chrome"
    }
    root.pendingSignal = null

    root.cardState = next.state
    root.opened = true

    var hold = Model.resultHoldMs(next.state, FaceChrome.holdMs(next.state))
    if (hold > 0) {
      // The canvas emits resultPlayed after the result has been on screen.
      // A wall-clock timer would hide the card if PAM returned before the
      // first frame, or while the display was still waking.
      root.awaitingPlayback = true
      root.playbackEpoch += 1
      holdTimer.stop()
      return "ok"
    }
    root.awaitingPlayback = false
    if (next.state === "scanning") {
      holdTimer.interval = Model.scanTimeoutMs()
      holdTimer.restart()
      return "ok"
    }
    root.hideCard()
    return "ok"
  }

  function hintText() {
    return Model.hintFor(root.cardState)
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() {
      var pendingState = root.pendingSignal ? root.pendingSignal.state : ""
      if (root.finishHoldIfChromeFailed(pendingState)) return
      if (FaceChrome.ready && root.pendingSignal) root.applySignal(root.pendingSignal)
    }
  }

  Timer {
    id: holdTimer
    repeat: false
    onTriggered: root.hideCard()
  }

  Process {
    id: ensureSignalDir
    command: ["bash", "-c", "mkdir -p -- \"$1\" && if [[ ! -e $2 ]]; then printf '%s\\n' '{}' >\"$2\"; fi", "omarchy-face-overlay", root.runtimeDir + "/omarchy", root.signalPath]
    running: false
    onExited: {
      if (exitCode === 0 && root.signalPath !== "") signalFile.reload()
    }
  }

  FileView {
    id: signalFile
    path: root.signalPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    property bool primed: false
    onLoaded: {
      var raw = text()
      if (!primed) {
        primed = true
        // Leftover from before this watch stays down. A live PAM write
        // that is the first file we see still has to open the card.
        var next = Model.parseSignal(raw)
        if (!next || Model.isStaleSignal(next, root.watchStartedTs)) return
      }
      root.ingest(raw)
    }
    onLoadFailed: {
      if (root.runtimeDir !== "") ensureSignalDir.running = true
    }
    onFileChanged: reload()
  }

  IpcHandler {
    target: "omarchy.face-overlay"
    function show(payloadJson: string): string { return root.open(payloadJson) }
    function close(): string { return root.close() }
    function state(): string { return root.opened ? root.cardState : "closed" }
    function ping(): string { return "ok" }
  }

  PanelWindow {
    id: panel
    visible: root.painting
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-face-overlay"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    BorderSurface {
      id: card
      width: card.borderLeft + root.pad + root.cardSide + root.pad + card.borderRight
      height: card.borderTop + root.pad + root.cardSide + Style.space(10) + hintMetrics.height + root.pad + card.borderBottom
      anchors.centerIn: parent
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.painting ? 1 : 0
      enabled: false

      Column {
        anchors.fill: parent
        anchors.topMargin: card.borderTop + root.pad
        anchors.rightMargin: card.borderRight + root.pad
        anchors.bottomMargin: card.borderBottom + root.pad
        anchors.leftMargin: card.borderLeft + root.pad
        spacing: Style.space(10)

        FaceChromeCanvas {
          objectName: "faceOverlayCard"
          anchors.horizontalCenter: parent.horizontalCenter
          width: root.cardSide
          height: width
          cardState: root.cardState
          playbackEpoch: root.playbackEpoch
          visible: root.painting
          active: root.painting
          onResultPlayed: {
            if (root.awaitingPlayback) root.hideCard()
          }
          accent: Color.polkit.accent
          foreground: Color.polkit.text
          errorColor: Color.polkit.textError
        }

        Text {
          textFormat: Text.PlainText
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: root.hintText()
          color: root.cardState === "notRecognized" ? Color.polkit.textError : Color.popups.text
          opacity: 0.86
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }
    }
  }

  TextMetrics {
    id: hintMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    text: root.hintText()
  }
}
