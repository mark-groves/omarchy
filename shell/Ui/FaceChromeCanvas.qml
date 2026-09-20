import QtQuick
import qs.Commons
import "../Commons/FaceCardPainter.js" as Painter

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

  // Milliseconds since `cardState` last changed. Results are timed from here
  // rather than from a timestamp the surface passes in, so every surface
  // animates identically without agreeing on a clock.
  property real elapsed: 0
  property real clock: 0

  onCardStateChanged: {
    elapsed = 0
    canvas.requestPaint()
  }

  FrameAnimation {
    running: root.active && root.painting && root.visible
    onTriggered: {
      var dt = frameTime * 1000
      root.clock += dt
      root.elapsed += dt
      canvas.requestPaint()
    }
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

    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() { canvas.requestPaint() }
  }
}
