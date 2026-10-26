#!/usr/bin/env python3
"""Probe the pinned 9.11.19 server for the file/thumbnail contract T38 depends on.

Answers, from the server itself (never from documentation):
  1. What a post's `metadata.files` actually carries (names, mime types, sizes, dimensions).
  2. What `GET /files/{id}/thumbnail` returns compared with the original bytes: byte size and the
     decoded pixel size, per image. This decides whether an inline preview can use the thumbnail
     endpoint at all (a 120 px thumbnail drawn at 300 pt is a blurred preview, and the card's
     criterion is that the image "renders correctly").
  3. What a PDF's original bytes look like (magic number + size), and that a text file is text.

Usage: python3 scripts/t38_file_probe.py [--channel t34-showcase]
"""
from __future__ import annotations

import argparse
import io
import json
import struct
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:8065/api/v4"
LOGIN = "perfprobe@example.invalid"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"


def call(path, token=None, method="GET", payload=None, raw=False):
    request = urllib.request.Request(BASE + path, method=method,
                                     data=None if payload is None else json.dumps(payload).encode())
    request.add_header("X-Requested-With", "XMLHttpRequest")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    if payload is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=20) as response:
        body = response.read()
        return body if raw else json.loads(body)


def login():
    """9.x returns the session token in the `Token:` response header, not the body."""
    request = urllib.request.Request(BASE + "/users/login", method="POST",
                                     data=json.dumps({"login_id": LOGIN,
                                                      "password": PASSWORD}).encode())
    request.add_header("Content-Type", "application/json")
    request.add_header("X-Requested-With", "XMLHttpRequest")
    with urllib.request.urlopen(request, timeout=20) as response:
        token = response.headers.get("Token")
    if not token:
        raise SystemExit("login returned no Token header")
    return token


def png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    width, height = struct.unpack(">II", data[16:24])
    return width, height


def jpeg_size(data):
    if data[:2] != b"\xff\xd8":
        return None
    i = 2
    while i < len(data) - 9:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3):
            height, width = struct.unpack(">HH", data[i + 5:i + 9])
            return width, height
        length = struct.unpack(">H", data[i + 2:i + 4])[0]
        i += 2 + length
    return None


def image_size(data):
    return png_size(data) or jpeg_size(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--channel", default="t34-showcase")
    args = parser.parse_args()

    token = login()
    team = [t for t in call("/users/me/teams", token) if t["name"] == "perf"][0]
    channels = call(f"/users/me/teams/{team['id']}/channels", token)
    names = {c["name"]: c for c in channels}
    if args.channel not in names:
        raise SystemExit(f"channel {args.channel} missing; have {sorted(names)[:20]}")
    channel = names[args.channel]
    page = call(f"/channels/{channel['id']}/posts?per_page=60", token)

    report = {"channel": args.channel, "posts": len(page["order"]), "files": []}
    for post_id in page["order"]:
        post = page["posts"][post_id]
        metadata = post.get("metadata") or {}
        for info in metadata.get("files") or []:
            fid = info["id"]
            entry = {k: info.get(k) for k in ("name", "mime_type", "size", "width", "height")}
            entry["id"] = fid
            try:
                original = call(f"/files/{fid}", token, raw=True)
                entry["original_bytes"] = len(original)
                entry["original_px"] = image_size(original)
                entry["magic"] = original[:8].hex()
            except urllib.error.HTTPError as error:
                entry["original_error"] = error.code
            try:
                thumb = call(f"/files/{fid}/thumbnail", token, raw=True)
                entry["thumbnail_bytes"] = len(thumb)
                entry["thumbnail_px"] = image_size(thumb)
            except urllib.error.HTTPError as error:
                entry["thumbnail_status"] = error.code
            report["files"].append(entry)

    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
