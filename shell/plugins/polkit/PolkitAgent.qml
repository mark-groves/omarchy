import QtQuick
import Quickshell
import Quickshell.Services.Polkit
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons

// The polkit agent: Quickshell's PolkitAgent service, the card's windows and
// the `polkit` IPC target. PolkitController.qml owns the request, the face
// lane and the field's rules; PolkitCard.qml draws them. The preview window
// draws the same card from a scripted FakeFlow and takes no input at all.
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

  // Display only: never the keyboard, no input region, and a card whose
  // field takes no text. Built on first use.
  LazyLoader {
    active: polkitController.previewLoaded

    PanelWindow {
      id: previewPanel
      Binding { target: previewPanel.contentItem; property: "LayoutMirroring.enabled"; value: Commons.I18n.rightToLeft }
      Binding { target: previewPanel.contentItem; property: "LayoutMirroring.childrenInherit"; value: true }

      visible: polkitController.previewShown
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "omarchy-polkit-preview"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      PolkitCard {
        anchors.fill: parent
        controller: polkitController
        preview: true
        shown: polkitController.previewShown
      }
    }
  }

  // Strings only. preview refuses while a real request owns the card, and a
  // real request ends any preview.
  ShellIpc {
    target: "polkit"

    // "match", "miss", "typed" or "cancel". scanMs is the time from the
    // scan's start to PAM's answer, or to the Esc; "" keeps the scenario's
    // own, as the lock's previewFace does. Quickshell wants every argument.
    function preview(scenario: string, scanMs: string): string {
      return polkitController.startPreview(scanMs === "" ? scenario : scenario + ":" + scanMs)
    }

    function hidePreview(): string {
      polkitController.stopPreview()
      return "ok"
    }

    function status(): string {
      return polkitController.statusJson()
    }
  }
}
