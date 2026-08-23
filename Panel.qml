import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Podcast client for the Omarchy bar: Castro's inbox triage, Overcast's Voice
// Boost, playing through mpv.
//
// The panel owns all state and every process; the four views are dumb
// renderers that call back into here. Feeds, the library and every write to
// disk go through scripts/podcasts.py — see Model.js for why nothing here
// ever touches a shell.
Panel {
  id: root
  moduleName: "bottelet.podcasts"
  ipcTarget: "bottelet.podcasts"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by must be that
  // widget (popout coordinator, switchPanelFrom).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color faint: Qt.rgba(dim.r, dim.g, dim.b, 0.35)
  readonly property string fontName: bar ? bar.fontFamily : Style.font.family

  readonly property string scriptDir: Qt.resolvedUrl("scripts/").toString().replace("file://", "")
  readonly property string socketPath: Model.mpvSocketPath(Quickshell.env("XDG_RUNTIME_DIR"))

  // ------------------------------------------------------------- settings

  readonly property int pollMinutes: Math.max(10, parseInt(setting("pollMinutes", 30), 10) || 30)
  readonly property real defaultSpeed: {
    var value = parseFloat(setting("defaultSpeed", 1.0))
    return value > 0 ? Math.max(0.8, Math.min(3.0, value)) : 1.0
  }
  readonly property bool voiceBoost: {
    var value = setting("voiceBoost", false)
    return value === true || value === "true" || value === 1 || value === "1"
  }
  readonly property string indexKey: String(setting("podcastIndexKey", "") || "")
  readonly property string indexSecret: String(setting("podcastIndexSecret", "") || "")

  // -------------------------------------------------------------- library

  property var inbox: []
  property var queue: []
  property var shows: []
  property var nowEpisode: null
  property var positions: ({})
  property real savedSeconds: 0
  property bool libraryLoaded: false
  property string libraryError: ""
  property string lastChecked: ""
  property bool refreshing: false

  readonly property int inboxCount: inbox.length
  readonly property var staleShows: Model.staleShows(shows)

  // ----------------------------------------------------------------- view

  // inbox | queue | player | shows
  property string view: "inbox"
  property int cursor: 0
  property bool settingsMode: false

  // Shows view drill-down: "" = the subscription grid.
  property string detailShowId: ""
  property var detailEpisodes: []
  readonly property var detailShow: detailShowId ? Model.showById(shows, detailShowId) : null

  property string searchTerm: ""
  property var searchResults: []
  property bool searching: false
  property string searchNote: ""
  property string actionNote: ""

  // Your own shows, narrowed by whatever is in the search box.
  readonly property var matchingShows: Model.filterShows(shows, searchTerm)
  // Directory hits you do not already have. Anything you are subscribed to
  // belongs in the list above, not offered to you again.
  readonly property var newResults: Model.unsubscribedResults(searchResults, shows)

  // A directory search can return 25 hits; showing them all buries your own
  // shows under a wall of near-misses. Five at a time, more on request.
  readonly property int resultPageSize: 5
  property int resultLimit: 5
  readonly property var visibleResults: newResults.slice(0, resultLimit)
  readonly property int hiddenResults: Math.max(0, newResults.length - visibleResults.length)

  function showMoreResults() {
    if (hiddenResults <= 0) return
    resultLimit += resultPageSize
    Qt.callLater(fetchResultArt)
  }

  // Artwork for directory results, cached to disk by the helper. QML never
  // points an Image at a remote URL — see scripts/podcasts.py `art`.
  property var artPaths: ({})

  // What the cursor walks in the current view. In Shows that is whichever
  // lists are on screen, concatenated in the order they are drawn: a show's
  // episodes when drilled in, otherwise your subscriptions followed by the
  // directory results underneath them.
  readonly property var rows: {
    if (view === "inbox") return inbox
    if (view === "queue") return queue
    if (view === "shows") {
      if (detailShowId) return detailEpisodes
      return matchingShows.concat(visibleResults)
    }
    return []
  }

  // Directory rows carry no show id — they are not in the library yet.
  function isDirectoryRow(row) {
    return !!row && row.id === undefined
  }

  readonly property bool cursorIsDirectory: view === "shows"
    && detailShowId === "" && isDirectoryRow(cursorRow())

  // --------------------------------------------------------------- player

  property bool playerStarted: false
  property bool socketReady: false
  property string currentId: ""
  property var currentEpisode: null
  property bool playing: false
  property real timePos: 0
  property real duration: 0
  property real playSpeed: 1.0
  property bool boostOn: false
  property var chapters: []
  property string playerError: ""
  // Set while a loadfile is in flight so time-pos updates from the outgoing
  // track cannot be written to the incoming episode's saved position.
  property bool loadPending: false
  property real resumeAt: 0

  readonly property real playProgress: duration > 0 ? Math.max(0, Math.min(1, timePos / duration)) : 0
  readonly property int chapterIndex: Model.chapterAt(chapters, timePos)

  signal libraryChanged()

  // -------------------------------------------------------------- helpers

  function currentShow() {
    return currentEpisode ? Model.showById(shows, currentEpisode.showId) : null
  }

  function episodeById(id) {
    var found = Model.findEpisode(queue, id) || Model.findEpisode(inbox, id)
    if (found) return found
    return Model.findEpisode(detailEpisodes, id)
  }

  function note(text) {
    actionNote = String(text || "")
    noteTimer.restart()
  }

  function setView(next) {
    // Asking for a view is also a way out of the settings page — otherwise
    // 1-4 look broken while ⚙ is open.
    settingsMode = false
    if (view === next) return
    view = next
    cursor = 0
    if (next !== "shows") searchResults = []
  }

  // ------------------------------------------------------------ processes

  // One generic worker for every state mutation. Commands are argv arrays
  // built in Model.js; the reply is always a single JSON object.
  Process {
    id: actionProc
    property var pending: []
    property string tag: ""

    function enqueue(command, newTag) {
      pending.push({ command: command, tag: newTag || "" })
      pump()
    }

    function pump() {
      if (running || pending.length === 0) return
      var next = pending.shift()
      tag = next.tag
      command = next.command
      running = true
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        root.onActionResult(actionProc.tag, reply)
      }
    }
    onExited: Qt.callLater(actionProc.pump)
  }

  function onActionResult(tag, reply) {
    if (!reply.ok) {
      if (tag === "add") {
        searchNote = reply.error || "could not add that feed"
        searching = false
      } else {
        note(reply.error || "that did not work")
      }
      return
    }
    if (tag === "add") {
      searching = false
      var title = reply.show ? reply.show.title : "that show"
      if (reply.note === "already subscribed") {
        searchNote = "already subscribed to " + title
      } else {
        searchNote = ""
        note("subscribed to " + title)
      }
      // Subscribing from a search result leaves the search alone on purpose:
      // the row migrates out of "not subscribed" and up into your own shows,
      // which is the clearest possible receipt that the click landed. A
      // pasted URL has no such list to move within, and leaving the URL in
      // the box would filter every show out — so that one clears.
      if (addedFromUrl) {
        searchResults = []
        lastSearched = ""
        showsView.clearSearch()
      }
      cursor = 0
    } else if (tag === "opml-import") {
      note("imported " + reply.added + " show" + (reply.added === 1 ? "" : "s")
           + (reply.skipped ? " · " + reply.skipped + " already there" : "")
           + (reply.failedCount ? " · " + reply.failedCount + " failed" : ""))
    } else if (tag === "opml-export") {
      note("exported " + reply.count + " subscriptions to " + reply.path)
    } else if (tag === "archive-all") {
      note("archived " + reply.archived)
    }
    reloadLibrary()
    if (detailShowId) loadDetail(detailShowId)
  }

  Timer {
    id: noteTimer
    interval: 6000
    onTriggered: root.actionNote = ""
  }

  Process {
    id: libraryProc
    command: Model.libraryCommand(root.scriptDir)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        if (!reply.ok) {
          root.libraryError = reply.error || "library unavailable"
          return
        }
        root.libraryError = ""
        root.inbox = reply.inbox || []
        root.queue = reply.queue || []
        root.shows = reply.shows || []
        root.positions = reply.positions || {}
        root.savedSeconds = reply.savedSeconds || 0
        root.libraryLoaded = true
        if (!root.currentEpisode && reply.now) root.adoptEpisode(reply.now)
        root.clampCursor()
        root.libraryChanged()
      }
    }
  }

  Process {
    id: refreshProc
    command: Model.refreshCommand(root.scriptDir, "", false)
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.refreshing = false
        root.lastChecked = Qt.formatTime(new Date(), "HH:mm")
        var reply = Model.parseJson(text)
        if (reply.ok) root.raiseNotifications(reply.notify || [])
        root.reloadLibrary()
      }
    }
  }

  Process {
    id: searchProc
    // The Podcast Index key and secret go down stdin as two lines. Nothing
    // assigns to stdinEnabled: writing to it from onStarted would overwrite
    // this binding, and every later search would find it false, write
    // nothing, and leave the helper waiting on a pipe that never closes.
    // The helper reads a line at a time, so no close is needed.
    stdinEnabled: root.indexKey !== "" && root.indexSecret !== ""
    onStarted: {
      if (stdinEnabled) write(root.indexKey + "\n" + root.indexSecret + "\n")
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.searching = false
        var reply = Model.parseJson(text)
        if (!reply.ok) {
          root.searchNote = reply.error || "search failed"
          root.searchResults = []
          return
        }
        root.searchResults = reply.results || []
        root.searchNote = reply.results && reply.results.length === 0
          ? "nothing found — try the show's RSS URL"
          : (reply.note || "")
        root.fetchResultArt()
      }
    }
  }

  Process {
    id: detailProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        if (reply.ok) root.detailEpisodes = reply.episodes || []
        else root.detailEpisodes = []
        root.clampCursor()
      }
    }
  }

  Process {
    id: chaptersProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        root.chapters = reply.ok ? (reply.chapters || []) : []
      }
    }
  }

  // Fire-and-forget: notifications and the 5-second position writes must
  // never queue behind a feed refresh.
  Process { id: notifyProc }
  Process { id: positionProc }

  function raiseNotifications(list) {
    // Desktop notifications are for auto-queue shows only; a plain inbox
    // arrival is what the bar badge is for.
    for (var i = 0; i < list.length && i < 5; i++) {
      var item = list[i]
      if (notifyProc.running) break
      notifyProc.command = Model.notifyCommand(root.scriptDir,
        item.show || "New episode", item.title || "", item.art || "")
      notifyProc.running = true
    }
  }

  function reloadLibrary() {
    if (!libraryProc.running) libraryProc.running = true
  }

  function refreshAll() {
    if (refreshProc.running) return
    refreshing = true
    refreshProc.command = Model.refreshCommand(root.scriptDir, "", false)
    refreshProc.running = true
  }

  function refreshShow(showId) {
    if (refreshProc.running) return
    refreshing = true
    refreshProc.command = Model.refreshCommand(root.scriptDir, showId, true)
    refreshProc.running = true
  }

  function loadDetail(showId) {
    detailShowId = showId
    detailEpisodes = []
    cursor = 0
    if (detailProc.running) return
    detailProc.command = Model.episodesCommand(root.scriptDir, showId)
    detailProc.running = true
  }

  // Enter in the search box. A pasted feed URL subscribes; anything else is
  // a directory search, run now rather than waiting out the debounce.
  function runSearch(term) {
    var text = String(term || "").replace(/^\s+|\s+$/g, "")
    searchDebounce.stop()
    searchNote = ""
    if (text === "") {
      searchResults = []
      lastSearched = ""
      return
    }
    if (Model.looksLikeUrl(text)) {
      searching = true
      addedFromUrl = true
      actionProc.enqueue(Model.addCommand(root.scriptDir, text, false), "add")
      return
    }
    searchDirectory(text, true)
  }

  // The last term actually sent to the directory, so a re-focus or a stray
  // property write does not re-fetch the same thing.
  property string lastSearched: ""

  function searchDirectory(term, force) {
    var text = String(term || "").replace(/^\s+|\s+$/g, "")
    if (text.length < minSearchChars) return
    if (!force && text === lastSearched) return
    if (searchProc.running) {
      // One search at a time; come back for this term in a moment.
      searchDebounce.restart()
      return
    }
    lastSearched = text
    searching = true
    resultLimit = resultPageSize
    searchProc.command = Model.searchCommand(root.scriptDir, text, root.indexKey, root.indexSecret)
    searchProc.running = true
  }

  // One batched call per page of results, and only for artwork not already
  // on disk.
  function fetchResultArt() {
    if (artProc.running) return
    var wanted = []
    for (var i = 0; i < visibleResults.length; i++) {
      var url = visibleResults[i].artwork
      if (url && !artPaths[url] && wanted.indexOf(url) === -1) wanted.push(url)
    }
    if (wanted.length === 0) return
    artProc.command = Model.artCommand(root.scriptDir, wanted)
    artProc.running = true
  }

  Process {
    id: artProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var reply = Model.parseJson(text)
        if (!reply.ok || !reply.paths) return
        var next = {}
        for (var known in root.artPaths) next[known] = root.artPaths[known]
        for (var url in reply.paths) next[url] = reply.paths[url]
        root.artPaths = next
        // A page can need more than one round when the batch cap trims it.
        Qt.callLater(root.fetchResultArt)
      }
    }
  }

  // Two characters is where a directory search stops returning noise, and
  // 400 ms is long enough that a typed word costs one request, not eight.
  readonly property int minSearchChars: 2

  Timer {
    id: searchDebounce
    interval: 400
    onTriggered: root.searchDirectory(root.searchTerm, false)
  }

  // Typing searches. A URL is left alone until Enter — nobody wants a
  // half-pasted address subscribing them to whatever it resolves to.
  onSearchTermChanged: {
    var text = String(searchTerm || "").replace(/^\s+|\s+$/g, "")
    if (text === "") {
      searchDebounce.stop()
      searchResults = []
      searchNote = ""
      lastSearched = ""
      searching = false
      resultLimit = resultPageSize
      return
    }
    if (Model.looksLikeUrl(text)) {
      searchDebounce.stop()
      return
    }
    searchDebounce.restart()
  }

  // Whether the add in flight came from a pasted URL rather than a directory
  // result — the two want different things to happen to the search box.
  property bool addedFromUrl: false

  function subscribe(feedUrl) {
    searching = true
    searchNote = ""
    addedFromUrl = false
    actionProc.enqueue(Model.addCommand(root.scriptDir, feedUrl, false), "add")
  }

  function unsubscribe(showId) {
    if (detailShowId === showId) detailShowId = ""
    actionProc.enqueue(Model.removeCommand(root.scriptDir, showId), "remove")
  }

  function cycleShowMode(show) {
    if (!show) return
    var next = Model.nextMode(show.mode)
    actionProc.enqueue(Model.showSetCommand(root.scriptDir, show.id, "mode", next), "mode")
    note(show.title + " → " + Model.modeLabel(next).toLowerCase())
  }

  function setShowMode(show, mode) {
    if (!show || show.mode === mode) return
    actionProc.enqueue(Model.showSetCommand(root.scriptDir, show.id, "mode", mode), "mode")
  }

  function setShowSpeed(show, speed) {
    if (!show) return
    actionProc.enqueue(Model.showSetCommand(root.scriptDir, show.id, "speed", speed), "speed")
  }

  function stepShowSpeed(show, delta) {
    if (!show) return
    var current = show.speed > 0 ? show.speed : root.defaultSpeed
    setShowSpeed(show, Math.max(0.8, Math.min(3.0, Math.round((current + delta) * 10) / 10)))
  }

  // ----------------------------------------------------------------- opml

  // The desktop file chooser Omarchy already ships, so the portal handles the
  // dialog and we only ever see a path — which travels to the helper as an
  // argv element, never through a shell.
  Process {
    id: pickerProc
    property string mode: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").replace(/^\s+|\s+$/g, "").split("\n")[0]
        if (path === "") {
          root.note("nothing chosen")
          return
        }
        if (pickerProc.mode === "import")
          actionProc.enqueue(Model.opmlImportCommand(root.scriptDir, path), "opml-import")
        else
          actionProc.enqueue(Model.opmlExportCommand(root.scriptDir,
            path.replace(/\/+$/, "") + "/omarchy-podcasts.opml"), "opml-export")
      }
    }
  }

  function importOpml() {
    if (pickerProc.running) return
    pickerProc.mode = "import"
    pickerProc.command = ["omarchy-file-select", "--title", "Import podcast subscriptions",
                          "--extensions", "opml xml"]
    pickerProc.running = true
  }

  function exportOpml() {
    if (pickerProc.running) return
    if (shows.length === 0) {
      note("nothing to export yet")
      return
    }
    pickerProc.mode = "export"
    pickerProc.command = ["omarchy-file-select", "--title", "Export subscriptions to…",
                          "--directory"]
    pickerProc.running = true
  }

  // --------------------------------------------------------------- triage

  function enqueueEpisode(episode, front) {
    if (!episode) return
    actionProc.enqueue(Model.queueCommand(root.scriptDir, "add", episode.id,
      { front: front === true }), "queue")
  }

  function archiveEpisode(episode) {
    if (!episode) return
    actionProc.enqueue(Model.triageCommand(root.scriptDir, "archive", episode.id), "archive")
  }

  function unarchiveEpisode(episode) {
    if (!episode) return
    actionProc.enqueue(Model.triageCommand(root.scriptDir, "unarchive", episode.id), "unarchive")
  }

  function archiveAll() {
    if (inbox.length === 0) return
    actionProc.enqueue(Model.archiveAllCommand(root.scriptDir), "archive-all")
  }

  function removeFromQueue(episode) {
    if (!episode) return
    actionProc.enqueue(Model.queueCommand(root.scriptDir, "remove", episode.id), "queue")
  }

  function moveInQueue(episode, delta) {
    if (!episode) return
    actionProc.enqueue(Model.queueCommand(root.scriptDir, "move", episode.id,
      { delta: delta }), "queue")
  }

  function clearQueue() {
    actionProc.enqueue(Model.queueCommand(root.scriptDir, "clear", "", {}), "queue")
  }

  // ----------------------------------------------------------------- mpv

  Process {
    id: mpvProc
    command: Model.mpvCommand(root.socketPath)
    onExited: {
      root.playerStarted = false
      root.socketReady = false
      root.playing = false
      mpvSock.connected = false
      if (root.currentId !== "") root.playerError = "mpv stopped"
    }
  }

  Socket {
    id: mpvSock
    path: root.socketPath

    onConnectionStateChanged: {
      if (connected) {
        root.socketReady = true
        root.playerError = ""
        socketRetry.stop()
        root.primePlayer()
      } else {
        root.socketReady = false
      }
    }

    onError: function(err) {
      // mpv creates the socket a beat after it starts; keep knocking.
      if (root.playerStarted && !socketRetry.running) socketRetry.start()
    }

    parser: SplitParser {
      splitMarker: "\n"
      onRead: function(line) { root.handleIpc(line) }
    }
  }

  Timer {
    id: socketRetry
    // mpv creates its IPC socket a beat after exec, so the first connect
    // loses the race with ServerNotFoundError. Keep knocking until it
    // answers, then the connection handler stops us.
    interval: 300
    repeat: true
    onTriggered: {
      if (mpvSock.connected || !root.playerStarted) { stop(); return }
      // A QLocalSocket that failed to connect keeps its requested state, so
      // re-assigning `true` is a no-op — the property has to transition
      // false → true (on separate event-loop turns) to try again.
      mpvSock.connected = false
      Qt.callLater(root.knockSocket)
    }
  }

  function knockSocket() {
    if (root.playerStarted && !mpvSock.connected) mpvSock.connected = true
  }

  readonly property bool playerAvailable: socketPath !== ""

  function ensurePlayer() {
    if (!playerAvailable) {
      playerError = "no XDG_RUNTIME_DIR, so there is nowhere safe to put the player's control socket"
      return false
    }
    playerStarted = true
    if (!mpvProc.running) mpvProc.running = true
    if (!mpvSock.connected && !socketRetry.running) socketRetry.restart()
    return true
  }

  function send(payload) {
    if (!mpvSock.connected) return
    mpvSock.write(payload)
    mpvSock.flush()
  }

  // Observers are re-armed on every (re)connect, so a restarted mpv still
  // reports back without the panel having to be reopened.
  function primePlayer() {
    send(Model.observe("time-pos", 1))
    send(Model.observe("duration", 2))
    send(Model.observe("pause", 3))
    send(Model.observe("speed", 4))
    send(Model.observe("eof-reached", 5))
    applyVoiceBoost()
    if (pendingUrl !== "") {
      var url = pendingUrl
      pendingUrl = ""
      sendLoad(url)
    }
  }

  property string pendingUrl: ""

  function sendLoad(url) {
    loadPending = true
    send(Model.ipc(["loadfile", url, "replace"]))
  }

  // Enclosure URLs are attacker-controlled: they reach mpv as a JSON string
  // over the IPC socket, never as an argv element and never through a shell.
  function playEpisode(episode, options) {
    if (!episode || !episode.url) return
    var opts = options || {}

    // Before anything is mutated: with no runtime dir there is no player,
    // and a half-applied state would leave a row rendering as current and
    // the next savePosition writing an episode that never played as "now".
    if (!ensurePlayer()) return

    if (currentId !== "" && currentId !== episode.id) savePosition(false)

    currentId = episode.id
    currentEpisode = episode
    chapters = []
    duration = episode.duration || 0
    var saved = positions[episode.id]
    resumeAt = opts.restart ? 0 : (saved ? saved.pos : (episode.pos || 0))
    // Never resume into the last few seconds — that is a finished episode.
    if (duration > 0 && resumeAt > duration - 10) resumeAt = 0
    timePos = resumeAt
    playing = true
    playerError = ""

    if (mpvSock.connected) sendLoad(episode.url)
    else pendingUrl = episode.url

    if (episode.chapters) {
      if (!chaptersProc.running) {
        chaptersProc.command = Model.chaptersCommand(root.scriptDir, episode.chapters)
        chaptersProc.running = true
      }
    }

    positionProc.command = Model.positionCommand(root.scriptDir, episode.id,
      resumeAt, duration, { now: true })
    if (!positionProc.running) positionProc.running = true

    if (!opts.keepView) setView("player")
  }

  // Reconstructs the player row from the library's `now` record after a
  // shell restart, without starting playback.
  function adoptEpisode(episode) {
    if (!episode) return
    currentId = episode.id
    currentEpisode = episode
    duration = episode.duration || 0
    timePos = episode.pos || 0
    playing = false
    // Show the speed this episode *will* play at, not mpv's idle 1.0× —
    // after a shell restart there is no mpv to report one yet.
    playSpeed = Model.speedFor(Model.showById(shows, episode.showId), defaultSpeed)
  }

  function togglePlay() {
    if (currentId === "") {
      playNextFromQueue()
      return
    }
    if (!mpvProc.running) {
      // Resuming after a shell restart: reload the episode where we left it.
      playEpisode(currentEpisode, { keepView: true })
      return
    }
    send(Model.ipc(["cycle", "pause"]))
  }

  function playNextFromQueue() {
    if (queue.length === 0) {
      note("queue is empty")
      return
    }
    playEpisode(queue[0], {})
  }

  function seekBy(delta) {
    if (currentId === "") return
    var target = Math.max(0, timePos + delta)
    if (duration > 0) target = Math.min(duration - 1, target)
    timePos = target
    send(Model.ipc(["seek", delta, "relative"]))
  }

  function seekTo(seconds) {
    if (currentId === "") return
    var target = Math.max(0, seconds)
    if (duration > 0) target = Math.min(duration - 1, target)
    timePos = target
    send(Model.ipc(["seek", target, "absolute"]))
  }

  function stepSpeed(delta) {
    var next = Math.max(0.8, Math.min(3.0, Math.round((playSpeed + delta) * 10) / 10))
    setSpeed(next)
    var show = currentShow()
    if (show) setShowSpeed(show, next)
  }

  function setSpeed(value) {
    playSpeed = value
    send(Model.ipc(["set_property", "speed", value]))
  }

  function applyVoiceBoost() {
    boostOn = voiceBoost
    send(voiceBoost ? Model.voiceBoostOn() : Model.voiceBoostOff())
  }

  onVoiceBoostChanged: if (socketReady) applyVoiceBoost()

  function stopPlayback() {
    if (currentId === "") return
    savePosition(false)
    send(Model.ipc(["stop"]))
    playing = false
  }

  function handleIpc(line) {
    var message = Model.parseIpcLine(line)
    if (!message) return

    if (message.event === "property-change") {
      if (message.name === "time-pos" && typeof message.data === "number") {
        if (!loadPending) timePos = message.data
      } else if (message.name === "duration" && typeof message.data === "number") {
        if (message.data > 0) duration = message.data
      } else if (message.name === "pause") {
        playing = message.data === false
      } else if (message.name === "speed" && typeof message.data === "number") {
        playSpeed = message.data
      }
      return
    }

    if (message.event === "file-loaded") {
      loadPending = false
      var show = currentShow()
      setSpeed(Model.speedFor(show, root.defaultSpeed))
      applyVoiceBoost()
      if (resumeAt > 1) send(Model.ipc(["seek", resumeAt, "absolute"]))
      send(Model.ipc(["set_property", "pause", false]))
      return
    }

    if (message.event === "end-file") {
      loadPending = false
      if (message.reason === "eof") finishEpisode()
      else if (message.reason === "error") {
        playing = false
        playerError = "could not play that episode"
      }
      return
    }
  }

  // ---------------------------------------------------------- positions

  function savePosition(played) {
    if (currentId === "") return
    positionProc.command = Model.positionCommand(root.scriptDir, currentId,
      played ? 0 : timePos, duration, { played: played === true, now: true })
    if (!positionProc.running) positionProc.running = true
  }

  function finishEpisode() {
    var finished = currentId
    savePosition(true)
    playing = false
    timePos = 0
    // Auto-advance: the next queue item that is not the one just finished.
    var next = null
    for (var i = 0; i < queue.length; i++) {
      if (queue[i].id !== finished) { next = queue[i]; break }
    }
    currentId = ""
    currentEpisode = null
    if (next) playEpisode(next, { keepView: true })
    else reloadLibrary()
  }

  Timer {
    // Position is persisted while playing and again on pause/stop, so a
    // shell restart never costs more than five seconds of listening.
    interval: 5000
    repeat: true
    running: root.playing && root.currentId !== "" && !root.loadPending
    onTriggered: root.savePosition(false)
  }

  onPlayingChanged: if (!playing && currentId !== "") savePosition(false)

  // ---------------------------------------------------------------- poll

  Timer {
    id: pollTimer
    // Jittered so a machine with several feed-polling widgets does not wake
    // them all in the same second.
    interval: root.pollMinutes * 60 * 1000 + Math.floor(Math.random() * 60000)
    running: true
    repeat: true
    onTriggered: root.refreshAll()
  }

  Component.onCompleted: {
    reloadLibrary()
    Qt.callLater(refreshAll)
  }

  Component.onDestruction: {
    if (mpvProc.running) mpvProc.running = false
  }

  // ------------------------------------------------------------- cursor

  function clampCursor() {
    var count = rows.length
    if (count === 0) cursor = 0
    else if (cursor >= count) cursor = count - 1
    else if (cursor < 0) cursor = 0
  }

  function moveCursor(delta) {
    var count = rows.length
    if (count === 0) return
    // Walking off the end of the results is how you ask for more of them.
    if (delta > 0 && cursor === count - 1 && hiddenResults > 0
        && view === "shows" && detailShowId === "") {
      showMoreResults()
    }
    cursor = Math.max(0, Math.min(rows.length - 1, cursor + delta))
  }

  function cursorRow() {
    return cursor >= 0 && cursor < rows.length ? rows[cursor] : null
  }

  // Enter: the primary action for the view the user is in.
  function activateCursor() {
    var row = cursorRow()
    if (!row) return
    if (view === "inbox") {
      enqueueEpisode(row, false)
      note("queued · " + row.title)
    } else if (view === "queue") {
      playEpisode(row, {})
    } else if (view === "shows") {
      if (detailShowId) enqueueEpisode(row, false)
      else if (isDirectoryRow(row)) subscribe(row.feed)
      else loadDetail(row.id)
    }
  }

  // Space: play right now, wherever you are.
  function previewCursor() {
    if (view === "player" || rows.length === 0) {
      togglePlay()
      return
    }
    var row = cursorRow()
    if (!row) return
    if (view === "shows" && !detailShowId) {
      if (isDirectoryRow(row)) subscribe(row.feed)
      else loadDetail(row.id)
      return
    }
    playEpisode(row, {})
  }

  function deleteCursor() {
    var row = cursorRow()
    if (!row) return
    if (view === "inbox") archiveEpisode(row)
    else if (view === "queue") removeFromQueue(row)
    else if (view === "shows" && detailShowId) archiveEpisode(row)
    else if (isDirectoryRow(row)) { searchResults = []; cursor = 0 }
    else if (view === "shows" && row.id) unsubscribe(row.id)
  }

  function reorderCursor(direction) {
    if (view !== "queue") return
    var row = cursorRow()
    if (!row) return
    moveInQueue(row, direction)
    cursor = Math.max(0, Math.min(queue.length - 1, cursor + direction))
  }

  function handleTextKey(key) {
    var row = cursorRow()
    switch (key) {
    case "a":
      if (view === "inbox" || (view === "shows" && detailShowId)) archiveEpisode(row)
      break
    case "A":
      if (view === "inbox") archiveAll()
      break
    case "p":
      if (row && view !== "player") playEpisode(row, {})
      else togglePlay()
      break
    case "q":
      if (row && view !== "player" && view !== "queue") enqueueEpisode(row, false)
      break
    case "Q":
      if (row) enqueueEpisode(row, true)
      break
    case "r":
      refreshAll()
      break
    case "s":
      settingsMode = !settingsMode
      break
    case "b":
      setVoiceBoost(!voiceBoost)
      break
    case "-":
      stepSpeed(-0.1)
      break
    case "+":
    case "=":
      stepSpeed(0.1)
      break
    case ",":
      seekBy(-15)
      break
    case ".":
      seekBy(30)
      break
    case "/":
      if (view === "shows") showsView.focusSearch()
      break
    case "u":
      if (view === "shows" && detailShowId) unarchiveEpisode(row)
      break
    }
  }

  function handleDigit(digit) {
    if (digit === 1) setView("inbox")
    else if (digit === 2) setView("queue")
    else if (digit === 3) setView("player")
    else if (digit === 4) setView("shows")
  }

  // ------------------------------------------------------------ settings

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value (same
  // pattern as the built-in clock panel).
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setVoiceBoost(value) {
    persistSettings({ voiceBoost: value === true })
  }

  function setDefaultSpeed(value) {
    persistSettings({ defaultSpeed: Math.max(0.8, Math.min(3.0, Math.round(value * 10) / 10)) })
  }

  function setPollMinutes(value) {
    persistSettings({ pollMinutes: Math.max(10, Math.min(720, Math.round(value))) })
  }

  // ---------------------------------------------------------- panel shape

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    onOpened()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    onOpened()
    // Deferred for the same popout-handoff reason as the weather panel.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function onOpened() {
    // The badge is the notification, so opening the panel lands wherever the
    // user's attention is owed: inbox when it has anything, else the player.
    if (inbox.length > 0) setView("inbox")
    else if (currentId !== "") setView("player")
    else if (queue.length > 0) setView("queue")
    else setView("shows")
    reloadLibrary()
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    settingsMode = false
    root.controller.hide()
  }

  function openSettings() {
    openFromHotkey()
    settingsMode = true
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll() }
    function settings(): void { root.openSettings() }
    function play(): void { root.togglePlay() }
    function pause(): void { root.togglePlay() }
    function next(): void { root.finishEpisode() }
    function forward(): void { root.seekBy(30) }
    function back(): void { root.seekBy(-15) }
  }

  // ------------------------------------------------------------------ ui

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(podcastColumn.implicitHeight)

    KeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: showsView.searchActive
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0 && root.view === "player") root.seekBy(dx > 0 ? 30 : -15)
        else if (dx < 0 && root.view === "shows" && root.detailShowId) root.detailShowId = ""
      }
      onReorderRequested: function(direction) { root.reorderCursor(direction) }
      onReturnRequested: root.activateCursor()
      onActivateRequested: root.previewCursor()
      onDeleteRequested: root.deleteCursor()
      onTextKey: function(text) { root.handleTextKey(text) }
      onDigitKey: function(digit) { root.handleDigit(digit) }

      Flickable {
        id: podcastScroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: podcastColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: podcastColumn
          width: podcastScroll.width
          spacing: Style.space(10)

          // ---- Header: brand left, last-poll + refresh + gear right.
          Item {
            width: parent.width
            height: Math.max(headerLeft.implicitHeight, headerRight.implicitHeight)

            Row {
              id: headerLeft
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                text: ""
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.heading
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                text: "PODCASTS"
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              id: headerRight
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                visible: root.lastChecked !== ""
                text: root.refreshing ? "checking…" : root.lastChecked
                color: root.dim
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              PanelActionButton {
                iconText: ""
                foreground: root.dim
                hoverColor: Color.accent
                fontFamily: root.fontName
                fontSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.refreshAll()
              }

              PanelActionButton {
                iconText: ""
                foreground: root.settingsMode ? Color.accent : root.dim
                hoverColor: Color.accent
                fontFamily: root.fontName
                fontSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.settingsMode = !root.settingsMode
              }
            }
          }

          // ---- View tabs.
          Row {
            visible: !root.settingsMode
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: [
                { key: "inbox", label: "Inbox", icon: "" },
                { key: "queue", label: "Queue", icon: "" },
                { key: "player", label: "Player", icon: "" },
                { key: "shows", label: "Shows", icon: "" }
              ]

              Rectangle {
                id: tab
                required property var modelData

                readonly property bool selected: root.view === modelData.key
                readonly property int badge: modelData.key === "inbox"
                  ? root.inboxCount
                  : (modelData.key === "queue" ? root.queue.length : 0)

                width: tabRow.implicitWidth + Style.space(18)
                height: tabRow.implicitHeight + Style.space(10)
                radius: Style.cornerRadius
                color: selected || tabArea.containsMouse
                  ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"
                border.width: 1
                border.color: selected
                  ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.9)
                  : root.faint

                Row {
                  id: tabRow
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Text {
                    text: tab.modelData.icon
                    color: tab.selected ? Style.hoverStateColor(root.fg, Color.accent) : root.dim
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: tab.modelData.label
                    color: tab.selected ? Style.hoverStateColor(root.fg, Color.accent) : root.fg
                    font.family: root.fontName
                    font.pixelSize: Style.font.bodySmall
                    font.bold: tab.selected
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Rectangle {
                    visible: tab.badge > 0
                    width: Math.max(height, tabBadge.implicitWidth + Style.space(6))
                    height: Style.space(13)
                    radius: height / 2
                    color: Color.accent
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: tabBadge
                      anchors.centerIn: parent
                      text: tab.badge > 99 ? "99+" : tab.badge
                      textFormat: Text.PlainText
                      color: Color.background
                      font.family: root.fontName
                      font.pixelSize: Math.max(8, Style.font.caption - 2)
                      font.bold: true
                    }
                  }
                }

                MouseArea {
                  id: tabArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setView(tab.modelData.key)
                }
              }
            }
          }

          // ---- Transient feedback (triage confirmations, import results).
          Text {
            textFormat: Text.PlainText
            visible: root.actionNote !== ""
            width: parent.width
            text: root.actionNote
            color: Color.accent
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Text {
            textFormat: Text.PlainText
            visible: root.libraryError !== "" || root.playerError !== ""
            width: parent.width
            text: "⚠ " + (root.libraryError !== "" ? root.libraryError : root.playerError)
            color: Color.urgent
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---- Stale-feed notice: a feed that keeps failing says so once,
          // in one line, instead of spamming the timeline.
          Text {
            textFormat: Text.PlainText
            visible: !root.settingsMode && root.staleShows.length > 0
            width: parent.width
            text: {
              var names = []
              for (var i = 0; i < root.staleShows.length && i < 3; i++)
                names.push(root.staleShows[i].title || root.staleShows[i].feed)
              var extra = root.staleShows.length - names.length
              return "⚠ not updating: " + names.join(", ") + (extra > 0 ? " +" + extra : "")
            }
            color: root.dim
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          InboxView {
            visible: !root.settingsMode && root.view === "inbox"
            width: parent.width
            panel: root
          }

          QueueView {
            visible: !root.settingsMode && root.view === "queue"
            width: parent.width
            panel: root
          }

          PlayerView {
            visible: !root.settingsMode && root.view === "player"
            width: parent.width
            panel: root
          }

          ShowsView {
            id: showsView
            visible: !root.settingsMode && root.view === "shows"
            width: parent.width
            panel: root
            onSearchDismissed: keyCatcher.forceActiveFocus()
            onSearchSubmitted: keyCatcher.forceActiveFocus()
          }

          SettingsView {
            visible: root.settingsMode
            width: parent.width
            panel: root
          }

          // ---- Keyboard legend, per view.
          Text {
            textFormat: Text.PlainText
            visible: !root.settingsMode
            width: parent.width
            topPadding: Style.space(4)
            text: {
              if (root.view === "inbox")
                return "enter queue · space play · a archive · A archive all · x archive · 1-4 views"
              if (root.view === "queue")
                return "enter play · shift+↑↓ reorder · x remove · 1-4 views"
              if (root.view === "player")
                return "space play/pause · ←/→ skip · -/+ speed · b voice boost · 1-4 views"
              if (root.detailShowId)
                return "enter queue · space play · a archive · ← back · 1-4 views"
              return root.cursorIsDirectory
                ? "enter subscribe · x dismiss results · / search again · 1-4 views"
                : "/ search · enter open · x unsubscribe · 1-4 views"
            }
            color: root.dim
            font.family: root.fontName
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
