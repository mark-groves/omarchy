import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "../../Commons/FacePlayback.js" as Playback
import "FingerprintModel.js" as FingerprintModel

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: home + "/.local/state"
  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string currentBackgroundLink: stateHome + "/omarchy/current/background"

  property bool lockRequested: false
  property bool pendingSessionLock: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  property bool faceAuthenticating: false
  // Display-only hold after PAM already returned, so an instant match still
  // lets the recognised (or miss) frame play out. Completion comes from the
  // canvas, after presented frames, and does not change the PAM result.
  property bool faceHolding: false
  // Set when a suspend is announced. A scan begun now would freeze inside
  // the suspend and fail on resume with the camera still gone, so none
  // starts until the resume is seen (or the announced sleep never comes).
  property bool faceAwaitingResume: false
  property double faceStartedAtMs: 0
  // Failures that cannot have been a look at a face: Howdy returning before
  // it could capture (the camera is not back yet after resume) or a scan
  // that spanned a suspend. Retried quietly, still showing the scan.
  property int faceQuietRetries: 0
  // A match that came back before the card had shown its scan. PAM has
  // already succeeded; the result waits only until the scan has booted
  // (faceScanSeen) or faceMatchWaitTimer runs out, whichever is first.
  property bool facePendingMatch: false
  property bool faceScanSeen: false
  // shell.json lock.face: "request" (the default) keeps the camera off and the
  // card hidden until the user asks with the face button, Space or Enter on
  // an empty field; "automatic" scans whenever the lock is up and lit.
  readonly property var lockConfig: shell && shell.shellConfig && Util.isPlainObject(shell.shellConfig.lock)
    ? shell.shellConfig.lock : ({})
  readonly property bool faceOnRequest: String(lockConfig.face || "request") !== "automatic"
  // The user asked for a scan and the attempt (quiet retries included) is
  // still theirs. Cleared by a miss, typing, a blank or a suspend.
  property bool faceRequested: false
  // Whether the face card belongs on screen at all.
  readonly property bool faceCardActive: !faceOnRequest || faceRequested || faceHolding || facePendingMatch
  property double lastResumeMs: 0
  readonly property int faceNoLookMs: 1500
  readonly property int faceSpannedSleepMs: 20000
  readonly property int faceQuietRetryLimit: 8
  property int facePlaybackEpoch: 0
  // Bumped when the lock surface has to commit a buffer again after resume.
  property int lockPresentEpoch: 0
  // What the shared face card should be showing. Lock previously bound nothing
  // face-related into the view, so a scan and a miss were both silent.
  property string faceState: "scanning"
  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property bool faceConfigured: false
  property bool laptopClosed: false
  property int fingerprintUnreachedStreak: 0
  property bool fingerprintAttemptReachedDevice: false
  property bool fingerprintAttemptFastError: false
  property double fingerprintAttemptPromptedAtMs: 0
  property double fingerprintLastNudgeMs: 0
  property double fingerprintLastSettleMs: 0
  property double fingerprintResumedAtMs: 0
  property int fingerprintProbeStreak: 0
  // While the lock has the displays off no new attempt starts, so the reader
  // isn't held awake all night; any wake starts it again.
  property bool fingerprintPaused: false
  // The sleep watch is stopped while paused, so a sleep seen after the
  // pre-suspend lock request is marked here instead.
  property bool fingerprintSleptWhilePaused: false
  // When the armed retry is due, so time spent blank counts toward it.
  property double fingerprintRetryDueMs: 0
  // The backoff the armed retry was set to; a wake shortens the timer to the
  // remaining wait, so the input guard reads the tier from here instead.
  property int fingerprintRetryBackoffMs: 0
  // Outputs the lock last saw, so only a display arriving counts as a wake.
  property int knownScreenCount: 0
  property bool previewVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property string backgroundPath: ""
  property string videoPosterPath: ""
  property int backgroundVersion: 0
  // The wallpaper file's mtime and size. The lock caches its wallpaper by
  // version, so a file overwritten in place must bump the version too.
  property string backgroundSignature: ""
  property string lastEvent: "init"
  property string lastEventAt: ""
  readonly property bool videoBackground: Util.isVideoPath(backgroundPath)
  // What the lock itself asked of the displays. Face pauses while they are
  // blank. The wallpaper no longer polls Hyprland for each panel's DPMS.
  property bool displaysBlank: false
  property bool strandedLock: false
  property bool strandedLockResolved: false

  // Published from currentlyLocked(), not bound to it. That binding once kept
  // its last true value after an unlock: lid lock then did nothing, and
  // polkit's cover hid the password card so the PAM conversation waited with
  // no face tile. It is writable:
  // assigning a readonly property throws and leaves the flag stuck.
  property bool locked: false

  onLockedChanged: LockCover.covered = locked
  onLockRequestedChanged: publishLockState()

  // Decisions read the lock state afresh. A property binding that missed a change
  // notification once reported locked after an unlock, and a lock request before
  // suspend then took that for done and never locked the session.
  function currentlyLocked() {
    return lockRequested || sessionLock.locked || sessionLock.secure
  }
  function publishLockState() {
    var now = root.currentlyLocked()
    if (root.locked !== now) root.locked = now
  }
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating || faceAuthenticating
  // A prompt clears the unavailable notice before the attempt finishes.
  readonly property bool fingerprintUnavailable: FingerprintModel.isUnavailable(fingerprintProbeStreak) || (fingerprintConfigured && (!fingerprintAttemptReachedDevice || fingerprintAttemptFastError) && FingerprintModel.isUnavailable(fingerprintUnreachedStreak))

  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0

    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count += 1
    }

    return count
  }

  function hasRealScreen() {
    return realScreenCount() > 0
  }

  function queueSessionLock() {
    pendingSessionLock = true
    if (!sessionLockStabilizeTimer.running) logEvent("lock-pending: screen-stabilizing")
    sessionLockStabilizeTimer.restart()
    if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure) return
    if (sessionLockStabilizeTimer.running) return

    if (!hasRealScreen()) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!pendingSessionLockTimer.running) pendingSessionLockTimer.start()
      return
    }

    pendingSessionLock = false
    pendingSessionLockTimer.stop()
    sessionLock.locked = true
  }

  // ext-session-lock outlives its client, and a restart carries no lock over, so
  // a session locked this early may be an orphan behind Hyprland's failsafe. It
  // may also be another shell's live lock, which Hyprland would let this one
  // take over and then strand on exit, so the helper answers undetermined while
  // another locker runs. Outputs are often still absent here, so ask until the
  // answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheckProc.running) return

    // A lock this shell took is nobody's orphan.
    if (currentlyLocked()) {
      strandedLockResolved = true
      return
    }

    strandedLockCheckProc.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || currentlyLocked() || !passwordPamConfigured) return

    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function refreshBackground() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function refreshPoster() {
    if (!root.videoBackground) {
      root.videoPosterPath = ""
      return
    }
    if (posterProc.running) return
    posterProc.sourcePath = root.backgroundPath
    posterProc.running = true
  }

  function refreshFingerprintStatus() {
    if (!fingerprintCheckProc.running) fingerprintCheckProc.running = true
  }

  function refreshFaceStatus() {
    if (!faceCheckProc.running) faceCheckProc.running = true
    refreshLidState()
  }

  function refreshLidState() {
    if (laptopClosedProc.running) laptopClosedProc.again = true
    else laptopClosedProc.running = true
  }

  // Only definitive enrollment results may disable authentication.
  function applyFingerprintProbe(text) {
    var status = FingerprintModel.classifyProbe(text)
    if (status === "unknown") {
      if (fingerprintConfigured) return
      fingerprintProbeStreak += 1
      if (lockRequested) {
        fingerprintRecheckTimer.interval = FingerprintModel.retryDelayMs(fingerprintProbeStreak)
        fingerprintRecheckTimer.restart()
      }
      return
    }
    fingerprintProbeStreak = 0
    fingerprintRecheckTimer.stop()
    fingerprintConfigured = status === "yes"
    if (lockRequested && fingerprintConfigured) {
      // A pending retry already owns the next attempt.
      if (!fingerprintRetryTimer.running) startFingerprint()
    } else if (!fingerprintConfigured) {
      // abort() delivers no completion signal, so close the attempt here
      // too; settle returns before arming a retry while unconfigured.
      if (fingerprintPam.active) fingerprintPam.abort()
      settleFingerprintAttempt()
      fingerprintRetryTimer.stop()
    }
  }

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("omarchy lock " + lastEventAt + " " + event)
  }

  function resetAuthenticationState() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    fingerprintAuthenticating = false
    faceAuthenticating = false
    faceHolding = false
    fingerprintUnreachedStreak = 0
    fingerprintAttemptFastError = false
    fingerprintAttemptPromptedAtMs = 0
    fingerprintLastNudgeMs = 0
    fingerprintLastSettleMs = 0
    fingerprintResumedAtMs = 0
    fingerprintProbeStreak = 0
    fingerprintPaused = false
    fingerprintSleptWhilePaused = false
    fingerprintRecheckTimer.stop()
    fingerprintRetryTimer.stop()
    fingerprintReachTimer.stop()
    faceRetryTimer.stop()
    faceAwaitingResume = false
    faceQuietRetries = 0
    facePendingMatch = false
    faceScanSeen = false
    faceRequested = false
    faceMatchWaitTimer.stop()
    sleepResumeWatch.stop()
    resumeSettleTimer.stop()
    resumePresentTimer.stop()
    resumeWakeRetryTimer.stop()
    faceUnlockCeiling.stop()
    faceState = "scanning"
    fingerprintResumeTimer.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
    if (facePam.active) facePam.abort()
  }

  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }

    resetAuthenticationState()
    lockRequested = true
    armBlankTimer()
    logEvent("lock-requested")
    queueSessionLock()

    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFaceStatus()
    })

    return true
  }

  function finishUnlock() {
    if (!root.currentlyLocked()) {
      publishLockState()
      return
    }

    lockRequested = false
    pendingSessionLock = false
    sessionLockStabilizeTimer.stop()
    pendingSessionLockTimer.stop()
    resetAuthenticationState()
    idleBlankTimer.stop()
    sessionLock.locked = false
    logEvent("unlocked")
    runWake()
    publishLockState()
  }

  function armBlankTimer() {
    idleBlankTimer.armedAt = Date.now()
    idleBlankTimer.restart()
  }

  function runWake() {
    root.displaysBlank = false
    requestWake()
    if (lockRequested) armBlankTimer()
    // A resume that does not change the lid or the output list never hits
    // the lid or screens handlers. Those were the only commits, so the
    // pre-suspend buffer stayed up and a later face hold could not finish.
    root.rearmLockPresentation()
    resumeFingerprint()
    nudgeFingerprint()
  }

  // A wake asked for while one is still running is queued, not dropped: a
  // wake script stalled by a resuming compositor used to swallow every key
  // and click behind it, leaving the panel dark until it finished.
  function requestWake() {
    if (wakeProcess.running) wakeProcess.again = true
    else wakeProcess.running = true
  }

  // After resume Qt can sit waiting for a frame callback the compositor only
  // sends once it renders that output again, so the lock stays frozen (or
  // dark, before its first commit) until the pointer moves. Moving it one
  // pixel and back is that same nudge without the user.
  function nudgePointer() {
    if (!pointerNudgeProcess.running) pointerNudgeProcess.running = true
  }

  // After resume the lock surface can keep its pre-suspend buffer while Qt
  // still ticks animations. A new commit is what makes Hyprland deliver
  // frame callbacks again, which is the clock the face hold follows.
  // Each output has its own surface, and ids inside the surface component
  // are out of scope here, so every LockView updates its own window.
  function rearmLockPresentation() {
    root.lockPresentEpoch += 1
  }

  // An attempt already running is left to finish under its own timeouts, so
  // a slow claim still completes; only the next one waits for a wake.
  function pauseFingerprint() {
    if (fingerprintPaused) return
    fingerprintPaused = true
    fingerprintRetryTimer.stop()
  }

  // The retry keeps whatever backoff was armed, counting the time spent blank,
  // so a failing reader still gets its idle window; after a sleep it recovers
  // at once, as the sleep watch does.
  function resumeFingerprint() {
    if (!fingerprintPaused) return
    fingerprintPaused = false
    if (fingerprintSleptWhilePaused) {
      fingerprintSleptWhilePaused = false
      noteFingerprintResumed()
      fingerprintRetryBackoffMs = FingerprintModel.MATCH_RETRY_MS
      fingerprintRetryTimer.interval = FingerprintModel.MATCH_RETRY_MS
    } else {
      fingerprintRetryTimer.interval = Math.max(FingerprintModel.MATCH_RETRY_MS, fingerprintRetryDueMs - Date.now())
    }
    if (lockRequested && fingerprintConfigured && !fingerprintAuthenticating) fingerprintRetryTimer.restart()
  }

  // A resume can light the panel with no input to wake the lock, so after a
  // lock request the reader comes back once a sleep is seen; the blank
  // countdown then pauses it again if nothing else happens. The idle service
  // repeats the same request without sleeping, so the sleep has to be seen.
  function noteSleepRequested() {
    if (!lockRequested) return
    holdFaceForSleep()
    if (!fingerprintPaused) return
    // logind holds a suspend for its inhibitor delay, at most 15 seconds here.
    fingerprintResumeTimer.ticksLeft = 20
    fingerprintResumeTimer.lastTickMs = Date.now()
    fingerprintResumeTimer.restart()
  }

  // A scan that is in flight when the machine suspends freezes with it, then
  // fails on resume because the camera is not back yet, and that failure
  // used to play as a miss on a surface that had not started presenting.
  // Drop the scan now and start a fresh one once the resume is seen.
  function holdFaceForSleep() {
    // A result still on the card cannot outlive the suspend. Leaving
    // faceHolding set once faceState returns to scanning stranded it: a match
    // neither played out nor hit its ceiling, and a miss kept every later scan
    // refused until a password unlock. A match is dropped, not honoured: a lid
    // closed mid-card means stay locked and scan again on wake.
    if (faceHolding || facePendingMatch) {
      logEvent("face-result-dropped: sleep")
      faceHolding = false
      facePendingMatch = false
      faceUnlockCeiling.stop()
      faceMatchWaitTimer.stop()
    }
    cancelFaceRequest("sleep")
    faceAwaitingResume = true
    faceRetryTimer.stop()
    faceQuickRetryTimer.stop()
    resumeSettleTimer.stop()
    if (facePam.active) facePam.abort()
    // abort() delivers no completion signal.
    faceAuthenticating = false
    faceState = "scanning"
    // Blanking a panel that is about to suspend buys nothing, and a panel
    // left off has to be woken again on resume. logind can hold the suspend
    // for many seconds while other inhibitors finish.
    idleBlankTimer.stop()
    // A quarter-second tick finds the resume sooner; 80 of them cover the
    // longest logind holds seen before a lid suspend.
    sleepResumeWatch.ticksLeft = 80
    sleepResumeWatch.lastTickMs = Date.now()
    sleepResumeWatch.restart()
  }

  // Lid open and the wall-clock jump after a suspend both land here. Once
  // resume settles, wake the panel, commit the lock surface again over the
  // next seconds while the GPU and outputs come back, and start the scan.
  function handleResume(why) {
    if (!lockRequested) return
    // The lid probe and the sleep watch each see the same resume.
    var now = Date.now()
    var already = resumeSettleTimer.running || now - lastResumeMs < 3000
    faceAwaitingResume = false
    sleepResumeWatch.stop()
    if (already) {
      // The settle may have found the lid still reading closed.
      if (!resumeSettleTimer.running && faceConfigured) startFace()
      return
    }
    lastResumeMs = now
    logEvent("resume: " + why)
    faceQuietRetries = 0
    // Read the lid now rather than on the next poll, so the scan is not
    // refused for a lid that was closed before the suspend.
    refreshLidState()
    // Harmless before the outputs are back, and the sooner the compositor
    // renders the lock again the shorter the frozen frame.
    nudgePointer()
    // The first tick after a suspend can land before the kernel has finished
    // resuming devices. A DPMS request sent then is lost in the compositor's
    // own DRM restore, so the wake waits for the settle.
    resumeSettleTimer.restart()
  }

  // A failure that came back before Howdy could have captured a frame, or
  // that spanned a suspend, says nothing about the face in front of it.
  function retryFaceQuietly() {
    var took = Date.now() - faceStartedAtMs
    if (faceStartedAtMs <= 0) return false
    if (took >= faceNoLookMs && took <= faceSpannedSleepMs) return false
    if (faceQuietRetries >= faceQuietRetryLimit) return false
    faceQuietRetries += 1
    logEvent("face-retry-quiet: took=" + took + "ms try=" + faceQuietRetries)
    faceState = "scanning"
    faceQuickRetryTimer.interval = 300 * faceQuietRetries
    if (!displaysBlank) faceQuickRetryTimer.restart()
    return true
  }

  // User activity advances retries without recreating a busy retry loop.
  function nudgeFingerprint() {
    if (!lockRequested) return
    if (!fingerprintConfigured && fingerprintRecheckTimer.running) {
      var now = Date.now()
      if (FingerprintModel.shouldNudge(now, fingerprintLastNudgeMs, now - FingerprintModel.IDLE_CLEAR_MS, fingerprintRecheckTimer.interval)) {
        fingerprintLastNudgeMs = now
        fingerprintRecheckTimer.interval = FingerprintModel.MATCH_RETRY_MS
        fingerprintRecheckTimer.restart()
      }
      return
    }
    if (!fingerprintConfigured) return
    if (fingerprintPam.active || fingerprintAuthenticating) return
    if (!fingerprintRetryTimer.running) return
    var now = Date.now()
    if (!FingerprintModel.shouldNudge(now, fingerprintLastNudgeMs, fingerprintLastSettleMs, fingerprintRetryBackoffMs)) return
    fingerprintLastNudgeMs = now
    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)
  }


  function armFingerprintRetry(delayMs) {
    fingerprintRetryTimer.interval = delayMs
    fingerprintRetryBackoffMs = delayMs
    fingerprintRetryDueMs = Date.now() + delayMs
    if (!fingerprintPaused) fingerprintRetryTimer.restart()
  }

  // Reset pre-sleep failures while the resume hook restarts fprintd.
  function noteFingerprintResumed() {
    var now = Date.now()
    if (FingerprintModel.inResumeGrace(now, fingerprintResumedAtMs)) return
    logEvent("fingerprint-resume: streak=" + fingerprintUnreachedStreak)
    fingerprintResumedAtMs = now
    fingerprintUnreachedStreak = 0
  }

  // A suspended PAM conversation may be orphaned by the daemon restart.
  function restartFingerprintAfterSleep() {
    noteFingerprintResumed()
    if (fingerprintAuthenticating || fingerprintPam.active) {
      if (fingerprintPam.active) fingerprintPam.abort()
      settleFingerprintAttempt()
      return
    }
    if (!fingerprintRetryTimer.running) return
    armFingerprintRetry(FingerprintModel.MATCH_RETRY_MS)
  }

  function runBlank() {
    root.displaysBlank = true
    cancelFaceRequest("blank")
    pauseFingerprint()
    if (!blankProcess.running) blankProcess.running = true
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || password.length === 0) return

    runWake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true

    if (!passwordPam.start()) {
      handlePasswordFailure()
      return
    }

    Qt.callLater(respondToPasswordPrompt)
  }

  function respondToPasswordPrompt() {
    if (!authenticatingPassword || !passwordPam.active || !passwordPam.responseRequired) return
    passwordPam.respond(pendingPassword)
  }

  function handlePasswordFailure() {
    if (!lockRequested) return

    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = I18n.t("lock.authenticationFailed").arg(I18n.formatNumber(failedAttempts))
    runWake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured || fingerprintPaused) return
    if (fingerprintPam.active || fingerprintAuthenticating) return

    fingerprintAuthenticating = true
    fingerprintAttemptReachedDevice = false
    fingerprintAttemptFastError = false
    fingerprintAttemptPromptedAtMs = 0
    if (!fingerprintPam.start()) {
      // Pace a failed start while checking whether its PAM configuration was
      // removed; a definitive "no" stops retries and hides the indicator.
      settleFingerprintAttempt()
      refreshFingerprintStatus()
      return
    }
    // Bound claims that never prompt; a normal verify waits for a finger
    // under pam_fprintd's own timeout after reaching the reader.
    fingerprintReachTimer.restart()
  }

  // A prompt proves the claim landed, so stop waiting for reachability.
  function noteFingerprintReachedDevice() {
    if (fingerprintAttemptReachedDevice) return
    fingerprintAttemptReachedDevice = true
    fingerprintAttemptPromptedAtMs = Date.now()
    fingerprintReachTimer.stop()
  }

  // abort() gives no completion signal; settle the attempt here.
  function timeoutFingerprintReach() {
    logEvent("fingerprint-reach-timeout")
    if (fingerprintPam.active) fingerprintPam.abort()
    settleFingerprintAttempt()
  }

  // onError and onCompleted can both fire; settle each attempt once.
  function settleFingerprintAttempt(deviceError) {
    if (!fingerprintAuthenticating) return
    fingerprintAuthenticating = false
    fingerprintReachTimer.stop()
    if (!lockRequested || !fingerprintConfigured) return

    // An error can arrive before the sleep watcher notices the wall-clock gap.
    var now = Date.now()
    fingerprintAttemptFastError = !!deviceError && fingerprintAttemptReachedDevice && now - fingerprintAttemptPromptedAtMs < FingerprintModel.FAST_ERROR_MS
    var usableAttempt = fingerprintAttemptReachedDevice && !fingerprintAttemptFastError
    if (!usableAttempt && fingerprintSleepWatch.running
        && FingerprintModel.spannedSleep(now - fingerprintSleepWatch.lastTickMs, fingerprintSleepWatch.interval)) {
      noteFingerprintResumed()
    }

    // Reached attempts are the steady state (one per swipe window), so only
    // the misses and the recovery from them leave a trace.
    var previousStreak = fingerprintUnreachedStreak
    var inGrace = FingerprintModel.inResumeGrace(now, fingerprintResumedAtMs)
    fingerprintUnreachedStreak = FingerprintModel.nextStreak(previousStreak, usableAttempt, inGrace)
    if (!usableAttempt) {
      var crossed = !FingerprintModel.isUnavailable(previousStreak) && FingerprintModel.isUnavailable(fingerprintUnreachedStreak)
      logEvent((crossed ? "fingerprint-unavailable" : "fingerprint-unreached") + ": streak=" + fingerprintUnreachedStreak)
    } else if (previousStreak > 0) {
      logEvent("fingerprint-recovered: streak=" + previousStreak)
    }
    fingerprintLastSettleMs = now
    armFingerprintRetry(FingerprintModel.retryDelayMs(fingerprintUnreachedStreak))
  }

  // The face button, or Space / Enter on an empty field.
  function requestFace() {
    if (!lockRequested || !faceConfigured || fingerprintConfigured) return
    if (faceRequested || faceHolding || facePendingMatch) return
    faceRequested = true
    faceQuietRetries = 0
    faceScanSeen = false
    faceState = "scanning"
    // A fresh cycle, so the card boots and sweeps from the start.
    facePlaybackEpoch += 1
    logEvent("face-requested")
    runWake()
    startFace()
  }

  // Typing a password, Esc, a blank or a suspend take the scan back. A match
  // PAM has already approved is never withdrawn.
  function cancelFaceRequest(why) {
    if (!faceOnRequest || !faceRequested) return
    if (faceHolding || facePendingMatch) return
    faceRequested = false
    faceRetryTimer.stop()
    faceQuickRetryTimer.stop()
    if (facePam.active) facePam.abort()
    // abort() delivers no completion signal.
    faceAuthenticating = false
    faceState = "scanning"
    logEvent("face-cancelled: " + why)
  }

  function startFace() {
    if (!lockRequested || !sessionLock.secure || !faceConfigured) return
    if (faceOnRequest && !faceRequested) return
    if (laptopClosed || displaysBlank) return
    // Resume settling owns the first scan; resumeSettleTimer starts it.
    if (faceAwaitingResume || resumeSettleTimer.running) return
    if (facePendingMatch) return
    if (facePam.active || faceAuthenticating) return
    // A result armed while the panel was blank or the frame clock was stopped
    // is still owed its frames. A new scan must not replace that card.
    if (faceHolding) return

    faceState = "scanning"
    faceAuthenticating = true
    faceQuickRetryTimer.stop()
    faceStartedAtMs = Date.now()
    if (!facePam.start()) {
      faceAuthenticating = false
      if (faceConfigured && !laptopClosed && !displaysBlank) faceRetryTimer.restart()
    }
  }

  // True when the card will play the result before the session moves on.
  // False leaves the PAM result untouched and lets the caller continue at once.
  function holdFaceResult(state) {
    var canPresent = root.faceConfigured && !root.fingerprintConfigured
    var chromeExpected = canPresent && FaceChrome.sourceUrl !== ""
    var action = Playback.playbackAction(state, FaceChrome.ready, FaceChrome.holdMs(state), chromeExpected, FaceChrome.failure !== "")
    faceState = state
    // The next scan starts a new cycle on the card.
    faceScanSeen = false
    if (!canPresent || action === "immediate") {
      faceHolding = false
      return false
    }
    if (state === "recognized") {
      faceRetryTimer.stop()
      faceUnlockCeiling.interval = Math.max(1, Playback.presentedCeilingMs(FaceChrome.holdMs(state)) || 3000)
      faceUnlockCeiling.restart()
    }
    faceHolding = true
    facePlaybackEpoch += 1
    return true
  }

  function completeFacePlayback() {
    faceUnlockCeiling.stop()
    if (!faceHolding) return
    var recognized = faceState === "recognized"
    faceHolding = false
    if (!lockRequested) return
    if (recognized) {
      finishUnlock()
      return
    }
    // On request, a miss hands back to the button rather than scanning again.
    if (faceOnRequest) {
      faceRequested = false
      return
    }
    // The retry may already be running. If it fired while the card was still
    // playing, startFace refused it, so arm another gap once the miss is done.
    if (!faceRetryTimer.running && faceConfigured && !laptopClosed && !displaysBlank) faceRetryTimer.restart()
  }

  function abandonFacePlaybackIfUnplayable() {
    if (!faceHolding) return
    if (!faceConfigured || fingerprintConfigured) {
      completeFacePlayback()
      return
    }
    if (FaceChrome.ready) {
      if (Playback.playbackAction(faceState, true, FaceChrome.holdMs(faceState), true) === "immediate") completeFacePlayback()
      return
    }
    if (FaceChrome.sourceUrl !== "" && FaceChrome.failure === "") return
    completeFacePlayback()
  }

  function releaseUnmatchedFace() {
    if (!lockRequested || !faceConfigured || laptopClosed) return
    if (faceAwaitingResume) return
    if (root.retryFaceQuietly()) return
    faceQuietRetries = 0
    var held = root.holdFaceResult("notRecognized")
    if (faceOnRequest) {
      // The miss card plays, then completeFacePlayback hands back to the
      // button. With no card to play, hand back now.
      if (!held) faceRequested = false
      return
    }
    if (!displaysBlank) faceRetryTimer.restart()
  }

  function handleFaceFinished(result) {
    faceAuthenticating = false

    if (!lockRequested) return
    if (result === PamResult.Success) {
      // PAM has already succeeded. Waiting here only lets the scan finish
      // and keeps the recognised frame on screen; with no card to play,
      // unlock is immediate.
      var scanMs = FaceChrome.ready ? FaceChrome.scanMs() : 0
      if (!faceScanSeen && scanMs > 0 && faceConfigured && !fingerprintConfigured) {
        facePendingMatch = true
        faceMatchWaitTimer.interval = scanMs + 1500
        faceMatchWaitTimer.restart()
        return
      }
      root.playFaceMatch()
      return
    }
    root.releaseUnmatchedFace()
  }

  function playFaceMatch() {
    facePendingMatch = false
    faceMatchWaitTimer.stop()
    if (!lockRequested) return
    if (root.holdFaceResult("recognized")) return
    finishUnlock()
  }

  function noteFaceScanShown() {
    faceScanSeen = true
    if (facePendingMatch) playFaceMatch()
  }

  function handleFingerprintFinished(result) {
    if (result === PamResult.Success && lockRequested) {
      // A match after a run of misses is the recovery too; the unlock resets
      // the streak without settling, so log it here or it leaves no trace.
      if (fingerprintUnreachedStreak > 0) logEvent("fingerprint-recovered: streak=" + fingerprintUnreachedStreak)
      finishUnlock()
    } else {
      settleFingerprintAttempt(result === PamResult.Error)
    }
  }

  WlSessionLock {
    id: sessionLock

    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (secure) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.startFingerprint()
        root.startFace()
      }
      root.publishLockState()
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)

      if (locked) {
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
      }

      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.pendingSessionLock = false
        sessionLockStabilizeTimer.stop()
        pendingSessionLockTimer.stop()
        root.resetAuthenticationState()
        root.runWake()
      }
      root.publishLockState()
    }

    WlSessionLockSurface {
      id: lockSurface
      // Right-to-left languages read this window mirrored.
      Binding { target: lockSurface.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
      Binding { target: lockSurface.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

      color: Commons.Color.background

      LockView {
        id: lockView
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        videoPosterPath: root.videoPosterPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured || root.fingerprintUnavailable
        fingerprintUnavailable: root.fingerprintUnavailable
        faceConfigured: root.faceConfigured
        faceState: root.faceState
        facePlaybackEpoch: root.facePlaybackEpoch
        lockPresentEpoch: root.lockPresentEpoch
        faceScanning: root.faceAuthenticating || root.faceHolding
        faceCardActive: root.faceCardActive
        faceOnRequest: root.faceOnRequest
        onFaceRequested: root.requestFace()
        onFaceCancelRequested: root.cancelFaceRequest("escape")
        onFaceResultPlayed: root.completeFacePlayback()
        onFaceScanShown: root.noteFaceScanShown()
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        failedAttempts: root.failedAttempts
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        displaysBlank: root.displaysBlank
        passwordText: root.enteredPassword
        onPasswordTextEdited: function(password) {
          root.enteredPassword = password
          if (password.length > 0) root.cancelFaceRequest("typing")
        }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.runWake()
      }

    }
  }

  PanelWindow {
    id: previewWindow
    // Right-to-left languages read this window mirrored.
    Binding { target: previewWindow.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
    Binding { target: previewWindow.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      videoPosterPath: root.videoPosterPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured || root.fingerprintUnavailable
      fingerprintUnavailable: root.fingerprintUnavailable
      faceConfigured: root.faceConfigured
      faceState: "scanning"
      faceScanning: root.previewVisible && root.faceConfigured
      faceCardActive: true
      authenticatingPassword: false
      failureMessage: ""
      failedAttempts: 0
      inputEnabled: false
      loadBackground: root.previewVisible
      displaysBlank: root.displaysBlank
      passwordText: ""
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.respondToPasswordPrompt()
    onPamMessage: root.respondToPasswordPrompt()

    onCompleted: function(result) {
      root.authenticatingPassword = false
      root.pendingPassword = ""

      if (!root.lockRequested) return
      if (result === PamResult.Success) root.finishUnlock()
      else root.handlePasswordFailure()
    }

    onError: function(error) {
      root.handlePasswordFailure()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "omarchy-lock-fingerprint"
    user: root.userName

    onPamMessage: {
      if (!messageIsError) root.noteFingerprintReachedDevice()
    }

    onCompleted: function(result) {
      root.handleFingerprintFinished(result)
    }

    onError: function(error) {
      root.settleFingerprintAttempt(true)
    }
  }

  PamContext {
    id: facePam
    config: "omarchy-lock-face"
    user: root.userName

    onCompleted: function(result) {
      root.handleFaceFinished(result)
    }

    onError: function(error) {
      root.faceAuthenticating = false
      root.releaseUnmatchedFace()
    }
  }

  // The lock only starts decoding its wallpaper once locked, and a machine
  // suspending right after locking froze that decode partway: waking showed
  // the password field on a bare background, then the wallpaper popped in.
  // Keep each screen's lock wallpaper decoded in the image cache ahead of
  // time, as the lock view requests it (same URL, the screen's logical size,
  // PreserveAspectCrop), so the lock draws it on its first frame.
  readonly property string lockWallpaperPath: videoBackground ? videoPosterPath : backgroundPath
  readonly property string lockWallpaperUrl: lockWallpaperPath && !Util.isVideoPath(lockWallpaperPath)
    ? Util.fileUrl(lockWallpaperPath) + (backgroundVersion ? "?v=" + backgroundVersion : "")
    : ""

  Variants {
    model: Quickshell.screens

    Image {
      required property var modelData
      visible: false
      source: root.lockWallpaperUrl
      sourceSize.width: modelData.width
      sourceSize.height: modelData.height
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: true
    }
  }

  Timer {
    id: fingerprintRetryTimer
    interval: FingerprintModel.MATCH_RETRY_MS
    repeat: false
    onTriggered: root.startFingerprint()
  }

  Timer {
    id: faceRetryTimer
    interval: 2000
    repeat: false
    onTriggered: root.startFace()
  }

  // Detect resume both during an active attempt and during backoff.
  Timer {
    id: fingerprintSleepWatch
    interval: 1000
    repeat: true
    running: root.lockRequested && root.fingerprintConfigured && (!root.fingerprintPaused || root.fingerprintAuthenticating)
    property double lastTickMs: 0
    onRunningChanged: lastTickMs = Date.now()
    onTriggered: {
      var now = Date.now()
      var slept = FingerprintModel.spannedSleep(now - lastTickMs, interval)
      lastTickMs = now
      if (slept) root.restartFingerprintAfterSleep()
    }
  }

  // Timers stand still through a suspend, so the first tick after a resume
  // sees the wall clock jump. Runs only for the seconds after a lock request
  // that a suspend can take to begin.
  Timer {
    id: fingerprintResumeTimer
    interval: 1000
    repeat: true
    property int ticksLeft: 0
    property double lastTickMs: 0
    onTriggered: {
      var now = Date.now()
      var slept = FingerprintModel.spannedSleep(now - lastTickMs, interval)
      lastTickMs = now
      if (slept && root.lockRequested && root.fingerprintPaused) {
        stop()
        root.fingerprintSleptWhilePaused = true
        root.resumeFingerprint()
        root.armBlankTimer()
      } else if (slept || !root.fingerprintPaused || --ticksLeft <= 0) {
        stop()
      }
    }
  }

  Timer {
    id: fingerprintReachTimer
    interval: FingerprintModel.REACH_TIMEOUT_MS
    repeat: false
    onTriggered: root.timeoutFingerprintReach()
  }

  // Quiet retries for scans that never looked at a face, paced short so the
  // first real scan after resume starts as soon as the camera is back.
  // PAM has already said yes. The recognised card is a courtesy, so the
  // unlock never waits on it longer than a fully presented hold would take,
  // however the surface is presenting (a panel still coming back after
  // resume used to keep the user at a dark lock for the whole stall ceiling).
  Timer {
    id: faceUnlockCeiling
    interval: 3000
    repeat: false
    onTriggered: {
      if (!root.faceHolding || root.faceState !== "recognized") return
      root.logEvent("face-unlock: card did not finish in " + interval + "ms")
      root.completeFacePlayback()
    }
  }

  // Bounds the wait for the scan to finish, in wall time, so a card that is
  // not presenting (or presenting slowly) never holds an approved unlock.
  Timer {
    id: faceMatchWaitTimer
    interval: 4000
    repeat: false
    onTriggered: {
      if (!root.facePendingMatch) return
      root.logEvent("face-match: scan did not finish in " + interval + "ms")
      root.playFaceMatch()
    }
  }

  Timer {
    id: faceQuickRetryTimer
    interval: 300
    repeat: false
    onTriggered: root.startFace()
  }

  // Timers stand still through a suspend, so the first tick after a resume
  // sees the wall clock jump. Runs only for the seconds after a sleep was
  // announced; if no sleep comes, the held scan is released.
  Timer {
    id: sleepResumeWatch
    interval: 250
    repeat: true
    property int ticksLeft: 0
    property double lastTickMs: 0
    onTriggered: {
      var now = Date.now()
      var slept = FingerprintModel.spannedSleep(now - lastTickMs, interval)
      lastTickMs = now
      if (slept) {
        root.handleResume("sleep")
      } else if (--ticksLeft <= 0) {
        stop()
        root.faceAwaitingResume = false
        root.armBlankTimer()
        root.startFace()
      }
    }
  }

  // The camera and the GPU come back a moment after userspace does. The
  // scan waits for that, and the surface is committed again so the compositor
  // resumes frame callbacks without needing pointer motion.
  Timer {
    id: resumeSettleTimer
    interval: 800
    repeat: false
    onTriggered: {
      root.runWake()
      root.nudgePointer()
      resumePresentTimer.ticksLeft = 6
      resumePresentTimer.restart()
      resumeWakeRetryTimer.restart()
      // Replay the scan from its boot: what played before the suspend was
      // seen by nobody, and the card's clock carried on through it.
      if (!root.faceHolding && !root.facePendingMatch) {
        root.faceScanSeen = false
        root.facePlaybackEpoch += 1
      }
      if (root.faceConfigured) root.startFace()
    }
  }

  // A second wake once the outputs have certainly been restored, for a
  // resume slow enough that the first still raced the compositor.
  Timer {
    id: resumeWakeRetryTimer
    interval: 1500
    repeat: false
    onTriggered: {
      if (!root.lockRequested) return
      root.requestWake()
      root.rearmLockPresentation()
      root.nudgePointer()
    }
  }

  Timer {
    id: resumePresentTimer
    interval: 400
    repeat: true
    property int ticksLeft: 0
    onTriggered: {
      root.rearmLockPresentation()
      if (--ticksLeft <= 0) stop()
    }
  }

  Process {
    id: readlinkProc
    command: ["bash", "-c", "path=$(readlink -f -- \"$1\") && printf '%s\\n%s\\n' \"$path\" \"$(stat -Lc %Y:%s -- \"$path\" 2>/dev/null)\"", "_", root.currentBackgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var next = String(lines[0] || "").trim()
        var signature = String(lines[1] || "").trim()
        if (next !== root.backgroundPath) {
          root.videoPosterPath = ""
          root.backgroundPath = next
          root.backgroundSignature = signature
          root.backgroundVersion += 1
        } else if (signature !== root.backgroundSignature) {
          root.backgroundSignature = signature
          root.backgroundVersion += 1
        }
        root.refreshPoster()
      }
    }
  }

  Process {
    id: posterProc
    property string sourcePath: ""
    command: ["bash", Quickshell.env("OMARCHY_PATH") + "/shell/plugins/lock/poster.sh", sourcePath]
    stdout: StdioCollector { id: posterOutput; waitForEnd: true }
    onExited: function(exitCode) {
      if (sourcePath !== root.backgroundPath) {
        root.refreshPoster()
      } else {
        root.videoPosterPath = exitCode === 0 ? String(posterOutput.text || "").trim() : ""
      }
    }
  }

  // Keep fprintd errors distinguishable from an explicit empty enrollment.
  Process {
    id: fingerprintCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-fingerprint ]] && command -v fprintd-list >/dev/null 2>&1; then LC_ALL=C fprintd-list \"$USER\" 2>&1; else echo no; fi"]
    stdout: StdioCollector { id: fingerprintCheckStdout; waitForEnd: true }
    onExited: root.applyFingerprintProbe(fingerprintCheckStdout.text)
  }

  // Retries a probe that could not reach fprintd, paced like the attempt
  // retries so a daemon that stays unreachable is asked about ever less often.
  Timer {
    id: fingerprintRecheckTimer
    interval: FingerprintModel.ERROR_RETRY_BASE_MS
    repeat: false
    onTriggered: root.refreshFingerprintStatus()
  }

  Process {
    id: faceCheckProc
    command: ["bash", "-c", "if [[ -f /etc/pam.d/omarchy-lock-face ]]; then echo yes; else echo no; fi"]
    stdout: StdioCollector { id: faceCheckStdout; waitForEnd: true }
    onExited: {
      root.faceConfigured = String(faceCheckStdout.text || "").trim() === "yes"
      if (root.lockRequested && root.faceConfigured) root.startFace()
      else if (!root.faceConfigured && facePam.active) facePam.abort()
    }
  }

  Process {
    id: laptopClosedProc
    command: ["bash", "-c", "omarchy-hw-laptop-closed && echo closed || echo open"]
    stdout: StdioCollector { id: laptopClosedOut; waitForEnd: true }
    // A request that lands while a probe is running may predate the change.
    property bool again: false
    onExited: {
      if (again) {
        again = false
        Qt.callLater(function() { laptopClosedProc.running = true })
      }
      var wasClosed = root.laptopClosed
      root.laptopClosed = String(laptopClosedOut.text || "").trim() === "closed"
      if (root.laptopClosed) {
        faceRetryTimer.stop()
        faceQuickRetryTimer.stop()
        resumeSettleTimer.stop()
        faceAuthenticating = false
        if (facePam.active) facePam.abort()
      } else if (wasClosed && root.lockRequested) {
        // Resume does not run system-wake. handleResume wakes the panel,
        // commits new buffers so the lock surface leaves the pre-suspend
        // frame, and starts a scan once the camera has had time to return.
        root.handleResume("lid-open")
      }
    }
  }

  Process {
    id: strandedLockCheckProc
    // $PPID is this shell: a crash re-execs in place, so its pid is the one to skip.
    command: ["bash", "-c", "omarchy-hyprland-session-lock-stranded \"$PPID\""]
    onExited: function(exitCode) {
      // No output to read the lock off yet.
      if (exitCode === 2) return

      root.strandedLockResolved = true

      // A lock taken while this was in flight is this shell's own.
      root.strandedLock = exitCode === 0 && !root.currentlyLocked()
      root.recoverStrandedLock()
    }
  }

  Process {
    id: wakeProcess
    command: ["bash", "-c", "omarchy-system-wake"]
    property bool again: false
    onExited: {
      if (!again) return
      again = false
      Qt.callLater(function() { wakeProcess.running = true })
    }
  }

  Process {
    id: pointerNudgeProcess
    command: ["bash", "-c", "pos=$(hyprctl cursorpos) || exit 0; x=${pos%%,*}; y=${pos##*, }; [[ $x =~ ^-?[0-9]+$ && $y =~ ^-?[0-9]+$ ]] || exit 0; hyprctl dispatch \"hl.dsp.cursor.move({ x = $((x + 1)), y = $y })\" >/dev/null && hyprctl dispatch \"hl.dsp.cursor.move({ x = $x, y = $y })\" >/dev/null"]
  }

  Process {
    id: blankProcess
    command: ["bash", "-c", "omarchy-brightness-keyboard off; omarchy-brightness-display off"]
  }

  Timer {
    id: idleBlankTimer
    interval: 5000
    repeat: false
    property double armedAt: 0
    onTriggered: {
      // A countdown frozen by suspend fires right after resume, which would
      // blank the freshly woken unlock screen under the user. Wall-clock time
      // exposes the gap: take a fresh run-up instead of blanking.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlankTimer()
        return
      }
      // Fingerprint PAM stays armed for the whole lock, so gating on
      // `authenticating` would keep the panel lit until unlock. Face is a
      // bounded Howdy scan. Hold the panel while that scan is in flight.
      // A suspend has been announced, or the lid is shut: logind can hold a
      // lid suspend back for many seconds, and a panel blanked meanwhile is
      // still dark after resume. Nobody can see a closed panel anyway.
      if (sleepResumeWatch.running || root.laptopClosed) return
      if (root.lockRequested && !root.authenticatingPassword && !root.faceAuthenticating && !root.faceHolding) root.runBlank()
    }
  }

  Timer {
    id: sessionLockStabilizeTimer
    interval: 500
    repeat: false
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: pendingSessionLockTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: strandedLockRetryTimer
    interval: 500
    repeat: true
    // Covers the compositor settling; screens coming back re-arm it.
    readonly property int budget: 20
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = budget
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      // A panel coming back is a display turning on that runWake did not ask
      // for, so the blank state has to be given up here or a visible lock
      // keeps face paused until the next keypress.
      root.displaysBlank = false
      root.rearmLockPresentation()
      var screens = root.realScreenCount()
      if (screens > root.knownScreenCount) {
        root.resumeFingerprint()
        if (root.lockRequested) root.armBlankTimer()
      }
      root.knownScreenCount = screens
      root.requestSessionLock()

      // A monitor still coming up has no workspace, so cannot answer yet.
      strandedLockRetryTimer.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) idleBlankTimer.stop()
    else armBlankTimer()
  }

  onFaceAuthenticatingChanged: {
    if (!lockRequested) return
    if (faceAuthenticating) idleBlankTimer.stop()
    else if (!faceHolding) armBlankTimer()
  }

  onFaceHoldingChanged: {
    if (!lockRequested) return
    if (faceHolding) idleBlankTimer.stop()
    else if (!faceAuthenticating) armBlankTimer()
  }

  onDisplaysBlankChanged: {
    if (displaysBlank) {
      faceRetryTimer.stop()
      faceQuickRetryTimer.stop()
    } else if (lockRequested) {
      // The canvas starts the armed result once frames are presented.
      // startFace returns while that hold is still playing.
      startFace()
    }
  }

  Connections {
    target: FaceChrome
    function onRevisionChanged() { root.abandonFacePlaybackIfUnplayable() }
  }

  Timer {
    id: lidPollTimer
    interval: 2000
    repeat: true
    running: root.lockRequested
    onTriggered: {
      if (!laptopClosedProc.running) laptopClosedProc.running = true
    }
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  FileView {
    path: "/etc/pam.d/omarchy-lock-face"
    watchChanges: true
    printErrors: false
    onLoaded: root.refreshFaceStatus()
    onLoadFailed: {
      root.faceConfigured = false
      if (facePam.active) facePam.abort()
    }
    onFileChanged: reload()
  }

  // No lock before PAM is known good. An answer from before then may be stale --
  // the failsafe can be cleared from a TTY -- so re-ask rather than act on it.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return

    strandedLock = false
    strandedLockResolved = false
    strandedLockRetryTimer.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    LockCover.covered = locked
    knownScreenCount = realScreenCount()
    refreshBackground()
    refreshFingerprintStatus()
    refreshFaceStatus()
    checkStrandedLock()
  }

  ShellIpc {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      // omarchy-system-sleep-lock asks for the lock before every suspend.
      if (root.currentlyLocked()) root.noteSleepRequested()
      if (!root.currentlyLocked() && !root.beginLock()) return "failed"
      return "ok"
    }

    function isLocked(): string {
      return root.currentlyLocked() ? "true" : "false"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.currentlyLocked(),
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        fingerprintUnavailable: root.fingerprintUnavailable,
        face: root.faceConfigured,
        laptopClosed: root.laptopClosed,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprintStatus()
      root.refreshFaceStatus()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }
}
