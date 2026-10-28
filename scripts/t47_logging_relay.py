#!/usr/bin/env python3
"""T47 wire witness — a logging TCP relay in front of the fixture Mattermost server.

The UI suite's verdict is asserted against the server (`GET /teams/{tid}/channels/name/{name}` 404
before, 200 after, `creator_id` = the signed-in user). This script answers the *narrower* question the
card also asks — "and `POST /channels` was the request that made it" — by recording the request lines the
app itself sends: run the app against `http://127.0.0.1:8066` while this relay forwards to
`http://127.0.0.1:8065`, then grep the log.

It is deliberately a dumb byte pump:
  * one thread per direction per connection, so a keep-alive connection or a long-lived socket does not
    block anything;
  * the first request line(s) of each connection are logged (and, for readability, the HTTP method + path
    of every request *line* it sees in the client→server stream, which for HTTP/1.1 keep-alive is one per
    request);
  * nothing is decoded, rewritten or answered locally.

Hazard, stated rather than hidden: a relay is **not** a websocket tunnel in the sense an assertion needs
(T40 measured exactly that — the app's `GET /api/v4/websocket` went through and no frame ever arrived).
So a relay run is evidence for HTTP requests, never the verdict for a test that asserts socket delivery.
T47's test asserts no socket frame: the sidebar reload after a create is an explicit HTTP read.

Usage:
    python3 scripts/t47_logging_relay.py --listen 8066 --upstream 8065 --log build/logs/t47-relay.txt
"""

from __future__ import annotations

import argparse
import re
import socket
import sys
import threading
import time

LOCK = threading.Lock()
LOG_PATH = "build/logs/t47-relay.txt"
DUMP = False


def log(line: str) -> None:
    stamped = f"{time.strftime('%H:%M:%S')} {line}"
    with LOCK:
        print(stamped, flush=True)
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(stamped + "\n")


REQUEST_LINE = re.compile(rb"(GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD) (/\S*) HTTP/1\.[01]")


def pump(source: socket.socket, destination: socket.socket, label: str, record_lines: bool,
         block: list[str]) -> None:
    buffer = b""
    try:
        while True:
            chunk = source.recv(65536)
            if not chunk:
                break
            if record_lines:
                # The request line is found by *search*, not by splitting on CRLF: a TCP read can end
                # mid-header, and the next read then begins with the tail of that header glued to the
                # next request line. Splitting produced a first "line" of "Authorization: Bearer …POST
                # /api/v4/channels HTTP/1.1" and the request was silently dropped from the log.
                buffer += chunk
                while (match := REQUEST_LINE.search(buffer)) is not None:
                    line = match.group(0).decode(errors="replace")
                    log(f"{label} {line}")
                    for pattern in block:
                        if pattern in line:
                            log(f"{label} BLOCKED {line}")
                            return
                    buffer = buffer[match.end():]
            if DUMP:
                log(f"{label} CHUNK {len(chunk)} {chunk[:300]!r}")
            destination.sendall(chunk)
    except OSError:
        pass
    finally:
        for sock in (source, destination):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass


def handle(client: socket.socket, upstream_host: str, upstream_port: int,
           block: list[str]) -> None:
    try:
        server = socket.create_connection((upstream_host, upstream_port), timeout=30)
    except OSError as error:
        log(f"upstream refused: {error}")
        client.close()
        return
    threading.Thread(target=pump, args=(client, server, "->", True, block), daemon=True).start()
    threading.Thread(target=pump, args=(server, client, "<-", False, []), daemon=True).start()


def main() -> int:
    global LOG_PATH, DUMP

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", type=int, default=8066)
    parser.add_argument("--upstream", type=int, default=8065)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--log", default=LOG_PATH)
    parser.add_argument("--seconds", type=float, default=0,
                        help="stop after this many seconds (0 = until killed)")
    parser.add_argument("--dump", action="store_true",
                        help="log every client chunk, escaped (for a request the parser missed)")
    parser.add_argument("--block", action="append", default=[],
                        help="drop a client connection whose request line contains this text "
                             "(used to prove which side a request came from)")
    args = parser.parse_args()

    LOG_PATH = args.log
    DUMP = args.dump
    open(LOG_PATH, "w", encoding="utf-8").close()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.host, args.listen))
    listener.listen(128)
    listener.settimeout(1.0)
    log(f"relay {args.host}:{args.listen} -> {args.host}:{args.upstream}")

    deadline = time.time() + args.seconds if args.seconds else None
    while True:
        if deadline and time.time() > deadline:
            break
        try:
            client, _ = listener.accept()
        except socket.timeout:
            continue
        except OSError:
            break
        threading.Thread(target=handle,
                         args=(client, args.host, args.upstream, args.block),
                         daemon=True).start()
    log("relay stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
