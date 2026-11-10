import QtQuick
import Quickshell.Io

// FileView.reload() drops its inotify watch and adds a new one. A delete
// that lands in that gap is never delivered, and the file keeps its old
// text. The parent directory watch stays up across that reload and sees
// the child appear or disappear.
QtObject {
  id: root

  required property var file

  function directoryOf(filePath) {
    var text = String(filePath || "")
    var slash = text.lastIndexOf("/")
    return slash > 0 ? text.substring(0, slash) : ""
  }

  property FileView directory: FileView {
    path: root.file ? root.directoryOf(root.file.path) : ""
    watchChanges: true
    printErrors: false
    preload: false
    blockAllReads: true
    onFileChanged: {
      if (root.file) root.file.reload()
    }
  }
}
