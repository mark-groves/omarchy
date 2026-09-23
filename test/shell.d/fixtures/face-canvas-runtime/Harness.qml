import QtQuick
import "../../../../shell/Ui" as Ui

// A hidden window is a surface that is not presenting: Qt keeps ticking
// animations on its own timer, but nothing is swapped. That is the lock
// surface after resume, before the compositor asks for a frame.
Window {
  id: win
  width: 160
  height: 160
  visible: false

  property int playedCount: 0
  property double shownAt: 0
  property double playedAt: 0

  function report(phase) {
    console.log("RESULT " + phase
      + " ticks=" + card.animationTicks
      + " swaps=" + card.presentedSwaps
      + " elapsed=" + Math.round(card.elapsed)
      + " played=" + win.playedCount
      + " afterShowMs=" + (win.playedAt > 0 ? Math.round(win.playedAt - win.shownAt) : -1))
  }

  Ui.FaceChromeCanvas {
    id: card
    anchors.fill: parent
    cardState: "recognized"
    active: true
    onResultPlayed: {
      win.playedCount += 1
      win.playedAt = Date.now()
    }
  }

  Timer {
    interval: 700
    running: true
    onTriggered: {
      win.report("frozen")
      win.shownAt = Date.now()
      win.visible = true
      presented.start()
    }
  }

  Timer {
    id: presented
    interval: 1200
    onTriggered: {
      win.report("presented")
      card.active = false
      win.playedAt = 0
      win.shownAt = Date.now()
      card.playbackEpoch += 1
      inactive.start()
    }
  }

  Timer {
    id: inactive
    interval: 700
    onTriggered: {
      win.report("inactive")
      Qt.quit()
    }
  }
}
