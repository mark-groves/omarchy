#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')

// The compositor holds the lock past its client, so a fresh shell must retake it.
assert(
  /Component\.onCompleted:[\s\S]*checkStrandedLock\(\)/.test(serviceQml),
  'the lock service asks the compositor whether the session is locked at startup'
)

assert(
  /id: strandedLockCheckProc[\s\S]*omarchy-hyprland-session-lock-stranded \\"\$PPID\\"/.test(serviceQml),
  'the startup check asks whether a lock has no live locker, skipping this shell'
)

// "No output to read" taken for "unlocked" leaves the failsafe up for good.
assert(
  /onExited: function\(exitCode\) \{[\s\S]*if \(exitCode === 2\) return/.test(serviceQml),
  'an undetermined answer never resolves the check'
)

assert(
  /if \(exitCode === 2\) return\s*\n\s*root\.strandedLockResolved = true/.test(serviceQml),
  'only a compositor that reports a lock counts as a stranded lock'
)

// omarchy-restart-shell re-locks a fresh shell, possibly mid-question.
assert(
  /root\.strandedLock = exitCode === 0 && !root\.currentlyLocked\(\)/.test(serviceQml),
  'a lock this shell took while the check was in flight is not stranded'
)

// A locked binding that missed a change once read locked after an unlock, and
// the lock before suspend took that for done. Decisions read the state afresh.
assert(
  /function currentlyLocked\(\) \{\s*return lockRequested \|\| sessionLock\.locked \|\| sessionLock\.secure\s*\}/.test(serviceQml),
  'the lock state is read from the session lock itself, not a cached binding'
)
assert(
  /function lock\(\): string \{[\s\S]*?if \(!root\.currentlyLocked\(\) && !root\.beginLock\(\)\) return "failed"/.test(serviceQml)
    && /function isLocked\(\): string \{\s*return root\.currentlyLocked\(\)/.test(serviceQml)
    && /locked: root\.currentlyLocked\(\),/.test(serviceQml),
  'lock, isLocked, and status decide from the current lock state'
)

// The sudo overlay and polkit cover read the published flag. A binding of the
// same three values once stayed true after unlock, so the overlay never opened
// and a password conversation waited with no card on screen.
assert(
  !/readonly property bool locked:\s*lockRequested \|\|/.test(serviceQml),
  'the published lock flag is not a binding that can stick after unlock'
)
assert(
  /(?:^|\n)  property bool locked:\s*false/.test(serviceQml) && !/readonly property bool locked:/.test(serviceQml),
  'the published lock flag is writable so publishLockState can assign it'
)
assert(
  /function publishLockState\(\) \{\s*var now = root\.currentlyLocked\(\)\s*if \(root\.locked !== now\) root\.locked = now\s*\}/.test(serviceQml),
  'the published lock flag is written from a fresh read of the session'
)
assert(
  /onLockRequestedChanged:\s*publishLockState\(\)/.test(serviceQml)
    && /onSecureStateChanged:[\s\S]*?root\.publishLockState\(\)/.test(serviceQml)
    && /onLockStateChanged:[\s\S]*?root\.publishLockState\(\)/.test(serviceQml),
  'request, secure, and session-lock changes republish the flag'
)
assert(
  /function finishUnlock\(\) \{[\s\S]*?publishLockState\(\)/.test(serviceQml),
  'unlock republishes after the request and the session lock are down'
)

assert(
  /id: strandedLockRetryTimer[\s\S]*running: !root\.strandedLockResolved && remaining > 0/.test(serviceQml),
  'the check retries while the compositor cannot answer, and stops once it has'
)

// A display asleep for hours outlasts any retry budget.
assert(
  /function onScreensChanged\(\) \{[\s\S]*root\.checkStrandedLock\(\)/.test(serviceQml),
  'a screen coming back re-asks whether a lock is stranded'
)

// One probe is not enough: a monitor still coming up cannot answer.
assert(
  /function onScreensChanged\(\) \{[\s\S]*strandedLockRetryTimer\.rearm\(\)[\s\S]*root\.checkStrandedLock\(\)/.test(serviceQml),
  'a screen coming back gives the check its settling time again'
)

assert(
  /function rearm\(\) \{\s*if \(!root\.strandedLockResolved\) remaining = budget/.test(serviceQml),
  're-arming never restarts a check that already has its answer'
)

// A lock this shell owns ends the search.
assert(
  /function checkStrandedLock\(\) \{\s*if \(strandedLockResolved \|\| strandedLockCheckProc\.running\) return[\s\S]*if \(currentlyLocked\(\)\) \{\s*strandedLockResolved = true/.test(serviceQml),
  'a lock this shell took is not treated as stranded'
)

assert(
  /function recoverStrandedLock\(\) \{\s*if \(!strandedLock \|\| currentlyLocked\(\) \|\| !passwordPamConfigured\) return/.test(serviceQml),
  'recovery is skipped unless a stranded lock is waiting and PAM can authenticate it'
)

// The compositor answer and the PAM config land asynchronously, in either
// order, so whichever arrives last has to drive the recovery.
assert(
  /onPasswordPamConfiguredChanged: \{[\s\S]*checkStrandedLock\(\)/.test(serviceQml),
  'recovery retries once the PAM config has loaded'
)

// The failsafe can be cleared from a TTY while PAM is still loading.
assert(
  /onPasswordPamConfiguredChanged: \{\s*if \(!passwordPamConfigured\) return\s*\n\s*strandedLock = false\s*\n\s*strandedLockResolved = false/.test(serviceQml),
  'a late PAM config re-asks the compositor instead of trusting a stale answer'
)

assert(
  /strandedLock = false\s*\n\s*logEvent\("lock-stranded: recovering"\)\s*\n\s*beginLock\(\)/.test(serviceQml),
  'recovery takes the lock once and records it in the journal'
)
JS
