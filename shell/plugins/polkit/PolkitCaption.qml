import QtQuick
import qs.Commons

// One caption line in a fixed slot. A new string fades in over the old one,
// which leaves in half the time, so the slot never moves and never shows two
// strings at full strength (agents/skills/motion.md). Its height is the
// font's line height whether or not it has text. The fades are Animators, so
// a GUI thread busy drawing the face card cannot stall them.
Item {
  id: root

  property string text: ""
  property color color: "white"
  // The opacity a shown string settles at.
  property real textOpacity: 1
  property string fontFamily: ""
  property int pixelSize: 12

  readonly property int fadeInMs: Style.duration(180)
  readonly property int fadeOutMs: Style.duration(90)

  implicitWidth: Math.max(first.implicitWidth, second.implicitWidth)
  implicitHeight: metrics.height
  height: metrics.height

  FontMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: root.pixelSize
  }

  // Which of the two lines holds root.text.
  property bool firstCurrent: true
  readonly property Text current: firstCurrent ? first : second
  readonly property Text previous: firstCurrent ? second : first

  function fade(line, animator, to, ms) {
    animator.stop()
    if (ms <= 0) {
      line.opacity = to
      return
    }
    animator.to = to
    animator.duration = ms
    animator.start()
  }

  function swap() {
    root.firstCurrent = !root.firstCurrent
    var incoming = root.current
    var outgoing = root.previous
    var inFade = incoming === first ? firstFade : secondFade
    var outFade = outgoing === first ? firstFade : secondFade
    inFade.stop()
    incoming.opacity = 0
    incoming.text = root.text
    incoming.color = root.color
    root.fade(outgoing, outFade, 0, root.fadeOutMs)
    if (root.text !== "") root.fade(incoming, inFade, root.textOpacity, root.fadeInMs)
  }

  onTextChanged: if (current.text !== root.text) swap()
  // A colour that changes with the string arrives after it or before it;
  // either way the current line takes it without a second fade.
  onColorChanged: current.color = root.color
  onTextOpacityChanged: if (current.text !== "") fade(current, current === first ? firstFade : secondFade, root.textOpacity, root.fadeInMs)

  Component.onCompleted: {
    first.text = root.text
    first.color = root.color
    first.opacity = root.text !== "" ? root.textOpacity : 0
  }

  Text {
    id: first
    anchors.fill: parent
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: root.pixelSize
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
    opacity: 0
  }

  Text {
    id: second
    anchors.fill: parent
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: root.pixelSize
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    elide: Text.ElideRight
    opacity: 0
  }

  OpacityAnimator {
    id: firstFade
    target: first
    easing.type: Easing.OutCubic
  }

  OpacityAnimator {
    id: secondFade
    target: second
    easing.type: Easing.OutCubic
  }
}
