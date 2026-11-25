#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const polkit = requireFromRoot('shell/plugins/polkit/PolkitModel.js')

assert(polkit.promptLooksFingerprint('Swipe your finger'), 'polkit detects fingerprint prompts')
assert(polkit.promptLooksFingerprint('fprintd verification'), 'polkit detects fprint prompts')
assert(!polkit.promptLooksFingerprint('Password:'), 'polkit ignores password prompts')

assertEqual(
  polkit.authorizationLabel("Authentication is needed to run `/usr/bin/true' as the super user"),
  "Authorize running '/usr/bin/true'",
  'polkit shortens the standard pkexec message'
)
assertEqual(
  polkit.authorizationLabel('Authentication is required to format Crucial X10 Pro (/dev/sda)'),
  'Authorize formatting of Crucial X10 Pro (/dev/sda)',
  'polkit says which drive udisks is formatting'
)
assertEqual(
  polkit.authorizationLabel('Authentication is required to change system settings'),
  'Authentication is required to change system settings',
  'polkit preserves custom authorization messages'
)

// A command that knows what its pkexec is for labels the prompt for that
// program once, within its minute; any other prompt keeps its own.
const pacman = "Authentication is needed to run `/usr/bin/pacman' as the super user"
const expected = { program: '/usr/bin/pacman', label: 'Authorize installing ChatGPT Desktop', until: 1000 }
assertEqual(polkit.expectedLabel(pacman, expected, 500), 'Authorize installing ChatGPT Desktop', 'a prompt for the program a command expected says what it asked')
assertEqual(polkit.expectedLabel("Authentication is needed to run `/usr/bin/true' as the super user", expected, 500), '', 'a prompt for another program keeps its own label')
assertEqual(polkit.expectedLabel('Authentication is required to change system settings', expected, 500), '', 'a prompt that names no program keeps its own label')
assertEqual(polkit.expectedLabel(pacman, expected, 1001), '', 'a label not used within its minute is dropped')
assertEqual(polkit.expectedLabel(pacman, null, 500), '', 'with nothing expected a prompt keeps its own label')
assertEqual(polkit.promptProgram(pacman), '/usr/bin/pacman', 'a pkexec prompt names the program it runs, which a label never hides')

assert(
  polkit.fingerprintConfiguredFromPamConfig(`
# comment
auth sufficient pam_fprintd.so
auth include system-auth
`),
  'polkit detects fingerprint in a PAM config'
)
assert(
  polkit.fingerprintConfiguredFromPamConfig(`
auth [success=1 default=ignore] pam_exec.so quiet /usr/bin/omarchy-hw-laptop-closed
auth sufficient pam_fprintd.so
auth required pam_unix.so
`),
  'polkit detects fingerprint even behind a clamshell gate'
)
assert(
  !polkit.fingerprintConfiguredFromPamConfig(`
account include system-auth
auth include system-auth
auth required pam_unix.so
`),
  'polkit reports no fingerprint when pam_fprintd is absent'
)

// Esc, a finished auth, and a finished drive unlock must not hold the card
// behind a close timer. A polkit result still plays its face exit, which
// already released the keyboard; a drive waiting on that card takes it now.
const fs = require('fs')
const vm = require('vm')
const controllerSource = fs.readFileSync(path.join(root, 'shell/plugins/polkit/PolkitController.qml'), 'utf8')
assert(!/id:\s*closeTimer/.test(controllerSource), 'the password card does not keep a close timer')
assert(!polkit.faceLaneWantsKeyboard({ outcome: 'cancelled', phase: 'closing' }), 'a polkit result releases the keyboard as soon as it has an outcome')

const extractFn = (name) => {
  const m = controllerSource.match(new RegExp(`^( *)function ${name}\\([^)]*\\)\\s*\\{([\\s\\S]*?)\\n\\1\\}`, 'm'))
  if (!m) throw new Error('missing function ' + name)
  return m[0]
}

const makeScope = () => {
  let cancelled = 0
  const scope = {
    previewing: false,
    starting: false,
    sessionLocked: false,
    driveDevice: '',
    driveLabel: '',
    driveQueue: [],
    currentLabel: 'label',
    currentMessage: 'auth',
    responseRequired: false,
    responseVisible: false,
    lane: { phase: 'open', epoch: 1 },
    events: [],
    realCard: null,
    trackedFlow: {
      isCompleted: false,
      cancelAuthenticationRequest: () => { cancelled += 1 }
    },
    I18n: { t: key => key === 'polkit.unlockDrive' ? 'Unlock %1' : key },
    Qt: { callLater: fn => { scope.later.push(fn) } },
    later: [],
    lidSettled: () => {},
    refocus: () => {},
    get cancelledCount() { return cancelled }
  }
  scope.root = scope
  scope.dispatch = (event) => {
    scope.events.push(event.type)
    if (event.type === 'open') scope.lane.phase = 'open'
  }
  scope.resetLane = () => { scope.lane.phase = 'closed' }
  vm.createContext(scope)
  vm.runInContext([
    extractFn('nextDrive'),
    extractFn('beginDrive'),
    extractFn('driveChecked'),
    extractFn('cancelRequest'),
    extractFn('noteFlowEnded'),
    extractFn('onAuthenticationSucceeded'),
    extractFn('onAuthenticationRequestCancelled')
  ].join('\n'), scope)
  return scope
}

{
  const s = makeScope()
  s.cancelRequest()
  assertEqual(s.events[0], 'cancelled', 'cancelling polkit lets the face lane play its exit')
  assertEqual(s.cancelledCount, 1, 'cancelling polkit forwards cancellation to the flow')
  s.onAuthenticationSucceeded()
  assert(s.events.includes('succeeded'), 'successful polkit auth settles in the same turn')
}
{
  const s = makeScope()
  s.onAuthenticationRequestCancelled()
  assertEqual(s.events[0], 'cancelled', 'a remote polkit cancellation settles in the same turn')
}
{
  const s = makeScope()
  s.driveQueue = [{ device: '/dev/sdb1', label: 'Backup' }]
  s.cancelRequest()
  assertEqual(s.driveDevice, '/dev/sdb1', 'a queued drive takes the card in the same turn as cancel')
  assertEqual(s.currentLabel, 'Unlock Backup', 'a queued drive names itself as it takes the card')
  assertEqual(s.cancelledCount, 1, 'handing the card to a drive still cancels the polkit flow')
  s.noteFlowEnded()
  assertEqual(s.driveDevice, '/dev/sdb1', 'polkitd finishing does not clear the drive that took the card')
  assertEqual(s.currentLabel, 'Unlock Backup', 'polkitd finishing keeps the drive label')
  s.driveChecked('/dev/sdb1', 0, '')
  assertEqual(s.driveDevice, '', 'a successful drive unlock clears the card in the same turn')
  assertEqual(s.lane.phase, 'closed', 'a successful drive unlock does not wait out an exit')
}
JS
