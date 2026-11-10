import QtQuick

// A scripted stand-in for Quickshell's AuthFlow, for the display-only
// preview (`omarchy-shell polkit preview`). It has the AuthFlow surface the
// polkit controller reads and plays one request on journal timings, so the
// card can be recorded in every state with no polkitd, PAM or camera.
//
// It takes no answer: submit() has no parameter, and the preview card's
// field never takes focus or text. The "user" of a scenario (Enter, typing,
// Esc) is userAction, which the controller turns into the same lane events
// a real key would, without ever reading a field.
QtObject {
  id: fake

  // AuthFlow's surface.
  property string message: ""
  property bool isResponseRequired: false
  property string inputPrompt: ""
  property bool responseVisible: false
  property string supplementaryMessage: ""
  property bool supplementaryIsError: false
  property bool isCompleted: false
  property bool isSuccessful: false
  property bool isCancelled: false
  property bool failed: false

  signal authenticationSucceeded()
  signal authenticationFailed()
  signal authenticationRequestCancelled()

  // "submitEmpty" | "submitTyped" | "type" | "cancel"
  signal userAction(string kind)

  property string scenario: ""
  // From the scan's start (Enter) to PAM's answer, or to the Esc.
  property int scanMs: 0
  property bool running: false
  property int sessions: 0

  // Timings from this host's journal: the helper's hint and prompt land
  // within about 0.1 s, a match reaches the agent about 0.1 s after Howdy's
  // verdict, and a new session prompts again as quickly.
  readonly property int hintAfterMs: 80
  readonly property int promptAfterMs: 110
  readonly property int enterAfterMs: 900
  readonly property int infoLeadMs: 90
  readonly property int missLingerMs: 4200
  readonly property int typeAfterMs: 500
  readonly property int typeEveryMs: 110
  readonly property int typedLength: 8

  // What PAM and polkit would print, in the English they print it in.
  readonly property string actionLine: "Authentication is needed to run `/usr/bin/true' as the super user" // i18n: ignore
  readonly property string askLine: "Press Enter on an empty password to use your face." // i18n: ignore
  readonly property string matchLine: "Face matched" // i18n: ignore
  readonly property string timeoutLine: "Face verification timed out" // i18n: ignore
  readonly property string promptLine: "Password: " // i18n: ignore

  property var queue: []
  property Timer clock: Timer {
    repeat: false
    onTriggered: fake.runDue()
  }

  function after(ms, fn) {
    var next = fake.queue.slice()
    next.push({ due: Date.now() + Math.max(0, ms), fn: fn })
    next.sort(function(a, b) { return a.due - b.due })
    fake.queue = next
    fake.arm()
  }

  function arm() {
    if (!fake.queue.length) {
      fake.clock.stop()
      return
    }
    fake.clock.interval = Math.max(0, fake.queue[0].due - Date.now())
    fake.clock.restart()
  }

  function runDue() {
    var now = Date.now()
    while (fake.running && fake.queue.length && fake.queue[0].due <= now + 1) {
      var item = fake.queue[0]
      fake.queue = fake.queue.slice(1)
      item.fn()
    }
    if (fake.running) fake.arm()
  }

  function reset() {
    fake.queue = []
    fake.clock.stop()
    fake.message = ""
    fake.isResponseRequired = false
    fake.inputPrompt = ""
    fake.responseVisible = false
    fake.supplementaryMessage = ""
    fake.supplementaryIsError = false
    fake.isCompleted = false
    fake.isSuccessful = false
    fake.isCancelled = false
    fake.failed = false
    fake.sessions = 0
  }

  function start(scenario, scanMs) {
    fake.running = false
    fake.reset()
    fake.scenario = scenario
    fake.scanMs = scanMs
    fake.message = fake.actionLine
    fake.running = true
    fake.beginSession()
  }

  function stop() {
    fake.running = false
    fake.queue = []
    fake.clock.stop()
  }

  // One PAM session: the ask hint, then the password prompt.
  function beginSession() {
    fake.sessions += 1
    var session = fake.sessions
    fake.after(fake.hintAfterMs, function() { fake.showInfo(fake.askLine) })
    fake.after(fake.promptAfterMs, function() {
      fake.request(fake.promptLine)
      if (session === 1) fake.playUser()
    })
  }

  // What the scenario's user does at the first prompt.
  function playUser() {
    if (fake.scenario === "typed") {
      var i
      for (i = 1; i <= fake.typedLength; i++) {
        fake.after(fake.typeAfterMs + i * fake.typeEveryMs, function() { fake.userAction("type") })
      }
      fake.after(fake.typeAfterMs + (fake.typedLength + 2) * fake.typeEveryMs, function() { fake.userAction("submitTyped") })
      return
    }
    fake.after(fake.enterAfterMs, function() { fake.userAction("submitEmpty") })
  }

  function request(prompt) {
    fake.inputPrompt = prompt
    fake.responseVisible = false
    fake.isResponseRequired = true
  }

  function showInfo(line) {
    fake.supplementaryIsError = false
    fake.supplementaryMessage = line
  }

  function showError(line) {
    fake.supplementaryIsError = true
    fake.supplementaryMessage = line
  }

  // Takes no answer: the preview has none to give.
  function submit() {
    if (!fake.running || !fake.isResponseRequired || fake.isCompleted) return
    fake.isResponseRequired = false
    fake.inputPrompt = ""
    fake.responseVisible = false
    if (fake.scenario === "match") {
      fake.after(Math.max(0, fake.scanMs - fake.infoLeadMs), function() { fake.showInfo(fake.matchLine) })
      fake.after(fake.scanMs, function() { fake.complete(true) })
    } else if (fake.scenario === "typed") {
      fake.after(fake.scanMs, function() { fake.complete(true) })
    } else if (fake.scenario === "miss") {
      fake.after(Math.max(0, fake.scanMs - 30), function() { fake.showError(fake.timeoutLine) })
      fake.after(fake.scanMs, function() { fake.complete(false) })
    } else if (fake.scenario === "cancel") {
      fake.after(fake.scanMs, function() { fake.userAction("cancel") })
    }
  }

  // AuthFlow.completed: a success ends the request; a failure starts a new
  // session for the same request.
  function complete(ok) {
    if (ok) {
      fake.isSuccessful = true
      fake.isCompleted = true
      fake.authenticationSucceeded()
      fake.stop()
      return
    }
    fake.failed = true
    fake.authenticationFailed()
    fake.beginSession()
    if (fake.scenario === "miss") fake.after(fake.missLingerMs, function() { fake.userAction("cancel") })
  }

  function cancelAuthenticationRequest() {
    if (fake.isCompleted) return
    fake.isCancelled = true
    fake.isCompleted = true
    fake.stop()
  }
}
