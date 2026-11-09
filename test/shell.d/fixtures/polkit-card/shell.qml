import QtQuick
import QtQuick.Window
import Quickshell
import qs.Commons

// Runs the real polkit controller and card in a plain window, offscreen:
// PanelWindow has no backend there, and nothing here touches polkitd. A
// recording stand-in for AuthFlow plays the real requests; the preview runs
// its own FakeFlow. Each step waits for a condition, then acts and checks.
ShellRoot {
  id: top

  readonly property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  readonly property string rootPath: Quickshell.env("OMARCHY_PATH")
  readonly property string plugin: "file://" + rootPath + "/shell/plugins/polkit/"
  property var failures: []
  property var controller: null
  property var realCard: null
  property var previewCard: null
  property var flow: null
  // Card rects seen in each face state, per card.
  property var rects: ({})

  function fail(message) {
    failures.push(String(message))
  }

  function check(condition, message) {
    if (!condition) fail(message)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function writeResult() {
    var payload = JSON.stringify({ ok: failures.length === 0, failures: failures, rects: rects })
    if (resultPath) Quickshell.execDetached(["bash", "-lc", "printf '%s' " + shellQuote(payload) + " > " + shellQuote(resultPath)])
  }

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

  function rectKey(r) {
    return [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height)].join(",")
  }

  // Every rect a card shows while open, keyed by the face state on screen.
  function sample(card, tag) {
    if (!card || !card.current || !controller || controller.lane.phase === "closed") return
    var key = tag + ":" + controller.lane.faceState
    var seen = rects[key] || []
    var r = rectKey(card.cardRect) + "|" + rectKey(card.faceRect)
    if (seen.indexOf(r) === -1) seen.push(r)
    var next = {}
    for (var k in rects) next[k] = rects[k]
    next[key] = seen
    rects = next
  }

  function sameRectEverywhere(tag, states) {
    var all = []
    for (var i = 0; i < states.length; i++) {
      var seen = rects[tag + ":" + states[i]]
      if (!seen) {
        fail(tag + " card never showed " + states[i])
        continue
      }
      for (var j = 0; j < seen.length; j++) if (all.indexOf(seen[j]) === -1) all.push(seen[j])
    }
    check(all.length === 1, tag + " card and face area keep one place and size through " + states.join(", ") + ": " + JSON.stringify(all))
  }

  function captions(card) {
    return find(card, "polkitCaptionPrimary").text + " | " + find(card, "polkitCaptionSecondary").text
  }

  Window {
    id: win
    width: 1600
    height: 1000
    visible: true
    color: "black"
  }

  Window {
    id: previewWin
    width: 1600
    height: 1000
    visible: true
    color: "black"
  }

  Component {
    id: recordingFlow

    // AuthFlow's surface, recording what the card submits and the lane at
    // that moment.
    QtObject {
      property string message: "Authentication is needed to run `/usr/bin/true' as the super user"
      property bool isResponseRequired: false
      property string inputPrompt: ""
      property bool responseVisible: false
      property string supplementaryMessage: ""
      property bool supplementaryIsError: false
      property bool isCompleted: false
      property bool isSuccessful: false
      property bool isCancelled: false
      property bool failed: false
      property var submissions: []
      property int cancels: 0

      signal authenticationSucceeded()
      signal authenticationFailed()
      signal authenticationRequestCancelled()

      function submit(value) {
        submissions = submissions.concat([{ value: value, faceState: top.controller.lane.faceState, pending: top.controller.lane.pending }])
        isResponseRequired = false
        inputPrompt = ""
      }

      function cancelAuthenticationRequest() {
        cancels += 1
        isCancelled = true
        isCompleted = true
      }

      function prompt() {
        supplementaryIsError = false
        supplementaryMessage = "Press Enter on an empty password to use your face."
        inputPrompt = "Password: "
        isResponseRequired = true
      }

      function succeed() {
        isSuccessful = true
        isCompleted = true
        authenticationSucceeded()
      }

      // AuthFlow.completed(false): a new session asks again.
      function failSession(reason) {
        if (reason) {
          supplementaryIsError = true
          supplementaryMessage = reason
        }
        failed = true
        authenticationFailed()
      }
    }
  }

  function newRequest() {
    flow = recordingFlow.createObject(top)
    controller.beginRealFlow(flow)
  }

  readonly property var steps: [
    {
      name: "build the controller and both cards",
      run: function() {
        var cc = Qt.createComponent(top.plugin + "PolkitController.qml", Component.PreferSynchronous)
        if (cc.status !== Component.Ready) return top.fail("PolkitController failed to load: " + cc.errorString())
        top.controller = cc.createObject(win.contentItem, { pamPath: top.rootPath + "/test/shell.d/fixtures/polkit-pam/ask-first.pam" })
        var card = Qt.createComponent(top.plugin + "PolkitCard.qml", Component.PreferSynchronous)
        if (card.status !== Component.Ready) return top.fail("PolkitCard failed to load: " + card.errorString())
        top.realCard = card.createObject(win.contentItem, { controller: top.controller, width: win.width, height: win.height })
        top.realCard.shown = Qt.binding(function() { return top.controller.realShown })
        top.previewCard = card.createObject(previewWin.contentItem, { controller: top.controller, preview: true, width: previewWin.width, height: previewWin.height })
        top.previewCard.shown = Qt.binding(function() { return top.controller.previewShown })
        top.controller.laneChanged.connect(function() {
          top.sample(top.realCard, "real")
          top.sample(top.previewCard, "preview")
        })
        top.check(top.controller.realCard === top.realCard && top.controller.previewCard === top.previewCard, "each card registers with the controller")
        win.requestActivate()
      }
    },
    {
      name: "the Ask first stack opens a face card on the idle offer",
      until: function() { return top.controller.pamSteps.length > 0 },
      run: function() {
        top.newRequest()
        top.check(top.controller.starting && top.controller.lane.phase === "closed", "the card waits for the lid check before it opens")
      }
    },
    {
      until: function() { return top.controller.lane.phase === "open" },
      run: function() {
        var lane = top.controller.lane
        top.check(lane.trigger === "ask", "the live Ask first stack is an ask lane, got " + lane.trigger)
        top.check(lane.faceState === "idle", "the card opens on the idle face area, not a scan")
        top.check(top.controller.wantsKeyboard, "a live request holds the keyboard")
        top.flow.prompt()
      }
    },
    {
      until: function() { return top.controller.lane.prompt && top.realCard.fieldFocused },
      run: function() {
        top.check(top.captions(top.realCard) === "Press Enter to use your face | or type your password", "the card offers face before Enter: " + top.captions(top.realCard))
        top.controller.submitResponse(false)
        top.check(top.flow.submissions.length === 0, "an empty Enter right after the prompt is dropped")
      }
    },
    {
      wait: 700,
      run: function() {
        top.controller.submitResponse(true)
        top.check(top.flow.submissions.length === 0, "an autorepeated empty Enter is dropped")
        top.controller.submitResponse(false)
        var sent = top.flow.submissions
        top.check(sent.length === 1 && sent[0].value === "", "an armed empty Enter sends an empty answer")
        top.check(sent.length === 1 && sent[0].faceState === "scanning" && sent[0].pending === "face", "the card is scanning before PAM hears the answer")
        top.check(top.captions(top.realCard) === "Look at the camera | Esc cancels", "scanning captions: " + top.captions(top.realCard))
      }
    },
    {
      wait: 150,
      run: function() {
        top.flow.succeed()
        top.check(!top.controller.wantsKeyboard, "the keyboard goes back as soon as PAM approves")
        top.check(top.controller.lane.pendingMatch || top.controller.lane.faceState === "recognized", "a match waits for the scan or plays")
      }
    },
    {
      until: function() { return top.controller.lane.faceState === "recognized" },
      run: function() {
        top.check(top.captions(top.realCard) === "Face recognized | ", "recognized captions: " + top.captions(top.realCard))
      }
    },
    {
      until: function() { return top.controller.lane.phase === "closed" && !top.controller.realShown },
      run: function() {
        top.check(top.controller.lane.outcome === "succeeded" && top.controller.lane.wrong === 0, "a face match closes the card without a wrong")
        top.newRequest()
      }
    },
    {
      name: "a face miss plays not recognized and goes back to the field",
      until: function() { return top.controller.lane.phase === "open" },
      run: function() { top.flow.prompt() }
    },
    {
      until: function() { return top.controller.lane.prompt && top.realCard.fieldFocused },
      wait: 700,
      run: function() {
        top.controller.submitResponse(false)
        top.check(top.controller.lane.faceState === "scanning", "the retry request scans")
      }
    },
    {
      wait: 400,
      run: function() {
        top.flow.failSession("Face verification timed out")
        var lane = top.controller.lane
        top.check(lane.faceState === "notRecognized" && lane.hold === "notRecognized", "a failed session during the scan is not recognized")
        top.check(lane.wrong === 0 && !top.controller.errorFlash && top.controller.shakeOffset === 0, "a face miss is not a wrong password")
        top.check(top.controller.wantsKeyboard, "the request stays live through a miss")
        top.flow.prompt()
        top.check(top.controller.lane.faceState === "notRecognized" && top.controller.lane.epoch === lane.epoch, "the next session's prompt is not another miss")
      }
    },
    {
      until: function() { return top.controller.lane.faceState === "idle" },
      run: function() {
        top.check(top.controller.lane.retry, "the field comes back offering another try")
        top.check(top.captions(top.realCard) === "Press Enter to try again | or type your password", "retry captions: " + top.captions(top.realCard))
        var field = top.find(top.realCard, "polkitPasswordInput")
        field.text = "hunter2"
        top.controller.submitResponse(false)
        var sent = top.flow.submissions
        top.check(sent.length === 2 && sent[1].value === "hunter2", "a typed password reaches PAM unchanged")
        top.check(sent.length === 2 && sent[1].faceState === "idle" && sent[1].pending === "password", "a typed password does not start a scan")
        top.check(top.realCard.fieldEmpty, "the field is cleared as the answer leaves")
      }
    },
    {
      wait: 100,
      run: function() {
        top.flow.failSession("")
        var lane = top.controller.lane
        top.check(lane.wrong === 1 && top.controller.errorFlash, "a refused password flashes wrong")
        top.check(lane.faceState === "idle" && lane.hold === "", "a refused password is not a face miss")
        top.flow.prompt()
      }
    },
    {
      wait: 200,
      run: function() {
        top.check(top.controller.startPreview("match") === "busy", "a preview is refused while a real request owns the card")
        top.controller.cancelRequest()
        top.check(top.flow.cancels === 1, "Esc cancels the request")
        top.check(top.controller.lane.phase === "closing", "Esc fades the card out")
      }
    },
    {
      until: function() { return top.controller.lane.phase === "closed" && !top.controller.realShown },
      run: function() {
        top.sameRectEverywhere("real", ["idle", "scanning", "recognized", "notRecognized"])
        top.check(top.controller.startPreview("bogus") !== "ok", "an unknown preview scenario is refused")
        top.check(top.controller.startPreview("match:300") === "ok", "the preview starts")
        top.check(top.controller.previewing && top.previewCard.current && !top.realCard.current, "the preview drives only the preview card")
      }
    },
    {
      name: "the preview plays a match from its scripted flow",
      until: function() { return top.controller.lane.faceState === "scanning" },
      run: function() {
        var field = top.find(top.previewCard, "polkitPasswordInput")
        top.check(!field.activeFocus && field.readOnly && !field.enabled, "the preview's field takes no focus or text")
        top.check(!top.controller.wantsKeyboard && !top.controller.realShown, "the preview never holds the keyboard")
      }
    },
    {
      until: function() { return top.controller.lane.faceState === "recognized" },
      run: function() {
        var status = JSON.parse(top.controller.statusJson())
        top.check(status.surface === "polkit-preview" && status.window === "omarchy-polkit-preview", "status names the preview surface")
        top.check(status.faceState === "recognized" && status.rect.h > 0, "status reports the face state and the card rect")
      }
    },
    {
      until: function() { return !top.controller.previewing && top.controller.lane.phase === "closed" },
      run: function() {
        top.sameRectEverywhere("preview", ["idle", "scanning", "recognized"])
        top.check(top.rects["preview:idle"][0] === top.rects["real:idle"][0], "the preview card sits where the real one does")
      }
    }
  ]

  property int stepIndex: 0
  property double stepStarted: 0
  property bool waited: false

  Timer {
    interval: 20
    repeat: true
    running: true
    onTriggered: {
      if (top.stepIndex >= top.steps.length || top.failures.length > 0) {
        stop()
        top.writeResult()
        return
      }
      var step = top.steps[top.stepIndex]
      var now = Date.now()
      if (top.stepStarted === 0) top.stepStarted = now
      try {
        if (step.until && !step.until()) {
          if (now - top.stepStarted > 5000) top.fail("timed out waiting before step " + top.stepIndex + (step.name ? " (" + step.name + ")" : ""))
          return
        }
        if (step.wait && !top.waited) {
          top.waited = true
          top.stepStarted = now
          return
        }
        if (step.wait && now - top.stepStarted < step.wait) return
        step.run()
      } catch (error) {
        top.fail("step " + top.stepIndex + " threw: " + error)
      }
      top.stepIndex += 1
      top.stepStarted = 0
      top.waited = false
    }
  }

  Component.onCompleted: FaceChrome.sourceUrl = "file://" + rootPath + "/test/shell.d/fixtures/polkit-card/stub-face.js"
}
