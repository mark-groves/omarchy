import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
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

  property color accent: Commons.Color.polkit.accent
  property color foreground: Commons.Color.polkit.text
  property color errorColor: Commons.Color.polkit.textError
  // What the card is composited over. Additive light only reads on a dark
  // surface; on a light theme the card paints normally, and its bloom is a
  // coloured halo that needs nearly full opacity to read against the light.
  property color surface: Commons.Color.polkit.background
  // The GPU bloom behind the strokes. Off paints exactly the sharp layer.
  property bool glowEnabled: true
  // The software scene graph draws no shader effects, so there the painter
  // falls back to faint halos on the sharp layer instead of a bloom.
  readonly property bool gpuEffects: root.GraphicsInfo.api !== GraphicsInfo.Software

  // From op level 3 the card carries its own dark glass panel, so the
  // instrument is lit on dark on every theme, and a light card no longer
  // turns its bloom into a haze. The panel and all six roles are resolved
  // against it from the theme: see FaceTheme.glass.
  readonly property bool glass: FaceChrome.opLevel >= 3
  readonly property var glassTheme: FaceTheme.glass(String(root.accent), String(root.foreground),
    String(root.errorColor), String(Commons.Color.background), Commons.Color.palette)

  // Role colours 3..5 follow the theme: see FaceTheme.js.
  readonly property var roleColors: root.glass ? root.glassTheme.roles
    : FaceTheme.roles(String(root.accent), String(root.foreground), String(root.errorColor), Commons.Color.palette)
  readonly property bool darkSurface: root.glass || FaceTheme.luminance(String(root.surface)) < 0.5
  readonly property var paintPalette: ({
    accent: root.roleColors[0], foreground: root.roleColors[1], errorColor: root.roleColors[2],
    roles: root.roleColors, additive: root.darkSurface,
    glowFallback: root.glowEnabled && !root.gpuEffects
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
  readonly property bool presenting: root.shown && root.canvas !== null && root.canvas.available
  // Shown to the user, whatever state its layers are in. A layer rebuild
  // interrupts presenting but not this.
  readonly property bool shown: root.active && root.painting && root.visible
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

  // Rasterising a frame of a few thousand antialiased segments costs tens
  // to hundreds of milliseconds on the CPU, whatever the scene graph backend.
  // Both layers rasterise on Qt's canvas thread so the window keeps
  // presenting and the password field keeps taking keys. That thread queues
  // every requested frame, so each layer keeps at most one in flight: a slow
  // raster drops frames instead of piling them up.
  readonly property int paintStallMs: 500

  // When a frame takes longer than slowPaintMs to reach the screen, the card
  // steps down a quality level: the sharp layer rasterises smaller and is
  // scaled up on the GPU, and the bloom source repaints less often. Each
  // time the card starts presenting it starts again at full quality.
  readonly property var qualityLevels: [
    { sharp: 1, glowEvery: 1 },
    { sharp: 0.75, glowEvery: 2 },
    { sharp: 0.5, glowEvery: 3 }
  ]
  readonly property int slowPaintMs: 60
  readonly property int qualitySamples: 6
  property int qualityLevel: 0
  property real paintLatencyMs: 0
  property int paintSamples: 0
  property int sharpDispatches: 0
  // A Canvas rasterises at its item size, not at the screen's pixel ratio, so
  // on a HiDPI panel a canvas the size of the card is drawn at 1x and scaled
  // up, and every hairline and readout goes soft. The sharp layer is sized in
  // device pixels instead; a quality step still shrinks it from there.
  readonly property real pixelRatio: Math.max(1, root.Screen.devicePixelRatio || 1)
  readonly property real sharpScale: root.qualityLevels[root.qualityLevel].sharp * root.pixelRatio
  readonly property int glowEvery: root.qualityLevels[root.qualityLevel].glowEvery

  function resetQuality() {
    root.qualityLevel = 0
    root.paintLatencyMs = 0
    root.paintSamples = 0
  }

  function notePaintLatency(ms) {
    root.paintSamples += 1
    root.paintLatencyMs = root.paintSamples === 1 ? ms : root.paintLatencyMs * 0.7 + ms * 0.3
    if (root.paintSamples < root.qualitySamples || root.paintLatencyMs <= root.slowPaintMs) return
    if (root.qualityLevel >= root.qualityLevels.length - 1) return
    root.qualityLevel += 1
    root.paintSamples = 0
    console.log("face card paint", Math.round(root.paintLatencyMs), "ms, quality level", root.qualityLevel)
  }

  function requestLayer(layer) {
    if (!layer) return false
    var now = Date.now()
    if (layer.inFlightSince > 0 && now - layer.inFlightSince < root.paintStallMs) {
      // The bloom source only follows a sharp frame; a busy one skips it.
      if (layer === root.canvas) layer.pending = true
      return false
    }
    layer.pending = false
    layer.inFlightSince = now
    layer.requestPaint()
    return true
  }

  function layerPainted(layer) {
    if (layer === root.canvas && root.painting) root.glassLit = true
    if (layer === root.canvas && layer.inFlightSince > 0) root.notePaintLatency(Date.now() - layer.inFlightSince)
    layer.inFlightSince = 0
    if (layer.pending) root.repaint()
  }

  function repaint() {
    if (!root.requestLayer(root.canvas)) return
    root.sharpDispatches += 1
    if (root.glowOn && root.sharpDispatches % root.glowEvery === 0) root.requestLayer(root.glowCanvas)
  }

  function finishResult(why) {
    if (root.resultLatched || !Playback.isHeldState(root.cardState)) return
    root.resultLatched = true
    console.log("face hold played", root.cardState, "by", why, "swaps", root.presentedSwaps, "ticks", root.animationTicks, "elapsed", Math.round(root.elapsed))
    root.resultPlayed()
  }

  function beginCycle() {
    elapsed = 0
    lastSwapMs = 0
    resultLatched = false
    cyclePresented = false
    if (stallCeiling.running) stallCeiling.restart()
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
    root.cyclePresented = true
    var next = Playback.creditSwap(root.elapsed, gap, true)
    if (next !== root.elapsed) {
      root.clock += next - root.elapsed
      root.elapsed = next
    }
    root.repaint()
    if (Playback.resultComplete(root.cardState, root.elapsed, root.holdMs)) root.finishResult("frames")
  }

  // True once this cycle has presented a frame.
  property bool cyclePresented: false
  readonly property bool holding: Playback.isHeldState(root.cardState) && !root.resultLatched && root.holdMs > 0

  // The wall-clock ceilings (FacePlayback.js). Each pauses, and restarts in
  // full, while the card is not presenting, so a blank or suspended panel
  // still cannot spend a hold.
  Timer {
    id: presentedCeiling
    interval: Math.max(1, Playback.presentedCeilingMs(root.holdMs))
    running: root.holding && root.presenting && root.cyclePresented
    onTriggered: root.finishResult("ceiling")
  }

  Timer {
    id: stallCeiling
    interval: Math.max(1, Playback.stallCeilingMs(root.holdMs))
    running: root.holding && root.presenting && !root.cyclePresented
    onTriggered: root.finishResult("stall ceiling")
  }

  onCardStateChanged: beginCycle()
  onPlaybackEpochChanged: beginCycle()
  onPresentEpochChanged: root.repaint()
  onPresentingChanged: {
    root.lastSwapMs = 0
    if (root.presenting) root.repaint()
  }
  // The glass lights with the first frame of the instrument, so a slow first
  // raster never shows an empty panel.
  property bool glassLit: false

  onShownChanged: {
    if (!root.shown) root.glassLit = false
    if (!root.shown) return
    root.resetQuality()
    console.log("face card shown: scene graph api", root.GraphicsInfo.api, "bloom", root.glowOn ? "gpu" : "off",
      "surface", String(root.surface), root.darkSurface ? "dark" : "light")
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

  // The glow layer: ops that carry a glow value, at half the sharp layer's
  // resolution, blurred on the GPU twice (a tight halo and a wide bloom) and
  // laid under the sharp strokes. Every item here is host-owned; the plugin
  // only chose numbers.
  readonly property real glowScale: 0.5 * root.qualityLevels[root.qualityLevel].sharp
  readonly property bool glowOn: root.painting && root.glowEnabled && root.gpuEffects

  // The glass: the panel colour, a faint sheen toward the top, and an edge
  // in the panel's own accent-tinted tone.
  Rectangle {
    anchors.fill: parent
    visible: root.glass && root.painting
    opacity: root.glassLit ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    radius: Math.round(root.side * 0.045)
    border.width: Math.max(1, Math.round(root.side / 220))
    border.color: root.glassTheme.edge
    gradient: Gradient {
      GradientStop { position: 0; color: Qt.tint(root.glassTheme.panel, Qt.alpha(root.glassTheme.edge, 0.55)) }
      GradientStop { position: 0.45; color: root.glassTheme.panel }
      GradientStop { position: 1; color: root.glassTheme.panel }
    }
  }

  // Nothing here is resized while live. A MultiEffect keeps the size its
  // source had when it started, so a smaller bloom source after a quality
  // step is drawn shrunk into its top-left corner, and a larger one spills
  // past the card. Both layers, and the bloom with them, are rebuilt
  // whenever the card's side or its quality level changes.
  readonly property int side: Math.min(root.width, root.height)
  readonly property string layerKey: root.side + ":" + root.qualityLevel + ":" + root.pixelRatio
  property Canvas canvas: null
  property Canvas glowCanvas: null

  Repeater {
    model: root.glowOn ? [root.layerKey] : []
    delegate: Item {
      width: root.side
      height: root.side

      Canvas {
        id: glowLayer
        width: Math.max(1, Math.round(root.side * root.glowScale))
        height: width
        renderTarget: Canvas.Image
        renderStrategy: Canvas.Threaded
        visible: false

        property real inFlightSince: 0
        property bool pending: false

        Component.onCompleted: root.glowCanvas = glowLayer
        Component.onDestruction: if (root.glowCanvas === glowLayer) root.glowCanvas = null

        onPaint: {
          var ctx = getContext("2d")
          if (!root.glowOn || root.side <= 0) {
            ctx.reset()
            return
          }
          // Qt polishes the most recently requested layer first, so this often
          // paints before the sharp layer. The frame key keeps it to one plugin
          // call either way.
          Painter.paintGlow(ctx, root.side, root.currentOps(root.side), root.paintPalette, width / root.side)
        }
        onPainted: root.layerPainted(glowLayer)

        onAvailableChanged: {
          inFlightSince = 0
          if (available) root.requestLayer(glowLayer)
        }
      }

      MultiEffect {
        anchors.fill: parent
        source: glowLayer
        autoPaddingEnabled: true
        blurEnabled: true
        blur: 1.0
        blurMax: 48
        blurMultiplier: 0.6
        opacity: root.darkSurface ? 0.95 : 0.85
      }

      MultiEffect {
        anchors.fill: parent
        source: glowLayer
        autoPaddingEnabled: true
        blurEnabled: true
        blur: 0.55
        blurMax: 12
        opacity: 1
      }
    }
  }

  Repeater {
    model: [root.layerKey]
    delegate: Canvas {
      id: sharpLayer
      width: Math.max(1, Math.round(root.side * root.sharpScale))
      height: width
      scale: root.side > 0 ? root.side / width : 1
      transformOrigin: Item.TopLeft
      smooth: true
      renderTarget: Canvas.Image
      renderStrategy: Canvas.Threaded
      visible: root.painting

      property real inFlightSince: 0
      property bool pending: false

      Component.onCompleted: root.canvas = sharpLayer
      Component.onDestruction: if (root.canvas === sharpLayer) root.canvas = null

      onPaint: {
        var ctx = getContext("2d")
        if (!root.painting || root.side <= 0) {
          ctx.reset()
          return
        }
        Painter.paint(ctx, root.side, root.currentOps(root.side), root.paintPalette, width / root.side)
      }
      onPainted: root.layerPainted(sharpLayer)

      onAvailableChanged: {
        inFlightSince = 0
        if (available) root.repaint()
      }
    }
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() { root.repaint() }
  }

  onPaintPaletteChanged: root.repaint()
}
