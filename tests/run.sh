#!/bin/bash
# Offline test suite for the bottelet.podcasts engine.
#
#   tests/run.sh            run everything
#   tests/run.sh -v         also print each command's JSON
#
# Nothing here touches the network: a stub curl (tests/fake-curl.py) serves
# tests/fixtures/ and simulates status codes, redirects, validators and
# transport failures, so the suite tests our parsing, state and hardening
# rather than the internet's mood.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname "$HERE")"
SCRIPT="$PLUGIN/scripts/podcasts.py"
VERBOSE=0
[[ ${1:-} == "-v" ]] && VERBOSE=1

WORK="$(mktemp -d -t omarchy-podcasts-tests-XXXXXX)"
export OMARCHY_PODCASTS_DIR="$WORK/state"
export FAKE_CURL_ROUTES="$WORK/routes.json"
export PATH="$WORK/bin:$PATH"

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<EOF
#!/bin/bash
exec python3 "$HERE/fake-curl.py" "\$@"
EOF
chmod +x "$WORK/bin/curl"

# notify-send is fire-and-forget; record the argv instead of popping toasts.
cat > "$WORK/bin/notify-send" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/notifications.log"
EOF
chmod +x "$WORK/bin/notify-send"

PASS=0
FAIL=0
CURRENT=""

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ok()   { PASS=$((PASS + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }

# run <subcommand...> — captures JSON into $OUT
run() {
  OUT="$(python3 "$SCRIPT" "$@" 2>"$WORK/stderr")"
  (( VERBOSE )) && printf '      $ %s\n      %s\n' "$*" "$OUT"
  if [[ -s "$WORK/stderr" ]]; then
    printf '  \033[33m!\033[0m stderr from %s: %s\n' "$1" "$(head -2 "$WORK/stderr")"
  fi
}

# check <name> <jq-filter> <expected>
check() {
  local name="$1" filter="$2" want="$3" got
  got="$(printf '%s' "$OUT" | jq -r "$filter" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then ok "$name"; else bad "$name" "want [$want] got [$got]"; fi
}

routes() { printf '%s' "$1" > "$FAKE_CURL_ROUTES"; }

FEED="https://example.com/feed.xml"
SECOND="https://example.com/second.xml"

# ---------------------------------------------------------------- unit tests

section "Pure functions"
while IFS=$'\t' read -r verdict name detail; do
  [[ -z "${verdict:-}" ]] && continue
  if [[ "$verdict" == "PASS" ]]; then ok "$name"; else bad "$name" "$detail"; fi
done < <(python3 - "$SCRIPT" <<'PYEOF'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("pc", sys.argv[1])
pc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pc)

results = []
def expect(name, got, want):
    results.append((name, got == want, "want %r got %r" % (want, got)))

# URL validation is the first gate every feed-supplied string passes.
expect("https URL accepted", pc.valid_url("https://a.example/f.xml"), "https://a.example/f.xml")
expect("http URL rejected by default", pc.valid_url("http://a.example/f.xml"), "")
expect("http URL allowed by exception", pc.valid_url("http://a.example/f.xml", True), "http://a.example/f.xml")
expect("file:// rejected", pc.valid_url("file:///etc/passwd", True), "")
expect("shell metacharacters rejected", pc.valid_url("https://a.example/'; rm -rf /; echo '"), "")
expect("whitespace rejected", pc.valid_url("https://a.example/a b"), "")
expect("absurdly long URL rejected", pc.valid_url("https://a.example/" + "x" * 2100), "")

expect("tags stripped", pc.plain_text("<p>hi <b>there</b></p>"), "hi there")
expect("entities unescaped", pc.plain_text("a &amp; b &lt;c&gt;"), "a & b <c>")
expect("control chars stripped", pc.plain_text("a\x07b\x00c"), "a b c")
expect("description truncated", len(pc.plain_text("x" * 5000)), pc.MAX_DESC_CHARS)

expect("duration H:MM:SS", pc.parse_duration("1:02:03"), 3723)
expect("duration MM:SS", pc.parse_duration("04:20"), 260)
expect("duration seconds", pc.parse_duration("930"), 930)
expect("duration garbage", pc.parse_duration("soon"), 0)
expect("date RFC 822", pc.parse_date("Wed, 20 Aug 2026 09:00:00 +0000"), 1787216400)
expect("date ISO 8601", pc.parse_date("2026-08-20T09:00:00Z"), 1787216400)
expect("date garbage", pc.parse_date("whenever"), 0)

expect("host lowercased", pc.normalize_feed("HTTPS://Example.COM/Feed.XML"), "https://example.com/Feed.XML")
expect("show id is stable", pc.show_id_for("https://a.example/f"), pc.show_id_for("https://a.example/f"))
expect("show ids differ", pc.show_id_for("https://a.example/f") != pc.show_id_for("https://b.example/f"), True)

expect("DOCTYPE found after declaration", pc.has_doctype(b'<?xml version="1.0"?><!DOCTYPE r><rss/>'), True)
expect("bare DOCTYPE found", pc.has_doctype(b'<!DOCTYPE rss><rss/>'), True)
expect("DOCTYPE after a PI found", pc.has_doctype(b'<?xml?><?xml-stylesheet?><!DOCTYPE r><rss/>'), True)
expect("DOCTYPE inside a comment ignored", pc.has_doctype(b'<?xml?><!-- <!DOCTYPE x> --><rss/>'), False)
expect("DOCTYPE-looking body text ignored", pc.has_doctype(b'<rss><t>&lt;!DOCTYPE</t></rss>'), False)
expect("byte-order mark tolerated", pc.has_doctype(b'\xef\xbb\xbf<?xml?><rss/>'), False)

# A DOCTYPE can hide from a naive byte scan two ways: behind enough prologue
# to push it out of the window, or inside an encoding the scanner does not
# speak but expat does. Both were live bypasses of an earlier version of this
# guard; expat parsed the UTF-16 bomb happily.
BOMB = b'<!DOCTYPE r [<!ENTITY a "aa">]><rss><channel><title>&a;</title></channel></rss>'
CLEAN = b'<?xml version="1.0"?><rss version="2.0"><channel><title>ok</title></channel></rss>'
expect("DOCTYPE padded past the window", pc.has_doctype(b"<!--" + b"x" * 70000 + b"-->" + BOMB), True)
expect("DOCTYPE hidden in UTF-16", pc.has_doctype(BOMB.decode().encode("utf-16")), True)
expect("DOCTYPE hidden in UTF-16-BE", pc.has_doctype(BOMB.decode().encode("utf-16-be")), True)
expect("DOCTYPE hidden in UTF-32", pc.has_doctype(BOMB.decode().encode("utf-32")), True)
expect("a truncated prolog is refused", pc.has_doctype(b'<?xml version='), True)
expect("a UTF-16 feed without a DTD still passes", pc.has_doctype(CLEAN.decode().encode("utf-16")), False)
expect("a long comment before a clean root passes", pc.has_doctype(b"<!--" + b"x" * 400 + b"-->" + CLEAN), False)

# Ids are the only thing that becomes a filename.
expect("a hex id loads", pc.ID_RE.match("6425ecf474e9") is not None, True)
expect("a traversing id does not", pc.ID_RE.match("../../etc/passwd") is not None, False)
expect("a slashed id does not", pc.ID_RE.match("aa/bb") is not None, False)

# Podcast Index credentials are pinned to an alphabet before they reach a
# curl config line.
expect("a normal credential is accepted", pc.CREDENTIAL_RE.match("AbC123_-xyz") is not None, True)
expect("a quote-bearing credential is not", pc.CREDENTIAL_RE.match('ab"cd efgh') is not None, False)
expect("a newline-bearing credential is not", pc.CREDENTIAL_RE.match("abcdefgh\nX") is not None, False)

expect("XML attributes escaped", pc.xml_attr('a"b&c<d'), '"a&quot;b&amp;c&lt;d"')
expect("numbers clamped", pc.clamp_number("9999999999", 0, 100, 5), 100)
expect("non-numbers fall back", pc.clamp_number("abc", 0, 100, 5), 5)

for name, passed, detail in results:
    print(("PASS" if passed else "FAIL") + "\t" + name + "\t" + ("" if passed else detail))
PYEOF
)

# ------------------------------------------------------------ feed parsing

section "Feed parsing"
routes "{\"$FEED\": {\"fixture\": \"full.xml\", \"etag\": \"\\\"v1\\\"\"}}"
run add "$FEED"
check "subscribe succeeds" '.ok' 'true'
check "channel title parsed" '.show.title' 'Test Show'
check "channel author parsed" '.show.author' 'A Host'
check "channel description flattened to text" '.show.description' 'A & test'
check "items without audio dropped" '.episodes' '6'

SHOW_ID="$(printf '%s' "$OUT" | jq -r '.show.id')"
run episodes "$SHOW_ID"
check "newest episode sorts first" '.episodes[0].title' 'Everything episode'
check "oldest episode sorts last" '.episodes[-1].title' 'Oldest but listed last'
check "duration H:MM:SS parsed" '.episodes[0].duration' '3723'
check "enclosure captured" '.episodes[0].url' 'https://example.com/full.mp3'
check "enclosure length captured" '.episodes[0].bytes' '12345'
check "episode notes flattened to text" '.episodes[0].desc' 'Notes with a link & an entity.'
check "podcast:chapters captured" '.episodes[0].chapters' 'https://example.com/chapters.json'
check "podcast:transcript captured" '.episodes[0].transcript' 'https://example.com/t.vtt'
check "season captured" '.episodes[0].season' '2'
check "missing itunes:duration is zero" '.episodes[1].duration' '0'
check "missing guid falls back to the enclosure" '.episodes[1].guid' 'https://example.com/noguid.mp3'
check "media:content used when there is no enclosure" '.episodes[2].url' 'https://example.com/media.mp3'
check "http enclosure kept for the player to judge" '.episodes[3].url' 'http://example.com/old.mp3'
check "non-JSON chapters ignored" '.episodes[4].chapters' ''
check "subscribing does not fill the inbox" '.episodes[0].state' 'new'

run library
check "back catalogue is not triage work" '.inboxCount' '0'

section "Feed parsing — hostile and malformed input"
routes "{\"https://example.com/bomb.xml\": {\"fixture\": \"entity-bomb.xml\"}}"
run add "https://example.com/bomb.xml"
check "billion-laughs feed refused" '.ok' 'false'
check "…because of the DTD" '.error | test("DTD")' 'true'

routes "{\"https://example.com/xxe.xml\": {\"fixture\": \"xxe.xml\"}}"
run add "https://example.com/xxe.xml"
check "external-entity feed refused" '.ok' 'false'

routes "{\"https://example.com/html\": {\"fixture\": \"not-a-feed.xml\"}}"
run add "https://example.com/html"
check "a web page is not a feed" '.ok' 'false'

routes "{\"https://example.com/ctrl.xml\": {\"fixture\": \"control-chars.xml\"}}"
run add "https://example.com/ctrl.xml"
check "control characters survive the parse" '.ok' 'true'
check "…and are scrubbed from the title" '.show.title' 'Test Show'
check "itunes:new-feed-url is adopted" '.show.feed' 'https://example.com/moved.xml'

routes "{\"https://example.com/big.xml\": {\"fixture\": \"big.xml\"}}"
run add "https://example.com/big.xml"
check "long feeds are capped at the newest 100" '.episodes' '100'
BIG_ID="$(printf '%s' "$OUT" | jq -r '.show.id')"
run episodes "$BIG_ID"
check "…and it is the newest 100 that are kept" '.episodes[0].title' 'Episode 149'

run add "http://example.com/insecure.xml"
check "http feed refused" '.ok' 'false'
check "…with the exception explained" '.error | test("https")' 'true'
run add "file:///etc/passwd"
check "file:// feed refused" '.ok' 'false'

# A term or URL beginning with a dash must reach the helper as a value, not
# be eaten by argparse as an option — otherwise the panel gets a usage
# message where it expected JSON.
run add -- "-rf"
check "a dash-leading feed is data, not a flag" '.ok' 'false'
check "…and answers in JSON, not usage text" '.error' 'that does not look like a feed URL'
run chapters -- "--version"
check "a dash-leading chapters URL is data too" '.ok' 'false'
run queue add -- "-x"
check "a dash-leading episode id is data too" '.ok' 'true'
run queue remove -- "-x"

# ----------------------------------------------------------- conditional GET

section "Polling"
routes "{\"$FEED\": {\"fixture\": \"full.xml\", \"etag\": \"\\\"v1\\\"\"}}"
run refresh --show "$SHOW_ID"
check "an unchanged feed answers 304" '.results[0].status' '304'
check "…and reports nothing new" '.results[0].new' '0'

routes "{\"$FEED\": {\"fixture\": \"full-plus-one.xml\", \"etag\": \"\\\"v2\\\"\"}}"
run refresh --show "$SHOW_ID"
check "a changed feed is re-read" '.results[0].status' 'ok'
check "…and the new episode is counted" '.results[0].new' '1'

run library
check "the new episode lands in the inbox" '.inboxCount' '1'
check "…as the newest thing there" '.inbox[0].title' 'Brand new episode'
NEW_ID="$(printf '%s' "$OUT" | jq -r '.inbox[0].id')"

routes "{\"$FEED\": {\"location\": \"https://example.com/moved-for-good.xml\", \"status\": 301}, \"https://example.com/moved-for-good.xml\": {\"fixture\": \"full-plus-one.xml\"}}"
run refresh --show "$SHOW_ID" --force
check "a permanent redirect is followed" '.results[0].status' 'ok'
run shows
check "…and the new feed URL is kept" ".shows[] | select(.id == \"$SHOW_ID\") | .feed" 'https://example.com/moved-for-good.xml'
run library
check "…without every episode looking new again" '.inboxCount' '1'
check "…because episode ids survive the move" ".inbox[0].id == \"$NEW_ID\"" 'true'

routes "{\"https://example.com/moved-for-good.xml\": {\"exit\": 6}}"
for _ in 1 2 3 4; do run refresh --show "$SHOW_ID" --force; done
check "a dead feed reports a readable error" '.results[0].error' 'could not find that host'
run shows
check "…and is marked stale after repeated failures" ".shows[] | select(.id == \"$SHOW_ID\") | .stale" 'true'

routes "{\"https://example.com/moved-for-good.xml\": {\"fixture\": \"full-plus-one.xml\"}}"
run refresh --show "$SHOW_ID" --force
run shows
check "a feed that comes back is no longer stale" ".shows[] | select(.id == \"$SHOW_ID\") | .stale" 'false'

# -------------------------------------------------------------------- triage

section "Inbox triage"
run triage archive "$NEW_ID"
run library
check "archiving clears the inbox" '.inboxCount' '0'
run triage unarchive "$NEW_ID"
run library
check "un-archiving puts it back" '.inboxCount' '1'

run queue add "$NEW_ID"
check "queueing reports the new queue" '.queue | length' '1'
run library
check "…and takes it out of the inbox" '.inboxCount' '0'
check "…and into the queue" '.queue[0].title' 'Brand new episode'

run archive-all
run library
check "archive-all leaves the queue alone" '.queue | length' '1'

# ---------------------------------------------------------------- the queue

section "Queue"
run episodes "$SHOW_ID"
A="$(printf '%s' "$OUT" | jq -r '.episodes[1].id')"
B="$(printf '%s' "$OUT" | jq -r '.episodes[2].id')"
run queue add "$A"
run queue add "$B"
check "episodes append in order" '.queue | length' '3'
run queue add "$B" --front
check "…and --front jumps the line without duplicating" '.queue | length' '3'
check "…landing at the head" ".queue[0] == \"$B\"" 'true'
run queue move "$B" --delta 2
check "moving down reorders" ".queue[2] == \"$B\"" 'true'
run queue move "$B" --delta 99
check "…and cannot fall off the end" '.queue | length' '3'
run queue remove "$A"
check "removing shortens the queue" '.queue | length' '2'
run queue clear
check "clearing empties it" '.queue | length' '0'
run library
check "…and cleared episodes do not reappear in the inbox" '.inboxCount' '0'

# ------------------------------------------------------------------ playback

section "Playback state"
run queue add "$NEW_ID"
run position "$NEW_ID" 125 600 --now
run library
check "position is remembered" ".positions[\"$NEW_ID\"].pos == 125" 'true'
check "…and hydrated onto the episode" '.queue[0].pos == 125' 'true'
check "…and the player knows what is loaded" '.now.title' 'Brand new episode'
run position "$NEW_ID" 599 600 --played
run library
check "finishing drops it from the queue" '.queue | length' '0'
check "…and rewinds it for a replay" ".positions[\"$NEW_ID\"].pos == 0" 'true'

# ------------------------------------------------------------- per-show modes

section "Per-show modes"
routes "{\"$SECOND\": {\"fixture\": \"full.xml\"}}"
run add "$SECOND"
SECOND_ID="$(printf '%s' "$OUT" | jq -r '.show.id')"
run show-set "$SECOND_ID" mode auto
check "mode switches to auto-queue" '.show.mode' 'auto'
run show-set "$SECOND_ID" mode nonsense
check "an unknown mode is refused" '.ok' 'false'
run show-set "$SECOND_ID" speed 1.6
check "per-show speed is stored" '.show.speed == 1.6' 'true'
run show-set "$SECOND_ID" speed 99
check "…and clamped to something playable" '.show.speed == 3' 'true'

routes "{\"$SECOND\": {\"fixture\": \"full-plus-one.xml\"}}"
run refresh --show "$SECOND_ID" --force
check "auto-queue shows raise a notification" '.notify | length' '1'
check "…naming the episode" '.notify[0].title' 'Brand new episode'
run library
check "…and the episode skips the inbox" '.inboxCount' '0'
check "…going straight to the queue" '.queue | length' '1'

run show-set "$SECOND_ID" mode ignore
run queue clear
routes "{\"$SECOND\": {\"fixture\": \"full.xml\"}}"
run refresh --show "$SECOND_ID" --force
run library
check "an ignored show contributes nothing to the inbox" '.inboxCount' '0'

# ----------------------------------------------------------------- unsubscribe

section "Unsubscribe"
run queue add "$NEW_ID"
run remove "$SHOW_ID"
check "unsubscribing succeeds" '.ok' 'true'
run library
check "…and takes that show's queue entries with it" '.queue | length' '0'
run shows
check "…and the show is gone" "[.shows[] | select(.id == \"$SHOW_ID\")] | length" '0'
run episodes "$SHOW_ID"
check "…as are its episodes" '.ok' 'false'

# ----------------------------------------------------------------------- opml

section "OPML"
run opml-export "$WORK/out.opml"
check "export writes every subscription" '.count >= 1' 'true'
if grep -q 'xmlUrl="https://example.com/' "$WORK/out.opml"; then
  ok "export writes xmlUrl attributes"
else
  bad "export writes xmlUrl attributes" "$(head -8 "$WORK/out.opml")"
fi

routes "{\"$FEED\": {\"fixture\": \"full.xml\"}, \"$SECOND\": {\"fixture\": \"full.xml\"}}"
run opml-import "$HERE/fixtures/subs.opml"
check "import reads nested outlines" '.added + .skipped' '2'
run opml-import "$HERE/fixtures/subs.opml"
check "re-importing skips what is already there" '.added' '0'
run opml-import "$HERE/fixtures/bad.opml"
check "an OPML file with a DTD is refused" '.ok' 'false'
run opml-import "$WORK/nope.opml"
check "a missing OPML file is a clean error" '.ok' 'false'

# ------------------------------------------------------------------- chapters

section "Chapters"
routes "{\"https://example.com/chapters.json\": {\"fixture\": \"chapters.json\"}}"
run chapters "https://example.com/chapters.json"
check "chapters parse" '.ok' 'true'
check "entries without a start time are dropped" '.chapters | length' '3'
check "…and the rest are sorted" '.chapters[0].title' 'Intro'
check "chapter titles are flattened to text" '.chapters[2].title' 'Third bold'
run chapters "http://example.com/chapters.json"
check "a cleartext chapters URL is refused" '.ok' 'false'

section "Credentials"
# The Podcast Index key and secret must never reach argv: /proc/<pid>/cmdline
# is world-readable, so an argument is legible to every other account on the
# machine.
if node -e '
const M = require(process.argv[1])
const argv = M.searchCommand("/d/", "syntax", "SECRETKEY", "SECRETVALUE").join(" ")
process.exit(/SECRETKEY|SECRETVALUE/.test(argv) ? 1 : 0)
' "$PLUGIN/Model.js" 2>/dev/null; then
  ok "the search command carries no credentials on argv"
else
  bad "the search command carries no credentials on argv" "$(node -e 'console.log(require(process.argv[1]).searchCommand("/d/","syntax","SECRETKEY","SECRETVALUE").join(" "))' "$PLUGIN/Model.js" 2>/dev/null)"
fi

ITUNES="https://itunes.apple.com/search?term=anything&media=podcast&entity=podcast&limit=25"
routes "{\"$ITUNES\": {\"fixture\": \"itunes-search.json\"}}"
OUT="$(printf 'notarealkey123\nnotarealsecret456\n' | python3 "$SCRIPT" search --auth-stdin -- "anything" 2>/dev/null)"
check "credentials are read from stdin" '.ok' 'true'
check "…and an unreachable Podcast Index falls back to iTunes" '.source' 'itunes'
check "…saying why" '.note | test("Podcast Index")' 'true'
check "results without a feed URL are dropped" '.results | length' '1'
check "a result keeps its title" '.results[0].title' 'Test Show'

run search "anything"
check "search works with no credentials at all" '.source' 'itunes'

# ------------------------------------------------------------------ artwork

section "Artwork cache"
while read -r key value; do
  case "$key" in
    over-cap-before)  [[ $value == True ]] && ok "the fixture really does exceed the cap" || bad "the fixture really does exceed the cap" ;;
    under-cap-after)  [[ $value == True ]] && ok "pruning brings the cache under the cap" || bad "pruning brings the cache under the cap" ;;
    kept-newest)      [[ $value == True ]] && ok "…keeping the most recently used artwork" || bad "…keeping the most recently used artwork" ;;
    dropped-oldest)   [[ $value == True ]] && ok "…and evicting the least" || bad "…and evicting the least" ;;
  esac
done < <(python3 - "$SCRIPT" "$OMARCHY_PODCASTS_DIR" <<'PYEOF'
import importlib.util, os, sys
os.environ["OMARCHY_PODCASTS_DIR"] = sys.argv[2]
spec = importlib.util.spec_from_file_location("pc", sys.argv[1])
pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)

os.makedirs(pc.ART_DIR, exist_ok=True)
chunk = b"x" * (1024 * 1024)
for n in range(60):
    path = os.path.join(pc.ART_DIR, "fill%02d.jpg" % n)
    with open(path, "wb") as handle:
        handle.write(chunk)
    os.utime(path, (n, n))
before = sum(os.path.getsize(os.path.join(pc.ART_DIR, f)) for f in os.listdir(pc.ART_DIR))
pc.prune_art_cache()
after = sum(os.path.getsize(os.path.join(pc.ART_DIR, f)) for f in os.listdir(pc.ART_DIR))
survivors = os.listdir(pc.ART_DIR)
print("over-cap-before", before > pc.ART_CACHE_BYTES)
print("under-cap-after", after <= pc.ART_CACHE_BYTES)
print("kept-newest", "fill59.jpg" in survivors)
print("dropped-oldest", "fill00.jpg" not in survivors)
PYEOF
)

# -------------------------------------------------------------- notifications

section "Notifications"
: > "$WORK/notifications.log"
run notify "A Show" "An episode" --icon "/etc/passwd"
if grep -q '/etc/passwd' "$WORK/notifications.log"; then
  bad "an icon outside the artwork cache is not passed through" "$(cat "$WORK/notifications.log")"
else
  ok "an icon outside the artwork cache is not passed through"
fi
if grep -q 'An episode' "$WORK/notifications.log"; then
  ok "the notification still carries the episode title"
else
  bad "the notification still carries the episode title" "$(cat "$WORK/notifications.log")"
fi

# ------------------------------------------------------------------ Model.js

# Model.js is plain JS behind a `module.exports` guard, so node can exercise
# the panel's own logic. Node is a test-time convenience only — nothing at
# runtime needs it — so this section is skipped rather than failed when it is
# not installed.
section "Panel logic (Model.js)"
if ! command -v node >/dev/null 2>&1; then
  printf '  \033[33m-\033[0m skipped: node is not installed\n'
else
while IFS=$'\t' read -r verdict name detail; do
  [[ -z "${verdict:-}" ]] && continue
  if [[ "$verdict" == "PASS" ]]; then ok "$name"; else bad "$name" "$detail"; fi
done < <(node -e '
const Model = require(process.argv[1])
const out = []
const expect = (name, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want)
  out.push([g === w ? "PASS" : "FAIL", name, `want ${w} got ${g}`])
}

// A pasted URL must never be mistaken for a search term, or search-as-you-type
// would subscribe people to half-typed addresses.
expect("a URL is recognised", Model.looksLikeUrl("https://a.example/f.xml"), true)
expect("a search term is not a URL", Model.looksLikeUrl("mostly technical"), false)
expect("a bare host is not a URL", Model.looksLikeUrl("example.com/feed"), false)

expect("trailing slashes do not change a feed", Model.sameFeed("https://a.example/f/", "https://a.example/f"), true)
expect("host case does not change a feed", Model.sameFeed("HTTPS://A.example/f", "https://a.example/f"), true)
expect("different feeds stay different", Model.sameFeed("https://a.example/f", "https://b.example/f"), false)
expect("an empty feed matches nothing", Model.sameFeed("", ""), false)

const shows = [
  { id: "1", title: "Syntax - Tasty Web Development Treats", feed: "https://feeds.megaphone.fm/syntax" },
  { id: "2", title: "Mostly Technical", feed: "https://feeds.transistor.fm/moved-here" }
]
const results = [
  { title: "Syntax - Tasty Web Development Treats", feed: "https://feeds.megaphone.fm/syntax/" },
  { title: "Mostly Technical", feed: "https://feeds.transistor.fm/mostly-technical" },
  { title: "SYNTAX", feed: "https://other.example/syntax" }
]
const fresh = Model.unsubscribedResults(results, shows)
expect("a subscribed feed is not offered again", fresh.length, 1)
expect("…and it is the genuinely new one that survives", fresh[0].title, "SYNTAX")
expect("a moved feed is matched on its title", Model.unsubscribedResults(
  [{ title: "Mostly Technical", feed: "https://feeds.transistor.fm/mostly-technical" }], shows).length, 0)
expect("with nothing subscribed everything is new", Model.unsubscribedResults(results, []).length, 3)
expect("an empty result set stays empty", Model.unsubscribedResults([], shows).length, 0)

expect("shows filter on title", Model.filterShows(shows, "syntax").length, 1)
expect("shows filter is case-insensitive", Model.filterShows(shows, "MOSTLY").length, 1)
expect("an empty filter keeps everything", Model.filterShows(shows, "").length, 2)

expect("a per-show speed wins", Model.speedFor({ speed: 1.6 }, 1.0), 1.6)
expect("…and the default fills in otherwise", Model.speedFor({ speed: 0 }, 1.4), 1.4)
expect("speed is clamped", Model.speedFor({ speed: 9 }, 1.0), 3)

expect("clock under an hour", Model.clockLabel(125), "2:05")
expect("clock over an hour", Model.clockLabel(3725), "1:02:05")
expect("duration in minutes", Model.durationLabel(600), "10 min")
expect("duration in hours", Model.durationLabel(3900), "1 hr 5 min")
expect("time remaining reads as remaining", Model.remainingLabel({ duration: 600, pos: 120 }), "8 min left")

const chapters = [{ start: 0 }, { start: 120 }, { start: 300 }]
expect("the chapter at a position", Model.chapterAt(chapters, 130), 1)
expect("…before the first chapter", Model.chapterAt([{ start: 30 }], 10), -1)
expect("…and past the last", Model.chapterAt(chapters, 9999), 2)

for (const [verdict, name, detail] of out) {
  console.log([verdict, name, verdict === "PASS" ? "" : detail].join("\t"))
}
' "$PLUGIN/Model.js")
fi

# -------------------------------------------------------------------- summary

printf '\n'
if (( FAIL == 0 )); then
  printf '\033[32m%d checks passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
exit 1
