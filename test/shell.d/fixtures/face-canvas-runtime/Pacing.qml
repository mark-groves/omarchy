import QtQuick
import "../../../../shell/Ui" as Ui
import qs.Commons

// The real FaceChromeCanvas against a stub plugin, run at scale 2: how big
// its layers are, and how it paces a slow plugin.
Window {
  id: win
  width: 240
  height: 240
  visible: true

  function report(phase, fields) {
    console.log("RESULT " + phase + " " + fields)
  }

  Loader {
    id: cardLoader
    width: 220
    height: 220
    active: false
    sourceComponent: Ui.FaceChromeCanvas {
      cardState: "scanning"
      active: true
    }
  }
  readonly property var card: cardLoader.item

  // frame() calls made beyond the sharp paints that have landed. Each frame
  // waits for the last one to land, so this never passes one.
  property int landed: 0
  property int ahead: 0
  property double firstSwapAt: 0

  Connections {
    target: win.card ? win.card.canvas : null
    function onPainted() {
      win.landed += 1
    }
  }

  onFrameSwapped: {
    if (win.card && win.firstSwapAt === 0) win.firstSwapAt = Date.now()
    if (win.card) win.ahead = Math.max(win.ahead, FaceChrome.frameCalls - win.landed)
  }

  function show(level, delayMs) {
    FaceChrome.qualityLevel = level
    FaceChrome.frameDelayMs = delayMs
    FaceChrome.frameCalls = 0
    win.landed = 0
    win.ahead = 0
    win.firstSwapAt = 0
    cardLoader.active = true
  }

  function hide() {
    cardLoader.active = false
  }

  // One step at a time, each after the last one's wait.
  property var steps: [
    function() { win.show(0, 0); return 400 },
    function() { win.sharp0 = win.card.canvas ? win.card.canvas.width : -1; win.hide(); win.show(1, 0); return 400 },
    function() {
      win.report("sizing", "sharp0=" + win.sharp0 + " sharp1=" + (win.card.canvas ? win.card.canvas.width : -1)
        + " side=" + win.card.side + " dpr=" + Math.round(Screen.devicePixelRatio))
      win.hide()
      // A plugin that takes 300 ms a frame: every swap gap is past what a hold
      // credits, and the art still has to move with the wall clock.
      win.show(0, 300)
      return 2500
    },
    function() {
      win.report("pacing", "frames=" + FaceChrome.frameCalls + " landed=" + win.landed + " ahead=" + win.ahead
        + " artElapsed=" + Math.round(FaceChrome.lastElapsed)
        + " wall=" + (win.firstSwapAt > 0 ? Date.now() - win.firstSwapAt : 0))
      win.hide()
      Qt.quit()
      return 0
    }
  ]
  property int sharp0: -1
  property int step: 0

  Timer {
    id: stepper
    interval: 50
    running: true
    onTriggered: {
      var wait = win.steps[win.step]()
      win.step += 1
      if (win.step < win.steps.length) {
        interval = Math.max(1, wait)
        restart()
      }
    }
  }
}
