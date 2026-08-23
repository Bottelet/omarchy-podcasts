#!/usr/bin/env python3
"""Feed, library and state engine for the bottelet.podcasts Omarchy plugin.

Every subcommand prints exactly one JSON object on stdout — {"ok": false,
"error": "..."} on any failure — and exits 0, so the QML side never has to
guess. Nothing this script runs goes through a shell: curl is invoked with an
argv list, and every feed-derived string (enclosure URLs, titles, chapter
URLs) is treated as hostile input.

Why Python and not bash+jq like the sibling plugins: the 9.6 MB Syntax feed
(1,031 episodes) has to be parsed without holding a DOM in memory, and
xml.etree.ElementTree.iterparse does that in the stdlib. See OMARCHY_PLUGIN.md
for the full rationale.
"""

import argparse
import errno
import fcntl
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from urllib.parse import urlencode, urlsplit

# ------------------------------------------------------------------ bounds
#
# Caps exist so a hostile or misbehaving endpoint cannot stream without end
# into this process. They are generous enough for the largest real feeds we
# tested against (Syntax: 9.6 MB).

MAX_FEED_BYTES = 15 * 1024 * 1024
MAX_ART_BYTES = 5 * 1024 * 1024
MAX_JSON_BYTES = 2 * 1024 * 1024
FEED_TIMEOUT = 45
API_TIMEOUT = 20
ART_TIMEOUT = 20
MAX_ITEMS_PER_FEED = 100        # newest N kept per show
MAX_ITEMS_SCANNED = 20000       # hard stop on absurd feeds
MAX_ELEMENTS = 2000000          # ceiling on total elements, junk included
# Detaching frees a subtree once it closes, but a deeply nested document
# closes nothing until the parser reaches the bottom, so the whole descent is
# resident whatever we do on the way out. A depth ceiling is the only thing
# that bounds it. Real feeds nest about six deep; sixty-four is room to
# spare and still refuses 700,000.
MAX_DEPTH = 64
MAX_DESC_CHARS = 700
MAX_CHAPTERS = 400
ART_CACHE_BYTES = 50 * 1024 * 1024
STALE_AFTER_FAILURES = 4
USER_AGENT = "omarchy-podcasts/1.0 (+https://omarchyplugins.com)"

NS = {
    "itunes": "http://www.itunes.com/dtds/podcast-1.0.dtd",
    "podcast": "https://podcastindex.org/namespace/1.0",
    "media": "http://search.yahoo.com/mrss/",
    "content": "http://purl.org/rss/1.0/modules/content/",
}

MODES = ("inbox", "auto", "ignore")


# ------------------------------------------------------------------- paths

def state_dir():
    override = os.environ.get("OMARCHY_PODCASTS_DIR", "").strip()
    if override:
        return os.path.abspath(os.path.expanduser(override))
    base = os.environ.get("XDG_DATA_HOME", "").strip() or os.path.join(
        os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "omarchy-podcasts")


ROOT = state_dir()
EPISODE_DIR = os.path.join(ROOT, "episodes")
ART_DIR = os.path.join(ROOT, "art")
SHOWS_FILE = os.path.join(ROOT, "shows.json")
LIBRARY_FILE = os.path.join(ROOT, "library.json")
LOCK_FILE = os.path.join(ROOT, ".lock")
TMP_DIR = os.path.join(ROOT, "tmp")


def ensure_dirs():
    # Everything here is private to the user: what they subscribe to, how far
    # into each episode they are. 0700 across the board.
    os.umask(0o077)
    for path in (ROOT, EPISODE_DIR, ART_DIR, TMP_DIR):
        try:
            os.makedirs(path, mode=0o700, exist_ok=True)
        except OSError as exc:
            fail("cannot create %s: %s" % (path, exc.strerror))
    try:
        os.chmod(ROOT, 0o700)
    except OSError:
        pass


# An OPML import holds the lock across one network fetch per feed, so a
# concurrent poll can be kept waiting for a while — but a plain flock() waits
# for ever, and a hung helper is a spinner the user cannot clear. Wait, but
# with an end to it.
LOCK_TIMEOUT_SECS = 120


class Lock(object):
    """Single-writer lock. Mutating commands hold it for their whole run."""

    def __init__(self, timeout=LOCK_TIMEOUT_SECS):
        self.handle = None
        self.timeout = timeout

    def __enter__(self):
        self.handle = open(LOCK_FILE, "a+")
        deadline = time.monotonic() + self.timeout
        while True:
            try:
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except OSError as exc:
                if exc.errno not in (errno.EAGAIN, errno.EACCES):
                    self.handle.close()
                    fail("cannot lock state: %s" % exc.strerror)
                if time.monotonic() >= deadline:
                    self.handle.close()
                    fail("another podcast update is still running — try again shortly")
                time.sleep(0.1)

    def __exit__(self, *_exc):
        try:
            fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        finally:
            self.handle.close()


# -------------------------------------------------------------------- i/o

def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":"), ensure_ascii=False))
    sys.stdout.write("\n")
    sys.stdout.flush()
    sys.exit(0)


def fail(message):
    emit({"ok": False, "error": str(message)})


def load_json(path, default):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return default
    return data if isinstance(data, type(default)) else default


def save_json(path, obj):
    tmp = path + ".tmp.%d" % os.getpid()
    try:
        with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600),
                  "w", encoding="utf-8") as handle:
            json.dump(obj, handle, separators=(",", ":"), ensure_ascii=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        fail("cannot write %s: %s" % (os.path.basename(path), exc.strerror))


ID_RE = re.compile(r"^[0-9a-f]{8,32}$")


def load_shows():
    """Subscriptions, repaired rather than filtered.

    Ids are hex digests we generated and the only thing that ever becomes a
    filename, so they are re-checked on the way in rather than trusted
    because of where they came from. But every mutating command ends in
    save_shows(), so a load that silently *drops* a record turns one bad
    field into a permanently deleted subscription the moment anything else
    is written. A record with a usable feed URL is therefore given a correct
    id instead; only one with no feed at all is beyond saving, and losing a
    subscription is a great deal worse than carrying an odd one."""
    shows = load_json(SHOWS_FILE, [])
    out = []
    for show in shows:
        if not isinstance(show, dict):
            continue
        feed = show.get("feed")
        if not isinstance(feed, str) or not feed.strip():
            continue
        show_id = show.get("id")
        if not isinstance(show_id, str) or not ID_RE.match(show_id):
            show["id"] = show_id_for(feed)
        out.append(show)
    return out


def save_shows(shows):
    save_json(SHOWS_FILE, shows)


DEFAULT_LIBRARY = {
    "queue": [],        # ordered episode ids
    "triage": {},       # epId -> "archived" | "queued" | "played"
    "positions": {},    # epId -> {"pos": secs, "dur": secs, "ts": epoch}
    "now": None,        # epId currently loaded in the player
    "savedSeconds": 0,  # Smart Speed accounting (v2)
}


def load_library():
    lib = load_json(LIBRARY_FILE, {})
    out = dict(DEFAULT_LIBRARY)
    out["queue"] = [str(x) for x in lib.get("queue", []) if isinstance(x, str)]
    out["triage"] = {k: v for k, v in (lib.get("triage") or {}).items()
                     if isinstance(k, str) and v in ("archived", "queued", "played")}
    positions = {}
    for key, val in (lib.get("positions") or {}).items():
        if isinstance(key, str) and isinstance(val, dict):
            positions[key] = {
                "pos": clamp_number(val.get("pos"), 0, 1e7, 0),
                "dur": clamp_number(val.get("dur"), 0, 1e7, 0),
                "ts": clamp_number(val.get("ts"), 0, 4e12, 0),
            }
    out["positions"] = positions
    now = lib.get("now")
    out["now"] = now if isinstance(now, str) else None
    out["savedSeconds"] = clamp_number(lib.get("savedSeconds"), 0, 1e9, 0)
    return out


def save_library(lib):
    save_json(LIBRARY_FILE, lib)


def episodes_path(show_id):
    return os.path.join(EPISODE_DIR, "%s.json" % show_id)


def load_episodes(show_id):
    data = load_json(episodes_path(show_id), [])
    return [e for e in data if isinstance(e, dict) and e.get("id")]


# --------------------------------------------------------------- helpers

def clamp_number(value, low, high, default):
    try:
        num = float(value)
    except (TypeError, ValueError):
        return default
    if num != num or num in (float("inf"), float("-inf")):
        return default
    return max(low, min(high, num))


def digest(*parts):
    hasher = hashlib.sha1()
    for part in parts:
        hasher.update(str(part).encode("utf-8", "replace"))
        hasher.update(b"\0")
    return hasher.hexdigest()


def show_id_for(feed_url):
    return digest(normalize_feed(feed_url))[:12]


def episode_id_for(show_id, guid):
    # Keyed on the show's own id, never on its current URL: feeds move (301,
    # itunes:new-feed-url) and an id that moved with them would make every
    # episode look brand new, flooding the inbox and losing every saved
    # position on the day a host changes CDN.
    return digest(show_id, guid)[:16]


def normalize_feed(url):
    """Canonical form for identity. Only scheme/host case is normalized —
    paths and queries stay byte-exact, because feed hosts do treat them so."""
    parts = urlsplit(str(url).strip())
    if not parts.scheme or not parts.netloc:
        return str(url).strip()
    return parts._replace(scheme=parts.scheme.lower(),
                          netloc=parts.netloc.lower()).geturl()


HTTPS_RE = re.compile(r"^https://[^\s<>\"']+$", re.IGNORECASE)
HTTP_RE = re.compile(r"^https?://[^\s<>\"']+$", re.IGNORECASE)


def valid_url(url, allow_http=False):
    text = str(url or "").strip()
    if len(text) > 2000:
        return ""
    pattern = HTTP_RE if allow_http else HTTPS_RE
    return text if pattern.match(text) else ""


TAG_RE = re.compile(r"<[^>]*>")
WS_RE = re.compile(r"\s+")
CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def plain_text(raw, limit=MAX_DESC_CHARS):
    """Feed HTML → plain text. QML renders every remote string as
    Text.PlainText too; this is the second of the two belts.

    Entities are decoded *before* tags are stripped, and then again, because
    stripping first lets `&lt;img src=http://…&gt;` sail through as text and
    come back out as a live tag — which matters where the result leaves QML,
    notably the body of a desktop notification."""
    text = str(raw or "")
    for _pass in range(3):
        decoded = html.unescape(TAG_RE.sub(" ", text))
        if decoded == text:
            break
        text = decoded
    text = TAG_RE.sub(" ", text)
    text = CTRL_RE.sub(" ", text)
    text = WS_RE.sub(" ", text).strip()
    return text[:limit]


DURATION_RE = re.compile(r"^\s*(?:(\d+):)?(\d{1,2}):(\d{1,2}(?:\.\d+)?)\s*$")


def parse_duration(raw):
    text = str(raw or "").strip()
    if not text:
        return 0
    match = DURATION_RE.match(text)
    if match:
        hours = int(match.group(1) or 0)
        minutes = int(match.group(2))
        seconds = float(match.group(3))
        return int(hours * 3600 + minutes * 60 + seconds)
    try:
        return max(0, min(360000, int(float(text))))
    except ValueError:
        return 0


def parse_date(raw):
    text = str(raw or "").strip()
    if not text:
        return 0
    try:
        stamp = parsedate_to_datetime(text)
    except (TypeError, ValueError, IndexError, OverflowError):
        stamp = None
    if stamp is None:
        # A minority of feeds emit ISO-8601 in pubDate.
        try:
            import datetime
            stamp = datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
        except ValueError:
            return 0
    try:
        if stamp.tzinfo is None:
            import datetime
            stamp = stamp.replace(tzinfo=datetime.timezone.utc)
        return int(stamp.timestamp())
    except (ValueError, OverflowError, OSError):
        return 0


# --------------------------------------------------------------- fetching

# curl's exit codes, in the words a listener would use. Anything unmapped
# falls through to curl's own last stderr line.
CURL_ERRORS = {
    3: "that URL is malformed",
    6: "could not find that host",
    7: "could not connect to that host",
    22: "the server refused the request",
    28: "the feed took too long to answer",
    35: "the secure connection failed",
    47: "too many redirects",
    56: "the connection dropped mid-transfer",
    60: "that server's certificate is not trusted",
}


class Fetched(object):
    def __init__(self, status, body_path, final_url, permanent_url, error="",
                 headers=None):
        self.status = status
        self.body_path = body_path
        self.final_url = final_url
        self.permanent_url = permanent_url
        self.error = error
        # Response headers of the final hop — where ETag/Last-Modified live.
        self.headers = headers or {}


def parse_header_dump(path):
    """curl -D across a redirect chain writes one header block per hop.
    Returns (blocks, permanent_chain) where permanent_chain is True only when
    every redirect hop was a 301/308 — the condition for persisting the new
    feed URL."""
    blocks = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            current = None
            for line in handle:
                line = line.rstrip("\r\n")
                if line.startswith("HTTP/"):
                    current = {"status": 0, "headers": {}}
                    parts = line.split(None, 2)
                    if len(parts) > 1 and parts[1].isdigit():
                        current["status"] = int(parts[1])
                    blocks.append(current)
                elif line and current is not None and ":" in line:
                    name, _, value = line.partition(":")
                    current["headers"][name.strip().lower()] = value.strip()
    except OSError:
        return [], False
    redirects = [b for b in blocks[:-1] if 300 <= b["status"] < 400]
    permanent = bool(redirects) and all(b["status"] in (301, 308) for b in redirects)
    return blocks, permanent


def curl(url, dest, *, max_bytes, timeout, headers=None, allow_http=False,
         post=None, secret_headers=None):
    """One HTTP GET (or POST) through curl with an argv list — never a shell.

    Redirects are followed but the protocol is pinned, so an https feed cannot
    bounce us down to cleartext.

    `secret_headers` are passed through a curl config file on stdin rather
    than as `-H` arguments: /proc/<pid>/cmdline is world-readable on a stock
    Linux, so anything on argv is legible to every other account on the box.
    Ordinary headers (conditional-GET validators) have nothing to hide and
    stay on the command line."""
    if not valid_url(url, allow_http):
        return Fetched(0, "", url, "", "unsupported url")

    protos = "http,https" if allow_http else "https"
    header_dump = dest + ".hdr"
    argv = [
        "curl", "-sS",
        "--proto", "=" + protos,
        "--proto-redir", "=" + protos,
        "-L", "--max-redirs", "5",
        "--max-filesize", str(max_bytes),
        "--max-time", str(timeout),
        "--connect-timeout", "10",
        "--retry", "0",
        "-A", USER_AGENT,
        "-D", header_dump,
        "-o", dest,
        "-w", "%{http_code} %{url_effective}",
    ]
    for name, value in (headers or {}).items():
        # Header values come from the server's own previous ETag; refuse
        # anything with CR/LF so a hostile server cannot inject a header.
        if "\r" in value or "\n" in value:
            continue
        argv += ["-H", "%s: %s" % (name, value)]

    stdin_payload = None
    if secret_headers:
        lines = []
        for name, value in secret_headers.items():
            # Values are already restricted to a safe alphabet by the caller;
            # this is the belt to that suspender.
            if any(c in value for c in '\r\n"\\'):
                continue
            lines.append('header = "%s: %s"' % (name, value))
        if lines:
            argv += ["-K", "-"]
            stdin_payload = ("\n".join(lines) + "\n").encode("utf-8")

    if post is not None:
        if stdin_payload is not None:
            # Both want stdin, and curl would read the POST body as a config
            # file — `output =` in an attacker-controlled body is an
            # arbitrary file write, and `url =` unwinds the protocol pinning.
            # No caller does this today; refuse rather than leave it loaded.
            cleanup(header_dump)
            return Fetched(0, "", url, "",
                           "cannot send a body and credentials on the same request")
        argv += ["-X", "POST", "-H", "Content-Type: application/json",
                 "--data-binary", "@-"]
        stdin_payload = post.encode("utf-8")
    argv.append(url)

    try:
        proc = subprocess.run(
            argv,
            input=stdin_payload,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout + 15)
    except subprocess.TimeoutExpired:
        cleanup(header_dump)
        return Fetched(0, "", url, "", "timed out")
    except OSError as exc:
        cleanup(header_dump)
        return Fetched(0, "", url, "", "curl unavailable: %s" % exc.strerror)

    out = proc.stdout.decode("utf-8", "replace").strip().split(" ", 1)
    status = int(out[0]) if out and out[0].isdigit() else 0
    final_url = out[1] if len(out) > 1 else url

    # curl reports the status line even when it then aborts the transfer —
    # --max-filesize on a chunked response leaves a truncated body next to a
    # 200. Trusting the status here once let a truncated feed's ETag be
    # persisted, which made the partial episode list authoritative for ever.
    if proc.returncode != 0:
        err = proc.stderr.decode("utf-8", "replace").strip().splitlines()
        message = CURL_ERRORS.get(proc.returncode)
        if message is None:
            message = err[-1][:200] if err else "transfer failed (curl %d)" % proc.returncode
        if proc.returncode == 63:
            message = "feed larger than %d MB" % (max_bytes // (1024 * 1024))
        cleanup(header_dump)
        return Fetched(status, "", final_url, "", message)

    blocks, permanent = parse_header_dump(header_dump)
    cleanup(header_dump)
    final_headers = blocks[-1]["headers"] if blocks else {}

    # Even with --max-filesize, a chunked response has no advertised length;
    # the on-disk size is the backstop curl cannot check up front.
    try:
        if os.path.getsize(dest) >= max_bytes:
            cleanup(dest)
            return Fetched(status, "", final_url, "",
                           "response larger than %d bytes" % max_bytes)
    except OSError:
        pass

    permanent_url = final_url if (permanent and normalize_feed(final_url)
                                  != normalize_feed(url)) else ""
    return Fetched(status, dest, final_url, permanent_url, headers=final_headers)


def cleanup(*paths):
    for path in paths:
        if not path:
            continue
        try:
            os.unlink(path)
        except OSError:
            pass


def tmp_path(tag):
    return os.path.join(TMP_DIR, "%s.%d.%d" % (tag, os.getpid(), int(time.time() * 1000) % 100000))


def fetch_json(url, *, timeout=API_TIMEOUT, headers=None, post=None,
               secret_headers=None):
    dest = tmp_path("json")
    try:
        result = curl(url, dest, max_bytes=MAX_JSON_BYTES, timeout=timeout,
                      headers=headers, post=post, secret_headers=secret_headers)
        if result.error:
            return None, result.error
        if result.status != 200:
            return None, "HTTP %d" % result.status
        with open(dest, "r", encoding="utf-8", errors="replace") as handle:
            return json.load(handle), ""
    except (OSError, ValueError):
        return None, "unreadable response"
    finally:
        cleanup(dest)


# ---------------------------------------------------------------- parsing

class SanitizingReader(object):
    """Strips the control bytes that XML 1.0 forbids. Real feeds ship them
    (smart-quote mojibake, stray form feeds) and ElementTree hard-fails on
    them; dropping them costs nothing and saves the parse."""

    BAD = bytes(b for b in range(0x20) if b not in (0x09, 0x0a, 0x0d))
    TABLE = bytes.maketrans(BAD, b" " * len(BAD))

    def __init__(self, handle):
        self.handle = handle

    def read(self, size=-1):
        return self.handle.read(size).translate(self.TABLE)


def as_utf8_prolog(head):
    """The head of the document, transcoded to UTF-8 for scanning.

    expat honours a UTF-16 byte-order mark, so a feed can hide its DOCTYPE
    from a naive byte scan simply by being UTF-16: `<` is `3C 00` there, and
    a scanner looking for ASCII would walk straight past the declaration and
    conclude the prolog was clean. Transcoding first closes that door.
    """
    if head[:2] in (b"\xff\xfe", b"\xfe\xff"):
        # A UTF-32 BOM starts with the UTF-16 one, so check the longer first.
        if head[:4] in (b"\xff\xfe\x00\x00", b"\x00\x00\xfe\xff"):
            codec = "utf-32"
        else:
            codec = "utf-16"
    elif head[:4] in (b"\x00\x00\xfe\xff", b"\xff\xfe\x00\x00"):
        codec = "utf-32"
    elif head[:2] == b"<\x00" or head[:2] == b"\x00<":
        # UTF-16 without a BOM. Not legal XML, but worth scanning rather
        # than trusting.
        codec = "utf-16-le" if head[:2] == b"<\x00" else "utf-16-be"
    else:
        return head
    try:
        # An odd-length tail would raise; drop it rather than give up.
        usable = len(head) - (len(head) % (4 if codec.startswith("utf-32") else 2))
        return head[:usable].decode(codec, "replace").encode("utf-8", "replace")
    except (UnicodeDecodeError, LookupError):
        # Undecodable in the encoding it claims: refuse to guess.
        return b"<!DOCTYPE unreadable>"


def has_doctype(head):
    """True if the prolog declares a DTD, or cannot be shown not to.

    A feed has no business carrying one, and expat expands internal entity
    declarations without limit — the billion-laughs amplification, which no
    byte cap on the download can catch. Refusing the DOCTYPE outright closes
    it. (External entities are already refused by ElementTree, which treats
    an undefined entity as a parse error.)

    Only the prolog can legally hold a DOCTYPE, so walking declarations and
    comments until the root element starts is a complete check — provided the
    root element is actually reached. A feed that fills the whole window with
    comments and puts its DOCTYPE beyond it would otherwise slip through, so
    running out of buffer counts as a refusal: no real feed opens with 64 KiB
    of prologue.
    """
    if not head.strip():
        return False              # nothing to refuse; the parser will say so
    head = as_utf8_prolog(head)
    index = 0
    size = len(head)
    while index < size:
        start = head.find(b"<", index)
        if start == -1:
            break
        marker = head[start + 1:start + 2]
        if marker == b"?":                       # XML declaration or PI
            end = head.find(b"?>", start)
            if end == -1:
                break
            index = end + 2
        elif marker == b"!":
            if head[start:start + 9].lower() == b"<!doctype":
                return True
            if head[start:start + 4] == b"<!--":
                end = head.find(b"-->", start)
                if end == -1:
                    break
                index = end + 3
            else:
                return True                      # any other prolog declaration
        else:
            return False                         # root element — prolog is over
    # Fell off the end of the window still inside the prolog.
    return True


PROLOG_WINDOW = 65536


def prolog_rejects(path):
    try:
        with open(path, "rb") as handle:
            return has_doctype(handle.read(PROLOG_WINDOW))
    except OSError:
        return False


def strip_ns(tag):
    return tag.rsplit("}", 1)[-1] if "}" in tag else tag


def local(elem, name, ns=None):
    """First child named `name` (namespace-aware, with a bare fallback)."""
    if ns:
        found = elem.find("{%s}%s" % (NS[ns], name))
        if found is not None:
            return found
    return elem.find(name)


def text_of(elem):
    if elem is None:
        return ""
    return "".join(elem.itertext())


def parse_feed(path, show_id, limit=MAX_ITEMS_PER_FEED):
    """Streaming RSS parse, in flat memory whatever the feed contains.

    Two things make that true, and both were learned the hard way.

    `clear()` empties an element but leaves it parented, so a subtree that
    has been "cleared" still costs a slot in its parent's child list for the
    rest of the parse. Detaching from the parent is what actually frees it;
    without that, a feed of 800k sibling elements peaked at 302 MB, and one
    of 1.9M *nested* elements at 608 MB. Nothing may be detached while its
    parent still has to be read, which is why items and the direct children
    of `<channel>` are exempt.

    Channel metadata is therefore collected as each direct child closes,
    rather than off a fully-built `</channel>`. Order of appearance is not
    the same thing as preference — Megaphone emits `<image>` before
    `<itunes:image>`, and taking the first would hand thousands of shows a
    144x400 RSS logo in place of 3000x3000 iTunes art — so candidates are
    recorded by namespaced tag and resolved by preference at the end.
    """
    show = {"title": "", "author": "", "artwork": "", "description": "",
            "link": "", "newFeed": ""}
    found = {}
    items = []
    scanned = 0
    elements = 0
    depth = 0
    inside_item = 0
    channel = None
    channel_depth = -1

    if prolog_rejects(path):
        return None, [], "that feed declares a DTD, which podcasts do not use"

    try:
        handle = open(path, "rb")
    except OSError as exc:
        return None, [], "cannot read feed: %s" % exc.strerror

    ITUNES = "{%s}" % NS["itunes"]

    # The only channel-level tags worth keeping. Anything else a feed puts
    # there is dropped on sight rather than retained for the whole parse —
    # 800,000 junk elements as direct children of <channel> cost 87 MB when
    # they were kept.
    WANTED = frozenset([
        "title", "link", "description", "author", "image",
        ITUNES + "image", ITUNES + "summary", ITUNES + "subtitle",
        ITUNES + "author", ITUNES + "owner", ITUNES + "new-feed-url",
    ])

    def record(elem):
        """Take what a direct child of <channel> is worth, as text, so that
        nothing has to stay in the tree until the end. First occurrence wins
        within a tag; preference *between* tags is resolved after the parse."""
        tag = elem.tag
        if tag not in WANTED or tag in found:
            return
        if tag == ITUNES + "image":
            found[tag] = valid_url(str(elem.get("href", "")).strip())
        elif tag == "image":
            found[tag] = valid_url(text_of(local(elem, "url")).strip())
        elif tag == ITUNES + "owner":
            found[tag] = text_of(local(elem, "name", "itunes"))
        else:
            found[tag] = text_of(elem)

    def text_for(*tags):
        for tag in tags:
            text = found.get(tag)
            if text and text.strip():
                return text
        return ""

    stack = []                    # open elements, innermost last

    try:
        parser = ET.iterparse(SanitizingReader(handle), events=("start", "end"))
        for event, elem in parser:
            tag = strip_ns(elem.tag)

            if event == "start":
                stack.append(elem)
                depth += 1
                elements += 1
                if elements > MAX_ELEMENTS:
                    handle.close()
                    return None, [], "that feed has more elements than any real feed has"
                if depth > MAX_DEPTH:
                    handle.close()
                    return None, [], "that feed is nested deeper than any real feed is"
                if tag == "item":
                    inside_item += 1
                elif tag == "channel" and channel is None:
                    channel = elem
                    channel_depth = depth
                continue

            at_depth = depth
            depth -= 1
            if stack:
                stack.pop()
            parent = stack[-1] if stack else None

            if tag == "item":
                inside_item = max(0, inside_item - 1)
                scanned += 1
                if scanned <= MAX_ITEMS_SCANNED:
                    parsed = parse_item(elem, show_id)
                    if parsed:
                        items.append(parsed)
                elem.clear()
                if channel is not None:
                    del channel[:]
                continue

            if inside_item:
                continue          # parse_item reads these while they are whole

            if channel is not None and at_depth == channel_depth + 1:
                record(elem)
                elem.clear()
                del channel[:]
                continue

            if at_depth == channel_depth + 2:
                continue          # a channel child still has to read this

            # Anything else is filler: nested padding below a channel child,
            # or an element outside the channel entirely. Emptying it is not
            # enough — it stays in its parent's child list — so drop the
            # parent's accumulated children too. Nothing still needed lives
            # there: items are exempt above, and every channel child was
            # recorded rather than left in the tree.
            elem.clear()
            if parent is not None:
                del parent[:]
    except ET.ParseError as exc:
        handle.close()
        if items:
            # A truncated tail is common on capped downloads; keep what parsed.
            return show, finalize_items(items, limit), ""
        return None, [], "not a valid feed (%s)" % str(exc).split(":")[0][:80]
    except (OSError, MemoryError) as exc:
        handle.close()
        return None, [], "feed read failed: %s" % exc
    handle.close()

    # Preference, not order of appearance — the old extraction's rules.
    show["title"] = plain_text(text_for("title"), 300)
    show["link"] = valid_url(text_for("link").strip(), True)
    show["description"] = plain_text(
        text_for("description", ITUNES + "summary", ITUNES + "subtitle"), 900)
    show["author"] = plain_text(
        text_for(ITUNES + "author", ITUNES + "owner", "author"), 200)
    show["artwork"] = (found.get(ITUNES + "image") or found.get("image") or "")
    show["newFeed"] = valid_url(text_for(ITUNES + "new-feed-url").strip())

    if not items and not show["title"]:
        return None, [], "no podcast feed found at that URL"
    return show, finalize_items(items, limit), ""


def channel_artwork(channel):
    art = local(channel, "image", "itunes")
    if art is not None:
        href = valid_url(str(art.get("href", "")).strip())
        if href:
            return href
    image = local(channel, "image")
    if image is not None:
        url = valid_url(text_of(local(image, "url")).strip())
        if url:
            return url
    return ""


def parse_item(item, show_id):
    enclosure = local(item, "enclosure")
    url = ""
    mime = ""
    length = 0
    if enclosure is not None:
        url = valid_url(str(enclosure.get("url", "")).strip(), True)
        mime = plain_text(enclosure.get("type", ""), 80)
        try:
            length = max(0, int(str(enclosure.get("length", "0")).strip() or 0))
        except ValueError:
            length = 0
    if not url:
        # Some feeds only carry the audio in media:content.
        media = local(item, "content", "media")
        if media is not None:
            url = valid_url(str(media.get("url", "")).strip(), True)
            mime = plain_text(media.get("type", ""), 80)
    if not url:
        return None

    title = plain_text(text_of(local(item, "title")), 400)
    if not title:
        title = "(untitled episode)"

    guid_elem = local(item, "guid")
    guid = plain_text(text_of(guid_elem), 400) if guid_elem is not None else ""
    if not guid:
        guid = url

    duration = parse_duration(text_of(local(item, "duration", "itunes")))
    pub = parse_date(text_of(local(item, "pubDate")))

    image = ""
    itunes_image = local(item, "image", "itunes")
    if itunes_image is not None:
        image = valid_url(str(itunes_image.get("href", "")).strip())

    description = plain_text(
        text_of(local(item, "subtitle", "itunes")) or
        text_of(local(item, "description")) or
        text_of(local(item, "encoded", "content")))

    chapters = ""
    chapters_elem = local(item, "chapters", "podcast")
    if chapters_elem is not None and "json" in str(chapters_elem.get("type", "")).lower():
        chapters = valid_url(str(chapters_elem.get("url", "")).strip())

    transcript = ""
    for candidate in item.findall("{%s}transcript" % NS["podcast"]):
        kind = str(candidate.get("type", "")).lower()
        if "vtt" in kind or "srt" in kind or "text" in kind:
            transcript = valid_url(str(candidate.get("url", "")).strip())
            if transcript:
                break

    season = str(text_of(local(item, "season", "itunes"))).strip()[:6]
    number = str(text_of(local(item, "episode", "itunes"))).strip()[:6]

    return {
        "id": episode_id_for(show_id, guid),
        "guid": guid,
        "title": title,
        "url": url,
        "mime": mime,
        "bytes": length,
        "duration": duration,
        "pub": pub,
        "image": image,
        "desc": description,
        "chapters": chapters,
        "transcript": transcript,
        "season": season,
        "number": number,
    }


def finalize_items(items, limit):
    seen = set()
    unique = []
    for item in items:
        if item["id"] in seen:
            continue
        seen.add(item["id"])
        unique.append(item)
    # Feeds are conventionally newest-first but not reliably so; sort by
    # pubDate and keep original order as the tiebreak for undated items.
    ordered = sorted(enumerate(unique), key=lambda pair: (-pair[1]["pub"], pair[0]))
    return [item for _index, item in ordered[:limit]]


# ----------------------------------------------------------------- artwork

def cache_artwork(url):
    """Downloads show artwork once and returns its on-disk path. Extension
    comes from the sniffed magic bytes, never from the remote URL."""
    if not valid_url(url):
        return ""
    key = digest(url)[:20]
    for ext in ("jpg", "png", "webp", "gif"):
        candidate = os.path.join(ART_DIR, "%s.%s" % (key, ext))
        if os.path.exists(candidate):
            try:
                os.utime(candidate, None)
            except OSError:
                pass
            return candidate

    dest = tmp_path("art")
    result = curl(url, dest, max_bytes=MAX_ART_BYTES, timeout=ART_TIMEOUT)
    if result.error or result.status != 200:
        cleanup(dest)
        return ""
    ext = sniff_image(dest)
    if not ext:
        cleanup(dest)
        return ""
    final = os.path.join(ART_DIR, "%s.%s" % (key, ext))
    try:
        os.replace(dest, final)
        os.chmod(final, 0o600)
    except OSError:
        cleanup(dest)
        return ""
    prune_art_cache()
    return final


def sniff_image(path):
    try:
        with open(path, "rb") as handle:
            head = handle.read(16)
    except OSError:
        return ""
    if head.startswith(b"\xff\xd8\xff"):
        return "jpg"
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    if head[:6] in (b"GIF87a", b"GIF89a"):
        return "gif"
    return ""


def prune_art_cache():
    """LRU trim. Cheap enough to run after every artwork write."""
    entries = []
    total = 0
    try:
        for name in os.listdir(ART_DIR):
            path = os.path.join(ART_DIR, name)
            try:
                stat = os.stat(path)
            except OSError:
                continue
            entries.append((stat.st_mtime, stat.st_size, path))
            total += stat.st_size
    except OSError:
        return
    if total <= ART_CACHE_BYTES:
        return
    entries.sort()
    for _mtime, size, path in entries:
        if total <= ART_CACHE_BYTES:
            break
        cleanup(path)
        total -= size


# ------------------------------------------------------------ show records

def default_show(feed_url, show_id):
    return {
        "id": show_id,
        "feed": normalize_feed(feed_url),
        "title": "",
        "author": "",
        "artwork": "",
        "artPath": "",
        "link": "",
        "description": "",
        "mode": "inbox",
        "speed": 0,          # 0 = follow the global defaultSpeed
        "allowHttp": False,
        "etag": "",
        "modified": "",
        "failures": 0,
        "lastError": "",
        "lastFetch": 0,
        "added": int(time.time()),
        "baseline": 0,       # episodes newer than this are inbox candidates
        "count": 0,
    }


def find_show(shows, show_id):
    for show in shows:
        if show["id"] == show_id:
            return show
    return None


def public_show(show):
    out = dict(show)
    out["stale"] = show.get("failures", 0) >= STALE_AFTER_FAILURES
    return out


def refresh_show(show, force=False):
    """One conditional GET + parse. Mutates `show` in place; returns a result
    dict describing what happened for the caller's report."""
    headers = {}
    if not force:
        if show.get("etag"):
            headers["If-None-Match"] = show["etag"]
        if show.get("modified"):
            headers["If-Modified-Since"] = show["modified"]

    dest = tmp_path("feed")
    result = curl(show["feed"], dest, max_bytes=MAX_FEED_BYTES,
                  timeout=FEED_TIMEOUT, headers=headers,
                  allow_http=bool(show.get("allowHttp")))
    show["lastFetch"] = int(time.time())

    try:
        if result.error or result.status == 0:
            cleanup(dest)
            return note_failure(show, result.error or "unreachable")

        if result.status == 304:
            cleanup(dest)
            show["failures"] = 0
            show["lastError"] = ""
            return {"id": show["id"], "status": "304", "new": 0, "newIds": []}

        if result.status != 200:
            cleanup(dest)
            return note_failure(show, "HTTP %d" % result.status)

        if result.permanent_url:
            # 301/308: the feed moved for good. Persist it so we stop paying
            # for the redirect — the id stays put so nothing else breaks.
            show["feed"] = normalize_feed(result.permanent_url)

        meta, items, error = parse_feed(dest, show["id"])
        if error:
            return note_failure(show, error)

        # Validators for the next poll. A server that sends neither leaves
        # both empty and we simply refetch — correctness over cleverness.
        show["etag"] = result.headers.get("etag", "")[:200]
        show["modified"] = result.headers.get("last-modified", "")[:100]
    finally:
        cleanup(dest)

    known = {e["id"] for e in load_episodes(show["id"])}
    fresh = [e["id"] for e in items if e["id"] not in known]

    save_json(episodes_path(show["id"]), items)

    if meta["newFeed"] and normalize_feed(meta["newFeed"]) != normalize_feed(show["feed"]):
        show["feed"] = normalize_feed(meta["newFeed"])
    show["title"] = meta["title"] or show.get("title") or show["feed"]
    show["author"] = meta["author"] or show.get("author", "")
    show["description"] = meta["description"] or show.get("description", "")
    show["link"] = meta["link"] or show.get("link", "")
    if meta["artwork"] and meta["artwork"] != show.get("artwork"):
        show["artwork"] = meta["artwork"]
        show["artPath"] = cache_artwork(meta["artwork"])
    elif show.get("artwork") and not show.get("artPath"):
        show["artPath"] = cache_artwork(show["artwork"])
    show["count"] = len(items)
    show["failures"] = 0
    show["lastError"] = ""
    return {"id": show["id"], "status": "ok", "new": len(fresh), "newIds": fresh}


def note_failure(show, message):
    show["failures"] = int(show.get("failures", 0)) + 1
    show["lastError"] = str(message)[:200]
    return {"id": show["id"], "status": "error", "error": show["lastError"],
            "new": 0, "newIds": []}


# --------------------------------------------------------------- commands

def cmd_init(_args):
    emit({"ok": True, "stateDir": ROOT})


def cmd_shows(_args):
    shows = load_shows()
    emit({"ok": True, "shows": [public_show(s) for s in shows]})


def cmd_episodes(args):
    shows = load_shows()
    show = find_show(shows, args.show_id)
    if not show:
        fail("no such show")
    episodes = load_episodes(show["id"])
    limit = int(clamp_number(args.limit, 1, MAX_ITEMS_PER_FEED, MAX_ITEMS_PER_FEED))
    lib = load_library()
    emit({"ok": True, "show": public_show(show),
          "episodes": hydrate(episodes[:limit], show, lib)})


def hydrate(episodes, show, lib):
    """Episode records as the UI wants them: show identity folded in, plus
    triage state and saved position."""
    out = []
    for episode in episodes:
        entry = dict(episode)
        entry["showId"] = show["id"]
        entry["show"] = show.get("title") or show["feed"]
        entry["showArt"] = show.get("artPath", "")
        entry["state"] = lib["triage"].get(episode["id"], "new")
        position = lib["positions"].get(episode["id"])
        entry["pos"] = position["pos"] if position else 0
        if position and position["dur"] > 0 and not entry.get("duration"):
            entry["duration"] = int(position["dur"])
        out.append(entry)
    return out


def all_episodes(shows, lib):
    index = {}
    for show in shows:
        for episode in hydrate(load_episodes(show["id"]), show, lib):
            index[episode["id"]] = episode
    return index


def inbox_of(shows, lib, index):
    """Untriaged episodes published after the show was subscribed. Shows in
    `ignore` mode never contribute; `auto` shows queue instead of landing
    here (see apply_new)."""
    rows = []
    for show in shows:
        if show.get("mode") == "ignore":
            continue
        baseline = show.get("baseline", 0)
        for episode in load_episodes(show["id"]):
            if episode["pub"] <= baseline:
                continue
            if lib["triage"].get(episode["id"]):
                continue
            row = index.get(episode["id"])
            if row:
                rows.append(row)
    rows.sort(key=lambda e: -e["pub"])
    return rows


def cmd_library(_args):
    shows = load_shows()
    lib = load_library()
    index = all_episodes(shows, lib)
    inbox = inbox_of(shows, lib, index)
    queue = [index[eid] for eid in lib["queue"] if eid in index]
    now = index.get(lib["now"]) if lib["now"] else None
    emit({
        "ok": True,
        "inbox": inbox,
        "inboxCount": len(inbox),
        "queue": queue,
        "now": now,
        "positions": lib["positions"],
        "savedSeconds": lib["savedSeconds"],
        "shows": [public_show(s) for s in shows],
    })


def cmd_search(args):
    term = str(args.term or "").strip()
    if not term:
        emit({"ok": True, "results": [], "source": ""})
    if args.auth_stdin:
        # readline, not read: the caller keeps its end of the pipe open, so
        # waiting for EOF would wait for ever.
        args.key = sys.stdin.readline(256).strip()
        args.secret = sys.stdin.readline(256).strip()
    if args.key and args.secret:
        results, error = search_podcastindex(term, args.key, args.secret)
        if results is not None:
            emit({"ok": True, "results": results, "source": "podcastindex"})
        # Podcast Index configured but unreachable — fall through to iTunes
        # rather than leaving the user with nothing.
        results, itunes_error = search_itunes(term)
        if results is None:
            fail("%s (and iTunes: %s)" % (error, itunes_error))
        emit({"ok": True, "results": results, "source": "itunes",
              "note": "Podcast Index: %s" % error})
    results, error = search_itunes(term)
    if results is None:
        fail(error)
    emit({"ok": True, "results": results, "source": "itunes"})


def search_itunes(term):
    url = "https://itunes.apple.com/search?" + urlencode({
        "term": term[:200], "media": "podcast", "entity": "podcast", "limit": "25"})
    data, error = fetch_json(url)
    if data is None:
        return None, error
    results = []
    for entry in (data.get("results") or [])[:25]:
        feed = valid_url(str(entry.get("feedUrl", "")).strip())
        if not feed:
            continue
        results.append({
            "title": plain_text(entry.get("collectionName"), 200),
            "author": plain_text(entry.get("artistName"), 200),
            "feed": feed,
            "artwork": valid_url(str(entry.get("artworkUrl600")
                                     or entry.get("artworkUrl100") or "").strip()),
            "count": int(clamp_number(entry.get("trackCount"), 0, 100000, 0)),
        })
    return results, ""


CREDENTIAL_RE = re.compile(r"^[A-Za-z0-9_-]{8,128}$")


def search_podcastindex(term, key, secret):
    # Podcast Index issues alphanumeric credentials. Pinning the alphabet
    # rules out header injection and makes the curl config quoting safe.
    if not CREDENTIAL_RE.match(key) or not CREDENTIAL_RE.match(secret):
        return None, "those Podcast Index credentials do not look valid"
    stamp = str(int(time.time()))
    token = hashlib.sha1((key + secret + stamp).encode("utf-8")).hexdigest()
    url = "https://api.podcastindex.org/api/1.0/search/byterm?" + urlencode({
        "q": term[:200], "max": "25"})
    data, error = fetch_json(url, headers={"X-Auth-Date": stamp},
                             secret_headers={"X-Auth-Key": key,
                                             "Authorization": token})
    if data is None:
        return None, error
    results = []
    for entry in (data.get("feeds") or [])[:25]:
        feed = valid_url(str(entry.get("url", "")).strip())
        if not feed:
            continue
        results.append({
            "title": plain_text(entry.get("title"), 200),
            "author": plain_text(entry.get("author"), 200),
            "feed": feed,
            "artwork": valid_url(str(entry.get("artwork") or entry.get("image") or "").strip()),
            "count": int(clamp_number(entry.get("episodeCount"), 0, 100000, 0)),
        })
    return results, ""


def add_feed(shows, feed_url, allow_http=False, mode="inbox"):
    """Subscribe + first fetch. Returns (show, error). Existing subscriptions
    are returned as-is rather than re-fetched.

    Callers that hold the writer lock should note this fetches the network
    while they hold it — fine for a single `add`, wrong for a bulk import,
    which is why cmd_opml_import does the fetch itself outside the lock."""
    url = valid_url(feed_url, allow_http)
    if not url:
        return None, ("that URL is not https (add it as an http exception if you "
                      "trust it)" if HTTP_RE.match(str(feed_url).strip())
                      else "that does not look like a feed URL")
    show_id = show_id_for(url)
    existing = find_show(shows, show_id)
    if existing:
        return existing, "already subscribed"

    show = default_show(url, show_id)
    show["allowHttp"] = bool(allow_http)
    if mode in MODES:
        show["mode"] = mode
    result = refresh_show(show, force=True)
    if result["status"] == "error":
        return None, result.get("error", "could not read that feed")

    # Castro's rule: subscribing does not dump the back catalogue into the
    # inbox. Everything present at subscribe time is history; only what
    # arrives afterwards is triageable.
    episodes = load_episodes(show_id)
    show["baseline"] = max([e["pub"] for e in episodes] or [0])
    shows.append(show)
    return show, ""


def cmd_add(args):
    with Lock():
        shows = load_shows()
        show, error = add_feed(shows, args.feed, allow_http=args.allow_http)
        if show is None:
            fail(error)
        save_shows(shows)
        emit({"ok": True, "show": public_show(show),
              "note": error, "episodes": len(load_episodes(show["id"]))})


def cmd_remove(args):
    with Lock():
        shows = load_shows()
        show = find_show(shows, args.show_id)
        if not show:
            fail("no such show")
        episodes = load_episodes(show["id"])
        gone = {e["id"] for e in episodes}
        shows = [s for s in shows if s["id"] != show["id"]]
        lib = load_library()
        lib["queue"] = [e for e in lib["queue"] if e not in gone]
        lib["triage"] = {k: v for k, v in lib["triage"].items() if k not in gone}
        lib["positions"] = {k: v for k, v in lib["positions"].items() if k not in gone}
        if lib["now"] in gone:
            lib["now"] = None
        cleanup(episodes_path(show["id"]))
        save_shows(shows)
        save_library(lib)
        emit({"ok": True, "removed": show["id"]})


def cmd_refresh(args):
    with Lock():
        shows = load_shows()
        if args.show_id:
            targets = [s for s in shows if s["id"] == args.show_id]
            if not targets:
                fail("no such show")
        else:
            targets = shows
        lib = load_library()
        results = []
        notify = []
        for show in targets:
            result = refresh_show(show, force=args.force)
            results.append(result)
            if result["status"] == "ok" and result["newIds"]:
                notify += apply_new(show, result["newIds"], lib)
        prune_triage(shows, lib)
        save_shows(shows)
        save_library(lib)
        emit({"ok": True, "results": results, "notify": notify})


def apply_new(show, new_ids, lib):
    """Route freshly-discovered episodes by the show's mode. Returns the
    notification payloads the caller should raise (auto-queue shows only)."""
    if show.get("mode") != "auto":
        return []
    episodes = {e["id"]: e for e in load_episodes(show["id"])}
    fresh = [episodes[eid] for eid in new_ids
             if eid in episodes and episodes[eid]["pub"] > show.get("baseline", 0)]
    fresh.sort(key=lambda e: e["pub"])
    payload = []
    for episode in fresh:
        if lib["triage"].get(episode["id"]):
            continue
        if episode["id"] not in lib["queue"]:
            lib["queue"].append(episode["id"])
        lib["triage"][episode["id"]] = "queued"
        payload.append({"show": show.get("title", ""), "title": episode["title"],
                        "art": show.get("artPath", "")})
    return payload


def prune_triage(shows, lib):
    """Triage/position entries for episodes that have aged out of every feed
    are dead weight; drop them so state cannot grow without bound."""
    live = set()
    for show in shows:
        live.update(e["id"] for e in load_episodes(show["id"]))
    lib["queue"] = [e for e in lib["queue"] if e in live]
    lib["triage"] = {k: v for k, v in lib["triage"].items() if k in live}
    lib["positions"] = {k: v for k, v in lib["positions"].items() if k in live}
    if lib["now"] and lib["now"] not in live:
        lib["now"] = None


def cmd_triage(args):
    with Lock():
        lib = load_library()
        episode_id = args.episode_id
        action = args.action
        if action == "archive":
            lib["triage"][episode_id] = "archived"
            lib["queue"] = [e for e in lib["queue"] if e != episode_id]
        elif action == "unarchive":
            lib["triage"].pop(episode_id, None)
        elif action == "queue":
            lib["triage"][episode_id] = "queued"
            if episode_id not in lib["queue"]:
                lib["queue"].append(episode_id)
        elif action == "played":
            lib["triage"][episode_id] = "played"
            lib["queue"] = [e for e in lib["queue"] if e != episode_id]
        else:
            fail("unknown triage action")
        save_library(lib)
        emit({"ok": True, "queue": lib["queue"]})


def cmd_archive_all(_args):
    with Lock():
        shows = load_shows()
        lib = load_library()
        index = all_episodes(shows, lib)
        count = 0
        for episode in inbox_of(shows, lib, index):
            lib["triage"][episode["id"]] = "archived"
            count += 1
        save_library(lib)
        emit({"ok": True, "archived": count})


def cmd_queue(args):
    with Lock():
        lib = load_library()
        action = args.action
        queue = lib["queue"]
        episode_id = args.episode_id or ""

        if action == "add":
            queue = [e for e in queue if e != episode_id]
            if args.front:
                queue.insert(0, episode_id)
            else:
                queue.append(episode_id)
            lib["triage"][episode_id] = "queued"
        elif action == "remove":
            queue = [e for e in queue if e != episode_id]
            if lib["triage"].get(episode_id) == "queued":
                lib["triage"][episode_id] = "archived"
        elif action == "move":
            if episode_id in queue:
                at = queue.index(episode_id)
                target = max(0, min(len(queue) - 1, at + int(args.delta or 0)))
                queue.insert(target, queue.pop(at))
        elif action == "clear":
            for eid in queue:
                if lib["triage"].get(eid) == "queued":
                    lib["triage"][eid] = "archived"
            queue = []
        else:
            fail("unknown queue action")

        lib["queue"] = queue
        save_library(lib)
        emit({"ok": True, "queue": queue})


def cmd_position(args):
    with Lock():
        lib = load_library()
        episode_id = args.episode_id
        pos = clamp_number(args.pos, 0, 1e7, 0)
        dur = clamp_number(args.dur, 0, 1e7, 0)
        lib["positions"][episode_id] = {"pos": pos, "dur": dur, "ts": int(time.time())}
        if args.now:
            lib["now"] = episode_id
        if args.played:
            lib["triage"][episode_id] = "played"
            lib["queue"] = [e for e in lib["queue"] if e != episode_id]
            lib["positions"][episode_id]["pos"] = 0
        save_library(lib)
        emit({"ok": True})


def cmd_show_set(args):
    with Lock():
        shows = load_shows()
        show = find_show(shows, args.show_id)
        if not show:
            fail("no such show")
        key, value = args.key, args.value
        if key == "mode":
            if value not in MODES:
                fail("mode must be one of %s" % ", ".join(MODES))
            show["mode"] = value
        elif key == "speed":
            show["speed"] = clamp_number(value, 0, 3.0, 0)
        elif key == "allow-http":
            show["allowHttp"] = value in ("1", "true", "yes")
        elif key == "baseline":
            show["baseline"] = int(clamp_number(value, 0, 4e12, 0))
        else:
            fail("unknown show setting")
        save_shows(shows)
        emit({"ok": True, "show": public_show(show)})


# -------------------------------------------------------------------- opml

OPML_ATTR_RE = re.compile(r'xmlUrl\s*=\s*"([^"]*)"', re.IGNORECASE)


def cmd_opml_import(args):
    path = os.path.abspath(os.path.expanduser(args.path))
    try:
        if os.path.getsize(path) > 4 * 1024 * 1024:
            fail("that OPML file is too large")
        if prolog_rejects(path):
            fail("that OPML file declares a DTD and will not be read")
        with open(path, "rb") as handle:
            tree = ET.parse(SanitizingReader(handle))
    except OSError as exc:
        fail("cannot read %s: %s" % (path, exc.strerror))
    except ET.ParseError:
        fail("that file is not valid OPML")

    feeds = []
    for outline in tree.getroot().iter():
        if strip_ns(outline.tag) != "outline":
            continue
        url = str(outline.get("xmlUrl") or outline.get("xmlurl") or "").strip()
        if url:
            feeds.append((url, plain_text(outline.get("text") or outline.get("title"), 200)))

    if not feeds:
        fail("no feeds found in that OPML file")

    added, skipped, failed = 0, 0, []
    for url, title in feeds[:500]:
        # Fetch first, without the lock. Taking it per feed was already
        # better than holding it for the whole import, but the fetch inside
        # it meant the importer held the lock essentially continuously and
        # re-took it faster than any waiter could win — five hundred feeds
        # would still push a concurrent poll past its deadline. The lock now
        # covers only the read-modify-write.
        candidate = valid_url(url)
        if not candidate:
            failed.append({"feed": str(url)[:120], "title": title,
                           "error": "that URL is not https"})
            continue
        show_id = show_id_for(candidate)
        prepared = default_show(candidate, show_id)
        result = refresh_show(prepared, force=True)

        with Lock():
            shows = load_shows()
            if find_show(shows, show_id):
                skipped += 1
            elif result["status"] == "error":
                failed.append({"feed": candidate[:120], "title": title,
                               "error": result.get("error", "could not read that feed")})
            else:
                episodes = load_episodes(show_id)
                prepared["baseline"] = max([e["pub"] for e in episodes] or [0])
                shows.append(prepared)
                added += 1
                save_shows(shows)
    emit({"ok": True, "added": added, "skipped": skipped,
          "failed": failed[:20], "failedCount": len(failed)})


def cmd_opml_export(args):
    shows = load_shows()
    path = os.path.abspath(os.path.expanduser(args.path))
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="2.0">',
        "  <head><title>Omarchy Podcasts subscriptions</title></head>",
        "  <body>",
    ]
    for show in shows:
        lines.append('    <outline type="rss" text=%s title=%s xmlUrl=%s />' % (
            xml_attr(show.get("title") or show["feed"]),
            xml_attr(show.get("title") or show["feed"]),
            xml_attr(show["feed"])))
    lines += ["  </body>", "</opml>", ""]
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines))
    except OSError as exc:
        fail("cannot write %s: %s" % (path, exc.strerror))
    emit({"ok": True, "path": path, "count": len(shows)})


def xml_attr(value):
    text = CTRL_RE.sub("", str(value or ""))
    return '"' + (text.replace("&", "&amp;").replace("<", "&lt;")
                  .replace(">", "&gt;").replace('"', "&quot;")) + '"'


# ---------------------------------------------------------------- chapters

def cmd_chapters(args):
    url = valid_url(args.url)
    if not url:
        fail("chapter URL must be https")
    data, error = fetch_json(url)
    if data is None:
        fail(error)
    chapters = []
    for entry in (data.get("chapters") or [])[:MAX_CHAPTERS]:
        if not isinstance(entry, dict):
            continue
        start = clamp_number(entry.get("startTime"), 0, 1e7, None)
        if start is None:
            continue
        chapters.append({
            "start": start,
            "title": plain_text(entry.get("title"), 200) or "—",
            "url": valid_url(str(entry.get("url", "")).strip()),
        })
    chapters.sort(key=lambda c: c["start"])
    emit({"ok": True, "chapters": chapters})


# ------------------------------------------------------------ result artwork

MAX_ART_BATCH = 8


def cmd_art(args):
    """Cache artwork for directory results and hand back local paths.

    Search results are remote URLs from a directory API, so QML never loads
    them directly — that would make every keystroke fan out HTTP requests to
    whatever hosts the API named, from the user's IP. They come through here
    instead: https only, size-capped, type-sniffed from the magic bytes, and
    dropped into the same LRU cache as show artwork.
    """
    paths = {}
    for url in args.urls[:MAX_ART_BATCH]:
        cached = cache_artwork(url)
        if cached:
            paths[url] = cached
    emit({"ok": True, "paths": paths})


# ----------------------------------------------------------- notifications

def notify_safe(text):
    """Notification daemons differ on whether the body is Pango markup, and
    the ones that render it will fetch an <img>. Escape rather than guess."""
    return (str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def cmd_notify(args):
    title = notify_safe(plain_text(args.title, 120)) or "Podcasts"
    body = notify_safe(plain_text(args.body, 300))
    argv = ["notify-send", "-a", "Podcasts", "-h", "string:x-canonical-private-synchronous:omarchy-podcasts"]
    icon = args.icon or ""
    if icon and os.path.isfile(icon) and os.path.commonpath([os.path.abspath(icon), ART_DIR]) == ART_DIR:
        argv += ["-i", os.path.abspath(icon)]
    argv += ["--", title, body]
    try:
        subprocess.run(argv, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        pass
    emit({"ok": True})


# -------------------------------------------------------------------- main

def build_parser():
    parser = argparse.ArgumentParser(prog="podcasts.py", add_help=True)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("init").set_defaults(run=cmd_init)
    sub.add_parser("shows").set_defaults(run=cmd_shows)
    sub.add_parser("library").set_defaults(run=cmd_library)
    sub.add_parser("archive-all").set_defaults(run=cmd_archive_all)

    p = sub.add_parser("search")
    p.add_argument("term")
    # Read as two lines on stdin, for the same /proc reason as above. The
    # flags remain for anyone driving this by hand.
    p.add_argument("--auth-stdin", action="store_true")
    p.add_argument("--key", default="")
    p.add_argument("--secret", default="")
    p.set_defaults(run=cmd_search)

    p = sub.add_parser("add")
    p.add_argument("feed")
    p.add_argument("--allow-http", action="store_true")
    p.set_defaults(run=cmd_add)

    p = sub.add_parser("remove")
    p.add_argument("show_id")
    p.set_defaults(run=cmd_remove)

    p = sub.add_parser("episodes")
    p.add_argument("show_id")
    p.add_argument("--limit", default=MAX_ITEMS_PER_FEED)
    p.set_defaults(run=cmd_episodes)

    p = sub.add_parser("refresh")
    p.add_argument("--show", dest="show_id", default="")
    p.add_argument("--force", action="store_true")
    p.set_defaults(run=cmd_refresh)

    p = sub.add_parser("triage")
    p.add_argument("action", choices=["archive", "unarchive", "queue", "played"])
    p.add_argument("episode_id")
    p.set_defaults(run=cmd_triage)

    p = sub.add_parser("queue")
    p.add_argument("action", choices=["add", "remove", "move", "clear"])
    p.add_argument("episode_id", nargs="?", default="")
    p.add_argument("--front", action="store_true")
    p.add_argument("--delta", default="0")
    p.set_defaults(run=cmd_queue)

    p = sub.add_parser("position")
    p.add_argument("episode_id")
    p.add_argument("pos")
    p.add_argument("dur")
    p.add_argument("--played", action="store_true")
    p.add_argument("--now", action="store_true")
    p.set_defaults(run=cmd_position)

    p = sub.add_parser("show-set")
    p.add_argument("show_id")
    p.add_argument("key", choices=["mode", "speed", "allow-http", "baseline"])
    p.add_argument("value")
    p.set_defaults(run=cmd_show_set)

    p = sub.add_parser("opml-import")
    p.add_argument("path")
    p.set_defaults(run=cmd_opml_import)

    p = sub.add_parser("opml-export")
    p.add_argument("path")
    p.set_defaults(run=cmd_opml_export)

    p = sub.add_parser("chapters")
    p.add_argument("url")
    p.set_defaults(run=cmd_chapters)

    p = sub.add_parser("art")
    p.add_argument("urls", nargs="+")
    p.set_defaults(run=cmd_art)

    p = sub.add_parser("notify")
    p.add_argument("title")
    p.add_argument("body")
    p.add_argument("--icon", default="")
    p.set_defaults(run=cmd_notify)

    return parser


def main():
    args = build_parser().parse_args()
    ensure_dirs()
    sweep_tmp()
    try:
        args.run(args)
    except SystemExit:
        raise
    except Exception as exc:  # never let a traceback reach the QML side
        fail("%s: %s" % (type(exc).__name__, exc))


def sweep_tmp():
    """A killed run can leave a partial download behind; anything older than
    an hour is nobody's."""
    cutoff = time.time() - 3600
    try:
        for name in os.listdir(TMP_DIR):
            path = os.path.join(TMP_DIR, name)
            try:
                if os.stat(path).st_mtime < cutoff:
                    cleanup(path)
            except OSError:
                continue
    except OSError:
        pass


if __name__ == "__main__":
    main()
