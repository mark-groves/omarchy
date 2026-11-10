import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PolkitModel.js" as PolkitModel
import "../../Commons/FaceTheme.js" as FaceTheme

// The polkit card as pixels: scrim, card, face area, captions, the password
// field and the justification pill. It reads everything from a
// PolkitController and hands keys and the face card's callbacks back to it.
// The agent draws the real request with one of these and the display-only
// preview with another; only the one the controller is showing gets its lane.
//
// Host-owned throughout. The face chrome plugin supplies numbers to the
// FaceChromeCanvas and never sees this item, its window or the field.
Item {
  id: root

  property var controller: null
  // The preview card never takes keys or text.
  property bool preview: false
  // This card's window is on screen.
  property bool shown: false

  readonly property bool current: !!controller && controller.previewing === root.preview
  readonly property var lane: current ? controller.lane : PolkitModel.faceLaneInitial()
  readonly property string phase: lane.phase
  readonly property bool interactive: !root.preview
  readonly property var presentation: controller ? controller.presentation : ({})
  readonly property bool faceLayout: lane.trigger === "ask" || lane.trigger === "auto"
  readonly property string cardKind: presentation && presentation.kind ? presentation.kind : "password"
  // The fingerprint card keeps its own glyph-and-hint face while PAM waits.
  readonly property bool showDefaultChrome: !root.faceLayout && root.cardKind !== "password"
  readonly property bool showField: !root.showDefaultChrome
  readonly property bool submitted: lane.pending !== ""
  readonly property bool errorFlash: current && controller.errorFlash
  readonly property var captions: PolkitModel.faceLaneCaptions(lane)

  property string fontFamily: Style.font.menuFamily
  // Bound to the central [polkit] section in shell.toml via Commons.Color.qml.
  property color accent: Commons.Color.polkit.accent
  property color background: Commons.Color.polkit.background
  property color foreground: Commons.Color.polkit.text
  property color border: Commons.Color.polkit.border
  property color borderError: Commons.Color.polkit.borderError
  property var borderSpec: Border.surfaceSpec("polkit", errorFlash ? "border-error" : "border", errorFlash ? borderError : border, Math.max(1, Style.space(2)), "border-alpha")
  property color scrim: Commons.Color.polkit.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int fieldHeight: Math.max(Style.space(42), Style.spacing.controlHeight)

  // The face card's fixed geometry: the face area, two caption slots and
  // the field, sized once for the request. Nothing in it grows, shrinks or
  // hides its space when the face state changes.
  readonly property int faceSide: Style.space(FaceChrome.cardSide)
  readonly property int captionGap: Style.space(10)
  readonly property int captionSpacing: Style.space(4)
  readonly property int fieldGap: Style.space(14)
  readonly property int faceBlock: faceSide + captionGap + primaryMetrics.height + captionSpacing + secondaryMetrics.height + fieldGap
  readonly property int passwordHeight: fieldHeight + contentMargin * 2
  readonly property int naturalHeight: passwordHeight + (faceLayout ? faceBlock : 0)
  readonly property int cardHeight: height > 0 ? Math.min(naturalHeight, height - Style.gapsOut * 2) : naturalHeight
  readonly property int cardWidth: presentation && presentation.square && !faceLayout ? cardHeight
    : Math.min(Style.space(312), Math.max(Style.space(260), width - Style.gapsOut * 2))

  // Where the card and the face area sit, in this window's coordinates.
  readonly property rect cardRect: Qt.rect(card.x, card.y, card.width, card.height)
  readonly property rect faceRect: Qt.rect(card.x + faceArea.x, card.y + faceArea.y, faceArea.width, faceArea.height)

  readonly property bool fieldFocused: passwordInput.activeFocus
  readonly property bool fieldEmpty: passwordInput.text.length === 0

  signal exitFinished()

  FontMetrics {
    id: primaryMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  FontMetrics {
    id: secondaryMetrics
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  function captionText(key) {
    switch (key) {
    case "offer": return I18n.t("polkit.useFace")
    case "retry": return I18n.t("polkit.retryFace")
    case "orType": return I18n.t("face.orTypeYourPassword")
    case "look": return I18n.t("face.lookAtTheCamera")
    case "escCancels": return I18n.t("face.escCancels")
    case "recognized": return I18n.t("face.recognized")
    case "notRecognized": return I18n.t("face.notRecognized")
    case "typePassword": return I18n.t("face.typeYourPassword")
    }
    return ""
  }

  // Hands the typed answer over and clears the field in one step, so the
  // answer never outlives the submit.
  function takeAnswer() {
    var answer = passwordInput.text
    passwordInput.text = ""
    return answer
  }

  function clearField() {
    passwordInput.text = ""
  }

  function focusField() {
    if (root.interactive) passwordInput.forceActiveFocus()
  }

  function focusCatcher() {
    if (root.interactive) keyCatcher.forceActiveFocus()
  }

  // ---- Entrance and exit -------------------------------------------------
  //
  // The scrim fades and the card grows from 0.97 and fades in; leaving takes
  // two thirds of the time. Animators run on the render thread. A window
  // that is not on screen renders nothing, so there the end state is set at
  // once.
  readonly property int enterMs: Style.duration(200)
  readonly property int exitMs: Style.duration(130)

  // Back to the state an entrance starts from.
  function settleHidden() {
    enterAnimation.stop()
    exitAnimation.stop()
    exitCeiling.stop()
    enterCeiling.stop()
    scrimLayer.opacity = 0
    cardLayer.opacity = 0
    cardLayer.scale = 0.97
  }

  // The face area shows the lane's state at once, with no fade.
  function syncCanvas() {
    canvasFade.stop()
    canvasSettle.stop()
    root.canvasState = root.faceState
    faceCanvas.opacity = 1
  }

  function settleClosed() {
    root.settleHidden()
    // The next request starts on the idle mark, never on this one's art.
    root.syncCanvas()
  }

  function enter() {
    exitAnimation.stop()
    exitCeiling.stop()
    if (!root.shown || root.enterMs <= 0) {
      enterAnimation.stop()
      scrimLayer.opacity = 1
      cardLayer.opacity = 1
      cardLayer.scale = 1
      return
    }
    enterAnimation.restart()
    enterCeiling.restart()
  }

  function exit() {
    enterAnimation.stop()
    enterCeiling.stop()
    if (!root.shown || root.exitMs <= 0) {
      exitAnimation.stop()
      Qt.callLater(root.finishExit)
      return
    }
    exitAnimation.restart()
    exitCeiling.restart()
  }

  property bool exitReported: false
  function finishExit() {
    if (root.exitReported || root.phase !== "closing") return
    root.exitReported = true
    exitCeiling.stop()
    root.exitFinished()
    if (root.current) root.controller.cardExitFinished()
  }

  onPhaseChanged: {
    if (root.phase === "open") {
      root.exitReported = false
      root.enter()
    } else if (root.phase === "closing") {
      root.exit()
    } else {
      root.exitReported = false
      root.settleClosed()
    }
  }

  onShownChanged: {
    if (!root.shown) {
      // Hidden under the lock: the next showing fades in again.
      if (root.phase === "closing") root.exit()
      else root.settleHidden()
    } else if (root.phase === "open") {
      root.syncCanvas()
      root.enter()
    }
  }

  ParallelAnimation {
    id: enterAnimation
    OpacityAnimator { target: scrimLayer; from: 0; to: 1; duration: root.enterMs; easing.type: Easing.OutCubic }
    OpacityAnimator { target: cardLayer; from: 0; to: 1; duration: root.enterMs; easing.type: Easing.OutCubic }
    ScaleAnimator { target: cardLayer; from: 0.97; to: 1; duration: root.enterMs; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
  }

  ParallelAnimation {
    id: exitAnimation
    OpacityAnimator { target: scrimLayer; to: 0; duration: root.exitMs; easing.type: Easing.OutCubic }
    OpacityAnimator { target: cardLayer; to: 0; duration: root.exitMs; easing.type: Easing.OutCubic }
    ScaleAnimator { target: cardLayer; to: 0.98; duration: root.exitMs; easing.type: Easing.Bezier; easing.bezierCurve: Style.easeOut }
    onFinished: root.finishExit()
  }

  // A surface the compositor stopped asking for frames never finishes an
  // Animator. The card must neither stay invisible while it holds the
  // keyboard nor keep its scrim over the desktop.
  Timer {
    id: enterCeiling
    interval: root.enterMs + 250
    onTriggered: {
      if (root.phase !== "open") return
      enterAnimation.stop()
      scrimLayer.opacity = 1
      cardLayer.opacity = 1
      cardLayer.scale = 1
    }
  }

  Timer {
    id: exitCeiling
    interval: root.exitMs + 250
    onTriggered: {
      exitAnimation.stop()
      root.finishExit()
    }
  }

  // ---- The face area's states --------------------------------------------
  //
  // The canvas keeps painting its last result while it fades back to the
  // idle mark, so a result never cuts away in one frame.
  property string canvasState: "idle"
  readonly property string faceState: lane.faceState

  onFaceStateChanged: {
    if (root.faceState === "idle") {
      if (root.canvasState === "idle") return
      if (!root.shown || Style.duration(120) <= 0) {
        root.canvasState = "idle"
        return
      }
      canvasFade.stop()
      canvasFade.to = 0
      canvasFade.duration = Style.duration(120)
      canvasFade.start()
      canvasSettle.restart()
      return
    }
    canvasFade.stop()
    canvasSettle.stop()
    faceCanvas.opacity = 1
    root.canvasState = root.faceState
  }

  OpacityAnimator {
    id: canvasFade
    target: faceCanvas
    easing.type: Easing.OutCubic
    onFinished: root.settleCanvas()
  }

  Timer {
    id: canvasSettle
    interval: Style.duration(120) + 250
    onTriggered: root.settleCanvas()
  }

  function settleCanvas() {
    canvasSettle.stop()
    if (root.faceState !== "idle") return
    root.canvasState = "idle"
    faceCanvas.opacity = 1
  }

  // ---- Pixels ----------------------------------------------------------

  Rectangle {
    id: scrimLayer
    anchors.fill: parent
    color: root.scrim
    opacity: 0
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.interactive
    onClicked: if (root.current) root.controller.refocus()
  }

  Item {
    id: cardLayer
    anchors.fill: parent
    opacity: 0
    scale: 0.97

    BorderSurface {
      id: card
      objectName: "polkitCard"
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: root.current ? root.controller.shakeOffset : 0
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea {
        anchors.fill: parent
        enabled: root.interactive
        onClicked: if (root.current) root.controller.refocus()
      }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: root.interactive

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (!root.interactive || !root.current) return
          if (event.key === Qt.Key_Escape) {
            root.controller.cancelRequest()
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.controller.responseRequired) root.controller.submitResponse(event.isAutoRepeat)
            event.accepted = true
          }
        }
      }

      // Host-owned. The chrome plugin supplies numbers and never sees this
      // item, this window, or the field below it.
      Item {
        id: faceArea
        objectName: "polkitFaceArea"
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.faceLayout ? Math.min(root.faceSide, parent.width - card.contentLeftInset - card.contentRightInset) : 0
        height: width
        visible: root.faceLayout
        enabled: false

        // The glass the face card is drawn on, here before the first frame
        // of art and after the last, so a scan starting or ending never
        // changes the panel under it. Matches FaceChromeCanvas's own glass.
        readonly property bool glass: FaceChrome.opLevel >= 3
        readonly property var glassTheme: FaceTheme.glass(String(root.accent), String(root.foreground),
          String(Commons.Color.polkit.textError), String(Commons.Color.background), Commons.Color.palette)

        Rectangle {
          anchors.fill: parent
          visible: faceArea.glass
          radius: Math.round(faceArea.width * 0.045)
          border.width: Math.max(1, Math.round(faceArea.width / 220))
          border.color: faceArea.glassTheme.edge
          gradient: Gradient {
            GradientStop { position: 0; color: Qt.tint(faceArea.glassTheme.panel, Qt.alpha(faceArea.glassTheme.edge, 0.55)) }
            GradientStop { position: 0.45; color: faceArea.glassTheme.panel }
            GradientStop { position: 1; color: faceArea.glassTheme.panel }
          }
        }

        // The idle mark: the face-ID glyph, until a scan starts.
        Text {
          id: idleMark
          anchors.centerIn: parent
          textFormat: Text.PlainText
          // md-face_recognition: a face in corner brackets, the face-ID mark.
          text: String.fromCodePoint(0xF0C7B)
          color: faceArea.glass ? faceArea.glassTheme.roles[0] : root.accent
          font.family: root.fontFamily
          font.pixelSize: Math.round(faceArea.width * 0.34)
          opacity: root.faceState === "idle" || !FaceChrome.ready ? 0.62 : 0
          // Leaves under the incoming art in half the time it takes to return.
          // The duration follows the value it fades to: one bound to
          // faceState still held the old state's when the Behavior started,
          // which swapped the two.
          Behavior on opacity {
            id: idleMarkFade
            OpacityAnimator { duration: Style.duration(idleMarkFade.targetValue > 0 ? 180 : 90); easing.type: Easing.OutCubic }
          }
        }

        FaceChromeCanvas {
          id: faceCanvas
          objectName: "polkitFaceCanvas"
          anchors.fill: parent
          visible: parent.visible
          cardState: root.canvasState
          playbackEpoch: root.lane.epoch
          active: root.shown && root.faceLayout
          onResultPlayed: if (root.current) root.controller.cardResultPlayed()
          onScanShown: if (root.current) root.controller.cardScanShown()
          accent: root.accent
          foreground: root.foreground
          errorColor: Commons.Color.polkit.textError
          surface: root.background
        }
      }

      PolkitCaption {
        id: primaryCaption
        objectName: "polkitCaptionPrimary"
        anchors.top: faceArea.bottom
        anchors.topMargin: root.captionGap
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        visible: root.faceLayout
        text: root.captionText(root.captions.primary)
        color: root.captions.error ? Commons.Color.polkit.textError : root.foreground
        textOpacity: 0.86
        fontFamily: root.fontFamily
        pixelSize: Style.font.body
      }

      PolkitCaption {
        id: secondaryCaption
        objectName: "polkitCaptionSecondary"
        anchors.top: primaryCaption.bottom
        anchors.topMargin: root.captionSpacing
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        visible: root.faceLayout
        text: root.captionText(root.captions.secondary)
        color: root.foreground
        textOpacity: 0.44
        fontFamily: root.fontFamily
        pixelSize: Style.font.bodySmall
      }

      Row {
        id: defaultChrome
        anchors.centerIn: parent
        spacing: Style.space(10)
        opacity: root.showDefaultChrome ? 1 : 0
        visible: opacity > 0
        enabled: visible

        Behavior on opacity {
          NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
        }

        OpticalGlyph {
          width: Math.round(root.fieldHeight * 0.7)
          height: width
          text: root.presentation.glyph || ""
          fontFamily: root.fontFamily
          fontSize: Math.round(root.fieldHeight * 0.7)
          color: root.errorFlash ? Commons.Color.polkit.textError : root.accent
        }

        Text {
          textFormat: Text.PlainText
          text: root.presentation.hint || ""
          visible: text !== ""
          color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
          opacity: 0.72
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          verticalAlignment: Text.AlignVCenter
          elide: Text.ElideRight
        }
      }

      // The same height in every layout: the whole content box of a
      // password card, the bottom of a face card. Once PAM has approved, the
      // field has nothing left to ask, so it fades and keeps its space.
      Row {
        id: cardRow
        opacity: root.showField && root.lane.outcome !== "succeeded" ? 1 : 0
        // An Animator sets opacity only once it ends, so a fade in must not
        // wait on it to become visible.
        visible: root.showField || opacity > 0
        enabled: root.showField && root.interactive
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        height: Math.max(0, root.passwordHeight - card.contentTopInset - card.contentBottomInset)
        spacing: Style.space(14)

        Behavior on opacity {
          OpacityAnimator { duration: Style.duration(140); easing.type: Easing.OutCubic }
        }

        Text {
          textFormat: Text.PlainText
          text: PolkitModel.glyphFor(root.faceLayout ? "password" : root.cardKind)
          color: root.errorFlash ? Commons.Color.polkit.textError : root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconLarge
          width: Style.space(26)
          height: root.fieldHeight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        Item {
          width: parent.width - Style.space(40)
          height: root.fieldHeight

          TextInput {
            id: passwordInput
            objectName: "polkitPasswordInput"
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            activeFocusOnPress: root.interactive
            clip: true
            selectionColor: Util.alpha(root.accent, 0.45)
            selectedTextColor: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            echoMode: root.current && root.controller.responseVisible ? TextInput.Normal : TextInput.Password
            passwordCharacter: "\u2022"
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            cursorVisible: activeFocus && !root.submitted && !root.errorFlash
            readOnly: !root.interactive || root.submitted || root.errorFlash
            enabled: root.interactive && root.current && root.controller.dialogVisible
            // Enter is taken here rather than through onAccepted, which does
            // not say whether the key was an autorepeat.
            Keys.onPressed: function(event) {
              if (!root.interactive || !root.current) return
              if (event.key === Qt.Key_Escape) {
                root.controller.cancelRequest()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.controller.submitResponse(event.isAutoRepeat)
                event.accepted = true
              }
            }
          }

          // The preview's typed scenario: dots, with no text behind them.
          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.preview && root.current && root.controller.previewDots > 0
            textFormat: Text.PlainText
            text: "\u2022".repeat(root.current ? root.controller.previewDots : 0)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
          }

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.errorFlash ? I18n.t("polkit.wrong") : (root.submitted ? I18n.t("polkit.checking") : I18n.t("polkit.enterPassword"))
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            opacity: root.errorFlash ? 1 : 0.36
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            elide: Text.ElideRight
            visible: passwordInput.text.length === 0 && !(root.preview && root.current && root.controller.previewDots > 0)
          }

          Rectangle {
            width: Math.max(1, Style.space(2))
            height: Style.space(24)
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            color: root.errorFlash ? Commons.Color.polkit.textError : root.foreground
            visible: passwordInput.visible && passwordInput.activeFocus && passwordInput.text.length === 0 && !root.submitted && !root.errorFlash
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            enabled: passwordInput.visible && root.interactive
            onClicked: passwordInput.forceActiveFocus()
          }
        }
      }
    }

    Rectangle {
      width: Math.min(justificationText.implicitWidth + Style.space(24), root.width - Style.gapsOut * 2)
      height: Style.space(28)
      anchors.horizontalCenter: card.horizontalCenter
      anchors.bottom: card.top
      anchors.bottomMargin: Style.space(10)
      radius: root.cornerRadius
      color: root.background

      Text {
        id: justificationText
        textFormat: Text.PlainText
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        text: root.current ? root.controller.authorizationLabel(root.controller.currentMessage) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideMiddle
      }
    }
  }

  Component.onCompleted: {
    if (!root.controller) return
    if (root.preview) root.controller.previewCard = root
    else root.controller.realCard = root
    // Built while its lane was already open: the preview's window loads on
    // first use. Report the state again now that it has a rect.
    if (root.phase === "open") {
      root.enter()
      if (root.current) root.controller.noteProbe(true)
    }
  }

  Component.onDestruction: {
    if (!root.controller) return
    if (root.preview && root.controller.previewCard === root) root.controller.previewCard = null
    if (!root.preview && root.controller.realCard === root) root.controller.realCard = null
  }
}
