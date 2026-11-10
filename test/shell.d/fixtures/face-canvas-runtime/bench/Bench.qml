import QtQuick
import QtQuick.Window
import qs.Commons
import "shell/Ui" as Ui
import "shell/Commons/FaceCardPainter.js" as Painter

// The host face renderer against a real face plugin, offscreen. The shell's
// own FaceChrome.qml loads the plugin (only Quickshell's FileView is
// stubbed), the shell's FaceChromeCanvas paints it at each quality level, and
// the shell's painter replays it into canvases of the sizes that card chose.
// bin/omarchy-dev-face-bench builds the import tree and reads the RESULT lines.
Window {
  id: win
  width: 260
  height: 260
  visible: true
  color: "black"

  function arg(name, fallback) {
    var args = Qt.application.arguments
    var prefix = "--" + name + "="
    for (var i = 0; i < args.length; i++) {
      var a = String(args[i])
      if (a.indexOf(prefix) === 0) return a.substring(prefix.length)
    }
    return fallback
  }

  readonly property string pluginPath: arg("plugin", "")
  readonly property real seconds: Math.max(1, Number(arg("seconds", "4")) || 4)
  readonly property var levels: arg("levels", "0,1,2").split(",").map(Number).filter(function(n) { return n >= 0 && n <= 2 })
  readonly property int side: 220
  readonly property int isoPaints: 32
  readonly property int isoWarmup: 2

  function report(line) {
    console.log("RESULT " + line)
  }

  function stats(list) {
    var n = list.length
    if (!n) return { n: 0, mean: 0, p50: 0, p95: 0, max: 0 }
    var sorted = list.slice().sort(function(a, b) { return a - b })
    var sum = 0
    for (var i = 0; i < n; i++) sum += sorted[i]
    return { n: n, mean: sum / n, p50: sorted[Math.floor((n - 1) * 0.5)], p95: sorted[Math.floor((n - 1) * 0.95)], max: sorted[n - 1] }
  }

  function fmt(s) {
    return "n=" + s.n + " mean=" + s.mean.toFixed(1) + " p50=" + s.p50 + " p95=" + s.p95 + " max=" + s.max
  }

  // One step at a time: each step names the next and how long to wait.
  property var nextStep: null
  Timer {
    id: stepper
    repeat: false
    onTriggered: {
      var step = win.nextStep
      win.nextStep = null
      if (step) step()
    }
  }
  function after(ms, step) {
    win.nextStep = step
    stepper.interval = Math.max(1, ms)
    stepper.restart()
  }

  // ---- the plugin, through the shell's own load path
  property int waitedMs: 0
  function loadPlugin() {
    if (!win.pluginPath) {
      win.report("error no plugin given")
      Qt.exit(2)
      return
    }
    FaceChrome.sourceUrl = "file://" + win.pluginPath
    win.after(50, win.awaitPlugin)
  }
  function awaitPlugin() {
    if (FaceChrome.ready) {
      win.report("env dpr=" + Screen.devicePixelRatio + " api=" + GraphicsInfo.api + " plugin=" + win.pluginPath)
      win.after(10, win.benchFrames)
      return
    }
    win.waitedMs += 50
    if (FaceChrome.failure !== "" || win.waitedMs > 5000) {
      win.report("error plugin did not load: " + (FaceChrome.failure || "timeout"))
      Qt.exit(2)
      return
    }
    win.after(50, win.awaitPlugin)
  }

  // ---- frame(): the plugin's JS on the GUI thread
  property var opsSequence: []
  function benchFrames() {
    var started = Date.now()
    FaceChrome.frame(win.side, "scanning", 0, 0)
    win.report("frame first-call ms=" + (Date.now() - started))
    var plan = [
      ["scanning", 3000],
      ["recognized", FaceChrome.holdMs("recognized")],
      ["notRecognized", FaceChrome.holdMs("notRecognized")]
    ]
    var clockBase = 20000
    var all = []
    for (var p = 0; p < plan.length; p++) {
      var state = plan[p][0]
      var length = Math.max(500, plan[p][1])
      var times = []
      var ops = 0
      var paths = 0
      var cmds = 0
      var glowOps = 0
      var frames = 0
      for (var e = 0; e <= length; e += 1000 / 60) {
        var t0 = Date.now()
        var frame = FaceChrome.frame(win.side, state, clockBase + e, e)
        var ms = Date.now() - t0
        times.push(ms)
        all.push(ms)
        frames += 1
        ops += frame.length
        for (var i = 0; i < frame.length; i++) {
          var op = frame[i]
          if (op[0] === 0) {
            paths += 1
            cmds += op[4].length
          }
          var at = op[0] === 0 ? 5 : (op[0] === 1 ? 7 : (op[0] === 2 ? 10 : -1))
          if (at > 0 && op.length > at && op[at] > 0) glowOps += 1
        }
        if (frames % 4 === 0) win.opsSequence.push(frame)
      }
      clockBase += length
      win.report("frame state=" + state + " " + win.fmt(win.stats(times))
        + " ops=" + Math.round(ops / frames) + " paths=" + Math.round(paths / frames)
        + " pathCmds=" + Math.round(cmds / frames) + " glowOps=" + Math.round(glowOps / frames))
    }
    win.report("frame state=all " + win.fmt(win.stats(all)))
    win.levelIndex = -1
    win.after(10, win.nextLevel)
  }

  // ---- the shell's card at one quality level
  property int levelIndex: -1
  property int level: 0
  property string cardState: "scanning"
  readonly property var card: cardLoader.item

  property bool measuring: false
  property double measureStart: 0
  property int swaps: 0
  property int paints: 0
  property int glowPaints: 0
  property int ticksAtStart: 0
  property double paintEndAt: 0
  property var rasterMs: []
  property var swapGaps: []
  property double lastSwapAt: 0

  onFrameSwapped: {
    if (!win.measuring) return
    var now = Date.now()
    if (win.lastSwapAt > 0) win.swapGaps.push(now - win.lastSwapAt)
    win.lastSwapAt = now
    win.swaps += 1
  }

  Loader {
    id: cardLoader
    x: 20
    y: 20
    width: win.side
    height: win.side
    active: false
    sourceComponent: Ui.FaceChromeCanvas {
      cardState: win.cardState
      active: true
    }
  }

  // Runs after the card's own onPaint, so it marks the end of the frame's
  // GUI-thread work; painted marks the end of its raster.
  Connections {
    target: win.card ? win.card.canvas : null
    ignoreUnknownSignals: true
    function onPaint(region) {
      win.paintEndAt = Date.now()
    }
    function onPainted() {
      if (!win.measuring) return
      win.paints += 1
      if (win.paintEndAt > 0) win.rasterMs.push(Date.now() - win.paintEndAt)
      win.paintEndAt = 0
    }
  }

  Connections {
    target: win.card ? win.card.glowCanvas : null
    ignoreUnknownSignals: true
    function onPainted() {
      if (win.measuring) win.glowPaints += 1
    }
  }

  function nextLevel() {
    win.levelIndex += 1
    if (win.levelIndex >= win.levels.length) {
      win.report("done")
      Qt.quit()
      return
    }
    win.level = win.levels[win.levelIndex]
    FaceChrome.qualityLevel = win.level
    win.cardState = "scanning"
    cardLoader.active = true
    if (win.card && typeof win.card.surface === "string") win.card.surface = "bench"
    win.waitedMs = 0
    win.after(50, win.awaitCard)
  }

  function awaitCard() {
    win.waitedMs += 50
    if (win.card && win.card.canvas && win.card.canvas.available && win.card.glassLit) {
      // Let the first frames (V4 warm-up, image allocation) pass.
      win.after(400, function() { win.startMeasure("scanning") })
      return
    }
    if (win.waitedMs > 5000) {
      win.report("error level=" + win.level + " card never painted")
      Qt.exit(3)
      return
    }
    win.after(50, win.awaitCard)
  }

  function startMeasure(phase) {
    win.phase = phase
    win.swaps = 0
    win.paints = 0
    win.glowPaints = 0
    win.rasterMs = []
    win.swapGaps = []
    win.lastSwapAt = 0
    win.ticksAtStart = win.card.animationTicks
    win.measureStart = Date.now()
    win.measuring = true
    var ms = phase === "scanning" ? win.seconds * 1000 : Math.max(500, FaceChrome.holdMs(phase))
    win.after(ms, win.stopMeasure)
  }
  property string phase: ""

  function stopMeasure() {
    win.measuring = false
    var secs = (Date.now() - win.measureStart) / 1000
    var c = win.card
    var line = "pipeline level=" + win.level + " phase=" + win.phase
      + " levelInUse=" + c.qualityLevel + " nextLevel=" + FaceChrome.qualityLevel
      + " paintsPerSec=" + (win.paints / secs).toFixed(1)
      + " glowPaintsPerSec=" + (win.glowPaints / secs).toFixed(1)
      + " ticksPerSec=" + ((c.animationTicks - win.ticksAtStart) / secs).toFixed(1)
      + " swapsPerSec=" + (win.swaps / secs).toFixed(1)
    win.report(line)
    win.report("pipeline level=" + win.level + " phase=" + win.phase + " raster " + win.fmt(win.stats(win.rasterMs)))
    win.report("pipeline level=" + win.level + " phase=" + win.phase + " swapGap " + win.fmt(win.stats(win.swapGaps)))
    if (typeof c.perfSnapshot === "function") {
      var p = c.perfSnapshot()
      win.report("pipeline level=" + win.level + " phase=" + win.phase + " card"
        + " frameMs=" + p.frameMs.toFixed(1) + " replayMs=" + p.replayMs.toFixed(1)
        + " jsMs=" + p.jsMs.toFixed(1) + " rasterMs=" + p.rasterMs.toFixed(1)
        + " frameCalls=" + p.frameCalls + " dispatches=" + p.dispatches + " landed=" + p.landed)
    }
    if (win.phase === "scanning") {
      win.cardState = "recognized"
      win.after(50, function() { win.startMeasure("recognized") })
      return
    }
    win.sharpItem = c.canvas ? c.canvas.width : 0
    win.glowItem = c.glowCanvas ? c.glowCanvas.width : 0
    win.isoPalette = JSON.parse(JSON.stringify(c.paintPalette))
    win.report("size level=" + win.level + " card=" + win.side + " sharpItem=" + win.sharpItem
      + " sharpRasterPx=" + Math.round(win.sharpItem * Screen.devicePixelRatio)
      + " glowItem=" + win.glowItem + " glowRasterPx=" + Math.round(win.glowItem * Screen.devicePixelRatio)
      + " glowEvery=" + (c.glowEvery || 0))
    cardLoader.active = false
    win.after(100, function() { win.startIsolated(false) })
  }

  // ---- replay and raster alone, at the sizes the card chose
  property int sharpItem: 0
  property int glowItem: 0
  property var isoPalette: ({})
  property bool isoGlow: false
  property int isoWidth: 1
  property int isoRuns: 0
  property var isoJs: []
  property var isoRaster: []

  function startIsolated(glow) {
    win.isoGlow = glow
    win.isoWidth = Math.max(1, glow ? win.glowItem : win.sharpItem)
    if (glow && win.glowItem <= 0) {
      win.after(10, win.nextLevel)
      return
    }
    win.isoRuns = 0
    win.isoJs = []
    win.isoRaster = []
    isoLoader.active = true
  }

  function isoDone() {
    isoLoader.active = false
    var layer = win.isoGlow ? "glow" : "sharp"
    win.report("isolated level=" + win.level + " layer=" + layer + " item=" + win.isoWidth
      + " replay " + win.fmt(win.stats(win.isoJs.slice(win.isoWarmup))))
    win.report("isolated level=" + win.level + " layer=" + layer + " item=" + win.isoWidth
      + " raster " + win.fmt(win.stats(win.isoRaster.slice(win.isoWarmup))))
    if (!win.isoGlow) win.after(50, function() { win.startIsolated(true) })
    else win.after(50, win.nextLevel)
  }

  Loader {
    id: isoLoader
    active: false
    sourceComponent: Canvas {
      id: iso
      width: win.isoWidth
      height: width
      renderTarget: Canvas.Image
      renderStrategy: Canvas.Threaded

      property double jsEndAt: 0

      onPaint: {
        var ctx = getContext("2d")
        var ops = win.opsSequence[win.isoRuns % win.opsSequence.length]
        var started = Date.now()
        if (win.isoGlow) Painter.paintGlow(ctx, win.side, ops, win.isoPalette, width / win.side)
        else Painter.paint(ctx, win.side, ops, win.isoPalette, width / win.side)
        iso.jsEndAt = Date.now()
        win.isoJs.push(iso.jsEndAt - started)
      }
      onPainted: {
        if (iso.jsEndAt <= 0) return
        win.isoRaster.push(Date.now() - iso.jsEndAt)
        iso.jsEndAt = 0
        win.isoRuns += 1
        if (win.isoRuns < win.isoPaints) iso.requestPaint()
        else Qt.callLater(win.isoDone)
      }
      onAvailableChanged: if (available) iso.requestPaint()
    }
  }

  Component.onCompleted: win.after(50, win.loadPlugin)
}
