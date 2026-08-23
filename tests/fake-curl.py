#!/usr/bin/env python3
"""Offline stand-in for curl, so the suite tests our own code and not the
internet.

Serves files out of tests/fixtures/ keyed by URL, honours the conditional-GET
headers the real fetch sends, and can be told to fail, redirect or stall via a
routes file. Speaks exactly the curl surface podcasts.py uses: -o, -D, -w,
-H, --max-filesize, and curl's own exit codes.
"""

import json
import os
import sys

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")
ROUTES = os.environ.get("FAKE_CURL_ROUTES", "")


def routes():
    if not ROUTES or not os.path.exists(ROUTES):
        return {}
    try:
        with open(ROUTES, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {}


def main(argv):
    dest = ""
    header_dump = ""
    write_format = ""
    headers = {}
    url = ""
    max_filesize = 0

    index = 0
    while index < len(argv):
        arg = argv[index]
        if arg == "-o":
            index += 1
            dest = argv[index]
        elif arg == "-D":
            index += 1
            header_dump = argv[index]
        elif arg == "-w":
            index += 1
            write_format = argv[index]
        elif arg == "-H":
            index += 1
            name, _, value = argv[index].partition(":")
            headers[name.strip().lower()] = value.strip()
        elif arg == "--max-filesize":
            index += 1
            max_filesize = int(argv[index])
        elif arg in ("-A", "--max-time", "--connect-timeout", "--max-redirs",
                     "--retry", "--proto", "--proto-redir", "-X", "--data-binary"):
            index += 1
        elif arg in ("-sS", "-L"):
            pass
        elif not arg.startswith("-"):
            url = arg
        index += 1

    route = routes().get(url, {})
    status = int(route.get("status", 200))
    fixture = route.get("fixture", "")
    exit_code = int(route.get("exit", 0))
    location = route.get("location", "")
    etag = route.get("etag", "")
    modified = route.get("modified", "")

    if exit_code:
        sys.stderr.write("curl: (%d) simulated failure\n" % exit_code)
        return exit_code

    # Conditional GET: answer 304 when the caller echoes back what we gave it.
    if status == 200 and etag and headers.get("if-none-match") == etag:
        status = 304
    elif status == 200 and modified and headers.get("if-modified-since") == modified:
        status = 304

    body = b""
    if status == 200 and fixture:
        path = os.path.join(FIXTURES, fixture)
        try:
            with open(path, "rb") as handle:
                body = handle.read()
        except OSError:
            sys.stderr.write("curl: (22) missing fixture %s\n" % fixture)
            return 22

    if max_filesize and len(body) > max_filesize:
        sys.stderr.write("curl: (63) Maximum file size exceeded\n")
        return 63

    blocks = []
    final_url = url
    if location:
        blocks.append("HTTP/1.1 %d Moved\r\nLocation: %s\r\n" % (status, location))
        final_url = location
        redirected = routes().get(location, {})
        status = int(redirected.get("status", 200))
        etag = redirected.get("etag", "")
        modified = redirected.get("modified", "")
        if redirected.get("fixture"):
            try:
                with open(os.path.join(FIXTURES, redirected["fixture"]), "rb") as handle:
                    body = handle.read()
            except OSError:
                body = b""

    tail = "HTTP/1.1 %d OK\r\n" % status
    if etag:
        tail += "ETag: %s\r\n" % etag
    if modified:
        tail += "Last-Modified: %s\r\n" % modified
    tail += "Content-Type: application/xml\r\n"
    blocks.append(tail)

    if dest:
        with open(dest, "wb") as handle:
            handle.write(body if status == 200 else b"")
    if header_dump:
        with open(header_dump, "w", encoding="utf-8") as handle:
            handle.write("\r\n".join(blocks))

    if write_format:
        route_ip = route.get("remote_ip", "203.0.113.10")
        # curl reports whether this request actually went through a proxy,
        # which is not the same as one being configured (no_proxy).
        proxy_used = str(route.get("proxy_used", "0"))
        sys.stdout.write(write_format
                         .replace("%{http_code}", str(status))
                         .replace("%{remote_ip}", route_ip)
                         .replace("%{proxy_used}", proxy_used)
                         .replace("%{url_effective}", final_url))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
