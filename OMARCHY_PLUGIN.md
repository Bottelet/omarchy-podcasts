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
| `tests/` | 297-check offline suite with a stub curl |

## Technical

Follows the Omarchy panel shape: exposes `settings` and `setting(name,
fallback)`, delegates `Color` and `Style` to Omarchy's `qs.Commons` / `qs.Ui`,
and persists settings only to this plugin's own `shell.json` entry via
`bar.shell.updateEntryInline`.

### Decisions worth knowing

**Feed parsing runs in Python, not bash+jq like the sibling plugins.** The
9.6 MB / 1,031-episode Syntax feed is the test case that settled it: the
parse has to stream. `xml.etree.ElementTree.iterparse` finishes that feed in
~1.3 s wall clock including the download, and it is stdlib, so there is
nothing to install.

Holding memory flat took more than the usual `clear()`, though — a claim
made here before it was measured, and wrong twice over. `clear()` empties an
element but leaves it parented, so a "cleared" subtree still costs a slot in
its parent for the rest of the parse: 400k sibling elements peaked at
**302 MB**, and a first fix that detached only items and channel children
still let 1.9M *nested* elements reach **608 MB** — worse than the original,
and returning success so nothing flagged it. What holds now:

- every element is detached from its parent as it closes, not merely
  cleared, with items exempt, and a metadata element's own children exempt
  while it holds fewer than 2,000 of them — exempting by *depth* let any
  container sitting at channel level keep every child it had, so 900,000 of
  them under a `<foo>`, or padding a `<description>`, still cost ~95 MB. That
  bound is a truncation cliff, since dropping a parent's children destroys
  their text, so it sits far beyond anything real: at 64 a `<description>`
  written with inline markup fell from 255 characters to 5, silently, and
  `plain_text` caps the result at 900 characters long before 2,000 children
  is reached;
- channel metadata is taken as text the moment each direct child closes, so
  nothing is retained to the end — keeping those elements around was itself
  87 MB when a feed put 400k junk elements at channel level;
- a depth ceiling of 64, because a deeply nested document closes nothing
  until the parser reaches the bottom, so no amount of care on the way out
  bounds the descent.

Every adversarial shape now sits at ~20 MB. Reading metadata per closing
child is also why a channel child is identified by **parentage rather than
depth**. Feeds carry containers at channel level with their own `<title>`
(Podcasting 2.0's `<podcast:liveItem>` is one, and it briefly named a real
show after a live-stream announcement), and matching on depth alone went
further wrong than that: a feed could put its `<title>` and its
`<itunes:image href>` in a sibling container *outside* `<channel>` and have
both taken — including an artwork URL the helper then fetches.

**Channel metadata is resolved by preference, not by order of appearance.**
That distinction is not academic: Megaphone emits `<image>` before
`<itunes:image>`, and RSS caps `<image>` at 144x400, so taking the first
would hand thousands of shows a legacy logo in place of 3000x3000 artwork.
Candidates are recorded under their namespaced tag and resolved afterwards —
`itunes:image` over `image`, `description` over `itunes:summary`,
`itunes:author` over `itunes:owner` over a bare `<author>`. A jq/xmlstarlet pipeline would have needed a
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
  URLs reach mpv as JSON strings over the IPC socket. There is no `bar.run`
  call and no `sh -c` in the plugin at all — an `xdg-open` helper that quoted
  its argument correctly but had no callers was deleted rather than left for
  a reviewer to find.
- **mpv gets `--no-ytdl`.** Without it, an enclosure URL mpv cannot demux
  natively is handed to yt-dlp, which is far more surface than playing an mp3
  needs. The user's own mpv config is deliberately left alone: that is where
  mpv-mpris loads from.
- **The control socket lives only in `XDG_RUNTIME_DIR`.** There is no `/tmp`
  fallback: a fixed path in a world-writable directory can be created by
  another account first, and whoever owns that socket sees every `loadfile`
  and can answer it. Without a runtime dir, playback reports that it is
  unavailable instead.
- **Entities are decoded before tags are stripped.** The other order let
  `&lt;img src=http://…&gt;` pass through tag-stripping as text and come back
  out as live markup — which reaches a notification body, where some daemons
  render Pango and fetch images. Notification text is escaped again on the
  way out.
- **A capped download is a failed one.** curl reports the status line even
  when it then aborts the transfer, so a `--max-filesize` trip on a chunked
  response left a truncated body next to a 200. Trusting that once let a
  truncated feed's ETag be persisted, which would have made a partial episode
  list authoritative for ever; any non-zero curl exit is now a failure.
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
- **A feed cannot send us somewhere only this machine can reach.** Loopback,
  link-local (which includes the cloud metadata endpoint at 169.254.169.254),
  unspecified, multicast and reserved addresses are refused on every
  feed-controlled URL —
  the feed itself, artwork, and `podcast:chapters`, whose titles render back
  into the panel and would otherwise be a read primitive against an internal
  service. Private LAN ranges are deliberately *not* blocked: a self-hosted
  podcast server on 192.168.x is a normal thing to subscribe to, and refusing
  it would break a real use case to close a hole loopback already accounts
  for.

  Addresses are unwrapped before they are judged. `::ffff:127.0.0.1` is
  loopback wearing a hat: it parses as IPv6, so a check against `127.0.0.0/8`
  never matched it, and curl reads it back in the same form — so neither
  stage caught it until IPv4-mapped, 6to4 and Teredo addresses were unwrapped
  first.

  Literal addresses are refused before anything leaves the machine. Names are
  judged afterwards, on `%{remote_ip}` — the address curl actually connected
  to — rather than by resolving them ourselves. That is both faster (our own
  lookup stalled for the full resolver timeout on a host that does not
  resolve, which would hang the plugin on a flaky network before curl even
  started) and more accurate, since there is no window between our lookup and
  curl's for the answer to change. It also catches the obvious way around a
  check on the starting URL — a public host answering 301 to localhost —
  because the response is discarded before it is parsed, cached or shown.

  Only *absolute* `Location` values are judged. A relative reference is
  permitted there and is everywhere in practice; it has no hostname, and
  treating that as unreachable rejected every ordinary redirect while
  blaming the feed. It cannot change the host in any case, and the connected
  address covers where the chain landed.

  The one place the guarantee is dropped on purpose is behind an HTTP proxy.
  curl honours `http_proxy` and friends, and through one `%{remote_ip}` is
  the proxy's address rather than the origin's — usually 127.0.0.1, since
  privoxy, mitmproxy and corporate MITM agents all sit on loopback. Judging
  that would block every fetch a proxied user makes, so on a request that
  actually went through one the connected-address test is skipped and only
  the URL and hop checks apply. A proxied request is already going somewhere
  this plugin cannot see.

  "Configured" is not "used", though: curl decides per host via `no_proxy`,
  and on a direct connection the address it reports is the true origin and
  free to check. `%{proxy_used}` says which happened, so the exemption covers
  only the connections that warrant it. A curl too old to know that variable
  falls back to the environment, which is the wider behaviour rather than a
  broken one.
- **No remote image loads.** Show and directory-result artwork is fetched by
  the helper (`art` subcommand), https-only, capped at 5 MB, with the file
  extension taken from sniffed magic bytes rather than the URL, then handed to
  QML as a local path. Pointing an `Image` at a search API's CDN would leak
  the user's IP on every keystroke of a search.
- **Plain text only.** Every feed-derived string renders as `Text.PlainText`
  and is HTML-stripped and control-character-scrubbed on the way in. No
  `RichText` sink touches remote content, so a feed cannot trigger a
  zero-click fetch through an `<img>` or a CSS `url()`.
- **A cap refuses; it never truncates.** More subscriptions, queue entries or
  triage records than the plugin will handle stops the command and leaves the
  file alone. Truncating instead would delete the remainder the moment
  anything else wrote — the same silent-loss shape as reading a broken file
  as empty, with a higher threshold and a longer fuse.
- **The state directory itself is checked for a symlink.** `O_NOFOLLOW` only
  refuses a link at the final component, and `makedirs(exist_ok=True)` walks
  into a linked directory without complaint — which would send every read and
  write somewhere of the attacker's choosing and make the file-level check
  irrelevant.
- **A failed write leaves nothing behind.** The handler catches
  `BaseException`, because `json.dump` raises `TypeError` on an object it
  cannot serialise; its own `close()` is made non-raising, because on a full
  disk that re-flushes and throws the same `ENOSPC`, which escaped the
  handler before it reached the unlink. The sweep covers the write temps as a
  backstop, in the state root and the episodes directory as well as the
  download area.
- **State files are read bounded and no-follow, and written through a name
  nobody can guess.** They live in a directory the user's own processes can
  write, so neither their size nor their type is ours to trust: reads use
  `O_NOFOLLOW` (a symlink pre-placed at the path is refused, not followed)
  and stop one byte past a cap, and records and string fields are capped
  again after parsing. Writes go through `mkstemp`, which creates `O_EXCL` at
  0600 under a name it chooses, before the atomic rename — the previous
  target-plus-pid name was predictable enough for another process running as
  the same user to drop a symlink there and redirect the truncation. Download
  targets got the same treatment, since `curl -o` follows a symlink too.
- **A state file that will not read stops the command.** Returning a default
  on any error is right for a cache and catastrophic for state: every
  mutating command ends in a full rewrite, so proceeding on a phantom empty
  subscription list persists the loss — and once an orphan sweep was added,
  one unreadable `shows.json` destroyed the subscriptions, every episode file
  and the whole queue, reporting `ok: true`. A missing file is a first run; a
  file that exists but will not parse, or parses to the wrong shape, aborts
  and is left untouched.
- **A malformed record is repaired, not dropped.** Every mutating command
  ends in a full rewrite of `shows.json`, so a load that silently filters a
  bad record deletes that subscription for good the next time anything else
  is written. A record with a usable feed URL gets a correct id instead; only
  one with no feed at all is discarded.
- **No credentials on argv or in logs.** `/proc/<pid>/cmdline` is
  world-readable on a stock Linux, so an argument is legible to every other
  account on the machine. The optional Podcast Index key and secret travel
  from QML to the helper on stdin, and from the helper to curl through a
  config file on stdin (`-K -`) rather than `-H`. They are pinned to
  `[A-Za-z0-9_-]{8,128}` before use, are sent only to api.podcastindex.org,
  and are never printed.
- **An episodes file never outlives its subscription.** The import writes
  `episodes/<id>.json` and `shows.json` under one lock, so a run that ends
  between them — which the lock's own timeout can cause, not only a kill —
  cannot leave a file no subscription names; a sweep clears any historical
  ones. It also asks whether a feed is already subscribed *before* fetching,
  so re-importing the same OPML no longer forces a full refetch of every
  subscription and then discards the result.
- **The state lock covers the write, not the fetch.** An OPML import fetches
  each feed with no lock held and takes it only around the read-modify-write.
  Holding it for the whole import made every poll and click wait for hours;
  taking it per feed but keeping the fetch inside meant the importer held it
  essentially continuously and re-took it faster than any waiter could win,
  which at five hundred feeds still pushed a waiter past its deadline. The
  wait is bounded at two minutes on top of that, so the worst case is a retry
  rather than a spinner the user cannot clear.
- **stdin has one occupant.** Passing a POST body and credentials on the same
  request would have curl read the body as a config file, where `output =` is
  an arbitrary file write and `url =` unwinds the protocol pinning. No caller
  does this; the combination is refused rather than left loaded.

`tests/run.sh` covers all of the above offline (297 checks; a stub curl serves
fixtures and simulates 304s, permanent redirects, transport failures and
oversized bodies).

## Not here yet

gpodder.net / oPodSync sync, Smart Speed silence-skipping with a saved-time
counter, offline downloads and a `podcast:transcript` viewer are the next
milestone. The transcript URL is already parsed and stored per episode; the
`savedSeconds` field in `library.json` is reserved for the Smart Speed
counter.

## Known limitations

Deliberate, with reasons, so the next reader does not re-litigate them:

- **A 301 or `itunes:new-feed-url` repoints a live subscription silently**,
  keeping the show id and saying nothing in the UI.
- **`show.allowHttp` has no interface.** Feeds must be HTTPS and there is
  currently no way for a user to grant a per-feed exception, so the error
  text that offers one is aspirational. Enclosure URLs are the exception:
  http ones are kept and played, because a great many old feeds still serve
  audio that way.
- **Show ids are 48 bits** (`sha1(feed)[:12]`). A collision costs a user a
  spurious "already subscribed"; it is free to widen when the state format
  next changes.
- **`library` hydrates every episode of every show** and the panel reloads it
  after every action. At a few dozen shows that is nothing; at five hundred
  it would be tens of megabytes parsed on the GUI thread.
- **Artwork is refetched whenever its URL changes**, so a feed that rotates a
  query string on its artwork costs a download per poll.
