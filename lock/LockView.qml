import QtQuick
import QtQuick.Window
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Wordmark.js" as Wordmark

Item {
  id: root

  property string backgroundPath: ""
  property string videoPosterPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool fingerprintUnavailable: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false

  // Wordmark lock. `knotTheme` turns on wordmark + clock and the animations
  // (Retro Stripes themes only; name kept from the knot version so Service.qml
  // stays small); `active` turns true once the surface is on screen;
  // `unlocking` while the service holds the lock for the unlock animation.
  property bool knotTheme: false
  property string knotPath: ""
  property bool active: false
  property bool unlocking: false

  // Animated values; their resting values are the plain locked screen.
  property real backdropScale: 1
  property real blurAmount: 1
  property real veilOpacity: 1
  property real headerOpacity: 1
  property real headerOffset: 0
  property real fieldOffset: 0
  property real fieldOpacity: 1
  property real stageOpacity: 1
  // Burn timelines, 0..1. burnIn = 1 and burnOut = 0 is the resting wordmark.
  property real burnIn: 1
  property real burnOut: 0

  // The six stripe colours, as on the theme's wallpapers.
  readonly property var stripes: Commons.Color.background.hslLightness > 0.5
    ? ["#C35B2F", "#E08634", "#D9A752", "#8D906A", "#7A794C", "#654A1F"]
    : ["#C1362F", "#E85237", "#D18F3F", "#34767D", "#8D6D33", "#B1A055"]
  // White-hot and ash for the fire.
  readonly property color hot: "#f6eddb"
  readonly property color ash: "#7d7258"
  readonly property var fireIn: [stripes[0], stripes[1], stripes[2], stripes[5], hot]
  readonly property var fireOut: [stripes[2], stripes[5], hot, ash]

  // One wordmark square in device pixels rounded to whole pixels, so the
  // squares meet without seams at fractional monitor scales (1.25).
  readonly property real dpr: Screen.devicePixelRatio > 0 ? Screen.devicePixelRatio : 1
  readonly property real cell: Math.max(2, Math.round(width * 0.26 / Wordmark.columns * dpr)) / dpr

  // Squares instead of dots: one per character, cycling through the stripes.
  // Enter clears the field at once, so the submitted squares are held
  // (heldCount) while PAM checks — about 2 s for a wrong password, pam_unix's
  // fail delay — with a light running through them, left to right and back.
  // A wrong password then turns them red with a shake; a right one keeps them
  // through the unlock animation. The count never drops in between, so the
  // squares are not rebuilt.
  property int heldCount: 0
  property int flashCount: 0
  property bool flashing: false
  property real shakeStep: 0
  property real checkPhase: 0
  readonly property bool checking: knotTheme && authenticatingPassword && heldCount > 0
  readonly property int squareCount: flashing ? flashCount : heldCount > 0 ? heldCount : passwordInput.text.length
  readonly property real squareSize: Math.max(6, Math.min(Math.round(fieldFontSize * 0.8), (passwordInput.width - 4) / Math.max(1, squareCount) / 1.45))

  readonly property int headerGap: Math.round(height * 0.045)

  property string timeText: ""
  property string dateText: ""

  readonly property string placeholderText: Commons.I18n.t("lock.enterPassword")
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Commons.Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Commons.Color.lock.borderActive, root.outlineThickness, "border-alpha")
  readonly property string errorText: knotTheme
    ? "Wrong password" + (failedAttempts > 1 ? " (" + failedAttempts + ")" : "")
    : failureMessage

  // A video wallpaper shows its still poster: nothing plays behind the lock.
  readonly property bool video: Util.isVideoPath(root.backgroundPath)

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  // Waking a DPMS-blanked display can stall the compositor for seconds while
  // the monitor modesets, so the wake key's release arrives late and client-side
  // key repeat floods the field with that character. A held key has no business
  // typing a password; only holding Backspace/Delete to clear stays useful.
  function dropsAutoRepeat(key) {
    return key !== Qt.Key_Backspace && key !== Qt.Key_Delete
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  // The field loses focus while a password is checked (it is disabled then),
  // and forcing focus onto it would not stick until the check ends.
  function restorePasswordFocus() {
    if (inputEnabled && passwordInput.enabled && !passwordInput.activeFocus) forcePasswordFocus()
  }

  function updateClock() {
    var now = new Date()
    timeText = Qt.formatTime(now, "HH:mm")
    dateText = Qt.formatDate(now, "dddd, d MMMM")
  }

  function clamp01(v) {
    return v < 0 ? 0 : v > 1 ? 1 : v
  }

  // Colour along a list of stops, k = 0..1.
  function ramp(stops, k) {
    var t = clamp01(k) * (stops.length - 1)
    var i = Math.min(stops.length - 2, Math.floor(t))
    var f = t - i
    var a = Qt.color(stops[i]), b = Qt.color(stops[i + 1])
    return Qt.rgba(a.r + (b.r - a.r) * f, a.g + (b.g - a.g) * f, a.b + (b.b - a.b) * f, 1)
  }

  function resetAnimation() {
    introAnim.stop()
    outroAnim.stop()
    backdropScale = 1
    blurAmount = 1
    veilOpacity = 1
    headerOpacity = 1
    headerOffset = 0
    fieldOffset = 0
    fieldOpacity = 1
    stageOpacity = 1
    burnIn = 1
    burnOut = 0
  }

  function playIntro() {
    heldCount = 0
    updateClock()
    if (!knotTheme) {
      resetAnimation()
      return
    }
    outroAnim.stop()
    introAnim.restart()
  }

  function stopFlash() {
    flashAnim.stop()
    flashing = false
    shakeStep = 0
  }

  onFailedAttemptsChanged: {
    if (!knotTheme || failedAttempts === 0 || heldCount === 0) return
    if (introAnim.running) introAnim.complete()
    flashCount = heldCount
    flashing = true
    heldCount = 0
    flashAnim.restart()
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  onActiveChanged: if (active) playIntro()
  onKnotThemeChanged: if (!knotTheme) resetAnimation()
  onUnlockingChanged: {
    if (!knotTheme) return
    // Unlock cancelled by a new lock: back to the full locked screen.
    if (!unlocking) {
      if (active) playIntro()
      return
    }
    introAnim.stop()
    outroAnim.restart()
  }

  // A VT switch, which the NVIDIA driver forces around every suspend, takes the
  // keyboard away and Qt drops the field's focus with it. Nothing gives it back
  // when the keyboard returns, so typing went nowhere until the field was clicked.
  Window.onActiveFocusItemChanged: Qt.callLater(restorePasswordFocus)
  Component.onCompleted: {
    syncPasswordText()
    updateClock()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
    if (active) playIntro()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.knotTheme && root.active
    onTriggered: root.updateClock()
  }

  // Lock: the blur comes up over the wallpaper (no zoom: it jumped), the wordmark burns in
  // from the bottom row up, then clock and field rise in.
  ParallelAnimation {
    id: introAnim
    NumberAnimation { target: root; property: "blurAmount"; from: 0; to: 1; duration: 800; easing.type: Easing.OutCubic }
    NumberAnimation { target: root; property: "veilOpacity"; from: 0; to: 1; duration: 800; easing.type: Easing.OutCubic }
    PropertyAction { target: root; property: "burnOut"; value: 0 }
    NumberAnimation { target: root; property: "burnIn"; from: 0; to: 1; duration: 1800; easing.type: Easing.Linear }
    PropertyAction { target: root; property: "stageOpacity"; value: 1 }
    SequentialAnimation {
      PropertyAction { target: root; property: "headerOpacity"; value: 0 }
      PauseAnimation { duration: 550 }
      ParallelAnimation {
        NumberAnimation { target: root; property: "headerOpacity"; from: 0; to: 1; duration: 600; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "headerOffset"; from: 40; to: 0; duration: 600; easing.type: Easing.OutCubic }
      }
    }
    SequentialAnimation {
      PropertyAction { target: root; property: "fieldOpacity"; value: 0 }
      PauseAnimation { duration: 750 }
      ParallelAnimation {
        NumberAnimation { target: root; property: "fieldOpacity"; from: 0; to: 1; duration: 600; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "fieldOffset"; from: 40; to: 0; duration: 600; easing.type: Easing.OutBack }
      }
    }
  }

  // Unlock: the wordmark catches fire from the top and goes up in smoke while
  // the blur clears and clock and field fade. Keep the total (1000 ms) in step
  // with unlockAnimationTimer in Service.qml.
  ParallelAnimation {
    id: outroAnim
    PropertyAction { target: root; property: "burnIn"; value: 1 }
    NumberAnimation { target: root; property: "burnOut"; from: 0; to: 1; duration: 1000; easing.type: Easing.Linear }
    SequentialAnimation {
      PauseAnimation { duration: 250 }
      ParallelAnimation {
        NumberAnimation { target: root; property: "blurAmount"; to: 0; duration: 700; easing.type: Easing.InOutCubic }
        NumberAnimation { target: root; property: "veilOpacity"; to: 0; duration: 700; easing.type: Easing.InOutCubic }
      }
    }
    SequentialAnimation {
      PauseAnimation { duration: 450 }
      NumberAnimation { target: root; property: "stageOpacity"; to: 0; duration: 450; easing.type: Easing.InQuad }
    }
  }

  SequentialAnimation {
    running: root.checking
    loops: Animation.Infinite
    NumberAnimation { target: root; property: "checkPhase"; from: 0; to: 1; duration: 520; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "checkPhase"; from: 1; to: 0; duration: 520; easing.type: Easing.InOutSine }
  }

  SequentialAnimation {
    id: flashAnim
    PropertyAction { target: root; property: "flashing"; value: true }
    NumberAnimation { target: root; property: "shakeStep"; from: 0; to: 1; duration: 650 }
    PropertyAction { target: root; property: "flashing"; value: false }
    PropertyAction { target: root; property: "shakeStep"; value: 0 }
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Commons.Color.background

    // Wrapped so the zoom scales the wallpaper and its blur together.
    Item {
      anchors.fill: parent
      scale: root.backdropScale

      BackgroundMedia {
        id: wallpaper
        objectName: "lockWallpaper"
        anchors.fill: parent
        path: root.loadBackground ? (root.video ? root.videoPosterPath : root.backgroundPath) : ""
        version: root.backgroundVersion
        // Decode only once sized, at the lock's own size: an unsized first
        // request decoded the file at its native resolution, then again once
        // sized. That size is what the lock service keeps decoded ahead of the
        // lock, so the first frame has the wallpaper.
        cached: true
        constrainDecode: true
        decodeSize: Qt.size(width, height)
      }

      MultiEffect {
        anchors.fill: wallpaper
        source: wallpaper
        autoPaddingEnabled: false
        blurEnabled: root.loadBackground && wallpaper.ready
        blur: root.blurAmount
        blurMax: 128
        blurMultiplier: 1.25
        contrast: -0.08
      }
    }

    // A light veil in the theme's background colour keeps clock and wordmark
    // readable on any wallpaper.
    Rectangle {
      anchors.fill: parent
      visible: root.knotTheme
      color: Commons.Color.background
      opacity: 0.4 * root.veilOpacity
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    // Wordmark, time and date above the field.
    Column {
      id: header
      visible: root.knotTheme
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: inputField.top
      // Cancels the field's rise so the header stays put while the field moves.
      anchors.bottomMargin: root.headerGap + root.fieldOffset
      spacing: 0

      Item {
        id: wordmark
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.cell * Wordmark.columns
        height: root.cell * Wordmark.rows

        // One square per wordmark pixel. Each square works out its own share of
        // the burn timeline (kIn, kOut); colour, position and fade are bound to
        // those, so only squares that are mid-burn get recomputed per frame.
        //   Burn in: from the bottom up, spreading through connected squares (start
        //   time per square in Wordmark.js, never one floating on black), each
        //   square running brick > tomato > amber > khaki > white-hot > its colour.
        //   Burn away: rows catch fire from the top down, run through amber >
        //   khaki > white-hot > ash and rise, shrink and fade like smoke.
        Repeater {
          model: root.knotTheme && root.active ? Wordmark.cells : []

          Rectangle {
            required property var modelData
            readonly property int col: modelData[0]
            readonly property int row: modelData[1]
            readonly property color base: root.stripes[modelData[2]]
            readonly property real jitter: modelData[3]
            readonly property real kIn: root.clamp01((root.burnIn - modelData[4]) / 0.18)
            readonly property real kOut: root.clamp01((root.burnOut - (row / Wordmark.rows * 0.53 + jitter * 0.12)) / 0.35)

            visible: kIn > 0 && kOut < 1
            antialiasing: false
            x: col * root.cell
            y: (row - kOut * kOut * kOut * 6) * root.cell
            // A hair of overlap hides seams between neighbours.
            width: root.cell + 0.5 / root.dpr
            height: root.cell + 0.5 / root.dpr
            scale: 1 - 0.4 * kOut
            opacity: 1 - kOut
            color: kOut > 0
              ? root.ramp([base].concat(root.fireOut), kOut)
              : kIn < 1 ? root.ramp(root.fireIn.concat([base]), kIn) : base
          }
        }
      }

      Item { width: 1; height: Math.round(root.height * 0.035) }

      Column {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Math.round(root.width * 0.006)
        opacity: root.headerOpacity * root.stageOpacity
        transform: Translate { y: root.headerOffset }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: root.timeText
          color: Commons.Color.lock.text
          font.family: Style.font.family
          font.pixelSize: Math.round(root.width * 0.046)
          font.weight: Font.Normal
          font.letterSpacing: -Math.round(root.width * 0.001)
        }

        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: root.dateText
          color: Commons.Color.lock.placeholder
          font.family: Style.font.family
          font.pixelSize: Math.max(11, Math.round(root.width * 0.0105))
          font.capitalization: Font.AllUppercase
          font.letterSpacing: Math.round(root.width * 0.0015)
        }
      }
    }

    BorderSurface {
      id: inputField
      width: root.fieldWidth
      height: root.fieldHeight
      anchors.centerIn: parent
      // With wordmark + clock above it, the whole group is centred, not the field.
      anchors.verticalCenterOffset: root.knotTheme
        ? Math.round((header.height + root.headerGap) / 2) + root.fieldOffset
        : 0
      opacity: root.fieldOpacity * root.stageOpacity
      color: Commons.Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "●"
        passwordMaskDelay: 0
        // The stripe squares below draw the mask on a Retro Stripes theme.
        color: root.knotTheme ? "transparent" : Commons.Color.lock.text
        selectionColor: root.knotTheme ? "transparent" : Commons.Color.lock.selection
        selectedTextColor: root.knotTheme ? "transparent" : Commons.Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0 && !root.knotTheme
        cursorDelegate: Rectangle {
          width: 2
          color: Commons.Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
            if (root.flashing) root.stopFlash()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          if (root.knotTheme) root.heldCount = submitted.length
          root.passwordTextEdited("")
          if (submitted.length > 0) root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.isAutoRepeat && root.dropsAutoRepeat(event.key)) {
            event.accepted = true
            return
          }
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
          }
        }
      }

      // Stripe squares stand in for the password dots, each popping in as it
      // is typed.
      Row {
        anchors.centerIn: passwordInput
        anchors.horizontalCenterOffset: root.flashing ? Math.sin(root.shakeStep * Math.PI * 8) * 7 * (1 - root.shakeStep) : 0
        visible: root.knotTheme && root.squareCount > 0
        spacing: Math.round(root.squareSize * 0.45)

        Repeater {
          model: root.knotTheme ? root.squareCount : 0

          Rectangle {
            // How close the running light is to this square (1 = on it).
            readonly property real lift: root.checking
              ? Math.max(0, 1 - Math.abs(index - root.checkPhase * (root.squareCount - 1)) / 1.6)
              : 0
            width: root.squareSize
            height: root.squareSize
            radius: Math.max(1, Math.round(root.squareSize * 0.12))
            color: root.flashing ? Commons.Color.lock.borderError : root.stripes[index % 6]
            opacity: root.flashing ? 1 - Math.max(0, root.shakeStep - 0.8) * 5 : root.checking ? 0.35 + 0.65 * lift : 1
            transformOrigin: Item.Center
            transform: [
              Scale { origin.x: width / 2; origin.y: height / 2; xScale: 1 + 0.3 * lift; yScale: 1 + 0.3 * lift },
              Translate { y: -lift * root.squareSize * 0.35 }
            ]

            SequentialAnimation on scale {
              NumberAnimation { from: 0; to: 1.35; duration: 110; easing.type: Easing.OutQuad }
              NumberAnimation { to: 1; duration: 160; easing.type: Easing.OutBack }
            }
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? Commons.I18n.t("lock.checking") : (root.failureMessage.length > 0 ? root.errorText : root.placeholderText)
        visible: passwordInput.text.length === 0 && !root.flashing && !(root.knotTheme && root.heldCount > 0)
        color: root.authenticatingPassword ? Commons.Color.lock.text : (root.failureMessage.length > 0 ? Commons.Color.lock.textError : Commons.Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      // Matches hyprlock, which draws its fingerprint icon in the same spot.
      // A reader the shell cannot reach crosses out rather than disappears, so
      // it stops inviting touches that can never unlock.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        textFormat: Text.PlainText
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: root.fingerprintUnavailable ? "󰺱" : "󰈷"
        color: root.fingerprintUnavailable ? Commons.Color.lock.textError : Commons.Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }

    // The crossed-out icon has no meaning to a user who has never seen it — it
    // is not intuitive that it signals a broken reader — so the words carry the
    // explanation and the icon only reinforces it.
    Text {
      objectName: "fingerprintUnavailableNotice"
      textFormat: Text.PlainText
      anchors.top: inputField.bottom
      anchors.topMargin: 18
      anchors.horizontalCenter: inputField.horizontalCenter
      visible: root.fingerprintConfigured && root.fingerprintUnavailable
      text: Commons.I18n.t("lock.fingerprintUnavailable")
      color: Commons.Color.lock.textError
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.italic: true
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
