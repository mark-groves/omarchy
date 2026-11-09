import QtQuick
import Quickshell
import Quickshell.Services.Polkit
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// The polkit agent: Quickshell's PolkitAgent service and the card's window.
// PolkitController.qml owns the request, the face lane and the field's
// rules; PolkitCard.qml draws them.
Item {
  id: root

  property var pluginRegistry: null

  PolkitController {
    id: polkitController
    pluginRegistry: root.pluginRegistry
    agentActive: polkitAgent.isActive
  }

  PolkitAgent {
    id: polkitAgent
    path: "/org/omarchy/PolkitAgent"

    onAuthenticationRequestStarted: polkitController.beginRealFlow(polkitAgent.flow)
    onIsActiveChanged: if (!isActive) polkitController.noteRealFlowGone()
    onIsRegisteredChanged: {
      if (isRegistered) console.log("omarchy polkit agent registered")
      else console.warn("omarchy polkit agent is not registered; another agent may be running")
    }
  }

  PanelWindow {
    id: panel
    // Right-to-left languages read this window mirrored.
    Binding { target: panel.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
    Binding { target: panel.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

    visible: polkitController.realShown
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-polkit"
    WlrLayershell.layer: WlrLayer.Overlay
    // Exclusive while the request can take an answer. A result still
    // playing after PAM has approved, and the fade out, are display only:
    // keys and clicks go back to the desktop.
    WlrLayershell.keyboardFocus: polkitController.wantsKeyboard ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: polkitController.wantsKeyboard ? null : displayOnly

    Region {
      id: displayOnly
    }

    PolkitCard {
      anchors.fill: parent
      controller: polkitController
      shown: polkitController.realShown
    }
  }
}
