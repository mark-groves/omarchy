import QtQuick
import Quickshell
import qs.Commons

// The face card hangs above the lock's password field. Walk the view through
// every face state the lock shows and check that the card and its captions
// stay put: a caption that hid itself when it had nothing to say once dropped
// the card 25px for the whole of a match. The view sits in a window, so it is
// laid out the way it is on screen (positioners settle on the window's
// polish, not as a property changes).
ShellRoot {
  id: root

  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  readonly property string rootPath: Quickshell.env("OMARCHY_PATH")
  readonly property var watched: ["faceCardIndicator", "faceStatusCaption", "faceHintCaption"]
  property var failures: []
  property var samples: []
  property var view: null
  property int step: 0

  // [label, card wanted, face state]
  readonly property var steps: [
    ["idle", false, "scanning"],
    ["request", true, "scanning"],
    ["recognized", true, "recognized"],
    ["scanning", true, "scanning"],
    ["notRecognized", true, "notRecognized"],
    ["idle after a miss", false, "notRecognized"]
  ]

  function find(node, name) {
    if (!node) return null
    if (node.objectName === name) return node
    var kids = node.children || []
    for (var i = 0; i < kids.length; i++) {
      var found = find(kids[i], name)
      if (found) return found
    }
    return null
  }

  function sample(label) {
    var at = { label: label }
    for (var i = 0; i < watched.length; i++) {
      var item = find(view, watched[i])
      if (item) at[watched[i]] = item.mapToItem(view, 0, 0).y
    }
    samples.push(at)
  }

  function check() {
    for (var i = 0; i < watched.length; i++) {
      var name = watched[i]
      if (samples[0][name] === undefined) {
        failures.push("the lock view has " + name)
        continue
      }
      for (var j = 1; j < samples.length; j++) {
        if (samples[j][name] !== samples[0][name]) {
          failures.push(name + " moved from y=" + samples[0][name] + " (" + samples[0].label + ") to y="
            + samples[j][name] + " (" + samples[j].label + ")")
        }
      }
    }
  }

  function writeResult() {
    var payload = JSON.stringify({ ok: failures.length === 0, failures: failures, samples: samples })
    var quoted = "'" + payload.replace(/'/g, "'\\''") + "'"
    Quickshell.execDetached(["bash", "-c", "printf '%s' " + quoted + " > \"$1\"", "_", resultPath])
  }

  Window {
    width: 1600
    height: 1000
    visible: true
    color: "black"

    Item { id: host; anchors.fill: parent }
  }

  // Each step gives the window time to lay out and present before it is read.
  Timer {
    interval: 150
    repeat: true
    running: true
    onTriggered: {
      try {
        if (!root.view) {
          // A chrome plugin that draws nothing, so the card paints.
          FaceChrome.api = {
            frame: function() { return [] },
            holdMs: function(state) { return state === "scanning" ? 0 : 300 },
            scanMs: function() { return 0 }
          }
          var component = Qt.createComponent("file://" + root.rootPath + "/shell/plugins/lock/LockView.qml", Component.PreferSynchronous)
          if (component.status !== Component.Ready) throw new Error(component.errorString())
          root.view = component.createObject(host, { width: 1600, height: 1000, loadBackground: false,
            faceConfigured: true, faceOnRequest: true, faceCardActive: false })
          if (!root.view) throw new Error(component.errorString())
        } else {
          root.sample(root.steps[root.step - 1][0])
        }
        if (root.step >= root.steps.length) {
          stop()
          root.check()
          root.writeResult()
          return
        }
        var next = root.steps[root.step]
        root.view.faceCardActive = next[1]
        root.view.faceState = next[2]
        root.view.facePlaybackEpoch += 1
        root.step += 1
      } catch (error) {
        stop()
        root.failures.push("lock face card fixture threw: " + error)
        root.writeResult()
      }
    }
  }
}
