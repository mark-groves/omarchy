pragma Singleton
import QtQuick

QtObject {
  property var palette: ({ cyan: "#88c0d0", magenta: "#b48ead", green: "#a3be8c" })
  readonly property QtObject polkit: QtObject {
    property color accent: "#88c0d0"
    property color text: "#eceff4"
    property color textError: "#bf616a"
    property color background: "#2e3440"
  }
}
