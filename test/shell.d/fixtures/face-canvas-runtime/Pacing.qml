import QtQuick
import "../../../../shell/Ui" as Ui
import qs.Commons

// The real FaceChromeCanvas against a stub plugin, run at scale 2: how big
// its layers are.
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

  function show(level) {
    FaceChrome.qualityLevel = level
    cardLoader.active = true
  }

  function hide() {
    cardLoader.active = false
  }

  // One step at a time, each after the last one's wait.
  property var steps: [
    function() { win.show(0); return 400 },
    function() { win.sharp0 = win.card.canvas ? win.card.canvas.width : -1; win.hide(); win.show(1); return 400 },
    function() {
      win.report("sizing", "sharp0=" + win.sharp0 + " sharp1=" + (win.card.canvas ? win.card.canvas.width : -1)
        + " side=" + win.card.side + " dpr=" + Math.round(Screen.devicePixelRatio))
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
