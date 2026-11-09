pragma Singleton
import QtQuick

// Stands in for the shell's FaceChrome so the real FaceChromeCanvas can run
// under plain Qt without Quickshell or a chrome plugin. frameDelayMs makes
// the plugin slow on the GUI thread; the frame() calls and the clocks they
// were handed are recorded.
QtObject {
  property bool ready: true
  property int revision: 0
  property int opLevel: 3
  property int qualityLevel: 0

  property int frameDelayMs: 0
  property int frameCalls: 0
  property real lastClock: 0
  property real lastElapsed: 0

  function holdMs(state) {
    if (state === "recognized") return 300
    if (state === "notRecognized") return 200
    return 0
  }

  function scanMs() {
    return 0
  }

  function frame(size, state, clock, elapsed) {
    frameCalls += 1
    lastClock = clock
    lastElapsed = elapsed
    var until = Date.now() + frameDelayMs
    while (Date.now() < until) {}
    return []
  }
}
