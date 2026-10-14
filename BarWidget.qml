import QtQuick
import Qt5Compat.GraphicalEffects
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.leandro-3rne.apple-music"

  readonly property var hostService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("io.github.leandro-3rne.apple-music")
    : null
  // Omarchy deliberately gives widgets hosted by a third-party replacement
  // bar a service-less facade. Keep the normal shared service in the trusted
  // stock bar, but provide the same view locally when this widget is hosted
  // by a cloned bar such as leand.bar. IPC stays owned by the singleton.
  readonly property var service: hostService || fallbackServiceLoader.item

  Loader {
    id: fallbackServiceLoader
    active: !root.hostService
    visible: false
    sourceComponent: Component {
      Service {
        manageIpc: false
        // A cloned bar creates one widget per monitor. Only the popup the user
        // actually opened needs its own catalog request; hidden copies keep
        // the quick local thumbnail without multiplying network traffic.
        catalogLookupEnabled: root.popoverOpen && activePlayer === applePlayer
      }
    }
  }

  // A MPRIS player can disappear for a single update during a skip. Keep
  // the panel's size and last metadata stable independently of the service's
  // player handoff; otherwise KeyboardPanel visibly collapses and expands.
  property bool mediaVisibleHold: false
  property string lastVisibleTitle: ""
  property string lastVisibleArtist: ""
  property string lastVisibleAlbum: ""
  property bool coverPending: false
  property string pendingCoverKey: ""
  property string coverBeforeWait: ""
  property int progressTick: 0
  function syncCatalogLookup() {
    if (!root.hostService || root.service !== root.hostService) return
    var shouldLookup = !!(root.service.activePlayer && root.service.applePlayer
      && root.service.activePlayer === root.service.applePlayer && root.service.hasMedia)
    if (root.service.catalogLookupEnabled !== shouldLookup)
      root.service.catalogLookupEnabled = shouldLookup
  }
  readonly property bool presentationWaiting: coverPending || !!(service &&
    (service.trackChanging || (trackToken && trackToken !== displayedCoverKey)))
  readonly property bool hasManagedApp: !!(service && (service.windowKnownOpen || service.youtubeTargetAddress))
  readonly property bool hasMedia: hasManagedApp
    && (!!(service && service.hasMedia) || (popoverOpen && mediaVisibleHold))
  onHasMediaChanged: {
    if (hasMedia) {
      mediaVisibleHold = !!(service && service.hasMedia)
      mediaHoldTimeout.stop()
      Qt.callLater(function() { root.stageTrackPresentation() })
    } else {
      mediaVisibleHold = false
      mediaHoldTimeout.stop()
      if (coverPending) cancelTrackPresentation()
    }
  }
  Connections {
    target: root.service
    function onAlbumChanged() {
      if (root.hasMedia && !root.presentationWaiting && root.service && root.service.album)
        root.lastVisibleAlbum = root.service.album
    }
    function onHasMediaChanged() {
      if (!root.service) return
      root.syncCatalogLookup()
      if (root.service.hasMedia) {
        root.mediaVisibleHold = true
        mediaHoldTimeout.stop()
      } else if (root.popoverOpen && root.mediaVisibleHold) {
        mediaHoldTimeout.restart()
        if (root.coverPending) root.cancelTrackPresentation()
        else {
          root.pendingCoverKey = ""
          coverWaitTimeout.stop()
        }
      }
    }
    function onTrackChangingChanged() {
      if (!root.service) return
      if (root.service.trackChanging) root.beginTrackPresentation()
      else Qt.callLater(function() {
        if (root.service && !root.service.trackChanging && !root.service.skipRequested
            && !root.service.playing && !root.pendingCoverKey)
          root.cancelTrackPresentation()
      })
    }
    function onCoverUrlChanged() {
      if (root.coverPending) coverWaitTimeout.restart()
      if (root.trackToken && coverCandidate.status === Image.Ready
          && root.service && String(coverCandidate.source) === String(root.service.coverUrl)
          && !coverSettle.running) coverSettle.restart()
    }
    function onArtLoadingChanged() {
      if (root.coverPending) coverWaitTimeout.restart()
    }
    function onActivePlayerChanged() { root.syncCatalogLookup() }
    function onArtworkLookupKeyChanged() { root.syncCatalogLookup() }
  }
  Timer {
    id: mediaHoldTimeout
    interval: 4000
    onTriggered: if (!root.service || !root.service.hasMedia) root.mediaVisibleHold = false
  }
  Timer {
    // Keep each monitor's progress bindings current independently of whether
    // its dropdown content is currently mounted/open.
    interval: 500
    repeat: true
    running: root.hasMedia
    onTriggered: root.progressTick++
  }
  readonly property bool playing: service ? service.playing : false
  readonly property bool spinActive: playing && hasMedia && !presentationWaiting
  function startRecordSpin() {
    if (!popoverOpen || !spinActive || recordSpin.running) return
    record.rotation = record.rotation % 360
    recordSpin.from = record.rotation
    recordSpin.to = record.rotation + 360
    recordSpin.start()
  }
  onSpinActiveChanged: { if (spinActive) startRecordSpin(); else recordSpin.stop() }
  readonly property string title: presentationWaiting
    ? " "
    : (root.hasMedia && service && service.hasMedia && service.title
        ? service.title : (mediaVisibleHold ? lastVisibleTitle : ""))
  readonly property string artist: presentationWaiting
    ? ""
    : (root.hasMedia && service && service.hasMedia && service.artist
        ? service.artist : (mediaVisibleHold ? lastVisibleArtist : ""))
  readonly property string album: presentationWaiting
    ? ""
    : (root.hasMedia && service && service.hasMedia && service.album
        ? service.album : (mediaVisibleHold ? lastVisibleAlbum : ""))
  onTitleChanged: if (root.hasMedia && !presentationWaiting && service && service.hasMedia && service.title) lastVisibleTitle = service.title
  onArtistChanged: if (root.hasMedia && !presentationWaiting && service && service.hasMedia && service.artist) lastVisibleArtist = service.artist
  readonly property string trackToken: root.hasMedia && service && !service.trackChanging && (service.title || service.artist)
    ? String(service.selectedSource || "") + "\n" + service.title + "\n" + service.artist + "\n" + service.album : ""
  property string displayedCover: ""
  property string displayedCoverKey: ""

  function beginTrackPresentation() {
    if (!coverPending) coverBeforeWait = displayedCover
    coverPending = true
    pendingCoverKey = ""
    displayedCover = ""
    coverWaitTimeout.attempts = 0
    coverWaitTimeout.stop()
    coverSettle.stop()
    recordSpin.stop()
    recordSwap.stop()
    record.scale = 1
  }

  function stageTrackPresentation() {
    var key = root.trackToken
    if (!root.service || !key) return
    if (root.coverPending && !root.pendingCoverKey && key === root.displayedCoverKey
        && !root.service.playing && !root.service.skipRequested) {
      cancelTrackPresentation()
      return
    }
    if (key === root.displayedCoverKey && !root.coverPending) return
    if (!root.coverPending || root.pendingCoverKey !== key) {
      if (!root.coverPending) root.coverBeforeWait = root.displayedCover
      root.coverPending = true
      root.pendingCoverKey = key
      root.displayedCover = ""
      coverWaitTimeout.attempts = 0
      coverSettle.stop()
    }
    coverWaitTimeout.restart()
    if (coverCandidate.status === Image.Ready && root.service.coverUrl
        && String(coverCandidate.source) === String(root.service.coverUrl)
        && !coverSettle.running) coverSettle.restart()
  }

  function finishTrackPresentation(key, coverSource) {
    if (!root.service || !key || root.trackToken !== key || root.service.trackChanging) return false
    if (root.coverPending && root.pendingCoverKey !== key) return false
    if (!root.coverPending && root.displayedCoverKey !== key) return false

    var nextCover = String(coverSource || "")
    if (nextCover && (coverCandidate.status !== Image.Ready
        || nextCover !== String(root.service.coverUrl)
        || nextCover !== String(coverCandidate.source))) return false

    var hadPresentedTrack = root.displayedCoverKey !== ""
    var changedTrack = hadPresentedTrack && root.displayedCoverKey !== key
    var changedImage = root.displayedCover !== nextCover
    root.displayedCover = nextCover
    root.displayedCoverKey = key
    root.coverBeforeWait = ""
    root.lastVisibleTitle = root.service.title
    root.lastVisibleArtist = root.service.artist
    root.lastVisibleAlbum = root.service.album
    root.coverPending = false
    root.pendingCoverKey = ""
    coverWaitTimeout.stop()
    if (nextCover && root.popoverOpen && (changedTrack || (hadPresentedTrack && changedImage)))
      recordSwap.restart()
    return true
  }

  function cancelTrackPresentation() {
    coverSettle.stop()
    coverWaitTimeout.stop()
    displayedCover = coverBeforeWait
    coverBeforeWait = ""
    coverPending = false
    pendingCoverKey = ""
  }

  onTrackTokenChanged: if (trackToken) stageTrackPresentation()
  Timer {
    id: coverSettle
    interval: 300
    onTriggered: {
      if (!root.trackToken || !root.service || root.service.trackChanging
          || coverCandidate.status !== Image.Ready || !root.service.coverUrl
          || String(coverCandidate.source) !== String(root.service.coverUrl)) return
      root.finishTrackPresentation(root.trackToken, String(coverCandidate.source))
    }
  }
  Timer {
    id: coverWaitTimeout
    interval: 500
    repeat: true
    property int attempts: 0
    onTriggered: {
      if (!root.service || !root.coverPending || !root.pendingCoverKey
          || root.pendingCoverKey !== root.trackToken || root.service.trackChanging) {
        stop()
        return
      }
      var candidateReady = coverCandidate.status === Image.Ready && root.service.coverUrl
        && String(coverCandidate.source) === String(root.service.coverUrl)
      if (candidateReady && !coverSettle.running) coverSettle.restart()
      attempts++
      var noArtwork = !root.service.coverUrl && !root.service.artLoading
      var failedImage = coverCandidate.status === Image.Error && !root.service.artLoading
      if (noArtwork || failedImage || attempts >= 20) {
        root.finishTrackPresentation(root.pendingCoverKey, candidateReady ? String(coverCandidate.source) : "")
        stop()
      }
    }
  }
  Image {
    id: coverCandidate
    visible: false
    asynchronous: true
    cache: !String(source).startsWith("file:")
    sourceSize.width: 48
    sourceSize.height: 48
    source: root.service ? root.service.coverUrl : ""
    onStatusChanged: if (status === Image.Ready && root.trackToken && !coverSettle.running) coverSettle.restart()
  }
  onServiceChanged: {
    coverSettle.stop()
    displayedCover = ""
    displayedCoverKey = ""
    coverBeforeWait = ""
    coverPending = !!(service && (service.title || service.trackChanging))
    pendingCoverKey = ""
    coverWaitTimeout.stop()
    Qt.callLater(function() { root.syncCatalogLookup() })
    if (service && service.album) lastVisibleAlbum = service.album
    Qt.callLater(function() { root.stageTrackPresentation() })
  }
  Component.onCompleted: Qt.callLater(function() { root.stageTrackPresentation() })

  property bool popoverOpen: false
  // The bar's panel navigation contract uses `opened` to identify widgets
  // that participate in Tab cycling. Keep it mirrored to the music popover.
  readonly property bool opened: popoverOpen
  // Standard panel controls keep the last hovered target lightly highlighted
  // after the pointer leaves. The popup owns one shared cursor so only one
  // button can retain that state at a time.
  property bool cursorActive: false
  property int cursorIndex: -1
  property bool popoutSwitchClosing: false
  property int popoutSwitchGeneration: 0

  // Flattens track metadata for the bar's tooltip: one line, no angle
  // brackets, trimmed to a sane length for a hover label.
  function tooltipSafe(text) {
    return String(text || "")
      .replace(/[<>]/g, "")
      .replace(/\s+/g, " ")
      .trim()
      .substring(0, 200)
  }

  // Standard bar-widget lifecycle trio, so the bar's single-popup
  // coordinator (below) and any external summon can drive this widget the
  // same way every other one is driven.
  function open() {
    root.popoutSwitchGeneration += 1
    root.popoutSwitchClosing = false
    if (bar && typeof bar.requestPopout === "function") bar.requestPopout(root)
    popoverOpen = true
  }
  function close() {
    root.popoutSwitchGeneration += 1
    root.popoutSwitchClosing = false
    popoverOpen = false
  }
  function toggle() { if (popoverOpen) close(); else open() }
  function closeForPopoutSwitch() {
    // Leave the old popover mounted for one event-loop turn, matching the
    // brief handoff used by KeyboardPanel when two normal shell panels are
    // switched. The generation guard prevents a fast reopen from being closed
    // by this delayed handoff.
    var generation = ++root.popoutSwitchGeneration
    root.popoutSwitchClosing = true
    Qt.callLater(function() {
      if (generation !== root.popoutSwitchGeneration) return
      root.popoverOpen = false
      root.popoutSwitchClosing = false
    })
  }

  // Only one bar popup is meant to be open at a time; this is what tells
  // the bar host to release whichever other widget's popup was open.
  function syncPopout() {
    if (!bar) return
    if (popoverOpen) {
      if (trackToken && coverCandidate.status === Image.Ready) coverSettle.restart()
      if (bar.activePopout !== root) bar.requestPopout(root)
    } else if (bar.activePopout === root) {
      bar.releasePopout(root)
    }
  }

  function cursorTargets() {
    return root.hasMedia ? [0, 1, 2, 3, 4] : [4]
  }

  function moveCursor(dx, dy, autoRepeat) {
    if (dx === 0 && dy === 0) return
    var targets = root.cursorTargets()
    if (!root.cursorActive) {
      root.cursorActive = true
      root.cursorIndex = root.hasMedia ? 2 : targets[0]
      return
    }

    // The progress slider, transport controls, and window button form three
    // vertical rows. Left/Right adjusts the focused slider by five seconds;
    // keyboard auto-repeat therefore keeps seeking while a key is held, just
    // like the volume slider in the audio panel. In the transport row the same
    // keys continue to move between its buttons.
    if (dx !== 0) {
      if (!root.hasMedia || root.cursorIndex === 4) return
      if (root.cursorIndex === 0) {
        if (root.service) {
          var step = autoRepeat ? 10 : 5
          root.service.seekBy(dx > 0 ? step : -step)
        }
        return
      }
      root.cursorIndex = Math.max(1, Math.min(root.cursorIndex + (dx > 0 ? 1 : -1), 3))
    } else if (root.hasMedia) {
      if (root.cursorIndex === 0 && dy > 0) root.cursorIndex = 2
      else if (root.cursorIndex >= 1 && root.cursorIndex <= 3)
        root.cursorIndex = dy > 0 ? 4 : 0
      else if (root.cursorIndex === 4 && dy < 0) root.cursorIndex = 2
    }
  }

  function activateCursor() {
    if (!root.cursorActive) return
    if (!root.service) return
    if (root.cursorIndex === 0 && playButton.enabled) root.service.runAction("playPause")
    else if (root.cursorIndex === 1 && prevButton.enabled) root.service.runAction("previous")
    else if (root.cursorIndex === 2 && playButton.enabled) root.service.runAction("playPause")
    else if (root.cursorIndex === 3 && nextButton.enabled) root.service.runAction("next")
    else if (root.cursorIndex === 4) root.openWindow()
  }

  onPopoverOpenChanged: {
    syncPopout()
    syncCatalogLookup()
    if (popoverOpen) {
      // Refresh Date.now()-based progress before the popup paints, so closing
      // the panel never leaves a stale position visible on the next open.
      root.progressTick++
      mediaVisibleHold = !!(service && service.hasMedia)
      mediaHoldTimeout.stop()
    } else {
      mediaVisibleHold = false
      mediaHoldTimeout.stop()
    }
    if (popoverOpen) startRecordSpin()
    else recordSpin.stop()
    if (popoverOpen) {
      root.cursorActive = false
      root.cursorIndex = -1
      if (service) service.refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }
  }
  onBarChanged: syncPopout()
  Component.onDestruction: if (bar && bar.activePopout === root) bar.releasePopout(root)

  // Toggle: bar-icon right-click and the popover's Open/Hide button. Hides
  // an already-open, in-view window instead of doing nothing.
  function openWindow() {
    if (service) service.openWindow()
    close()
  }

  // Always brings the window into view, never hides it. Used by the
  // artwork/title tap — that should reliably take you to the window, not
  // occasionally hide it because it happened to already be in view.
  function focusWindowOnly() {
    if (service) service.focusPlayingWindow()
    close()
  }

  // Keep the slot at the same width as the other icon-only bar modules. The
  // host centers the active mark on this slot; extra trailing width would
  // move both the icon and its mark left and leave too much room on the right.
  implicitWidth: iconButton.implicitWidth
  implicitHeight: iconButton.implicitHeight
  // Keep the active mark compact and centered under the optical music glyph
  // instead of using the bar's wider fallback extent.
  readonly property real openPanelIndicatorWidth: Style.space(16)

  // BarIconButton (not a bare Text) is what every other bar icon uses: it
  // renders through OpticalGlyph inside a fixed Style.bar.iconCanvas square
  // using Style.bar.iconFont, so it lines up with its neighbors instead of
  // being centered within the whole widget slot at a mismatched font size.
  // It also registers as a proper bar click target (multi-popup
  // coordination) and swaps in iconComponent in place of the glyph, which
  // is what drives the playing visualization below.
  BarIconButton {
    id: iconButton
    anchors.fill: parent
    bar: root.bar
    // Routed through iconComponent (idleIconComponent below) rather than
    // BarIconButton's built-in `text`, so the swap to the playing
    // visualizer and the idle glyph share one code path.
    useActiveColor: false
    // The bar owns how a tooltip is rendered, so track metadata is flattened
    // to a single line of plain characters on the way out rather than handed
    // over as-is — the popover's own labels, which this plugin does control,
    // still show the title exactly as reported.
    // Details are shown only in the click-opened player panel.
    tooltipText: ""
    iconComponent: root.playing ? visualizerComponent : idleIconComponent

    onPressed: function(button) {
      if (button === Qt.RightButton) root.openWindow()
      else root.toggle()
    }

    // Raw wheel deltas are far noisier than one scroll gesture: trackpads
    // report many small events per swipe rather than a single ±120 "click".
    // Reacting to every nonzero delta skips a track per event instead of
    // per gesture, so this accumulates deltas and acts once the total
    // reaches one notch's worth, then goes quiet briefly so a fast fling
    // can't still fire several skips in a row.
    property real wheelAccum: 0

    onWheelMoved: function(delta) {
      if (!root.hasMedia || !root.service || wheelCooldown.running) return
      wheelAccum += delta
      if (Math.abs(wheelAccum) < 120) return
      root.service.runAction(wheelAccum > 0 ? "previous" : "next")
      wheelAccum = 0
      wheelCooldown.restart()
    }

    Timer {
      id: wheelCooldown
      interval: 350
    }
  }

  Component {
    id: idleIconComponent
    OpticalGlyph {
      width: parent.width
      height: parent.height
      anchors.centerIn: parent
      anchors.verticalCenterOffset: 1
      text: "󰝚"
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
      fontSize: Style.bar.iconFont
      color: root.bar ? root.bar.barForeground : Color.foreground
    }
  }

  Component {
    id: visualizerComponent
    PlayingVisualizer {
      // Optical correction for the animated bars only; the idle music note
      // deliberately keeps its existing centered position.
      anchors.horizontalCenterOffset: 1
      foreground: root.bar ? root.bar.barForeground : Color.foreground
    }
  }

  // KeyboardPanel, not PopupCard: PopupCard is built on xdg-popup, which
  // only receives keys after a click or hover routes focus through its
  // parent surface, so it never reliably closes on Escape. KeyboardPanel
  // does the extra work (a brief Wayland Exclusive→OnDemand keyboard-focus
  // prime on a real layer-shell surface) that every first-party widget
  // needing real keyboard interaction (Agents, Audio, Bluetooth, Network,
  // Power, ...) relies on for this.
  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popoverOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    MusicKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy, autoRepeat) { root.moveCursor(dx, dy, autoRepeat) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
          root.bar.switchPanelFrom(root, direction)
      }

      Column {
        id: column
        anchors.fill: parent

        spacing: root.hasMedia ? Style.space(12) : popup.padding + Border.bottom(popup.borderSpec)

        // ---------- Now playing ----------
        // Wrapped in a plain Item (not a positioner) so the tap-to-open
        // MouseArea below can overlay the whole row via anchors.fill —
        // anchoring a sibling directly inside the Row itself would conflict
        // with Row's own child-positioning logic.
        Item {
          visible: true
          width: parent.width
          height: nowPlayingColumn.implicitHeight

          Column {
            id: nowPlayingColumn
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: root.hasMedia ? Style.space(10) : 0

          Item {
            width: parent.width
          height: turntable.height + (root.hasMedia ? Style.space(8) : 0)

            Rectangle {
              id: turntable
              width: parent.width
              height: Math.round(width * 0.61)
              anchors.centerIn: parent
              radius: Style.space(5)
              color: Style.normalFillFor(root.bar.foreground, Color.accent)
              border.width: 1
              border.color: Color.accent

              Rectangle {
                x: Style.space(12)
                y: Style.space(10)
                width: turntable.height - Style.space(20)
                height: width
                color: "#34343c"
                radius: Style.space(4)
                border.width: Style.space(2)
                border.color: "#595963"
              }

            Item {
              id: record
              width: turntable.height - Style.space(34)
              height: width
              x: Style.space(19)
              y: Style.space(17)
              transform: Rotation {
                id: seekRotation
                origin.x: record.width / 2
                origin.y: record.height / 2
              }
              Connections {
                target: root.service
                function onSeekCueSerialChanged() {
                  seekKick.stop()
                  seekKick.from = seekRotation.angle
                  // When paused, symmetric rotation; when playing, backward stronger to counter platter spin.
                  var isPlaying = root.service && root.service.playing
                  var forwardAngle = isPlaying ? 42 : 60
                  var backwardAngle = isPlaying ? -80 : -60
                  seekKick.to = seekRotation.angle + (root.service.seekCue > 0 ? forwardAngle : backwardAngle)
                  seekKick.start()
                }
              }
              NumberAnimation { id: seekKick; target: seekRotation; property: "angle"; duration: 200; easing.type: Easing.OutQuad }
              SequentialAnimation {
                id: recordSwap
                NumberAnimation { target: record; property: "scale"; from: 0.78; to: 1.04; duration: 220; easing.type: Easing.OutCubic }
                NumberAnimation { target: record; property: "scale"; to: 1; duration: 120; easing.type: Easing.OutQuad }
              }
              NumberAnimation {
                id: recordSpin
                target: record
                property: "rotation"
                duration: 2800
                onFinished: root.startRecordSpin()
              }
              Canvas {
                anchors.fill: parent
                onPaint: {
                  var ctx = getContext("2d")
                  var pixel = 4
                  ctx.clearRect(0, 0, width, height)
                  for (var y = 0; y < height; y += pixel) {
                    for (var x = 0; x < width; x += pixel) {
                      var dx = x + pixel / 2 - width / 2
                      var dy = y + pixel / 2 - height / 2
                      var distance = Math.sqrt(dx * dx + dy * dy)
                      if (distance > Math.min(width, height) / 2 - pixel) continue
                      ctx.fillStyle = distance > width * 0.45 ? "#62626b"
                        : Math.floor(distance / 7) % 2 ? "#292930" : "#17171b"
                      ctx.fillRect(x, y, pixel, pixel)
                    }
                  }
                }
              }
              Rectangle {
                width: Math.round(record.width * 0.49)
                height: width
                anchors.centerIn: parent
                radius: width / 2
                color: Color.accent
                border.width: Style.space(3)
                border.color: "#777780"
                visible: root.hasMedia && !root.presentationWaiting
                Image {
                  id: recordCover
                  anchors.fill: parent
                  anchors.margins: Style.space(3)
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  smooth: false
                  sourceSize.width: 48
                  sourceSize.height: 48
                  cache: !String(source).startsWith("file:")
                  source: root.displayedCover
                  visible: false
                }
                Rectangle {
                  id: coverMask
                  anchors.fill: recordCover
                  radius: width / 2
                  color: "white"
                  visible: false
                }
                OpacityMask {
                  anchors.fill: recordCover
                  source: recordCover
                  maskSource: coverMask
                  cached: true
                  visible: root.displayedCover !== "" && recordCover.status === Image.Ready
                }
                Text {
                  anchors.centerIn: parent
                  text: "♫"
                  color: Color.background
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.title
                  visible: root.displayedCover === "" || recordCover.status !== Image.Ready
                }
              }
              Rectangle {
                anchors.centerIn: parent
                width: Style.space(17)
                height: width
                color: "#a8a8b0"
                border.width: 1
                border.color: "#262630"
                Rectangle {
                  anchors.centerIn: parent
                  width: Style.space(7)
                  height: width
                  color: "#17171b"
                }
              }
            }
              // Fixed pixel-art tonearm, stylus and control buttons: only
              // the platter rotates, as it would on a real turntable.
              Rectangle {
                x: parent.width - Style.space(52)
                y: Style.space(38)
                width: Style.space(20)
                height: width
                color: "#62626b"
                border.color: root.bar.foreground
                border.width: 2
              }
              Rectangle {
                x: parent.width - Style.space(184)
                y: Style.space(66)
                width: Style.space(145)
                height: Style.space(7)
                rotation: -13
                color: "#c1c1c8"
              }
              Rectangle {
                x: parent.width - Style.space(186)
                y: Style.space(83)
                width: Style.space(11)
                height: Style.space(18)
                color: Color.accent
              }
              Rectangle {
                x: parent.width - Style.space(85)
                y: parent.height - Style.space(44)
                width: Style.space(26)
                height: Style.space(22)
                color: root.spinActive ? Color.accent : "#505059"
                border.color: root.spinActive ? root.bar.foreground : "#777780"
                border.width: 2
              }
              Rectangle {
                x: parent.width - Style.space(49)
                y: parent.height - Style.space(44)
                width: Style.space(26)
                height: Style.space(22)
                color: !root.spinActive ? Color.accent : "#505059"
                border.color: !root.spinActive ? root.bar.foreground : "#777780"
                border.width: 2
              }
            }
          }

          // Track title, artist, and album are page-supplied metadata, so
          // each is pinned to PlainText and rendered verbatim rather than
          // left to Text's default markup auto-detection.
          Column {
            visible: root.hasMedia
            spacing: Style.space(4)
            width: parent.width

            Text {
              text: root.title
              textFormat: Text.PlainText
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.artist
              textFormat: Text.PlainText
              color: Qt.darker(root.bar.foreground, 1.3)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              width: parent.width
              visible: text !== ""
            }

            Text {
              text: root.album
              textFormat: Text.PlainText
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              width: parent.width
              visible: text !== ""
            }
          }
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.focusWindowOnly()
          }
        }

        // ---------- Progress ----------
        // Apple Music doesn't always report a track's total duration over
        // MPRIS, even well into active playback (see the length sanity
        // check in Service.qml). There's a real difference between "no
        // total, so no fill ratio or remaining time" and "no metadata at
        // all": elapsed time is always known, so it's shown regardless,
        // just without a bar or a total when there's nothing to measure it
        // against.
        Column {
          id: progress
          visible: root.hasMedia
          width: parent.width
          spacing: Style.space(4)

          // Reading progressTick makes the root's 500ms timer invalidate this
          // binding — livePosition() depends on Date.now(), which QML cannot
          // observe changing on its own.
          readonly property real position: {
            var _ = root.progressTick
            return root.service && !root.presentationWaiting ? root.service.livePosition() : 0
          }
          readonly property real sourceLength: root.service ? root.service.length : 0
          property real length: 0
          property bool rangeSettling: false
          readonly property bool lengthKnown: length > 0 && !rangeSettling

          onSourceLengthChanged: {
            rangeSettling = true
            lengthSettle.interval = sourceLength > 0 && length <= 0 ? 1000 : 100
            lengthSettle.restart()
          }

          Component.onCompleted: {
            length = sourceLength
            rangeSettling = false
            lengthSettle.stop()
          }

          Timer {
            id: lengthSettle
            interval: 100
            repeat: false
            onTriggered: {
              progress.length = progress.sourceLength
              progress.rangeSettling = false
              root.progressTick++
            }
          }

          function fmt(seconds) {
            var s = Math.max(0, Math.floor(seconds))
            var m = Math.floor(s / 60)
            var r = s % 60
            return m + ":" + (r < 10 ? "0" : "") + r
          }

          CursorSurface {
            width: parent.width
            height: playbackSlider.implicitHeight + Style.spacing.controlGap
            foreground: root.bar.foreground
            outline: true
            hasCursor: root.cursorActive && root.cursorIndex === 0

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              height: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
              radius: height / 2
              color: Style.selectedFillFor(root.bar.foreground, Color.accent)
              visible: root.presentationWaiting || progress.rangeSettling || !progress.lengthKnown
                || !root.service || !root.service.positionReady
            }

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: playbackSlider.knobSize
              height: width
              radius: width / 2
              color: root.bar.foreground
              border.width: Math.max(1, Style.space(2))
              border.color: root.bar.background
              x: Style.space(6) + (!root.presentationWaiting && !progress.rangeSettling && progress.lengthKnown
                && root.service && root.service.positionReady
                ? Math.max(0, Math.min(1, progress.position / progress.length))
                    * Math.max(0, parent.width - Style.space(12) - width)
                : 0)
              visible: root.presentationWaiting || progress.rangeSettling || !progress.lengthKnown
                || !root.service || !root.service.positionReady
            }

            MusicProgressSlider {
              id: playbackSlider
              bar: root.bar
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              minimum: 0
              maximum: Math.max(1, progress.length)
              step: 5
              value: progress.lengthKnown && !root.presentationWaiting
                && root.service && root.service.positionReady ? progress.position : 0
              enabled: !root.presentationWaiting && !progress.rangeSettling && progress.lengthKnown
                && root.service && root.service.activePlayer
                && root.service.activePlayer.canSeek
              // Keep the row's layout stable while Apple Music's catalogue
              // duration loads, but do not draw a placeholder slider whose
              // knob would visibly jump once the real range arrives.
              opacity: !root.presentationWaiting && !progress.rangeSettling && progress.lengthKnown
                && root.service && root.service.positionReady
                ? (enabled ? 1.0 : 0.45) : 0.0
              // Dragging only previews locally. One seek on release avoids
              // queueing dozens of asynchronous MPRIS requests and the large
              // overshoot that their delayed acknowledgements used to cause.
              onReleased: function(seconds) { if (root.service) root.service.seekTo(seconds) }
            }

            HoverHandler {
              onHoveredChanged: if (hovered) {
                root.cursorActive = true
                root.cursorIndex = 0
              }
            }
          }

          Row {
            width: parent.width
            // Keep the elapsed/total labels in step with the slider while
            // MPRIS is settling a track change or late duration update.
            opacity: !root.presentationWaiting && root.service ? 1.0 : 0.0
            Text {
              id: timeLeft
              text: progress.fmt(playbackSlider.dragging ? playbackSlider.liveValue : progress.position)
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Item { width: parent.width - timeLeft.implicitWidth - timeRight.implicitWidth; height: 1 }
            Text {
              id: timeRight
              text: progress.lengthKnown ? progress.fmt(progress.length) : ""
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // ---------- Transport ----------
        // The play/pause button is deliberately bigger (iconLarge, more
        // padding) than prev/next, so it's taller — and Row only positions
        // children's x, not y, so without help the shorter buttons sit
        // top-aligned against the taller one instead of centered against
        // it. Each button is wrapped in a plain Item pinned to the row's
        // own height so it can anchor its vertical center normally;
        // anchoring the Button directly as a Row child would conflict with
        // Row's own positioning (Qt warns and ignores it).
        Row {
          id: transportRow
          visible: root.hasMedia
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(12)
          height: playButton.implicitHeight

          Item {
            width: prevButton.implicitWidth
            height: parent.height

            Button {
              id: prevButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒮"
              foreground: root.bar.foreground
              horizontalPadding: Style.space(12)
              verticalPadding: Style.space(8)
              iconSize: Style.font.iconLarge
              hasCursor: root.cursorActive && root.cursorIndex === 1
              onHovered: function(isHovered) {
                if (!isHovered) return
                root.cursorActive = true
                root.cursorIndex = 1
              }
              enabled: !root.presentationWaiting && root.service && root.service.activePlayer
                && root.service.activePlayer.canGoPrevious
              opacity: enabled ? 1.0 : 0.4
              onClicked: if (root.service) root.service.runAction("previous")
            }
          }

          Item {
            width: playButton.implicitWidth
            height: parent.height

            Button {
              id: playButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.playing ? "󰏤" : "󰐊"
              foreground: root.bar.foreground
              horizontalPadding: Style.space(16)
              verticalPadding: Style.space(10)
              iconSize: Style.font.heading
              hasCursor: root.cursorActive && root.cursorIndex === 2
              onHovered: function(isHovered) {
                if (!isHovered) return
                root.cursorActive = true
                root.cursorIndex = 2
              }
              enabled: !root.presentationWaiting && root.service && root.service.activePlayer
                && (root.service.activePlayer.canTogglePlaying || root.service.activePlayer.canPlay || root.service.activePlayer.canPause)
              opacity: enabled ? 1.0 : 0.4
              onClicked: if (root.service) root.service.runAction("playPause")
            }
          }

          Item {
            width: nextButton.implicitWidth
            height: parent.height

            Button {
              id: nextButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒭"
              foreground: root.bar.foreground
              horizontalPadding: Style.space(12)
              verticalPadding: Style.space(8)
              iconSize: Style.font.iconLarge
              hasCursor: root.cursorActive && root.cursorIndex === 3
              onHovered: function(isHovered) {
                if (!isHovered) return
                root.cursorActive = true
                root.cursorIndex = 3
              }
              enabled: !root.presentationWaiting && root.service && root.service.activePlayer
                && root.service.activePlayer.canGoNext
              opacity: enabled ? 1.0 : 0.4
              onClicked: if (root.service) root.service.runAction("next")
            }
          }
        }

        // ---------- Empty state ----------
        Column {
          visible: false
          width: parent.width
          spacing: Style.space(8)
          topPadding: Style.space(10)
          bottomPadding: Style.space(2)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "󰝚"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.service && root.service.launching ? "Opening Apple Music…" : "No song playing"
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        PanelSeparator {
          visible: root.hasMedia
          foreground: root.bar.foreground
        }

        Button {
          width: parent.width
          // Same toggle as right-click on the bar icon (openWindow, not
          // focusWindowOnly). Uses windowVisible rather than
          // windowKnownOpen: the window still "exists" while hidden, so
          // windowKnownOpen alone can't distinguish hidden from shown.
          // Refreshed whenever the popover opens (see onPopoverOpenChanged),
          // so it's accurate at the moment it's seen.
          text: root.service && root.service.selectedSource === "youtube"
            ? (root.service.youtubeTargetVisible ? "Hide YouTube" : "Open YouTube")
            : root.service && root.service.windowVisible ? "Hide Apple Music" : "Open Apple Music"
          bordered: true
          hasCursor: root.cursorActive && root.cursorIndex === 4
          onHovered: function(isHovered) {
            if (!isHovered) return
            root.cursorActive = true
            root.cursorIndex = 4
          }
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.openWindow()
        }
      }
    }
  }

  // KeyboardPanel retains keyboard focus on the popup's original output.
  // Its other-monitor dismiss surface doesn't focus that monitor merely on
  // pointer entry, so a subsequent Super+F could fullscreen the old output.
  Variants {
    model: root.popoverOpen ? Quickshell.screens : []
    delegate: Component {
      PanelWindow {
        required property var modelData
        screen: modelData
        visible: root.popoverOpen && popup.screen && modelData.name !== popup.screen.name
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        anchors { top: true; bottom: true; left: true; right: true }
        WlrLayershell.namespace: "music-monitor-follow"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        property Item focusTarget: null
        onFocusTargetChanged: if (focusTarget) Qt.callLater(function() { focusTarget.forceActiveFocus() })
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.AllButtons
          onEntered: {
            var name = String(modelData.name || "")
            if (!/^[A-Za-z0-9_.-]+$/.test(name)) return
            Quickshell.execDetached(["hyprctl", "eval",
              'hl.dispatch(hl.dsp.focus({ monitor = "' + name + '" }))'])
          }
          onClicked: root.close()
        }
        PanelKeyCatcher {
          id: monitorCatcher
          anchors.fill: parent
          onCloseRequested: root.close()
          onActivateRequested: if (root.service) root.service.runAction("playPause")
        }
        Component.onCompleted: focusTarget = monitorCatcher
      }
    }
  }

  // PanelKeyCatcher intentionally abstracts the raw QKeyEvent away, including
  // whether a press came from keyboard auto-repeat. Seeking uses that bit to
  // make held arrows advance faster while keeping the standard panel
  // navigation contract for every other control.
  component MusicKeyCatcher: Item {
    id: catcher
    signal moveRequested(int dx, int dy, bool autoRepeat)
    signal activateRequested()
    signal closeRequested()
    signal tabRequested(int direction)

    focus: true
    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Escape) {
        catcher.closeRequested(); event.accepted = true; return
      }
      if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
        catcher.tabRequested((event.modifiers & Qt.ShiftModifier)
          || event.key === Qt.Key_Backtab ? -1 : 1)
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Down || event.text === "j") {
        catcher.moveRequested(0, 1, event.isAutoRepeat); event.accepted = true; return
      }
      if (event.key === Qt.Key_Up || event.text === "k") {
        catcher.moveRequested(0, -1, event.isAutoRepeat); event.accepted = true; return
      }
      if (event.key === Qt.Key_Right || event.text === "l") {
        catcher.moveRequested(1, 0, event.isAutoRepeat); event.accepted = true; return
      }
      if (event.key === Qt.Key_Left || event.text === "h") {
        catcher.moveRequested(-1, 0, event.isAutoRepeat); event.accepted = true; return
      }
      if (event.key === Qt.Key_Space) {
        if (root.service) root.service.runAction("playPause")
        event.accepted = true
        return
      }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        catcher.activateRequested(); event.accepted = true
      }
    }
  }

  // A small animated equalizer for the bar icon while something is
  // playing. Not real audio analysis (that would mean capturing this
  // specific Chromium process's PipeWire stream continuously any time
  // anything plays, just to animate a ~16px bar icon) — each bar just
  // drifts to a fresh random height on its own timer, staggered per bar so
  // they don't move in lockstep.
  component PlayingVisualizer: Row {
    id: viz
    // Row only positions children along its own width, so sizing it to
    // parent would leave the bars packed against the left edge instead of
    // centered. Sizing it to its own content (the default) and centering
    // that keeps them centered regardless of bar count or width; height is
    // pinned to the parent explicitly since centering needs a height to
    // center against.
    anchors.centerIn: parent
    height: parent.height
    property color foreground: Color.foreground
    readonly property real barWidth: Math.max(1, Style.space(2))
    // Lifts the bars off the very bottom edge of the icon canvas, and
    // shrinks the range they grow into to match — flush-to-the-edge, nearly
    // full-height bars read as much bigger than the idle note glyph, which
    // has its own natural padding.
    readonly property real bottomInset: Math.max(1, Style.space(3))
    readonly property real availableHeight: Math.max(1, viz.height - bottomInset)
    spacing: Math.max(1, Style.space(2))

    Repeater {
      model: 4

      Item {
        id: slot
        required property int index
        width: viz.barWidth
        height: viz.height

        Rectangle {
          id: bar
          anchors.bottom: parent.bottom
          anchors.bottomMargin: viz.bottomInset
          anchors.horizontalCenter: parent.horizontalCenter
          width: parent.width
          radius: width / 2
          color: viz.foreground
          height: viz.availableHeight * 0.25

          Behavior on height {
            NumberAnimation { duration: 240; easing.type: Easing.InOutSine }
          }
        }

        Timer {
          interval: 260 + slot.index * 35
          repeat: true
          running: true
          triggeredOnStart: true
          onTriggered: bar.height = Math.max(1, viz.availableHeight * (0.15 + Math.random() * 0.55))
        }
      }
    }
  }
}
