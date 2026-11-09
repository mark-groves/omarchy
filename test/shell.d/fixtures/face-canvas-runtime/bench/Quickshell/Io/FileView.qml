import QtQuick

// Stands in for Quickshell's FileView so the shell's real FaceChrome.qml
// loads a plugin under plain Qt: the same text reaches the same install().
// File reads need QML_XHR_ALLOW_FILE_READ=1.
QtObject {
  id: view

  property string path: ""
  property bool watchChanges: false
  property bool printErrors: true
  property string loadedText: ""

  signal loaded()
  signal loadFailed(var error)
  signal fileChanged()

  function text() {
    return view.loadedText
  }

  function reload() {
    if (view.path === "") return
    var xhr = new XMLHttpRequest()
    try {
      xhr.open("GET", "file://" + encodeURI(view.path), false)
      xhr.send()
    } catch (e) {
      view.loadFailed(String(e))
      return
    }
    if (xhr.status !== 200 && xhr.status !== 0) {
      view.loadFailed(xhr.status)
      return
    }
    view.loadedText = String(xhr.responseText || "")
    view.loaded()
  }

  onPathChanged: Qt.callLater(view.reload)
}
