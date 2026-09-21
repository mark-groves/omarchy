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
  property var lastSignal: null
  property var pendingSignal: null

  readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  readonly property string signalPath: Model.signalPath(root.runtimeDir)

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
    root.opened = false
  }

  function applySignal(next) {
    if (!Model.isNewerSignal(next, root.lastSignal)) return "stale"
    root.lastSignal = next
    if (root.suppress) return "suppressed"
    if (!FaceChrome.ready) {
      root.pendingSignal = next
      return "no-chrome"
    }
    root.pendingSignal = null

    root.cardState = next.state
    root.opened = true

    var hold = Model.resultHoldMs(next.state, FaceChrome.holdMs(next.state))
    if (hold > 0) {
      holdTimer.interval = hold
      holdTimer.restart()
    } else if (next.state !== "scanning") {
      root.hideCard()
    } else {
      holdTimer.stop()
    }
    return "ok"
  }

  function hintText() {
    return Model.hintFor(root.cardState)
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() {
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
    command: ["mkdir", "-p", root.runtimeDir + "/omarchy"]
    running: false
    onExited: {
      if (exitCode === 0 && root.signalPath !== "") signalFile.setText("{}\n")
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
      // The first read is only to start the watch. A leftover file from the
      // last session must not pop the card; PAM writes after that do.
      if (!primed) {
        primed = true
        return
      }
      root.ingest(text())
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
          active: root.painting
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
