import QtQuick
import QtQuick.Effects
import qs.Commons
import "../Commons/FaceCardPainter.js" as Painter
import "../Commons/FacePlayback.js" as Playback
import "../Commons/FaceTheme.js" as FaceTheme

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
  // What the card is composited over. Additive light only reads on a dark
  // surface; on a light theme the card paints normally and glows less.
  property color surface: Color.polkit.background
  // The GPU bloom behind the strokes. Off paints exactly the sharp layer.
  property bool glowEnabled: true
  // The software scene graph draws no shader effects, so there the painter
  // falls back to faint halos on the sharp layer instead of a bloom.
  readonly property bool gpuEffects: root.GraphicsInfo.api !== GraphicsInfo.Software

  // Role colours 3..5 follow the theme: see FaceTheme.js.
  readonly property var roleColors: FaceTheme.roles(String(root.accent), String(root.foreground),
    String(root.errorColor), Color.palette)
  readonly property bool darkSurface: FaceTheme.luminance(String(root.surface)) < 0.5
  readonly property var paintPalette: ({
    accent: root.accent, foreground: root.foreground, errorColor: root.errorColor,
    roles: root.roleColors, additive: root.darkSurface, glowFallback: !root.glowOn
  })

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
  // The QQuickWindow, which emits frameSwapped. QsWindow.window is
  // Quickshell's wrapper: it has no frameSwapped, and on a session lock
  // surface it is null.
  readonly property var hostWindow: root.Window.window

  // Milliseconds of the last frameSwapped that counted. A result cycle
  // starts this at 0 so the first presented frame does not include the
  // gap since the previous swap.
  property real lastSwapMs: 0
  property int animationTicks: 0
  property int presentedSwaps: 0

  // Both layers paint the same frame. The plugin runs once per frame, not
  // once per layer.
  property var frameKey: ""
  property var frameOps: []
  function currentOps(side) {
    var key = side + "|" + root.cardState + "|" + root.clock + "|" + root.elapsed + "|" + FaceChrome.revision
    if (key !== root.frameKey) {
      root.frameKey = key
      root.frameOps = FaceChrome.frame(side, root.cardState, root.clock, root.elapsed)
    }
    return root.frameOps
  }

  function repaint() {
    canvas.requestPaint()
    if (root.glowOn) glowCanvas.requestPaint()
  }

  function beginCycle() {
    elapsed = 0
    lastSwapMs = 0
    resultLatched = false
    root.repaint()
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
    root.repaint()
    if (!root.resultLatched && Playback.resultComplete(root.cardState, root.elapsed, root.holdMs)) {
      root.resultLatched = true
      console.log("face hold played", root.cardState, "swaps", root.presentedSwaps, "ticks", root.animationTicks, "elapsed", Math.round(root.elapsed))
      root.resultPlayed()
    }
  }

  onCardStateChanged: beginCycle()
  onPlaybackEpochChanged: beginCycle()
  onPresentEpochChanged: root.repaint()
  onPresentingChanged: {
    root.lastSwapMs = 0
    if (root.presenting) root.repaint()
  }

  // Ticks keep the draw requested. They do not move the hold: after resume
  // they run while the lock surface is still showing its pre-suspend buffer.
  FrameAnimation {
    running: root.active && root.painting && root.visible
    onTriggered: {
      root.animationTicks += 1
      root.repaint()
    }
  }

  Connections {
    target: root.hostWindow
    function onFrameSwapped() { root.notePresentedFrame() }
  }

  // The glow layer: ops that carry a glow value, at half resolution, blurred
  // on the GPU twice (a tight halo and a wide bloom) and laid under the
  // sharp strokes. Every item here is host-owned; the plugin only chose
  // numbers.
  readonly property real glowScale: 0.5
  readonly property bool glowOn: root.painting && root.glowEnabled && root.gpuEffects

  Canvas {
    id: glowCanvas
    width: Math.max(1, Math.round(canvas.side * root.glowScale))
    height: width
    renderTarget: Canvas.Image
    renderStrategy: Canvas.Cooperative
    visible: false

    onPaint: {
      var ctx = getContext("2d")
      if (!root.glowOn || canvas.side <= 0) {
        ctx.reset()
        return
      }
      Painter.paintGlow(ctx, canvas.side, root.currentOps(canvas.side), root.paintPalette, root.glowScale)
    }

    onAvailableChanged: {
      if (available) requestPaint()
    }
  }

  MultiEffect {
    id: bloomWide
    width: canvas.side
    height: canvas.side
    source: glowCanvas
    visible: root.glowOn
    autoPaddingEnabled: true
    blurEnabled: true
    blur: 1.0
    blurMax: 48
    blurMultiplier: 0.6
    brightness: root.darkSurface ? 0.08 : 0
    opacity: root.darkSurface ? 0.95 : 0.45
  }

  MultiEffect {
    id: bloomTight
    width: canvas.side
    height: canvas.side
    source: glowCanvas
    visible: root.glowOn
    autoPaddingEnabled: true
    blurEnabled: true
    blur: 0.55
    blurMax: 12
    brightness: root.darkSurface ? 0.05 : 0
    opacity: root.darkSurface ? 1 : 0.5
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
      Painter.paint(ctx, side, root.currentOps(side), root.paintPalette)
    }

    onAvailableChanged: {
      if (available) root.repaint()
    }

    onWidthChanged: root.repaint()
    onHeightChanged: root.repaint()
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() { root.repaint() }
  }

  onPaintPaletteChanged: root.repaint()
}
