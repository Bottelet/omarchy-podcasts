// Command building, response parsing and formatting for the podcast panel.
//
// Every network access, every feed parse and every write to the library goes
// through scripts/podcasts.py, which returns exactly one JSON object per call
// — QML only ever parses small, pre-trimmed JSON and renders it PlainText.
//
// All commands are plain argv arrays: no `sh -c` anywhere, so no feed-derived
// string (enclosure URL, episode title, chapter URL) is ever handed to a
// shell. mpv likewise receives URLs over its JSON IPC socket, never on a
// command line.

// ---------------------------------------------------------------- commands

function helper(scriptDir) {
  return ["python3", scriptDir + "podcasts.py"]
}

// `subcommand`, then any flags, then a literal `--`, then the positionals.
// The terminator matters: a search term or a feed URL beginning with a dash
// would otherwise be parsed as an option and the helper would answer with a
// usage message instead of JSON.
function cmd(scriptDir, subcommand, flags, positionals) {
  var argv = helper(scriptDir).concat([subcommand]).concat(flags || [])
  var values = (positionals || []).map(String)
  // Only when there is something to separate: argparse rejects a bare `--`
  // on a subcommand that declares no positionals, which is every read-only
  // one here (library, shows, refresh, archive-all).
  if (values.length > 0) argv = argv.concat(["--"]).concat(values)
  return argv
}

function initCommand(scriptDir) {
  return cmd(scriptDir, "init", [], [])
}

function libraryCommand(scriptDir) {
  return cmd(scriptDir, "library", [], [])
}

function showsCommand(scriptDir) {
  return cmd(scriptDir, "shows", [], [])
}

function episodesCommand(scriptDir, showId) {
  return cmd(scriptDir, "episodes", [], [showId])
}

// Credentials are written to the helper's stdin, never passed as arguments:
// /proc/<pid>/cmdline is world-readable, so an argv secret is legible to
// every other account on the machine. See searchProc in Panel.qml.
function searchCommand(scriptDir, term, key, secret) {
  var flags = key && secret ? ["--auth-stdin"] : []
  return cmd(scriptDir, "search", flags, [term])
}

function addCommand(scriptDir, feedUrl, allowHttp) {
  return cmd(scriptDir, "add", allowHttp ? ["--allow-http"] : [], [feedUrl])
}

function removeCommand(scriptDir, showId) {
  return cmd(scriptDir, "remove", [], [showId])
}

function refreshCommand(scriptDir, showId, force) {
  var flags = []
  if (showId) flags = flags.concat(["--show", String(showId)])
  if (force) flags.push("--force")
  return cmd(scriptDir, "refresh", flags, [])
}

function triageCommand(scriptDir, action, episodeId) {
  return cmd(scriptDir, "triage", [], [action, episodeId])
}

function archiveAllCommand(scriptDir) {
  return cmd(scriptDir, "archive-all", [], [])
}

function queueCommand(scriptDir, action, episodeId, options) {
  var flags = []
  if (options && options.front) flags.push("--front")
  if (options && options.delta !== undefined) flags = flags.concat(["--delta", String(options.delta)])
  var positionals = episodeId ? [action, episodeId] : [action]
  return cmd(scriptDir, "queue", flags, positionals)
}

function positionCommand(scriptDir, episodeId, pos, dur, options) {
  var flags = []
  if (options && options.played) flags.push("--played")
  if (options && options.now) flags.push("--now")
  return cmd(scriptDir, "position", flags, [
    episodeId,
    Math.max(0, Math.round(pos || 0)),
    Math.max(0, Math.round(dur || 0))
  ])
}

function showSetCommand(scriptDir, showId, key, value) {
  return cmd(scriptDir, "show-set", [], [showId, key, value])
}

function opmlImportCommand(scriptDir, path) {
  return cmd(scriptDir, "opml-import", [], [path])
}

function opmlExportCommand(scriptDir, path) {
  return cmd(scriptDir, "opml-export", [], [path])
}

function chaptersCommand(scriptDir, url) {
  return cmd(scriptDir, "chapters", [], [url])
}

// Directory-result artwork is cached to disk by the helper rather than being
// loaded straight into an Image, so the panel never issues a request to a
// host a search API named.
function artCommand(scriptDir, urls) {
  return cmd(scriptDir, "art", [], urls || [])
}

function notifyCommand(scriptDir, title, body, icon) {
  return cmd(scriptDir, "notify", icon ? ["--icon", String(icon)] : [], [title, body])
}

// -------------------------------------------------------------------- mpv

// Audio only, idle so the process outlives the end of a track, and no ytdl:
// an enclosure URL is attacker-chosen, and without --no-ytdl one mpv cannot
// demux natively gets handed to yt-dlp, which is a great deal more surface
// than playing an mp3 needs. The user's own mpv config is left alone on
// purpose — that is where mpv-mpris is loaded from, and MPRIS is a feature.
function mpvCommand(socketPath) {
  return [
    "mpv",
    "--no-video",
    "--idle=yes",
    "--no-terminal",
    "--really-quiet",
    "--audio-display=no",
    "--force-window=no",
    "--keep-open=no",
    "--no-ytdl",
    "--cache=yes",
    "--input-ipc-server=" + socketPath
  ]
}

// XDG_RUNTIME_DIR is a 0700 tmpfs that dies with the session — the right
// home for a control socket, and the only acceptable one. There is no /tmp
// fallback: a fixed path in a world-writable directory can be created by
// another account first, and whoever owns that socket sees every loadfile
// and can answer it. Returning "" disables playback instead, which is the
// honest outcome on a session with no runtime dir.
function mpvSocketPath(runtimeDir) {
  var dir = String(runtimeDir || "").replace(/\/+$/, "")
  if (dir === "") return ""
  return dir + "/omarchy-podcasts-mpv.sock"
}

// Every IPC message is JSON.stringify'd, so an enclosure URL containing
// quotes or newlines is data, not syntax.
function ipc(command, requestId) {
  var payload = { command: command }
  if (requestId !== undefined) payload.request_id = requestId
  return JSON.stringify(payload) + "\n"
}

function observe(property, id) {
  return ipc(["observe_property", id, property])
}

// dynaudnorm levels quiet speech against loud stings without the pumping a
// plain compressor gives you — this is the Overcast "Voice Boost" trick.
var VOICE_BOOST_FILTER = "dynaudnorm=f=150:g=15"

function voiceBoostOn() {
  return ipc(["af", "set", VOICE_BOOST_FILTER])
}

function voiceBoostOff() {
  return ipc(["af", "set", ""])
}

// ----------------------------------------------------------------- parsing

function parseJson(raw) {
  var text = String(raw || "").replace(/^\s+|\s+$/g, "")
  if (text === "") return { ok: false, error: "no output" }
  try {
    var data = JSON.parse(text)
    if (!data || typeof data !== "object") return { ok: false, error: "bad output" }
    return data
  } catch (e) {
    return { ok: false, error: "bad output" }
  }
}

// mpv streams one JSON object per line over the IPC socket. Anything we
// cannot parse is dropped rather than guessed at.
function parseIpcLine(line) {
  var text = String(line || "").replace(/^\s+|\s+$/g, "")
  if (text === "" || text.charAt(0) !== "{") return null
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

// --------------------------------------------------------------- formatting

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

function ageLabel(ts) {
  if (!ts) return ""
  var diff = Date.now() / 1000 - ts
  if (diff < 3600) return Math.max(1, Math.round(diff / 60)) + "m"
  if (diff < 86400) return Math.round(diff / 3600) + "h"
  if (diff < 14 * 86400) return Math.round(diff / 86400) + "d"
  var d = new Date(ts * 1000)
  return MONTHS[d.getMonth()] + " " + d.getDate()
}

function clockLabel(seconds) {
  var total = Math.max(0, Math.round(seconds || 0))
  var h = Math.floor(total / 3600)
  var m = Math.floor((total % 3600) / 60)
  var s = total % 60
  var mm = (h > 0 && m < 10 ? "0" : "") + m
  var ss = (s < 10 ? "0" : "") + s
  return (h > 0 ? h + ":" : "") + mm + ":" + ss
}

function durationLabel(seconds) {
  var total = Math.max(0, Math.round(seconds || 0))
  if (total === 0) return ""
  if (total < 3600) return Math.round(total / 60) + " min"
  var h = Math.floor(total / 3600)
  var m = Math.round((total % 3600) / 60)
  if (m === 60) return (h + 1) + " hr"
  return h + " hr" + (m > 0 ? " " + m + " min" : "")
}

// "34 min left" reads better than a progress percentage on a queue row.
function remainingLabel(episode) {
  if (!episode) return ""
  var dur = episode.duration || 0
  var pos = episode.pos || 0
  if (dur <= 0) return ""
  if (pos <= 0) return durationLabel(dur)
  var left = Math.max(0, dur - pos)
  if (left < 60) return "almost done"
  return durationLabel(left) + " left"
}

function progressOf(episode) {
  if (!episode) return 0
  var dur = episode.duration || 0
  if (dur <= 0) return 0
  return Math.max(0, Math.min(1, (episode.pos || 0) / dur))
}

function speedLabel(speed) {
  var value = Math.round((speed || 1) * 10) / 10
  return (value === Math.round(value) ? value.toFixed(1) : String(value)) + "×"
}

function savedLabel(seconds) {
  var total = Math.max(0, Math.round(seconds || 0))
  if (total < 3600) return Math.round(total / 60) + " minutes"
  var hours = total / 3600
  return (hours < 10 ? hours.toFixed(1) : String(Math.round(hours))) + " hours"
}

// ------------------------------------------------------------------- logic

var MODES = ["inbox", "auto", "ignore"]

function modeLabel(mode) {
  if (mode === "auto") return "AUTO-QUEUE"
  if (mode === "ignore") return "IGNORED"
  return "INBOX"
}

function modeHint(mode) {
  if (mode === "auto") return "new episodes go straight to the queue, with a notification"
  if (mode === "ignore") return "subscribed but silent — browse this show manually"
  return "new episodes land in the inbox for triage"
}

function nextMode(mode) {
  var at = MODES.indexOf(mode)
  return MODES[(at === -1 ? 0 : at + 1) % MODES.length]
}

// Speed a given show should play at: its own override, else the global
// default from settings.
function speedFor(show, defaultSpeed) {
  var own = show && show.speed ? Number(show.speed) : 0
  var speed = own > 0 ? own : Number(defaultSpeed || 1)
  if (!(speed > 0)) speed = 1
  return Math.max(0.8, Math.min(3.0, Math.round(speed * 10) / 10))
}

function findEpisode(rows, episodeId) {
  for (var i = 0; i < (rows || []).length; i++) {
    if (rows[i].id === episodeId) return rows[i]
  }
  return null
}

function indexOfEpisode(rows, episodeId) {
  for (var i = 0; i < (rows || []).length; i++) {
    if (rows[i].id === episodeId) return i
  }
  return -1
}

function showById(shows, showId) {
  for (var i = 0; i < (shows || []).length; i++) {
    if (shows[i].id === showId) return shows[i]
  }
  return null
}

function staleShows(shows) {
  var out = []
  for (var i = 0; i < (shows || []).length; i++) {
    if (shows[i].stale) out.push(shows[i])
  }
  return out
}

// Filter for the Shows grid search box — matches title or author.
function filterShows(shows, needle) {
  var query = String(needle || "").toLowerCase().replace(/^\s+|\s+$/g, "")
  if (query === "") return shows || []
  var out = []
  for (var i = 0; i < (shows || []).length; i++) {
    var show = shows[i]
    var hay = String(show.title || "").toLowerCase() + " " + String(show.author || "").toLowerCase()
    if (hay.indexOf(query) !== -1) out.push(show)
  }
  return out
}

// A pasted string is a feed URL if it looks like one; anything else is a
// search term. Keeps the Shows view down to a single input.
function looksLikeUrl(text) {
  return /^https?:\/\/\S+$/i.test(String(text || "").replace(/^\s+|\s+$/g, ""))
}

// Loose feed-URL identity for "do I already have this?". Deliberately looser
// than the engine's canonical form — a trailing slash or a capitalised host
// is the same subscription to a human.
function sameFeed(a, b) {
  var x = String(a || "").toLowerCase().replace(/\/+$/, "")
  var y = String(b || "").toLowerCase().replace(/\/+$/, "")
  return x !== "" && x === y
}

// Directory hits the user is not already subscribed to. Matched on feed URL,
// and on an exact title as a second pass — a show whose feed has permanently
// moved is stored under its new URL while the directory still lists the old
// one, and listing it as "not subscribed" would be a lie.
function unsubscribedResults(results, shows) {
  var out = []
  for (var i = 0; i < (results || []).length; i++) {
    var result = results[i]
    var known = false
    for (var j = 0; j < (shows || []).length; j++) {
      var show = shows[j]
      if (sameFeed(result.feed, show.feed)
          || (result.title && show.title
              && String(result.title).toLowerCase() === String(show.title).toLowerCase())) {
        known = true
        break
      }
    }
    if (!known) out.push(result)
  }
  return out
}

function chapterAt(chapters, position) {
  var at = -1
  for (var i = 0; i < (chapters || []).length; i++) {
    if (chapters[i].start <= position + 0.25) at = i
    else break
  }
  return at
}

if (typeof module !== "undefined") {
  module.exports = {
    helper: helper,
    initCommand: initCommand,
    libraryCommand: libraryCommand,
    showsCommand: showsCommand,
    episodesCommand: episodesCommand,
    searchCommand: searchCommand,
    addCommand: addCommand,
    removeCommand: removeCommand,
    refreshCommand: refreshCommand,
    triageCommand: triageCommand,
    archiveAllCommand: archiveAllCommand,
    queueCommand: queueCommand,
    positionCommand: positionCommand,
    showSetCommand: showSetCommand,
    opmlImportCommand: opmlImportCommand,
    opmlExportCommand: opmlExportCommand,
    chaptersCommand: chaptersCommand,
    artCommand: artCommand,
    notifyCommand: notifyCommand,
    mpvCommand: mpvCommand,
    mpvSocketPath: mpvSocketPath,
    ipc: ipc,
    observe: observe,
    voiceBoostOn: voiceBoostOn,
    voiceBoostOff: voiceBoostOff,
    parseJson: parseJson,
    parseIpcLine: parseIpcLine,
    ageLabel: ageLabel,
    clockLabel: clockLabel,
    durationLabel: durationLabel,
    remainingLabel: remainingLabel,
    progressOf: progressOf,
    speedLabel: speedLabel,
    savedLabel: savedLabel,
    MODES: MODES,
    modeLabel: modeLabel,
    modeHint: modeHint,
    nextMode: nextMode,
    speedFor: speedFor,
    findEpisode: findEpisode,
    indexOfEpisode: indexOfEpisode,
    showById: showById,
    staleShows: staleShows,
    filterShows: filterShows,
    looksLikeUrl: looksLikeUrl,
    sameFeed: sameFeed,
    unsubscribedResults: unsubscribedResults,
    chapterAt: chapterAt
  }
}
