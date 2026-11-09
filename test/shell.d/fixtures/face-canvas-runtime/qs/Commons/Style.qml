pragma Singleton
import QtQuick

QtObject {
  property bool reduceMotion: false

  function duration(ms) {
    return reduceMotion ? 0 : ms
  }

  function space(px) {
    return px
  }
}
