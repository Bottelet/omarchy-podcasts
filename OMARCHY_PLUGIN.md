# Podcasts — Omarchy plugin

Bar widget (`kinds: ["bar-widget"]`, entry `BarWidget.qml`), id
`bottelet.podcasts`. Badges the bar with the number of untriaged inbox
episodes, and plays a queue through mpv.

## Install

Installs to `~/.config/omarchy/plugins/bottelet.podcasts/`.

```sh
omarchy plugin add https://github.com/Bottelet/omarchy-podcasts.git --enable
omarchy bar put bottelet.podcasts --after omarchy.clock
```

## IPC

`IpcHandler` target `bottelet.podcasts` exposes: `open`, `close`, `show`,
`hide`, `toggle`, `refresh`, `settings`, plus transport controls `play`,
`pause`, `next`, `forward`, `back` — e.g.
`omarchy-shell bottelet.podcasts toggle`.

## Settings

Configured in the widget's own entry in `~/.config/omarchy/shell.json`, or via
the ⚙ panel / `omarchy bar set`:

| Key | Type | Meaning |
| --- | --- | --- |
| `pollMinutes` | integer | Feed poll cadence (default 30, floor 10) |
| `defaultSpeed` | number | Speed for shows with no override (default 1.0) |
| `voiceBoost` | boolean | mpv `dynaudnorm` levelling (default false) |
| `podcastIndexKey` / `podcastIndexSecret` | string | Optional Podcast Index credentials; empty means iTunes search |

```sh
omarchy bar set bottelet.podcasts pollMinutes 60
omarchy bar set bottelet.podcasts defaultSpeed 1.4
```

Subscriptions, queue order, triage state and playback positions are **state,
not settings**: they live under `~/.local/share/omarchy-podcasts/`
(`shows.json`, `library.json`, `episodes/<showId>.json`, `art/`), written
0600 under a 0700 directory and guarded by an `flock` so one writer touches
them at a time.

## Layout

| File | Role |
| --- | --- |
| `BarWidget.qml` | Bar chip: icon, inbox badge, playback hairline, middle-click play/pause |
| `Panel.qml` | All state, every process, the mpv socket, IPC, view host |
| `InboxView` / `QueueView` / `PlayerView` / `ShowsView` / `SettingsView` | Dumb renderers that call back into the panel |
| `EpisodeRow.qml` | The shared episode line |
| `KeyCatcher.qml` | `qs.Ui.PanelKeyCatcher`'s contract plus modifier-aware movement |
| `Model.js` | Command builders, mpv IPC messages, parsing, formatting |
| `scripts/podcasts.py` | Feeds, library, artwork, OPML, chapters, notifications |
| `tests/` | 175-check offline suite with a stub curl |

## Technical

Follows the Omarchy panel shape: exposes `settings` and `setting(name,
fallback)`, delegates `Color` and `Style` to Omarchy's `qs.Commons` / `qs.Ui`,
and persists settings only to this plugin's own `shell.json` entry via
`bar.shell.updateEntryInline`.

### Decisions worth knowing

**Feed parsing runs in Python, not bash+jq like the sibling plugins.** The
9.6 MB / 1,031-episode Syntax feed is the test case that settled it: the
parse has to stream. `xml.etree.ElementTree.iterparse` with a `clear()` on
every closing `</item>` holds flat memory regardless of feed size and finishes
that feed in ~1.3 s wall clock including the download, and it is stdlib, so
there is nothing to install. A jq/xmlstarlet pipeline would have needed a
dependency that is not on a stock Omarchy box. QML only ever sees the trimmed
JSON the script prints — one object per call, `{ok: false, error}` on any
failure, always exit 0.

**mpv-mpris is present on stock Omarchy** (`/etc/mpv/scripts/mpris.so`, which
mpv auto-loads), so playback shows up on D-Bus for media keys and other
now-playing widgets with no work on our side. It is listed as an optional
dependency because nothing here depends on it.

**mpv is driven over a `Quickshell.Io.Socket`,** not by shelling out. The
plugin spawns `mpv --no-video --idle=yes
--input-ipc-server=$XDG_RUNTIME_DIR/omarchy-podcasts-mpv.sock` lazily on first
play and connects to it. mpv creates the socket a beat after exec, so the
first connect loses the race with `ServerNotFoundError`; a retry timer knocks
every 300 ms, and because a failed `QLocalSocket` keeps its requested state,
each retry has to drive the property `false → true` across two event-loop
turns rather than re-assigning `true`. Property observation (`time-pos`,
`duration`, `pause`, `speed`) and the `end-file` event drive the scrubber,
position persistence and queue auto-advance.

**Episode ids are keyed on the show id, never on the feed URL.** Feeds move —
301s and `itunes:new-feed-url` are routine — and an id derived from the
current URL would make every episode look brand new the day a host changes
CDN, flooding the inbox and losing every saved position. The show id is
assigned once at subscribe time and never recomputed. There is a regression
test for exactly this.

**Keybindings** mirror the sibling plugins where they overlap (`Esc` closes,
`Tab` switches panels, `j`/`k` move, `x` deletes, `r` refreshes, ⚙ is `s`).
The one addition is `Shift+↑/↓` for queue reordering, which the shell's shared
`PanelKeyCatcher` cannot express because it consumes arrows before any
ancestor sees the modifier — hence the small plugin-local `KeyCatcher.qml`
that keeps the same signal names and adds `reorderRequested` and `digitKey`.

### Hardening

Feed content is attacker-controlled and is handled that way:

- **No shell, anywhere.** curl and mpv are invoked as argv arrays; enclosure
  URLs reach mpv as JSON strings over the IPC socket. The only `bar.run` call
  in the plugin is `xdg-open` on a scheme-checked, single-quote-escaped show
  link.
- **HTTPS only.** `--proto '=https' --proto-redir '=https'` pins the protocol
  across redirects so an https feed cannot bounce down to cleartext. `http://`
  feeds are refused unless the user marks that feed as an explicit exception.
- **DTDs are refused.** ElementTree already treats an external entity as a
  parse error, but expat expands *internal* entity declarations without limit
  — the billion-laughs amplification, which no byte cap on the download can
  catch. The prolog is scanned (skipping the XML declaration, PIs and
  comments) and any `<!DOCTYPE` rejects the document. Same check on OPML
  import. Two ways of hiding a DOCTYPE from that scan were found and closed
  during the security pass, both with regression tests: burying it behind
  more prologue than the scan window holds (running out of window now counts
  as a refusal — no real feed opens with 64 KiB of preamble), and writing the
  feed in UTF-16, where `<` is `3C 00` and an ASCII scan walks straight past
  the declaration that expat then honours. The head is transcoded before
  scanning.
- **Arguments cannot become flags.** Every helper invocation puts a literal
  `--` between its options and its positionals, so a search term or feed URL
  beginning with a dash arrives as a value instead of making argparse answer
  with a usage message where the panel expected JSON.
- **Everything is capped.** 15 MB per feed, 5 MB per artwork, 2 MB per JSON
  response, 100 newest episodes kept per show, 700 characters of episode
  notes, 400 chapters, 50 MB LRU artwork cache. Timeouts on every request and
  no retries.
- **No remote image loads.** Show and directory-result artwork is fetched by
  the helper (`art` subcommand), https-only, capped at 5 MB, with the file
  extension taken from sniffed magic bytes rather than the URL, then handed to
  QML as a local path. Pointing an `Image` at a search API's CDN would leak
  the user's IP on every keystroke of a search.
- **Plain text only.** Every feed-derived string renders as `Text.PlainText`
  and is HTML-stripped and control-character-scrubbed on the way in. No
  `RichText` sink touches remote content, so a feed cannot trigger a
  zero-click fetch through an `<img>` or a CSS `url()`.
- **No credentials on argv or in logs.** `/proc/<pid>/cmdline` is
  world-readable on a stock Linux, so an argument is legible to every other
  account on the machine. The optional Podcast Index key and secret travel
  from QML to the helper on stdin, and from the helper to curl through a
  config file on stdin (`-K -`) rather than `-H`. They are pinned to
  `[A-Za-z0-9_-]{8,128}` before use, are sent only to api.podcastindex.org,
  and are never printed.
- **The state lock cannot wedge the UI.** An OPML import holds the writer
  lock across one network fetch per feed, so a plain `flock()` would let a
  concurrent poll block for ever behind it. The wait is bounded at two
  minutes and then fails with a message, so the worst case is a retry rather
  than a spinner the user cannot clear.

`tests/run.sh` covers all of the above offline (175 checks; a stub curl serves
fixtures and simulates 304s, permanent redirects, transport failures and
oversized bodies).

## Not here yet

gpodder.net / oPodSync sync, Smart Speed silence-skipping with a saved-time
counter, offline downloads and a `podcast:transcript` viewer are the next
milestone. The transcript URL is already parsed and stored per episode; the
`savedSeconds` field in `library.json` is reserved for the Smart Speed
counter.
