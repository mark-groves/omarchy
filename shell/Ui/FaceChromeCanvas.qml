import QtQuick
import qs.Commons
import "../Commons/FaceCardPainter.js" as Painter
import "../Commons/FacePlayback.js" as Playback

// The shared face-scan card, painted by the host.
//
// This Item and its Canvas belong to the shell. The plugin supplies numbers
// and never sees either, which is what lets this sit on a credential surface
// at all. Drop it next to a password field without fear: there is no plugin
// object anywhere in this tree to walk out of.
Item {
  id: root

  // "scanning" | "recognized" | "notRecognized". Anything else paints nothing.
  property string cardState: "scanning"
  property bool active: true

  property color accent: Color.polkit.accent
  property color foreground: Color.polkit.text
  property color errorColor: Color.polkit.textError

  readonly property bool painting: FaceChrome.ready && root.known
  readonly property bool known: cardState === "scanning"
    || cardState === "recognized" || cardState === "notRecognized"

  // How long the surface should hold the current result before tearing down.
  readonly property int holdMs: FaceChrome.holdMs(cardState)

  // Milliseconds of presented frames since this card cycle began. A result
  // hold starts at the first presented frame of the cycle, which is 0 until
  // the frame clock actually runs.
  property real elapsed: 0
  property real clock: 0

  // Surfaces bump this when a new result should play, including a repeat of
  // the same state string. PAM time is not part of the cycle.
  property int playbackEpoch: 0
  // The lock bumps this when the surface must commit a new buffer after resume.
  property int presentEpoch: 0
  property bool resultLatched: false

  signal resultPlayed()

  // The 2D context is dropped across suspend. A swap while it is gone is
  // not a frame of this card.
  readonly property bool presenting: root.active && root.painting && root.visible && canvas.available
  readonly property var hostWindow: root.QsWindow.window

  // Milliseconds of the last frameSwapped that counted. A result cycle
  // starts this at 0 so the first presented frame does not include the
  // gap since the previous swap.
  property real lastSwapMs: 0
  property int animationTicks: 0
  property int presentedSwaps: 0

  function beginCycle() {
    elapsed = 0
    lastSwapMs = 0
    resultLatched = false
    canvas.requestPaint()
  }

  function notePresentedFrame() {
    root.presentedSwaps += 1
    if (!root.presenting) {
      root.lastSwapMs = 0
      return
    }
    var now = Date.now()
    var gap = root.lastSwapMs > 0 ? now - root.lastSwapMs : 0
    root.lastSwapMs = now
    var next = Playback.creditSwap(root.elapsed, gap, true)
    if (next !== root.elapsed) {
      root.clock += next - root.elapsed
      root.elapsed = next
    }
    canvas.requestPaint()
    if (!root.resultLatched && Playback.resultComplete(root.cardState, root.elapsed, root.holdMs)) {
      root.resultLatched = true
      root.resultPlayed()
    }
  }

  onCardStateChanged: beginCycle()
  onPlaybackEpochChanged: beginCycle()
  onPresentEpochChanged: canvas.requestPaint()
  onPresentingChanged: {
    if (root.presenting) canvas.requestPaint()
  }

  // Ticks keep the draw requested. They do not move the hold: after resume
  // they run while the lock surface is still showing its pre-suspend buffer.
  FrameAnimation {
    running: root.active && root.painting && root.visible
    onTriggered: {
      root.animationTicks += 1
      canvas.requestPaint()
    }
  }

  Connections {
    target: root.hostWindow
    function onFrameSwapped() { root.notePresentedFrame() }
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    renderTarget: Canvas.Image
    renderStrategy: Canvas.Cooperative
    visible: root.painting

    readonly property int side: Math.min(width, height)

    onPaint: {
      var ctx = getContext("2d")
      if (!root.painting || side <= 0) {
        ctx.reset()
        return
      }
      Painter.paint(ctx, side,
        FaceChrome.frame(side, root.cardState, root.clock, root.elapsed),
        { accent: root.accent, foreground: root.foreground, errorColor: root.errorColor })
    }

    onAvailableChanged: {
      if (available) requestPaint()
    }

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() { canvas.requestPaint() }
  }
}
