pragma Singleton
import QtQuick

// Stands in for the shell's FaceChrome so the real FaceChromeCanvas can run
// under plain Qt without Quickshell or a chrome plugin.
QtObject {
  property bool ready: true
  property int revision: 0
  property int opLevel: 3
  property int qualityLevel: 0

  function holdMs(state) {
    if (state === "recognized") return 300
    if (state === "notRecognized") return 200
    return 0
  }

  function scanMs() {
    return 0
  }

  function frame(size, state, clock, elapsed) {
    return []
  }
}
