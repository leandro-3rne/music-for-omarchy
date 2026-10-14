import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Mpris

// Owns exactly two things: enough Hyprland window state to find-or-launch
// the dedicated Chromium window, and the MPRIS player that belongs to it.
// Playback metadata, artwork, and transport controls all ride on MPRIS —
// Chromium already publishes those for any tab using the Media Session API,
// which music.apple.com does — so no in-page extension is needed. Browser
// theming (chrome color + light/dark) is likewise already handled
// system-wide by Omarchy's `omarchy-theme-set-browser` policy.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property var pluginRegistry: null
  property bool manageIpc: true
  // Replacement bars create one fallback service per widget instance. Give
  // each service its own artwork namespace so their snapshot helpers cannot
  // remove files that another bar is still displaying.
  readonly property string artOwner: Date.now().toString(16)
    + Math.floor(Math.random() * 0x100000000).toString(16)

  // Third-party manifests intentionally hide __sourceDir from plugins. Resolve
  // the helper relative to this QML component instead, so the browser control
  // path remains available without exposing the plugin registry's source path.
  readonly property string controlPath: {
    var url = String(Qt.resolvedUrl("control.sh"))
    if (url.indexOf("file://") !== 0) return ""
    try { return decodeURIComponent(url.substring("file://".length)) }
    catch (e) { return "" }
  }
  readonly property string fullscreenOpenHelper: (Quickshell.env("HOME") || "")
    + "/.config/omarchy/plugins/io.github.leandro-3rne.window-switcher/unfullscreen-on-new-window.sh"
  readonly property string fullscreenMoveHelper: (Quickshell.env("HOME") || "")
    + "/.config/omarchy/plugins/io.github.leandro-3rne.window-switcher/unfullscreen-on-window-move.sh"

  // The media service is kept loaded with the bar, so this listener remains
  // active even while the Alt-Tab overlay itself is closed.
  Connections {
    target: Hyprland
    enabled: root.manageIpc
    function onRawEvent(event) {
      var eventName = String(event && event.name || "")
      if (eventName === "closewindow") {
        var closed = []
        try { closed = event.parse(1) } catch (e) { return }
        var closedAddress = String(closed[0] || "")
        if (/^[0-9a-fA-F]+$/.test(closedAddress)) closedAddress = "0x" + closedAddress
        var isMediaWindow = closedAddress === root.windowAddress
        for (var c = 0; !isMediaWindow && c < root.youtubeWindows.length; c++)
          isMediaWindow = String(root.youtubeWindows[c].address || "") === closedAddress
        if (isMediaWindow) root.requestState("sync")
        return
      }
      if (eventName !== "openwindow" && eventName !== "movewindow" && eventName !== "movewindowv2") return
      var fields = []
      try {
        fields = event.parse(eventName === "openwindow" ? 4 : eventName === "movewindowv2" ? 3 : 2)
      } catch (e) { return }
      var address = String(fields[0] || "")
      // Hyprland's event stream omits the 0x prefix used by clients JSON.
      if (/^[0-9a-fA-F]+$/.test(address)) address = "0x" + address
      if (!/^0x[0-9a-fA-F]+$/.test(address)) return
      if (eventName === "openwindow")
        Quickshell.execDetached(["bash", root.fullscreenOpenHelper, address])
      else
        Quickshell.execDetached(["bash", root.fullscreenMoveHelper, address])
    }
  }

  // ------------------------------------------------------- Hyprland window
  property int browserPid: 0
  property string youtubeAddress: ""
  property int youtubePid: 0
  property var youtubePids: []
  property var youtubeWindows: []
  property bool youtubeVisible: false
  property string lastPlayedSource: ""
  property string lastYoutubeAddress: ""
  property string lastPlayingPlayer: ""
  property string windowAddress: ""
  property string windowWorkspace: ""
  property bool windowWorkspaceVisible: false
  property bool windowKnownOpen: false
  property bool launching: false
  // Preserve the focused group across Chromium startup. Once the new window
  // maps, control.sh adds only Apple Music to that exact group.
  property string launchGroupTargetAddress: ""
  property bool launchCommandStarted: false
  property string pendingIntent: ""
  property string lastError: ""
  property int postActionSyncAttempts: 0

  // windowKnownOpen only means the process exists — it stays true after
  // hiding, since that just parks the window rather than closing it. Real
  // workspace visibility also covers a user scratchpad correctly: visible
  // while presented on a monitor, hidden after the scratchpad is toggled off.
  readonly property bool windowVisible: windowKnownOpen && windowWorkspaceVisible

  function refresh() { requestState("sync") }

  // Window actions run detached so they never block the shell. Re-read the
  // resulting Hyprland state for a short time afterwards: otherwise the
  // service keeps the pre-action visibility until the popover is reopened,
  // making an open window look unrecognised (and the Open/Hide label stale).
  function syncAfterWindowAction() {
    postActionSyncAttempts = 0
    postActionSync.restart()
  }

  function requestState(intent) {
    if (!controlPath) return
    if (stateProc.running) {
      pendingIntent = intent
      return
    }
    stateProc.__intent = intent
    stateProc.command = [controlPath, "state"]
    stateProc.running = true
  }

  function applyState(raw, intent) {
    var state = {}
    try { state = JSON.parse(String(raw || "{}")) } catch (e) { state = {} }

    windowKnownOpen = state.open === true
    windowAddress = windowKnownOpen ? String(state.address || "") : ""
    windowWorkspace = windowKnownOpen ? String(state.workspace || "") : ""
    windowWorkspaceVisible = windowKnownOpen && state.visible === true
    browserPid = windowKnownOpen ? (parseInt(state.pid, 10) || 0) : 0
    youtubeAddress = String(state.youtubeAddress || "")
    youtubePid = parseInt(state.youtubePid, 10) || 0
    youtubePids = Array.isArray(state.youtubePids) ? state.youtubePids : []
    youtubeWindows = Array.isArray(state.youtubeWindows) ? state.youtubeWindows : []
    youtubeVisible = state.youtubeVisible === true
    if (!lastPlayedSource && (state.lastPlayedSource === "apple" || state.lastPlayedSource === "youtube")) {
      lastPlayedSource = state.lastPlayedSource
      lastYoutubeAddress = String(state.lastYoutubeAddress || "")
    }

    if (intent === "open") {
      // A window we already know about might be on the workspace the user
      // is currently looking at (toggleVisibility hides it) or elsewhere/
      // hidden (toggleVisibility brings it into view) — control.sh checks
      // which.
      if (windowKnownOpen) toggleVisibility()
      else launchWindow()
    } else if (intent === "show") {
      // Always brings the window into view — never hides it, regardless of
      // whether it's already open. Distinct from "open" above: tapping the
      // artwork/title should reliably take you to the window, not
      // occasionally hide it out from under you because it happened to
      // already be in view.
      if (windowKnownOpen) showWindow()
      else launchWindow()
    } else if (intent === "awaitLaunch" && windowKnownOpen) {
      launchPoll.stop()
      launching = false
      showWindow()
    }
  }

  // Pops the window onto the current workspace and focuses it. A hidden
  // special workspace is never revealed; Apple Music is detached on its own
  // first and joins the currently focused group when there is one. Classic
  // dispatch strings ("movetoworkspace ...") aren't reliably honored by
  // this Hyprland build, whether issued via Hyprland.dispatch() or the
  // hyprctl CLI; control.sh's "show" goes through hl.dsp.* via `hyprctl
  // eval` instead, which does work. Used unconditionally, even when the
  // window is already visible: moving it onto the workspace it's already on
  // is a harmless no-op.
  function showWindow() {
    if (!controlPath || !windowAddress) return
    var command = ["bash", controlPath, "show", windowAddress]
    if (launchGroupTargetAddress) command.push(launchGroupTargetAddress)
    launchGroupTargetAddress = ""
    Quickshell.execDetached(command)
    syncAfterWindowAction()
  }

  // The right-click action once a window already exists: hide only Apple
  // Music (parked on its special workspace, playback and the session keep
  // going) if it's currently in view, otherwise bring it into view.
  // control.sh checks the window's *workspace*, not which window has input
  // focus — Omarchy runs with input:follow_mouse, so the pointer travelling
  // from this window to the bar icon crosses other windows on the way and
  // steals focus before the click is processed, making "was it focused a
  // moment ago" unreliable. It also always acts on our own window's address
  // specifically, never on whatever window happens to be active.
  function toggleVisibility() {
    if (!controlPath) return
    Quickshell.execDetached(["bash", controlPath, "toggle"])
    syncAfterWindowAction()
  }

  function launchWindow() {
    if (launching || !controlPath) return
    // A newly created browser window must not inherit the presentation kept
    // for track-to-track gaps in the previous Apple Music session.
    launching = true
    launchGroupTargetAddress = ""
    launchCommandStarted = false
    lastError = ""
    launchTargetProc.command = ["hyprctl", "-j", "activewindow"]
    launchTargetProc.running = true
  }

  function startLaunch() {
    if (!launching || launchCommandStarted) return
    launchCommandStarted = true
    Quickshell.execDetached(["bash", controlPath, "launch"])
    launchPoll.attempts = 0
    launchPoll.restart()
  }

  // Launches the real Chromium window if it doesn't exist yet; otherwise
  // toggles it between hidden and shown (see toggleVisibility). Used by the
  // bar icon's right-click and the popover's Open/Hide button.
  function openWindow() {
    if (selectedSource === "youtube" && youtubeTargetAddress) {
      Quickshell.execDetached(["bash", controlPath, "toggle-media", youtubeTargetAddress])
      syncAfterWindowAction()
      return
    }
    requestState("open")
  }

  // Same launch-if-needed fallback, but never hides an already-open window
  // — always brings it into view. Used by the popover's tap-to-open
  // artwork/title, which should be a reliable "take me there", not a toggle.
  function focusWindow() { requestState("show") }

  function focusPlayingWindow() {
    if (selectedSource === "youtube" && youtubeTargetAddress) {
      Quickshell.execDetached(["bash", controlPath, "show-media", youtubeTargetAddress])
      syncAfterWindowAction()
    } else focusWindow()
  }

  // End the dedicated browser process instead of asking the page to close
  // its window. Apple Music installs a beforeunload handler while playback
  // is active; process termination bypasses that confirmation while still
  // letting Chromium flush its isolated profile normally.
  function quitWindow() {
    if (!controlPath) return
    Quickshell.execDetached(["bash", controlPath, "close"])
    windowKnownOpen = false
    windowAddress = ""
    windowWorkspace = ""
    windowWorkspaceVisible = false
    browserPid = 0
    launchGroupTargetAddress = ""
    launchCommandStarted = false
    if (activePlayer === applePlayer) clearDisplayedMetadata()
  }

  Process {
    id: stateProc
    property string __intent: ""
    stdout: StdioCollector {
      onStreamFinished: {
        root.applyState(text, stateProc.__intent)
        if (root.pendingIntent !== "") {
          var next = root.pendingIntent
          root.pendingIntent = ""
          root.requestState(next)
        }
      }
    }
    onExited: function(code) {
      if (code !== 0 && stateProc.__intent === "open") {
        root.lastError = "Could not read Hyprland window state"
        Quickshell.execDetached(["omarchy-notification-send", "Apple Music", root.lastError])
      }
    }
  }

  Timer {
    id: postActionSync
    interval: 250
    repeat: true
    onTriggered: {
      root.postActionSyncAttempts++
      root.requestState("sync")
      if (root.postActionSyncAttempts >= 6) stop()
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    onTriggered: root.refresh()
  }

  // Read the focused window before launching. The active window changes to
  // Chromium as soon as it maps, so looking it up later would lose the group
  // the user had focused when they invoked Apple Music.
  Process {
    id: launchTargetProc
    stdout: StdioCollector {
      onStreamFinished: {
        var active = {}
        try { active = JSON.parse(String(text || "{}")) } catch (e) { active = {} }
        var grouped = active && active.grouped
        if (Array.isArray(grouped) && grouped.length > 1 && active.address)
          root.launchGroupTargetAddress = String(active.address)
        root.startLaunch()
      }
    }
    onExited: function() { Qt.callLater(function() { root.startLaunch() }) }
  }

  Timer {
    id: launchPoll
    interval: 250
    repeat: true
    property int attempts: 0
    onTriggered: {
      attempts++
      if (attempts > 40) {
        stop()
        root.launching = false
        root.launchGroupTargetAddress = ""
        root.launchCommandStarted = false
        root.lastError = "Chromium did not create the Apple Music window"
        Quickshell.execDetached(["omarchy-notification-send", "Apple Music", root.lastError])
        return
      }
      root.requestState("awaitLaunch")
    }
  }

  Component.onCompleted: Qt.callLater(function() {
    root.requestState("sync")
    if (root.length > 0) root.lastStableLength = root.length
    initialPositionReveal.restart()
    // Covers a start that already has a track loaded, where artCandidate is
    // set from the outset and so never changes to announce itself.
    root.snapshotArt()
    // The same applies to title/artist/album after a plugin hot reload: the
    // composed lookup key may already be initialized before its change
    // handler is connected, so explicitly resolve the current track once.
    root.lookupArtwork()
  })

  // Cleanup is keyed to the registry's enabled state for this plugin id
  // going true -> false, which is what both `omarchy plugin remove` and a
  // plain disable do. Object destruction is deliberately not the trigger:
  // the shell also tears these instances down on an ordinary shell restart,
  // where the plugin stays enabled and is rebuilt moments later, and a
  // destructor can't tell the two apart.
  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : ""
  property bool pluginWasEnabled: true

  Connections {
    target: root.pluginRegistry
    function onPluginsChanged() {
      if (!root.pluginRegistry || !root.pluginId) return
      var enabledNow = root.pluginRegistry.isEnabled(root.pluginId) === true
      if (root.pluginWasEnabled && !enabledNow) root.handleDisabled()
      root.pluginWasEnabled = enabledNow
    }
  }

  // Quits the dedicated browser so a signed-in session doesn't outlive the
  // UI that was managing it. Removal and a plain disable arrive here the
  // same way — `omarchy plugin remove` disables the plugin before deleting
  // its folder — so control.sh's "quit" settles which of the two happened
  // and whether the on-disk profile goes with it.
  function handleDisabled() {
    if (controlPath) Quickshell.execDetached(["bash", controlPath, "quit"])
  }

  // ------------------------------------------------------------------ MPRIS
  //
  // Chromium publishes one org.mpris.MediaPlayer2.chromium.instance<PID>
  // service per browser process, so matching on pid isolates this dedicated
  // instance from any other Chromium/Brave window the user has open.
  readonly property var players: Mpris.players ? Mpris.players.values : []

  function playerForPid(pid) {
    if (!pid) return null
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      var match = /\.instance(\d+)$/.exec(String(p && p.dbusName || ""))
      if (match && parseInt(match[1], 10) === pid) return p
    }
    return null
  }

  readonly property var applePlayer: playerForPid(browserPid)
  readonly property var youtubePlayer: playerForPid(youtubePid)
  function parked(workspace) {
    return workspace === "special:Music" || workspace === "special:Apple Music"
      || workspace === "special:AM"
  }
  // A parked window always wins over a normal one. Within YouTube, the last
  // window to emit audio wins; newly opened idle windows never steal its slot.
  readonly property var youtubeTarget: {
    var parkedWindow = null
    var playedWindow = null
    for (var i = 0; i < youtubeWindows.length; i++) {
      var w = youtubeWindows[i]
      if (w.address === lastYoutubeAddress) playedWindow = w
      if (parked(w.workspace) && !parkedWindow) parkedWindow = w
    }
    if (playedWindow && parked(playedWindow.workspace)) return playedWindow
    return parkedWindow || playedWindow || (youtubeWindows.length ? youtubeWindows[0] : null)
  }
  readonly property string youtubeTargetAddress: youtubeTarget ? String(youtubeTarget.address) : ""
  readonly property bool youtubeTargetVisible: youtubeTarget ? youtubeTarget.visible === true : false
  readonly property bool appleParked: windowKnownOpen && parked(windowWorkspace)
  readonly property bool youtubeParked: youtubeTarget && parked(youtubeTarget.workspace)
  readonly property var playingYoutubePlayer: {
    var preferred = playerForPid(youtubeTarget ? youtubeTarget.pid : 0)
    if (preferred && preferred.isPlaying) return preferred
    for (var i = 0; i < players.length; i++)
      if (players[i] && players[i].isPlaying && isYoutubePlayer(players[i])) return players[i]
    return null
  }
  readonly property bool youtubePreferred: {
    if (!youtubeTarget) return false
    if (skipRequested && transitionSource) return transitionSource === "youtube"
    return !windowKnownOpen || (youtubeParked && !appleParked) ||
      (youtubeParked === appleParked &&
        (playingYoutubePlayer && !(applePlayer && applePlayer.isPlaying)
          || ((!!playingYoutubePlayer === !!(applePlayer && applePlayer.isPlaying))
              && lastPlayedSource === "youtube")))
  }

  function recordPlayback(player) {
    if (!player || !player.isPlaying) return
    var name = String(player.dbusName || "")
    if (player === applePlayer) {
      lastPlayingPlayer = name
      lastPlayedSource = "apple"
      if (windowAddress)
        Quickshell.execDetached(["bash", controlPath, "remember", "apple", windowAddress, lastYoutubeAddress])
    } else if (isYoutubePlayer(player)) {
      lastPlayingPlayer = name
      var match = /\.instance(\d+)$/.exec(name)
      var pid = match ? Number(match[1]) : 0
      var address = ""
      var track = String(player.trackTitle || "").trim().toLowerCase()
      // Chromium can put several YouTube windows in the same process. Match
      // the playing video's title against the window title before falling
      // back to the most recently focused window of that process.
      if (track.length > 4) {
        for (var t = 0; t < youtubeWindows.length; t++) {
          var candidate = youtubeWindows[t]
          if (candidate.pid === pid && String(candidate.title || "").toLowerCase().indexOf(track) !== -1) {
            address = String(candidate.address)
            break
          }
        }
      }
      for (var i = 0; i < youtubeWindows.length; i++) {
        if (!address && youtubeWindows[i].pid === pid) {
          address = String(youtubeWindows[i].address)
          break
        }
      }
      lastYoutubeAddress = address || youtubeTargetAddress
      lastPlayedSource = "youtube"
      if (lastYoutubeAddress)
        Quickshell.execDetached(["bash", controlPath, "remember", "youtube", lastYoutubeAddress])
    }
  }

  Instantiator {
    model: root.players
    delegate: Item {
      required property var modelData
      visible: false
      Connections {
        target: modelData
        function onIsPlayingChanged() {
          if (modelData.isPlaying) root.recordPlayback(modelData)
        }
      }
    }
  }
  function isYoutubePlayer(player) {
    if (!player || !youtubeAddress) return false
    if (player === youtubePlayer || /youtube/i.test(String(player.identity || ""))) return true
    var match = /\.instance(\d+)$/.exec(String(player.dbusName || ""))
    return !!match && youtubePids.indexOf(Number(match[1])) !== -1
  }
  // Playback wins; if both browsers play, the one that started playing most
  // recently wins. Parked windows take priority over the audio history.
  readonly property var activePlayer: {
    var apple = applePlayer
    var youtube = playerForPid(youtubeTarget ? youtubeTarget.pid : 0)
    var playingYoutube = playingYoutubePlayer
    if (skipRequested && transitionSource === "apple") return apple
    if (skipRequested && transitionSource === "youtube") return youtube || playingYoutube
    if (youtubeParked && !appleParked)
      return youtube || playingYoutube
    if (appleParked && !youtubeParked)
      return apple
    if (apple && apple.isPlaying && playingYoutube)
      return youtubePreferred ? playingYoutube : apple
    if (apple && apple.isPlaying) return apple
    if (playingYoutube) return playingYoutube
    for (var j = 0; j < players.length; j++)
      if (players[j] && players[j].isPlaying) return players[j]
    if (youtubePreferred) {
      if (youtube) return youtube
      for (var k = 0; k < players.length; k++)
        if (isYoutubePlayer(players[k])) return players[k]
      return null
    }
    if (windowKnownOpen) return apple
    if (youtubeTarget) {
      if (youtube) return youtube
      for (var n = 0; n < players.length; n++)
        if (isYoutubePlayer(players[n])) return players[n]
    }
    if (youtubeTarget) return null
    return apple || (players.length > 0 ? players[0] : null)
  }
  readonly property string selectedSource: youtubePreferred ? "youtube" : "apple"
  readonly property bool selectedWindowVisible: selectedSource === "youtube"
    ? youtubeTargetVisible : windowVisible
  readonly property string rawTitle: activePlayer ? String(activePlayer.trackTitle || "") : ""
  readonly property string rawArtist: activePlayer ? String(activePlayer.trackArtist || "") : ""
  readonly property string rawAlbum: activePlayer ? String(activePlayer.trackAlbum || "") : ""
  readonly property string positionIdentity: (activePlayer ? String(activePlayer.dbusName || "") : "")
    + "\n" + rawTitle + "\n" + rawArtist
  property bool positionReady: false
  property double lastObservedPosition: -1
  property double lastStablePosition: 0
  property bool positionEndJump: false
  property double positionIdentityTimestamp: 0
  property double positionAtIdentity: 0
  property bool positionAtIdentityValid: false
  property double lastStableLength: 0

  function waitForStablePosition() {
    positionReady = false
    initialPositionReveal.restart()
  }

  function positionIsPlausible(value) {
    var seconds = Number(value)
    if (!isFinite(seconds) || seconds < 0 || seconds >= 86400) return false
    if (positionEndJump && activePlayer && activePlayer.isPlaying) return false
    // Do not clamp a broken MPRIS position to the track length: that turns a
    // transient sentinel/overshoot into a misleading 100% progress reading.
    return length <= 0 || seconds <= length + 5
  }

  function observePositionChange() {
    var reported = activePlayer ? Number(activePlayer.position) : NaN
    if (activePlayer && !activePlayer.isPlaying && pendingSeekPosition < 0) {
      // The paused/stopped MPRIS position may briefly reset while Chromium
      // tears down its session. Keep the last playback sample until resume or
      // an explicit seek instead of following that transient value.
      lastObservedPosition = reported
      return
    }
    if (!rawTitle && !rawArtist && !skipRequested
        && (!activePlayer || !activePlayer.isPlaying)) return
    var previous = lastObservedPosition
    lastObservedPosition = reported

    var nearEnd = length > 0 && reported >= length - 5
    if (positionEndJump && (!activePlayer || !activePlayer.isPlaying || !nearEnd)) {
      positionEndJump = false
      waitForStablePosition()
    }
    // A jump from the opening part of a playing track straight to its end is
    // not a credible playback update. Keep it quarantined until MPRIS reports
    // a new track/position, an explicit seek is made, or playback is paused.
    if (positionReady && pendingSeekPosition < 0 && activePlayer && activePlayer.isPlaying && length > 0
        && previous >= 0 && previous < length * 0.25
        && nearEnd && reported - previous > Math.max(5, length * 0.25)) {
      positionEndJump = true
      waitForStablePosition()
      return
    }
    if (!positionIsPlausible(reported)) {
      waitForStablePosition()
      return
    }
    if (length > 0) lastStableLength = length
    if (!positionReady) {
      if (pendingSeekPosition < 0) lastStablePosition = reported
      initialPositionReveal.restart()
      return
    }

    // A normal playback update advances by about a second. Larger jumps that
    // are not our own pending seek usually mean MPRIS has just reset or caught
    // up to the newly loaded track; debounce the display until it settles.
    if (pendingSeekPosition < 0 && activePlayer && activePlayer.isPlaying
        && previous >= 0 && Math.abs(reported - previous) > 5) {
      waitForStablePosition()
      return
    }
    if (pendingSeekPosition < 0) lastStablePosition = reported
  }

  onPositionIdentityChanged: {
    clearPendingSeek()
    if (skipRequested) {
      positionEndJump = false
      waitForStablePosition()
      return
    }
    if (activePlayer && !activePlayer.isPlaying
        && rawTitle === displayedTitle && rawArtist === displayedArtist) {
      positionEndJump = false
      if (positionIsPlausible(lastStablePosition)) {
        positionReady = true
        initialPositionReveal.stop()
      }
      return
    }
    if (!rawTitle && !rawArtist && !skipRequested && (!activePlayer || !activePlayer.isPlaying))
      return
    var wasPositionReady = positionReady
    var previousStablePosition = lastStablePosition
    positionEndJump = false
    lastStableLength = 0
    positionIdentityTimestamp = Date.now()
    var initialPosition = activePlayer ? Number(activePlayer.position) : NaN
    if ((wasPositionReady || skipRequested) && length > 0 && isFinite(initialPosition)
        && previousStablePosition >= 0
        && initialPosition >= length - Math.max(5, length * 0.02)
        && previousStablePosition < length * 0.25
        && initialPosition - previousStablePosition > Math.max(5, length * 0.25))
      initialPosition = previousStablePosition
    positionAtIdentityValid = isFinite(initialPosition) && initialPosition >= 0 && initialPosition < 86400
    positionAtIdentity = positionAtIdentityValid ? initialPosition : 0
    lastStablePosition = positionAtIdentityValid ? initialPosition : 0
    waitForStablePosition()
  }

  // Chromium can publish a temporary zero position and then correct either
  // the position or duration in a later update. Debounce those changes so
  // the slider does not reveal an intermediate range or 0 -> current jump.
  Timer {
    id: initialPositionReveal
    interval: 450
    repeat: false
    onTriggered: {
      root.positionReady = !!root.activePlayer
        && !!(root.rawTitle || root.rawArtist)
        && root.positionIsPlausible(root.activePlayer.position)
    }
  }

  // Apple Music briefly clears its Media Session metadata between tracks.
  // Keep the last complete presentation while the dedicated application is
  // still alive, then replace it as soon as the next song arrives. Without
  // this small state layer the panel collapses to its empty view during every
  // skip and looks as if it closed and reopened.
  property string displayedTitle: ""
  property string displayedArtist: ""
  property string displayedAlbum: ""
  property string displayedSource: ""
  // Keeps the player panel mounted through MPRIS player/metadata handoffs.
  // It is released only by the explicit idle/transition timeout path.
  property bool mediaPresentationLatched: false
  property bool trackChanging: false
  property bool skipRequested: false
  property string transitionSource: ""
  property int seekCue: 0
  property int seekCueSerial: 0

  function clearDisplayedMetadata() {
    displayedTitle = ""
    displayedArtist = ""
    displayedAlbum = ""
    trackChanging = false
    skipRequested = false
    transitionSource = ""
    displayedSource = ""
    mediaPresentationLatched = false
    artUrl = ""
    highResArtUrl = ""
    catalogLength = 0
    lastStableLength = 0
  }

  function beginTrackTransition() {
    transitionSource = selectedSource
    skipRequested = true
    trackChanging = true
    positionEndJump = false
    lastStablePosition = 0
    lastStableLength = 0
    positionIdentityTimestamp = Date.now()
    positionAtIdentity = 0
    positionAtIdentityValid = true
    waitForStablePosition()
    metadataGapTimeout.stop()
    trackTransitionTimeout.restart()
    artUrl = ""
    highResArtUrl = ""
    catalogLength = 0
  }

  function refreshDisplayedMetadata() {
    if (!rawTitle && !rawArtist) {
      if (displayedTitle || displayedArtist) {
        // A pause/stop can momentarily clear MPRIS metadata without changing
        // tracks. Keep the current presentation and position through that gap.
        if (!skipRequested && (!activePlayer || !activePlayer.isPlaying)) {
          trackChanging = false
          positionEndJump = false
          if (positionIsPlausible(lastStablePosition)) {
            positionReady = true
            initialPositionReveal.stop()
          }
          metadataGapTimeout.restart()
          return
        }
        trackChanging = true
        artUrl = ""
        highResArtUrl = ""
        catalogLength = 0
        if (!skipRequested) metadataGapTimeout.restart()
      } else {
        trackChanging = skipRequested
      }
      return
    }
    var nextKey = rawTitle + "\n" + rawArtist
    var previousKey = displayedTitle + "\n" + displayedArtist
    if (skipRequested && nextKey === previousKey) return
    if (skipRequested) {
      positionEndJump = false
      positionIdentityTimestamp = Date.now()
      positionAtIdentity = 0
      positionAtIdentityValid = true
      lastStablePosition = 0
    }
    metadataGapTimeout.stop()
    trackTransitionTimeout.stop()
    skipRequested = false
    transitionSource = ""
    if (nextKey !== previousKey) {
      // Never let the temporary Chromium Media Session icon captured during
      // the metadata gap become the next song's cover.
      artUrl = ""
      highResArtUrl = ""
    }
    displayedTitle = rawTitle
    displayedArtist = rawArtist
    displayedAlbum = rawAlbum
    mediaPresentationLatched = true
    trackChanging = false
    queueSnapshotArt()
  }

  // Metadata normally returns quickly during a skip. If it stays empty, the
  // player is idle rather than changing tracks, so expose the empty state
  // instead of showing the last artist and an endless loading message.
  Timer {
    id: metadataGapTimeout
    interval: root.skipRequested ? 30000 : 10000
    repeat: false
    onTriggered: if (!root.rawTitle && !root.rawArtist) root.clearDisplayedMetadata()
  }

  // A failed transport action should not leave the previous metadata in a
  // permanent loading state. Normal skips resolve much sooner; this is only
  // a safety net for a browser/MPRIS instance that disappears mid-transition.
  Timer {
    id: trackTransitionTimeout
    interval: 30000
    repeat: false
    onTriggered: {
      if (root.skipRequested && !root.rawTitle && !root.rawArtist)
        root.clearDisplayedMetadata()
    }
  }

  readonly property bool hasMedia: mediaPresentationLatched || !!(rawTitle || rawArtist ||
    (activePlayer && (displayedTitle || displayedArtist)) || trackChanging || skipRequested)
  readonly property string title: rawTitle || rawArtist ? rawTitle : displayedTitle
  readonly property string artist: rawTitle || rawArtist ? rawArtist : displayedArtist
  readonly property string album: rawTitle || rawArtist ? rawAlbum : displayedAlbum

  onRawTitleChanged: refreshDisplayedMetadata()
  onRawArtistChanged: refreshDisplayedMetadata()
  onRawAlbumChanged: refreshDisplayedMetadata()

  // Chromium's MPRIS artwork is often only a 150px thumbnail. Resolve the
  // current song through Apple's public catalog to obtain the matching CDN
  // artwork when Chromium's local thumbnail is unavailable. The same result
  // also carries
  // trackTimeMillis, which is a duration fallback for Chromium's occasional
  // INT64_MAX "unknown length" MPRIS value.
  property string highResArtUrl: ""
  property double catalogLength: 0
  property bool catalogLookupRunning: false
  property bool catalogLookupEnabled: false
  property int catalogRetryAttempt: 0
  // Every track on an album normally shares one catalog artwork URL. Keep
  // successful resolutions for this shell session so one well-indexed track
  // can immediately provide sharp art to its harder-to-find neighbours.
  property var albumArtCache: ({})
  // Durations are track-specific, so unlike artwork they are keyed by both
  // normalized album and title. Collection IDs let later tracks skip the
  // unreliable free-text song search altogether.
  property var trackLengthCache: ({})
  property var albumCollectionCache: ({})
  readonly property bool artLoading: trackChanging || catalogLookupRunning || artProc.running || localArtDelay.running
  // Album is part of the identity as well as the fallback route. Chromium
  // can publish it a moment after title/artist; including it here retries the
  // lookup when that extra disambiguation becomes available.
  readonly property string artworkLookupKey: title + "\n" + artist + "\n" + album

  function lookupArtwork() {
    var albumKey = normalizedCatalogText(album)
    var trackKey = albumKey + "\n" + normalizedCatalogText(title)
    highResArtUrl = albumKey !== "" ? String(albumArtCache[albumKey] || "") : ""
    catalogLength = Number(trackLengthCache[trackKey] || 0)
    if (!catalogLookupEnabled) {
      catalogLookupRunning = false
      return
    }
    if (highResArtUrl !== "") catalogRetry.stop()
    if (!title || !artist || lookupProc.running || albumSearchProc.running || collectionProc.running) return
    catalogLookupRunning = true
    var cachedCollectionId = Number(albumCollectionCache[albumKey] || 0)
    if (albumKey !== "" && cachedCollectionId > 0) {
      startCollectionLookup(cachedCollectionId, artworkLookupKey)
      return
    }
    lookupProc.__lookupKey = artworkLookupKey
    lookupProc.command = [
      "curl", "-fsSL", "--connect-timeout", "4", "--max-time", "12", "--get",
      // Apple's search often returns nothing when every collaborator from
      // MPRIS is included. The first credit is the release's lead artist;
      // album/title verification below still decides whether a result is safe.
      "--data-urlencode", "term=" + catalogLeadArtist(artist) + " " + title,
      "--data-urlencode", "entity=song",
      "--data-urlencode", "limit=20",
      "https://itunes.apple.com/search"
    ]
    lookupProc.running = true
  }

  onArtworkLookupKeyChanged: {
    catalogRetry.stop()
    catalogRetryAttempt = 0
    lookupArtwork()
  }

  onCatalogLookupEnabledChanged: {
    if (!catalogLookupEnabled) {
      catalogRetry.stop()
      catalogLookupRunning = false
      return
    }
    catalogRetryAttempt = 0
    lookupArtwork()
  }

  function scheduleCatalogRetry(key) {
    if (!catalogLookupEnabled || key !== artworkLookupKey || highResArtUrl !== ""
        || !title || !artist || catalogRetryAttempt >= 3) return
    catalogRetryAttempt++
    catalogRetry.__lookupKey = key
    catalogRetry.interval = 1000 * Math.pow(2, catalogRetryAttempt - 1)
    catalogRetry.restart()
  }

  Timer {
    id: catalogRetry
    property string __lookupKey: ""
    repeat: false
    onTriggered: {
      if (__lookupKey === root.artworkLookupKey && root.catalogLookupEnabled)
        root.lookupArtwork()
    }
  }

  function normalizedCatalogText(value) {
    return String(value || "").toLowerCase()
      .replace(/\([^)]*(?:feat|ft\.)[^)]*\)/g, "")
      .replace(/\[[^\]]*(?:feat|ft\.)[^\]]*\]/g, "")
      .replace(/[^a-z0-9]+/g, " ").trim()
  }

  // Apple Music/Chromium can disagree on release labels such as
  // "MINT JAMS" versus "MINT JAMS (Live)". Keep the distinction for cache
  // keys, but use a conservative trailing-"live" equivalence when choosing
  // a catalog collection. This is especially useful when the track title is
  // localized by Chromium and cannot be compared to Apple's English title.
  function catalogAlbumKey(value) {
    return normalizedCatalogText(value).replace(/\s+live$/, "").trim()
  }

  function catalogLeadArtist(value) {
    var credits = String(value || "").split(/\s*(?:,|&|;)\s*/)
    return credits.length > 0 && credits[0] !== "" ? credits[0] : String(value || "")
  }

  function applyCatalogItem(item, wantedAlbum, wantedTitle) {
    var duration = Number(item.trackTimeMillis || 0) / 1000
    if (isFinite(duration) && duration > 0 && duration < 86400) {
      root.catalogLength = duration
      root.trackLengthCache[wantedAlbum + "\n" + wantedTitle] = duration
    }
    var collectionId = Number(item.collectionId || 0)
    if (wantedAlbum !== "" && collectionId > 0)
      root.albumCollectionCache[wantedAlbum] = collectionId
    var art = String(item.artworkUrl100 || item.artworkUrl60 || "")
    if (art !== "") {
      var largeArt = art.replace(/\/(?:100|60)x(?:100|60)bb\./, "/1024x1024bb.")
      root.highResArtUrl = largeArt
      catalogRetry.stop()
      root.catalogRetryAttempt = 0
      if (wantedAlbum !== "") root.albumArtCache[wantedAlbum] = largeArt
    }
    return true
  }

  function applyCatalogResults(results) {
    var wantedArtist = normalizedCatalogText(root.artist)
    var wantedTitle = normalizedCatalogText(root.title)
    var wantedAlbum = normalizedCatalogText(root.album)
    var wantedAlbumMatch = catalogAlbumKey(root.album)
    var fallbackItem = null
    var fallbackCount = 0
    for (var i = 0; i < results.length; i++) {
      var item = results[i] || {}
      if (item.wrapperType !== "track") continue
      var itemArtist = normalizedCatalogText(item.artistName)
      var itemTitle = normalizedCatalogText(item.trackName)
      var itemAlbum = catalogAlbumKey(item.collectionName)
      var sameAlbum = wantedAlbumMatch !== "" && itemAlbum === wantedAlbumMatch
      var sameArtist = itemArtist === wantedArtist
        || itemArtist.indexOf(wantedArtist) !== -1
        || wantedArtist.indexOf(itemArtist) !== -1
      if (itemTitle !== wantedTitle) {
        // Chromium may expose a localized title (for example Japanese) while
        // Apple's catalog search returns the English release title. If the
        // album and artist identify exactly one result, that result is still
        // safe to use for its duration and shared album artwork. Ambiguous
        // results deliberately fall through to the collection lookup.
        if (wantedAlbumMatch !== "" && sameAlbum && sameArtist) {
          fallbackItem = item
          fallbackCount++
        }
        continue
      }
      // When Apple Music names an album, do not let an otherwise identical
      // single win merely because it appears first in the free-text search.
      // A missing album-version here deliberately falls through to the
      // collection lookup below. Artist matching remains the fallback only
      // for players that publish no album metadata at all.
      if (wantedAlbum !== "" ? !sameAlbum : !sameArtist) continue
      return root.applyCatalogItem(item, wantedAlbum, wantedTitle)
    }
    if (fallbackCount === 1)
      return root.applyCatalogItem(fallbackItem, wantedAlbum, wantedTitle)
    return false
  }

  function matchingCollectionId(results) {
    var wantedAlbum = catalogAlbumKey(root.album)
    var wantedArtist = normalizedCatalogText(root.artist)
    if (wantedAlbum === "") return 0
    var fallbackId = 0
    var ambiguous = false
    for (var i = 0; i < results.length; i++) {
      var item = results[i] || {}
      if (catalogAlbumKey(item.collectionName) !== wantedAlbum) continue
      var collectionId = Number(item.collectionId || 0)
      if (collectionId <= 0) continue
      var collectionArtist = normalizedCatalogText(item.collectionArtistName || item.artistName)
      if (collectionArtist !== "" && wantedArtist.indexOf(collectionArtist) !== -1)
        return collectionId
      // Collaborative tracks may omit the album artist from MPRIS. An exact
      // album title is still safe when every matching search result points to
      // the same collection; reject it only if the title is genuinely
      // ambiguous between multiple collection IDs.
      if (fallbackId === 0) fallbackId = collectionId
      else if (fallbackId !== collectionId) ambiguous = true
    }
    return ambiguous ? 0 : fallbackId
  }

  function startCollectionLookup(collectionId, key) {
    collectionProc.__lookupKey = key
    collectionProc.command = [
      "curl", "-fsSL", "--connect-timeout", "4", "--max-time", "12", "--get",
      "--data-urlencode", "id=" + collectionId,
      "--data-urlencode", "entity=song",
      "https://itunes.apple.com/lookup"
    ]
    collectionProc.running = true
  }

  function startAlbumSearch(key) {
    if (!album) return false
    albumSearchProc.__lookupKey = key
    albumSearchProc.command = [
      "curl", "-fsSL", "--connect-timeout", "4", "--max-time", "12", "--get",
      "--data-urlencode", "term=" + album,
      "--data-urlencode", "entity=album",
      "--data-urlencode", "limit=20",
      "https://itunes.apple.com/search"
    ]
    albumSearchProc.running = true
    return true
  }

  function cacheCollectionResults(results) {
    var wantedAlbum = normalizedCatalogText(root.album)
    var wantedAlbumMatch = catalogAlbumKey(root.album)
    if (wantedAlbum === "") return
    for (var i = 0; i < results.length; i++) {
      var item = results[i] || {}
      if (item.wrapperType !== "track"
          || catalogAlbumKey(item.collectionName) !== wantedAlbumMatch) continue
      var itemTitle = normalizedCatalogText(item.trackName)
      var duration = Number(item.trackTimeMillis || 0) / 1000
      if (itemTitle !== "" && isFinite(duration) && duration > 0 && duration < 86400)
        root.trackLengthCache[wantedAlbum + "\n" + itemTitle] = duration
    }
  }

  Process {
    id: lookupProc
    property string __lookupKey: ""
    stdout: StdioCollector {
      onStreamFinished: {
        // A response for the previous song must not provide the new song's
        // cover or duration after a quick track change.
        if (lookupProc.__lookupKey !== root.artworkLookupKey) return
        var payload = {}
        try { payload = JSON.parse(String(text || "{}")) } catch (e) { payload = {} }
        var results = Array.isArray(payload.results) ? payload.results : []
        if (!root.applyCatalogResults(results)) {
          var collectionId = root.matchingCollectionId(results)
          if (collectionId > 0) {
            root.startCollectionLookup(collectionId, lookupProc.__lookupKey)
          } else root.startAlbumSearch(lookupProc.__lookupKey)
        }
      }
    }
    onExited: {
      if (__lookupKey === root.artworkLookupKey
          && !albumSearchProc.running && !collectionProc.running) {
        root.catalogLookupRunning = false
        root.scheduleCatalogRetry(__lookupKey)
      }
      // lookupArtwork() deliberately does not start a second Process while
      // one is running. If the song changed in flight, launch the queued
      // lookup now so its cover and duration do not stay empty.
      if (__lookupKey !== root.artworkLookupKey) Qt.callLater(root.lookupArtwork)
    }
  }

  Process {
    id: albumSearchProc
    property string __lookupKey: ""
    stdout: StdioCollector {
      onStreamFinished: {
        if (albumSearchProc.__lookupKey !== root.artworkLookupKey) return
        var payload = {}
        try { payload = JSON.parse(String(text || "{}")) } catch (e) { payload = {} }
        var results = Array.isArray(payload.results) ? payload.results : []
        var collectionId = root.matchingCollectionId(results)
        if (collectionId > 0)
          root.startCollectionLookup(collectionId, albumSearchProc.__lookupKey)
      }
    }
    onExited: {
      if (__lookupKey === root.artworkLookupKey && !collectionProc.running) {
        root.catalogLookupRunning = false
        root.scheduleCatalogRetry(__lookupKey)
      } else if (__lookupKey !== root.artworkLookupKey) Qt.callLater(root.lookupArtwork)
    }
  }

  Process {
    id: collectionProc
    property string __lookupKey: ""
    stdout: StdioCollector {
      onStreamFinished: {
        if (collectionProc.__lookupKey !== root.artworkLookupKey) return
        var payload = {}
        try { payload = JSON.parse(String(text || "{}")) } catch (e) { payload = {} }
        var results = Array.isArray(payload.results) ? payload.results : []
        root.cacheCollectionResults(results)
        root.applyCatalogResults(results)
      }
    }
    onExited: {
      if (__lookupKey === root.artworkLookupKey) {
        root.catalogLookupRunning = false
        root.scheduleCatalogRetry(__lookupKey)
      }
      else Qt.callLater(root.lookupArtwork)
    }
  }

  // Track metadata reaches this plugin by way of the page's own Media
  // Session API, so everything in it is treated as untrusted input rather
  // than as something the plugin chose.
  //
  // For artwork that means naming exactly one thing: the local temp file
  // Chromium writes for this profile when it re-serves cover art for its own
  // media UI. Anything else, including any network URL, yields an empty
  // string and the popover falls back to its placeholder glyph. This
  // identifies the candidate; it is control.sh's "art" action, not this
  // check, that decides what the popover ends up loading.
  function safeArtPath(raw) {
    var url = String(raw || "")
    if (url === "") return ""
    var parsed
    try {
      parsed = new URL(url)
    } catch (e) {
      return ""
    }
    if (parsed.protocol !== "file:") return ""
    if (parsed.hostname !== "") return ""
    var path
    try {
      path = decodeURIComponent(parsed.pathname)
    } catch (e) {
      return ""
    }
    if (path.indexOf("..") !== -1) return ""
    if (!/^\/tmp\/\.org\.chromium\.Chromium\.[A-Za-z0-9]+$/.test(path)) return ""
    return path
  }

  // The artwork file named by the player, before anything has been read.
  readonly property string artCandidate: safeArtPath(activePlayer ? activePlayer.trackArtUrl : "")
  // Non-Chromium players commonly publish HTTPS artwork rather than a temp
  // file. The small record label can load it directly without a catalog query.
  readonly property string directArtUrl: {
    var url = activePlayer ? String(activePlayer.trackArtUrl || "") : ""
    return /^https:\/\//i.test(url) ? url : ""
  }
  readonly property string coverUrl: directArtUrl || artUrl

  // What the popover actually loads: control.sh's own copy of the artwork,
  // never the name above. That name is one this plugin is handed rather than
  // one it picks, so it is used once to read from and never passed on to be
  // opened again. Empty until a copy succeeds, which shows the placeholder.
  property string artUrl: ""
  property string lastSnapCandidate: ""
  property string transitionalArtCandidate: ""

  Timer {
    id: transitionalArtTimeout
    interval: 1800
    onTriggered: {
      root.transitionalArtCandidate = ""
      root.queueSnapshotArt()
    }
  }

  onArtCandidateChanged: {
    if (!rawTitle && !rawArtist && artCandidate) {
      transitionalArtCandidate = artCandidate
      transitionalArtTimeout.restart()
    } else if (artCandidate && artCandidate !== transitionalArtCandidate) {
      transitionalArtCandidate = ""
      transitionalArtTimeout.stop()
    }
    queueSnapshotArt()
  }

  function queueSnapshotArt() {
    // Copy the tiny Chromium thumbnail as soon as metadata is present.
    if (!rawTitle && !rawArtist) return
    // Chromium can keep advertising the old thumbnail across a new title.
    // A genuinely new file can be copied quickly; a reused path needs time
    // for Chromium to overwrite its contents before we take the snapshot.
    localArtDelay.interval = lastSnapCandidate ? 650 : 200
    localArtDelay.restart()
  }

  Timer {
    id: localArtDelay
    // The old Chromium cover often remains at the old MPRIS path briefly
    // after new metadata arrives. Wait for its new thumbnail before copying.
    interval: 200
    repeat: false
    onTriggered: root.snapshotArt()
  }

  function snapshotArt() {
    // An empty candidate is normal for a moment during a skip. Preserve the
    // previous decoded cover through that gap; a real new candidate clears
    // it immediately before its fast local snapshot starts.
    if ((!rawTitle && !rawArtist) || artCandidate === "" || !controlPath || artProc.running
        || artCandidate === transitionalArtCandidate) return
    artUrl = ""
    artProc.__candidate = artCandidate
    artProc.__trackKey = positionIdentity
    artProc.command = ["bash", controlPath, "art", artOwner, artCandidate]
    artProc.running = true
  }

  // Percent-encodes a local path for use as a file: URL. The path is one the
  // helper composed under $XDG_RUNTIME_DIR, but encoding keeps characters a
  // URL would otherwise read as structure from being read that way.
  function pathToFileUrl(path) {
    return "file://" + encodeURI(path).replace(/#/g, "%23").replace(/\?/g, "%3F")
  }

  Process {
    id: artProc
    property string __candidate: ""
    property string __trackKey: ""
    stdout: StdioCollector {
      onStreamFinished: {
        if (artProc.__candidate !== root.artCandidate || artProc.__trackKey !== root.positionIdentity) return
        var snapshot = String(text).trim()
        if (snapshot.indexOf("/") === 0) {
          root.lastSnapCandidate = artProc.__candidate
          root.transitionalArtCandidate = ""
          root.artUrl = root.pathToFileUrl(snapshot)
        }
      }
    }
    // A track can change while a copy is in flight; that result is discarded
    // above, so start again against whatever is current now.
    onExited: {
      if (artProc.__candidate !== root.artCandidate || artProc.__trackKey !== root.positionIdentity)
        Qt.callLater(root.queueSnapshotArt)
    }
  }

  readonly property bool playing: activePlayer ? activePlayer.isPlaying === true : false
  // MPRIS players sometimes report length as a sentinel meaning "not known
  // yet" — typically right after a track change, before real duration
  // metadata has loaded. Apple Music's bridge does this as (close to)
  // INT64_MAX microseconds, which surfaces here as ~9.2 trillion seconds:
  // enough to render as a nonsense multi-billion-minute countdown if it
  // isn't screened out. A full day is far beyond any real track, so treat
  // anything past that (or non-finite, or negative) as unknown and fall back
  // to the duration from the Apple catalog lookup already used for artwork.
  readonly property double length: {
    var raw = activePlayer ? Number(activePlayer.length || 0) : 0
    if (isFinite(raw) && raw > 0 && raw < 86400) return raw
    var fallback = Number(catalogLength || 0)
    if (isFinite(fallback) && fallback > 0 && fallback < 86400) return fallback
    return !playing && !trackChanging && (displayedTitle || displayedArtist)
      ? lastStableLength : 0
  }

  onLengthChanged: {
    if (length > 0) lastStableLength = length
    if (!activePlayer || (!rawTitle && !rawArtist)) return
    if (length > 0 && positionAtIdentityValid && activePlayer.isPlaying) {
      var reported = Number(activePlayer.position)
      var elapsed = Math.max(0, (Date.now() - positionIdentityTimestamp) / 1000)
      var nearEnd = reported >= length - Math.max(5, length * 0.02)
      var expected = positionAtIdentity + elapsed
      if (nearEnd && reported - expected > Math.max(5, elapsed + 2)) {
        positionEndJump = true
        lastStablePosition = Math.max(0, Math.min(expected, length))
      }
    }
    // A duration arriving late is not itself a reason to delay the bar. Only
    // wait again if the current position no longer fits the updated range.
    if (!positionIsPlausible(activePlayer.position)) waitForStablePosition()
  }

  function runAction(action) {
    var player = activePlayer
    if (!player) return false
    if (action === "next" && player.canGoNext) {
      beginTrackTransition()
      player.next()
      return true
    }
    if (action === "previous" && player.canGoPrevious) {
      beginTrackTransition()
      player.previous()
      return true
    }
    if (action === "playPause") {
      if (player.isPlaying && player.canPause) { player.pause(); return true }
      if (!player.isPlaying && player.canPlay) { player.play(); return true }
      if (player.canTogglePlaying) { player.togglePlaying(); return true }
    }
    return false
  }

  function seekTo(seconds) {
    var player = activePlayer
    var target = Number(seconds)
    if (!player || !player.canSeek || !isFinite(target)) return false
    if (positionEndJump) {
      positionEndJump = false
      waitForStablePosition()
    }
    var clamped = Math.max(0, length > 0 ? Math.min(target, length) : target)
    if (Math.abs(clamped - livePosition()) < 0.001) return false

    seekCue = clamped >= livePosition() ? 1 : -1
    seekCueSerial++

    // Apple Music's Chromium media session advertises relative seeking but
    // ignores the requested offset and applies its own ~30-second jump. Its
    // absolute SetPosition path does honor exact seconds, so every input is
    // resolved to one absolute target here.
    pendingSeekPosition = clamped
    pendingSeekTimestamp = Date.now()
    pendingSeekAttempts = 0
    seekAckTimeout.restart()
    player.position = clamped
    return true
  }

  function seekBy(seconds) {
    var delta = Number(seconds)
    if (!isFinite(delta)) return false
    return seekTo(livePosition() + delta)
  }

  property double pendingSeekPosition: -1
  property double pendingSeekTimestamp: 0
  property int pendingSeekAttempts: 0

  function clearPendingSeek() {
    pendingSeekPosition = -1
    pendingSeekTimestamp = 0
    pendingSeekAttempts = 0
    seekAckTimeout.stop()
  }

  onActivePlayerChanged: {
    clearPendingSeek()
    positionEndJump = false
    lastObservedPosition = activePlayer ? Number(activePlayer.position || 0) : -1
    if (length > 0) lastStableLength = length
    if (activePlayer && displayedSource && displayedSource !== selectedSource)
      clearDisplayedMetadata()
    if (activePlayer) displayedSource = selectedSource
    refreshDisplayedMetadata()
    queueSnapshotArt()
  }

  onSelectedSourceChanged: {
    if (displayedSource && displayedSource !== selectedSource) clearDisplayedMetadata()
  }

  Connections {
    target: root.activePlayer
    function onPositionChanged() {
      root.observePositionChange()
      if (root.pendingSeekPosition < 0 || !root.activePlayer) return
      var expected = root.pendingSeekPosition
      if (root.activePlayer.isPlaying)
        expected += (Date.now() - root.pendingSeekTimestamp) / 1000
      var reported = Number(root.activePlayer.position || 0)
      // Several wheel steps can be queued before Chromium replies. Ignore
      // acknowledgements for older intermediate steps and only hand control
      // back to MPRIS when it reaches the most recently requested position.
      if (Math.abs(reported - expected) <= 3) {
        root.lastStablePosition = reported
        root.clearPendingSeek()
      }
    }
    function onIsPlayingChanged() {
      if (!root.activePlayer) return
      if (!root.activePlayer.isPlaying && !root.skipRequested
          && (root.displayedTitle || root.displayedArtist)) {
        root.positionEndJump = false
        if (root.positionIsPlausible(root.lastStablePosition)) {
          root.positionReady = true
          initialPositionReveal.stop()
        }
      }
      if (root.pendingSeekPosition < 0) return
      root.pendingSeekPosition = root.livePosition()
      root.pendingSeekTimestamp = Date.now()
    }
  }

  Timer {
    id: seekAckTimeout
    // Chromium occasionally accepts SetPosition only after its media-session
    // bridge catches up. Retry the same absolute position a few times instead
    // of letting a stale MPRIS position make subsequent rewinds appear stuck.
    interval: 350
    repeat: false
    onTriggered: {
      if (root.pendingSeekPosition < 0 || !root.activePlayer) return

      var expected = root.pendingSeekPosition
      if (root.activePlayer.isPlaying)
        expected += (Date.now() - root.pendingSeekTimestamp) / 1000
      var reported = Number(root.activePlayer.position || 0)
      if (Math.abs(reported - expected) <= 3) {
        root.lastStablePosition = reported
        root.clearPendingSeek()
        return
      }

      if (root.pendingSeekAttempts >= 5) {
        root.clearPendingSeek()
        return
      }
      root.pendingSeekAttempts += 1
      root.activePlayer.position = root.pendingSeekPosition
      restart()
    }
  }

  function livePosition() {
    var stable = isFinite(lastStablePosition) ? Math.max(0, lastStablePosition) : 0
    if (!activePlayer || (!activePlayer.isPlaying && pendingSeekPosition < 0))
      return length > 0 ? Math.min(stable, length) : stable
    // Quickshell's MPRIS wrapper already returns an interpolated live
    // position. Re-interpolating that value here caused the two clocks to
    // drift and made later seek calculations unreliable.
    var value = pendingSeekPosition >= 0
      ? pendingSeekPosition + (activePlayer.isPlaying ? (Date.now() - pendingSeekTimestamp) / 1000 : 0)
      : Number(activePlayer.position || 0)
    if (!isFinite(value) || value < 0
        || (pendingSeekPosition < 0 && !positionIsPlausible(value)))
      return length > 0 ? Math.min(stable, length) : stable
    return length > 0 ? Math.max(0, Math.min(value, length)) : Math.max(0, value)
  }

  IpcHandler {
    enabled: root.manageIpc
    // A generic target like "apple-music" could collide with another
    // installed plugin's IPC handler, so this uses the full, namespaced
    // plugin id instead.
    target: "io.github.leandro-3rne.apple-music"

    function open(): string { root.openWindow(); return "ok" }
    function show(): string { root.focusWindow(); return "ok" }
    function playPause(): string { return root.runAction("playPause") ? "ok" : "unavailable" }
    function next(): string { return root.runAction("next") ? "ok" : "unavailable" }
    function previous(): string { return root.runAction("previous") ? "ok" : "unavailable" }
    function quit(): string { root.quitWindow(); return "ok" }
    function refresh(): string { root.refresh(); return "ok" }
    function ping(): string { return "ok" }

    function status(): string {
      return JSON.stringify({
        windowOpen: root.windowKnownOpen,
        windowVisible: root.windowVisible,
        youtubeAddress: root.youtubeAddress,
        youtubeTargetAddress: root.youtubeTargetAddress,
        youtubeVisible: root.youtubeVisible,
        selectedSource: root.selectedSource,
        lastPlayedSource: root.lastPlayedSource,
        lastYoutubeAddress: root.lastYoutubeAddress,
        windowWorkspace: root.windowWorkspace,
        browserPid: root.browserPid,
        hasMedia: root.hasMedia,
        playing: root.playing,
        title: root.title,
        artist: root.artist,
        album: root.album,
        length: root.length,
        lengthSource: root.activePlayer && Number(root.activePlayer.length || 0) > 0
          && Number(root.activePlayer.length || 0) < 86400 ? "mpris"
          : (root.catalogLength > 0 ? "catalog" : "unknown"),
        // The image itself, not a location, so report only whether one
        // loaded rather than dumping it into every status response.
        artLoaded: root.highResArtUrl !== "",
        lastError: root.lastError
      })
    }
  }
}
