pragma Singleton
import QtQuick

// Whether the session lock is covering the screen.
//
// The lock service is the only writer. Polkit reads it so its card does not
// paint underneath the lock or pop out after a request that already finished
// there. This stays a bool on purpose: the polkit agent must not receive the
// shell, because that object is the host and the password field can be
// reached from it.
QtObject {
  property bool covered: false
}
