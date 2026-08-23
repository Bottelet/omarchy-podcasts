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
expect("entities unescaped", pc.plain_text("a &amp; b"), "a & b")

# Stripping tags before decoding entities let an escaped tag sail through as
# text and come back out as live markup — which matters wherever the result
# leaves QML's PlainText, notably a notification body.
expect("an escaped tag cannot be reassembled",
       pc.plain_text('&lt;img src="http://attacker.example/p.png"&gt;'), "")
expect("a double-escaped tag cannot either",
       pc.plain_text('&amp;lt;img src=x&amp;gt;'), "")
expect("an enormous tag is still stripped whole",
       pc.plain_text("<a" + "x" * 4100 + ">hi"), "hi")
expect("notification markup is escaped", pc.notify_safe("<b>&</b>"), "&lt;b&gt;&amp;&lt;/b&gt;")
expect("an empty body is not a DTD", pc.has_doctype(b""), False)
expect("a whitespace body is not a DTD", pc.has_doctype(b"   \n"), False)
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

# Every mutating command ends in save_shows(), so a load that drops a record
# deletes a subscription for good the next time anything is written. A bad id
# is repaired; only a record with no feed at all is beyond saving.
import tempfile, os as _os
_fd, _sp = tempfile.mkstemp(suffix=".json")
_os.write(_fd, b'[{"id":"../../etc/passwd","feed":"https://a.example/f.xml","title":"Kept"},'
               b'{"id":"6425ecf474e9","feed":"https://b.example/f.xml","title":"Fine"},'
               b'{"title":"No feed at all"}]')
_os.close(_fd)
_real = pc.SHOWS_FILE
pc.SHOWS_FILE = _sp
_loaded = pc.load_shows()
pc.SHOWS_FILE = _real
_os.unlink(_sp)
expect("a bad id does not delete the subscription", len(_loaded), 2)
expect("…it is repaired to a real one", pc.ID_RE.match(_loaded[0]["id"]) is not None, True)
expect("…and the good record is untouched", _loaded[1]["id"], "6425ecf474e9")

# Two records repaired from the same feed would share an id, and then an
# episodes file, each overwriting the other every poll.
_fd, _sp2 = tempfile.mkstemp(suffix=".json")
_os.write(_fd, b'[{"id":"bad!","feed":"https://a.example/f.xml"},'
               b'{"id":"worse/","feed":"https://a.example/f.xml"}]')
_os.close(_fd)
pc.SHOWS_FILE = _sp2
_dup = pc.load_shows()
pc.SHOWS_FILE = _real
_os.unlink(_sp2)
expect("a repair cannot collide two shows onto one id", len(_dup), 1)

# Podcast Index credentials are pinned to an alphabet before they reach a
# curl config line.
expect("a normal credential is accepted", pc.CREDENTIAL_RE.match("AbC123_-xyz") is not None, True)
expect("a quote-bearing credential is not", pc.CREDENTIAL_RE.match('ab"cd efgh') is not None, False)
expect("a newline-bearing credential is not", pc.CREDENTIAL_RE.match("abcdefgh\nX") is not None, False)

expect("XML attributes escaped", pc.xml_attr('a"b&c<d'), '"a&quot;b&amp;c&lt;d"')

# Channel metadata must come from direct children of <channel> only: feeds
# carry containers at that level with their own <title> — Podcasting 2.0's
# <podcast:liveItem> is one, and it named a real show after a live-stream
# announcement until the parse was depth-gated.
_fd, _p = tempfile.mkstemp(suffix=".xml")
_os.write(_fd, b"""<?xml version="1.0"?>
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
     xmlns:podcast="https://podcastindex.org/namespace/1.0" version="2.0">
  <channel>
    <podcast:liveItem><title>A Live Stream</title></podcast:liveItem>
    <image><title>Artwork Caption</title><url>https://example.com/a.jpg</url></image>
    <title>The Real Show</title>
    <item><title>An Episode</title>
      <enclosure url="https://example.com/e.mp3" type="audio/mpeg"/></item>
  </channel>
</rss>""")
_os.close(_fd)
_show, _items, _err = pc.parse_feed(_p, "abc123")
_os.unlink(_p)
expect("a container's title does not name the show", _show["title"], "The Real Show")

# A decoy <channel>: RDF nests one inside <item>, and an empty one placed
# first should not shadow the real one.
_fd, _dc = tempfile.mkstemp(suffix=".xml")
_os.write(_fd, b"""<?xml version="1.0"?><rss version="2.0"><channel/>
<channel><item><channel><title>Decoy</title></channel>
<title>E</title><enclosure url="https://e.example/a.mp3"/></item>
<title>Real Show</title></channel></rss>""")
_os.close(_fd)
_decoyed, _ditems, _ = pc.parse_feed(_dc, "abc123")
_os.unlink(_dc)
expect("a decoy channel does not name the show", _decoyed["title"], "Real Show")
expect("…and the real item still parses", len(_ditems), 1)

_HEAD = ('<?xml version="1.0"?><rss version="2.0" '
         'xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>')
_ITEM = '<item><title>E</title><enclosure url="https://e.example/a.mp3"/></item>'

def _parse(body):
    fd, path = tempfile.mkstemp(suffix=".xml")
    _os.write(fd, (_HEAD + body + _ITEM + "</channel></rss>").encode())
    _os.close(fd)
    try:
        show, items, err = pc.parse_feed(path, "abc123")
        return show or {}
    finally:
        _os.unlink(path)

# Order of appearance is not preference: real feeds put the legacy tag first.
expect("itunes:image beats a preceding RSS image",
       _parse('<title>S</title><image><url>https://a/small.jpg</url></image>'
              '<itunes:image href="https://a/big.jpg"/>')["artwork"], "https://a/big.jpg")
expect("RSS image is still used alone",
       _parse('<title>S</title><image><url>https://a/small.jpg</url></image>')["artwork"],
       "https://a/small.jpg")
expect("description beats a preceding itunes:summary",
       _parse('<title>S</title><itunes:summary>SUM</itunes:summary>'
              '<description>REAL</description>')["description"], "REAL")
expect("itunes:summary is still used alone",
       _parse('<title>S</title><itunes:summary>SUM</itunes:summary>')["description"], "SUM")
expect("itunes:author beats a preceding bare author",
       _parse('<title>S</title><author>webmaster@a.example</author>'
              '<itunes:author>Real Host</itunes:author>')["author"], "Real Host")
expect("itunes:owner fills in for a missing itunes:author",
       _parse('<title>S</title><itunes:owner><itunes:name>Owner</itunes:name>'
              '</itunes:owner>')["author"], "Owner")
expect("a bare author is a last resort",
       _parse('<title>S</title><author>webmaster@a.example</author>')["author"],
       "webmaster@a.example")

# Channel metadata is claimed by parentage, not by depth. Matching on depth
# let a feed put its <title> and its <itunes:image href> in a sibling
# container outside <channel> and have both taken — and that artwork URL is
# then fetched by the helper.
_fd, _hj = tempfile.mkstemp(suffix=".xml")
_os.write(_fd, b"""<?xml version="1.0"?>
<rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd" version="2.0">
  <channel><item><title>E</title><enclosure url="https://e.example/a.mp3"/></item></channel>
  <other><title>HIJACKED</title><itunes:image href="https://evil.example/x.jpg"/></other>
</rss>""")
_os.close(_fd)
_hijacked, _hitems, _ = pc.parse_feed(_hj, "abc123")
_os.unlink(_hj)
expect("a sibling container cannot name the show", _hijacked["title"], "")
expect("…nor choose the artwork we fetch", _hijacked["artwork"], "")
expect("…and the real channel's item still parses", len(_hitems), 1)

# Bounding a metadata element's children is a truncation cliff: del parent[:]
# destroys the text of everything it removes. At 64 a description written
# with inline markup fell from 255 characters to 5, silently. The bound has
# to sit far beyond anything real — and plain_text's own 900-character cap
# bites long before it.
def _desc(n):
    inner = "".join("<b>w%d</b> " % i for i in range(n))
    return _parse("<title>S</title><description>start %s end</description>" % inner)["description"]

expect("inline markup survives past the old bound", "end" in _desc(65), True)
expect("…and well past it", len(_desc(200)) >= 800, True)
expect("a padded image still yields its artwork",
       _parse('<title>S</title><image><url>https://a/i.jpg</url>'
              + "".join("<x%d/>" % i for i in range(100)) + '</image>')["artwork"],
       "https://a/i.jpg")
expect("the cliff is far beyond any real feed", pc.MAX_METADATA_CHILDREN >= 1000, True)
expect("…and the episode still parses", len(_items), 1)
expect("…and RSS image artwork is still found", _show["artwork"], "https://example.com/a.jpg")
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

section "Addresses a feed may not reach"
# A feed can point its artwork, chapters or its own URL at something only
# this machine can reach. Loopback and link-local (which includes the cloud
# metadata endpoint) are refused; private LAN ranges are deliberately not,
# because a self-hosted podcast server is a normal thing to subscribe to.
run add "https://127.0.0.1/feed.xml"
check "loopback is refused" '.error | test("may reach")' 'true'
run add "https://[::1]/feed.xml"
check "IPv6 loopback is refused" '.error | test("may reach")' 'true'
run add "https://169.254.169.254/feed.xml"
check "the metadata endpoint is refused" '.error | test("may reach")' 'true'
run chapters "https://127.0.0.1/chapters.json"
check "…and chapters cannot reach it either" '.error | test("may reach")' 'true'

# A name is judged by the address curl actually connected to, so a host
# pointed at loopback is caught after the fetch rather than before it.
routes "{\"https://sneaky.example/feed.xml\": {\"fixture\": \"full.xml\", \"remote_ip\": \"127.0.0.1\"}}"
run add "https://sneaky.example/feed.xml"
check "a name pointed at loopback is refused" '.error | test("may not reach")' 'true'

routes "{\"https://sneaky.example/feed.xml\": {\"fixture\": \"full.xml\", \"remote_ip\": \"169.254.169.254\"}}"
run add "https://sneaky.example/feed.xml"
check "…as is one pointed at the metadata endpoint" '.error | test("may not reach")' 'true'

# The obvious way around a check on the starting URL: answer 301 to it.
routes "{\"https://redirector.example/feed.xml\": {\"status\": 301, \"location\": \"https://127.0.0.1/feed.xml\"}}"
run add "https://redirector.example/feed.xml"
check "a redirect into loopback is refused" '.error | test("may not reach")' 'true'

# And a perfectly ordinary feed is still fetched.
routes "{\"https://fine.example/feed.xml\": {\"fixture\": \"full.xml\", \"remote_ip\": \"203.0.113.10\"}}"
run add "https://fine.example/feed.xml"
check "an ordinary feed is unaffected" '.ok' 'true'

# A relative Location is permitted by RFC 9110 and is everywhere in practice.
# It has no hostname, and judging it like a URL rejected every ordinary
# redirect — telling the user their feed was malicious.
routes "{\"https://rel.example/feed\": {\"status\": 301, \"location\": \"/moved/feed.xml\"},
         \"/moved/feed.xml\": {\"fixture\": \"full.xml\", \"remote_ip\": \"203.0.113.10\"}}"
run add "https://rel.example/feed"
check "an absolute-path redirect is followed" '.ok' 'true'

routes "{\"https://rel2.example/feed\": {\"status\": 302, \"location\": \"feed.xml\"},
         \"feed.xml\": {\"fixture\": \"full.xml\", \"remote_ip\": \"203.0.113.10\"}}"
run add "https://rel2.example/feed"
check "…as is a bare relative one" '.ok' 'true'

# A proxy makes remote_ip the proxy's address, and privoxy, mitmproxy and
# corporate MITM agents all sit on loopback. Judging it would block
# everything; the guarantee is dropped there rather than the plugin.
routes "{\"https://proxied.example/feed.xml\": {\"fixture\": \"full.xml\", \"remote_ip\": \"127.0.0.1\"}}"
run add "https://proxied.example/feed.xml"
check "without a proxy, a loopback connection is refused" '.ok' 'false'
routes "{\"https://proxied.example/feed.xml\": {\"fixture\": \"full.xml\", \"remote_ip\": \"127.0.0.1\", \"proxy_used\": \"1\"}}"
OUT="$(http_proxy=http://127.0.0.1:8118 python3 "$SCRIPT" add -- "https://proxied.example/feed.xml" 2>/dev/null)"
check "behind a proxy, the same fetch succeeds" '.ok' 'true'

# A proxy variable being set is not the same as it being used: no_proxy makes
# curl connect directly, and then the address it reports is the true origin
# and free to check.
python3 "$SCRIPT" remove -- "$(python3 "$SCRIPT" shows | jq -r '.shows[] | select(.feed | test("proxied")) | .id')" >/dev/null 2>&1
routes "{\"https://proxied.example/feed.xml\": {\"fixture\": \"full.xml\", \"remote_ip\": \"127.0.0.1\", \"proxy_used\": \"0\"}}"
OUT="$(http_proxy=http://127.0.0.1:8118 python3 "$SCRIPT" add -- "https://proxied.example/feed.xml" 2>/dev/null)"
check "…but a direct connection is still judged" '.ok' 'false'

while IFS=$'\t' read -r verdict name detail; do
  [[ -z "${verdict:-}" ]] && continue
  if [[ "$verdict" == "PASS" ]]; then ok "$name"; else bad "$name" "$detail"; fi
done < <(python3 - "$SCRIPT" <<'PYINNER'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pc", sys.argv[1])
pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
cases = [
    ("a name is judged after the connection, not before",
     pc.address_blocked("localhost"), False),
    ("…and the connected address decides", pc.connected_blocked("127.0.0.1"), True),
    ("…including the metadata endpoint", pc.connected_blocked("169.254.169.254"), True),
    ("…while a public one is fine", pc.connected_blocked("93.184.216.34"), False),
    # ::ffff:127.0.0.1 is loopback wearing a hat: it parses as IPv6, so a
    # check against 127.0.0.0/8 never matched it, and curl reads it back the
    # same way, so neither stage caught it. 6to4 and Teredo embed one too.
    ("IPv4-mapped loopback is blocked", pc.address_blocked("::ffff:127.0.0.1"), True),
    ("…in its hex spelling too", pc.address_blocked("::ffff:7f00:1"), True),
    ("…and the mapped metadata endpoint", pc.address_blocked("::ffff:169.254.169.254"), True),
    ("6to4 wrapping loopback is blocked", pc.address_blocked("2002:7f00:0001::"), True),
    ("multicast is blocked", pc.address_blocked("224.0.0.1"), True),
    ("reserved space is blocked", pc.address_blocked("240.0.0.1"), True),
    ("a mapped LAN address is still allowed", pc.address_blocked("::ffff:192.168.1.5"), False),
    ("a mapped public address is still allowed", pc.address_blocked("::ffff:93.184.216.34"), False),
    ("IPv6 unique-local is still allowed", pc.address_blocked("fd00::1"), False),
    ("a public IPv6 address is allowed", pc.address_blocked("2606:4700::1111"), False),
    # A transfer that succeeded without saying where it connected is unknown,
    # not safe — the earlier bool() guard inverted exactly that case.
    ("a direct connection is judged even with a proxy set",
     pc.went_through_proxy("0"), False),
    ("…and a proxied one is not", pc.went_through_proxy("1"), True),
    ("an unreported connection fails closed", pc.connected_blocked(""), True),
    ("…as does an unparseable one", pc.connected_blocked("garbage"), True),
    ("a relative Location is not a host change", pc.hop_blocked("/moved/feed.xml"), False),
    ("…nor is a bare relative one", pc.hop_blocked("feed.xml"), False),
    ("an absolute Location into loopback is", pc.hop_blocked("https://127.0.0.1/f.xml"), True),
    ("a LAN address is still allowed", pc.address_blocked("192.168.1.50"), False),
    ("…as is the 10/8 range", pc.address_blocked("10.0.0.4"), False),
    ("…and 172.16/12", pc.address_blocked("172.16.5.5"), False),
    ("a public address is allowed", pc.address_blocked("93.184.216.34"), False),
    ("0.0.0.0 is refused", pc.address_blocked("0.0.0.0"), True),
    ("an empty host is refused", pc.address_blocked(""), True),
    ("an unknown name is left to curl", pc.address_blocked("no-such-host.invalid"), False),
]
for name, got, want in cases:
    print(("PASS" if got == want else "FAIL") + "\t" + name + "\t" +
          ("" if got == want else "want %r got %r" % (want, got)))
PYINNER
)

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

section "State files that will not read"
# load_json returns its default on any error, which is right for a cache and
# catastrophic for state: every mutating command ends in a full rewrite, so a
# phantom empty subscription list gets persisted. With the orphan sweep added
# later, one unreadable shows.json destroyed the subscriptions, every episode
# file and the whole queue — and reported ok:true.
cp "$OMARCHY_PODCASTS_DIR/shows.json" "$WORK/shows.bak"
BEFORE_EPISODES="$(ls "$OMARCHY_PODCASTS_DIR/episodes" | wc -l)"

printf '{"not":"a list"}' > "$OMARCHY_PODCASTS_DIR/shows.json"
run refresh
check "a wrongly-shaped subscriptions file stops the command" '.ok' 'false'
run library
check "…and every read of it too" '.ok' 'false'

printf 'this is not json' > "$OMARCHY_PODCASTS_DIR/shows.json"
run refresh
check "a corrupt subscriptions file stops the command" '.ok' 'false'
check "…and says so in words" '.error | test("corrupt")' 'true'

chmod 000 "$OMARCHY_PODCASTS_DIR/shows.json"
run refresh
check "an unreadable subscriptions file stops the command" '.ok' 'false'
chmod 600 "$OMARCHY_PODCASTS_DIR/shows.json"

# State files sit where the user's own processes can write, so neither their
# size nor their type is ours to trust.
python3 -c "
import json, os, sys
json.dump([{'id': 'a' * 12, 'feed': 'https://x/' + 'p' * 900}] * 40000,
          open(os.environ['OMARCHY_PODCASTS_DIR'] + '/shows.json', 'w'))"
run shows
check "an oversized subscriptions file is refused" '.ok' 'false'
check "…and says it was the size, not corruption" '.error | test("larger than")' 'true'

rm -f "$OMARCHY_PODCASTS_DIR/shows.json"
ln -s /etc/passwd "$OMARCHY_PODCASTS_DIR/shows.json"
run shows
check "a symlink pre-placed at a state file is not followed" '.ok' 'false'
rm -f "$OMARCHY_PODCASTS_DIR/shows.json"

# A cap that truncates is a cap that deletes: the next command to end in a
# full rewrite persists the shortened list.
python3 -c "
import json, os
json.dump([{'id': '%012x' % i, 'feed': 'https://f%d.example/rss' % i}
           for i in range(2005)],
          open(os.environ['OMARCHY_PODCASTS_DIR'] + '/shows.json', 'w'))"
run shows
check "more subscriptions than the cap is refused, not truncated" '.ok' 'false'
BEFORE_ROWS="$(python3 -c "
import json, os
print(len(json.load(open(os.environ['OMARCHY_PODCASTS_DIR'] + '/shows.json'))))")"
if [[ "$BEFORE_ROWS" == "2005" ]]; then
  ok "…and every one of them is still on disk"
else
  bad "…and every one of them is still on disk" "$BEFORE_ROWS remain"
fi

# O_NOFOLLOW only refuses a link at the final component; a link at the state
# directory sends every read and write somewhere else, and makedirs follows
# it without complaint.
HIJACK="$WORK/hijack-target"
mkdir -p "$HIJACK"
ln -s "$HIJACK" "$WORK/hijack-link"
OUT="$(OMARCHY_PODCASTS_DIR="$WORK/hijack-link" python3 "$SCRIPT" init 2>/dev/null)"
check "a symlinked state directory is refused" '.ok' 'false'
if [[ -z "$(ls -A "$HIJACK")" ]]; then
  ok "…and nothing was written through it"
else
  bad "…and nothing was written through it" "$(ls -A "$HIJACK")"
fi

if [[ "$(ls "$OMARCHY_PODCASTS_DIR/episodes" | wc -l)" == "$BEFORE_EPISODES" ]]; then
  ok "…and none of this deleted a single episode file"
else
  bad "…and none of this deleted a single episode file" \
      "$BEFORE_EPISODES before, $(ls "$OMARCHY_PODCASTS_DIR/episodes" | wc -l) after"
fi

cp "$WORK/shows.bak" "$OMARCHY_PODCASTS_DIR/shows.json"
run shows
check "a restored file reads normally again" '.ok' 'true'

# The temporary name a write goes through must be one nobody could have
# pre-placed a symlink at.
run refresh
if compgen -G "$OMARCHY_PODCASTS_DIR/*.tmp.*" > /dev/null; then
  bad "writes leave no predictable temporary name" "$(ls "$OMARCHY_PODCASTS_DIR")"
else
  ok "writes leave no predictable temporary name"
fi

# A failed write must not leave its temp behind: nothing swept ROOT or
# episodes/, so every failure was permanent litter in the state directory.
while IFS=$'\t' read -r verdict name detail; do
  [[ -z "${verdict:-}" ]] && continue
  if [[ "$verdict" == "PASS" ]]; then ok "$name"; else bad "$name" "$detail"; fi
done < <(python3 - "$SCRIPT" "$OMARCHY_PODCASTS_DIR" <<'PYINNER'
import glob, importlib.util, os, sys
os.environ["OMARCHY_PODCASTS_DIR"] = sys.argv[2]
spec = importlib.util.spec_from_file_location("pc", sys.argv[1])
pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)

root = sys.argv[2]
try:
    pc.save_json(os.path.join(root, "probe.json"), {"x": object()})
except BaseException:
    pass
left = glob.glob(os.path.join(root, ".write-*"))
print("PASS\ta write that cannot serialise leaves no temp behind" if not left
      else "FAIL\ta write that cannot serialise leaves no temp behind\t%s" % left)

# And the sweep clears anything a killed run left.
stale = os.path.join(root, ".write-stale.tmp")
open(stale, "w").close()
os.utime(stale, (0, 0))
pc.sweep_tmp()
print("PASS\t…and a stale one is swept" if not os.path.exists(stale)
      else "FAIL\t…and a stale one is swept\tstill there")
PYINNER
)

# An absent file is a first run, not a fault.
mv "$OMARCHY_PODCASTS_DIR/shows.json" "$WORK/shows.away"
run shows
check "an absent subscriptions file is simply empty" '.shows | length' '0'
mv "$WORK/shows.away" "$OMARCHY_PODCASTS_DIR/shows.json"

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

head -c 5000000 /dev/zero | tr '\0' 'x' > "$WORK/huge.opml"
run opml-import "$WORK/huge.opml"
check "an oversized OPML file is refused" '.error | test("larger than")' 'true'

# A read that fails after the descriptor has been handed to a file object
# must not close it twice — the number can be reused by then, and the second
# close lands on someone else's file.
while IFS=$'\t' read -r verdict name detail; do
  [[ -z "${verdict:-}" ]] && continue
  if [[ "$verdict" == "PASS" ]]; then ok "$name"; else bad "$name" "$detail"; fi
done < <(python3 - "$SCRIPT" <<'PYINNER'
import importlib.util, os, sys, tempfile
spec = importlib.util.spec_from_file_location("pc", sys.argv[1])
pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)

before = len(os.listdir("/proc/self/fd"))
kinds = set()
for _ in range(200):
    d = tempfile.mkdtemp()
    try:
        pc.read_bounded(d, 1000)          # opens, then read() fails
    except Exception as exc:
        kinds.add(type(exc).__name__)
    os.rmdir(d)
    try:
        pc.read_bounded("/nonexistent-path-%d" % _, 1000)
    except Exception as exc:
        kinds.add(type(exc).__name__)
after = len(os.listdir("/proc/self/fd"))
print("PASS\tfailed reads leak no descriptors" if after <= before
      else "FAIL\tfailed reads leak no descriptors\t%d -> %d" % (before, after))
print("PASS\t…and report the real error, not a bad descriptor"
      if "BadFileDescriptor" not in kinds and "OSError" not in kinds
      else "FAIL\t…and report the real error, not a bad descriptor\t%s" % kinds)
PYINNER
)

# Re-importing used to force a full refetch of every subscription, ignoring
# their validators, and then throw the result away as "skipped".
: > "$WORK/curl.log"
cat > "$WORK/bin/curl" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WORK/curl.log"
exec python3 "$HERE/fake-curl.py" "\$@"
EOF
chmod +x "$WORK/bin/curl"
run opml-import "$HERE/fixtures/subs.opml"
check "a repeat import adds nothing" '.added' '0'
if grep -q "example.com" "$WORK/curl.log"; then
  bad "…and does not refetch what it already has" "$(head -1 "$WORK/curl.log")"
else
  ok "…and does not refetch what it already has"
fi

# An episodes file must never outlive the subscription that named it: the
# import writes both under one lock, and a sweep clears anything historical.
touch "$OMARCHY_PODCASTS_DIR/episodes/deadbeefdead.json"
run refresh
if [[ -e "$OMARCHY_PODCASTS_DIR/episodes/deadbeefdead.json" ]]; then
  bad "an orphaned episodes file is swept" "still present after refresh"
else
  ok "an orphaned episodes file is swept"
fi
SURVIVOR="$(python3 "$SCRIPT" shows | jq -r '.shows[0].id')"
if [[ -e "$OMARCHY_PODCASTS_DIR/episodes/$SURVIVOR.json" ]]; then
  ok "…while a live show keeps its episodes"
else
  bad "…while a live show keeps its episodes" "$SURVIVOR.json was removed"
fi

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

section "Parser memory"
# clear() leaves an element parented, so a "cleared" subtree still costs a
# slot in its parent for the rest of the parse. Sibling floods peaked at
# 302 MB and nested ones at 608 MB before parents were detached too and a
# depth ceiling was added. Every shape below is an adversarial feed under
# the 15 MB download cap.
while read -r key value; do
  case "$key" in
    siblings)   [[ $value == True ]] && ok "a flood of sibling elements stays flat" || bad "a flood of sibling elements stays flat" ;;
    outside)    [[ $value == True ]] && ok "…as does one outside the channel" || bad "…as does one outside the channel" ;;
    items)      [[ $value == True ]] && ok "…and a flood of items" || bad "…and a flood of items" ;;
    deep)       [[ $value == True ]] && ok "deep nesting is refused rather than absorbed" || bad "deep nesting is refused rather than absorbed" ;;
    contained)  [[ $value == True ]] && ok "…including nesting inside a container" || bad "…including nesting inside a container" ;;
    elements)   [[ $value == True ]] && ok "an absurd element count is refused" || bad "an absurd element count is refused" ;;
    container)  [[ $value == True ]] && ok "padding inside a channel-level container stays flat" || bad "padding inside a channel-level container stays flat" ;;
    padded-image) [[ $value == True ]] && ok "…as does padding inside <image>" || bad "…as does padding inside <image>" ;;
    real)       [[ $value == True ]] && ok "…while a normal feed still parses in full" || bad "…while a normal feed still parses in full" ;;
  esac
done < <(python3 - "$SCRIPT" "$WORK" "$HERE" <<'PYINNER'
import importlib.util, os, resource, sys
spec = importlib.util.spec_from_file_location("pc", sys.argv[1])
pc = importlib.util.module_from_spec(spec); spec.loader.exec_module(pc)
work, here = sys.argv[2], sys.argv[3]

def run(name, body):
    path = os.path.join(work, "shape-%s.xml" % name)
    with open(path, "wb") as h:
        h.write(b'<?xml version="1.0"?>' + body)
    base = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    show, items, err = pc.parse_feed(path, "abc123")
    grew = (resource.getrusage(resource.RUSAGE_SELF).ru_maxrss - base) / 1024.0
    os.unlink(path)
    return grew, err

CH = b'<rss><channel><title>t</title>'
grew, err = run("siblings", CH + b"<a/>" * 400000 + b"</channel></rss>")
print("siblings", grew < 100)
grew, err = run("outside", b'<rss>' + b"<a/>" * 400000 + b'<channel><title>t</title></channel></rss>')
print("outside", grew < 100)
grew, err = run("items", CH + b"<item><title>e</title></item>" * 200000 + b"</channel></rss>")
print("items", grew < 100)
grew, err = run("deep", CH + b"<a>" * 300000 + b"</a>" * 300000 + b"</channel></rss>")
print("deep", "nested" in (err or "") and grew < 100)
grew, err = run("contained", CH + b"<box>" + b"<a>" * 200000 + b"</a>" * 200000 + b"</box></channel></rss>")
print("contained", "nested" in (err or "") and grew < 100)
grew, err = run("elements", CH + b"<a/>" * (pc.MAX_ELEMENTS + 10) + b"</channel></rss>")
print("elements", "elements" in (err or ""))

# Exempting by depth meant any container sitting at channel level kept every
# child it had, padding included.
grew, err = run("container", CH + b"<foo>" + b"<a/>" * 400000 + b"</foo></channel></rss>")
print("container", grew < 100)
grew, err = run("padded-image", CH + b"<image><url>https://a/i.jpg</url>"
                + b"<a/>" * 400000 + b"</image></channel></rss>")
print("padded-image", grew < 100)

show, items, err = pc.parse_feed(os.path.join(here, "fixtures", "full.xml"), "abc123")
print("real", err == "" and show["title"] == "Test Show" and len(items) == 6)
PYINNER
)

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

# ------------------------------------------------- Model.js -> helper wiring

# The two halves were tested apart and agreed on paper while disagreeing in
# practice: an `--` terminator that argparse accepts after a positional is a
# hard error on the subcommands that declare none, and every read-only call
# the panel makes is one of those. This runs the argv Model.js actually
# builds through the real helper and insists on JSON coming back.
section "Model.js commands against the helper"
if ! command -v node >/dev/null 2>&1; then
  printf '  \033[33m-\033[0m skipped: node is not installed\n'
else
  ITUNES_WIRE="https://itunes.apple.com/search?term=wiring&media=podcast&entity=podcast&limit=25"
  routes "{\"$ITUNES_WIRE\": {\"fixture\": \"itunes-search.json\"}}"
  SOME_SHOW="$(python3 "$SCRIPT" shows | jq -r '.shows[0].id // "deadbeef1234"')"

  while IFS=$'\t' read -r label argv_json; do
    [[ -z "${label:-}" ]] && continue
    mapfile -t ARGV < <(printf '%s' "$argv_json" | jq -r '.[]')
    reply="$("${ARGV[@]}" 2>/dev/null)"
    if printf '%s' "$reply" | jq -e 'has("ok")' >/dev/null 2>&1; then
      ok "$label answers with JSON"
    else
      bad "$label answers with JSON" "got: $(printf '%s' "$reply" | head -c 120)"
    fi
  done < <(node -e '
const M = require(process.argv[1])
const d = process.argv[2] + "/"
const show = process.argv[3]
const commands = [
  ["library",      M.libraryCommand(d)],
  ["shows",        M.showsCommand(d)],
  ["init",         M.initCommand(d)],
  ["archive-all",  M.archiveAllCommand(d)],
  ["refresh all",  M.refreshCommand(d, "", false)],
  ["refresh one",  M.refreshCommand(d, show, true)],
  ["episodes",     M.episodesCommand(d, show)],
  ["search",       M.searchCommand(d, "wiring", "", "")],
  ["triage",       M.triageCommand(d, "archive", "0123456789abcdef")],
  ["queue add",    M.queueCommand(d, "add", "0123456789abcdef", {})],
  ["queue move",   M.queueCommand(d, "move", "0123456789abcdef", {delta: -1})],
  ["queue clear",  M.queueCommand(d, "clear", "", {})],
  ["position",     M.positionCommand(d, "0123456789abcdef", 12, 60, {now: true})],
  ["show-set",     M.showSetCommand(d, show, "mode", "inbox")],
  ["chapters",     M.chaptersCommand(d, "https://example.com/chapters.json")],
  ["art",          M.artCommand(d, ["https://example.com/art.jpg"])],
  ["notify",       M.notifyCommand(d, "A show", "An episode")],
  ["opml-export",  M.opmlExportCommand(d, process.argv[4])],
]
for (const [label, argv] of commands) console.log(label + "\t" + JSON.stringify(argv))
' "$PLUGIN/Model.js" "$PLUGIN/scripts" "$SOME_SHOW" "$WORK/wire.opml")
fi

# -------------------------------------------------------------------- summary

printf '\n'
if (( FAIL == 0 )); then
  printf '\033[32m%d checks passed\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[31m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
exit 1
