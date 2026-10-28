#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A locked binding that missed a change once read locked after an unlock, and
# the lock before suspend took that for done, so the machine resumed unlocked.
# The session lock only changes state under a compositor, so nothing offscreen
# can make it disagree with a binding; this reads the source instead, as the
# one guard on a lock that must hold.
run_node_test <<'JS'
const fs = require('fs')
const serviceQml = fs.readFileSync(path.join(root, 'shell/plugins/lock/Service.qml'), 'utf8')

assert(
  /function currentlyLocked\(\) \{\s*return lockRequested \|\| sessionLock\.locked \|\| sessionLock\.secure\s*\}/.test(serviceQml),
  'the lock state is read from the session lock itself, not a cached binding'
)
assert(
  /function lock\(\): string \{[\s\S]*?if \(!root\.currentlyLocked\(\) && !root\.beginLock\(\)\) return "failed"/.test(serviceQml)
    && /function isLocked\(\): string \{\s*return root\.currentlyLocked\(\)/.test(serviceQml)
    && /locked: root\.currentlyLocked\(\),/.test(serviceQml),
  'lock, isLocked and status decide from the current lock state'
)

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
JS
