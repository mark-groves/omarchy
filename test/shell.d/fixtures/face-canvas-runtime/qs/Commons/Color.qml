pragma Singleton
import QtQuick

QtObject {
  readonly property QtObject polkit: QtObject {
    property color accent: "#88c0d0"
    property color text: "#eceff4"
    property color textError: "#bf616a"
  }
}
