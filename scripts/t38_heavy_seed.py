#!/usr/bin/env python3
"""T38 memory-probe fixture: a media-heavy channel for the T27-style measurement.

The card's second criterion is *"image loading is cancellable and bounded — measure it with the T27
probe."*  A bound can only be measured against a channel whose images are big enough that an
unbounded cache would show: a flat-colour PNG downloads in a few hundred bytes and proves nothing.
This script uploads **noisy** (poorly compressible) PNGs and posts them, so the app's inline path
really transfers megabytes and decodes real pixels while
`MattermostUITests/T38HeavyScrollProbeUITests` scrolls them and `scripts/t38_mem_sample.py` samples
the process.

Idempotent by `props.t38_heavy_key`, like the other fixtures: a rerun reuses its posts.

    python3 scripts/t38_heavy_seed.py                      # 4 posts x 10 images, 1024x768 (~2 MB each)
    python3 scripts/t38_heavy_seed.py --posts 2 --images 10 --width 800 --height 600

Measured 2026-10-26 against the local throwaway server (127.0.0.1:8065, 9.11.19): 40 files,
83,042,276 bytes total, 2,075,541..2,076,496 bytes per file.

The credentials are the throwaway dev account `scripts/perf_seed.py` creates; nothing here talks to a
server that is not already local.
"""
from __future__ import annotations

import argparse
import json
import os
import struct
import urllib.error
import urllib.request
import zlib

BASE = "http://127.0.0.1:8065/api/v4"
LOGIN = ("perfprobe", "PerfProbe-Not-A-Real-Secret-1")
TEAM = "perf"
CHANNEL = "t38-heavy"
KEY = "t38_heavy_key"


def call(method, path, body=None, token=None, raw=None, content_type="application/json"):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            payload, headers, status = r.read(), {k.lower(): v for k, v in r.headers.items()}, r.status
    except urllib.error.HTTPError as exc:
        payload, headers, status = exc.read(), {k.lower(): v for k, v in exc.headers.items()}, exc.code
    try:
        return status, json.loads(payload), headers
    except json.JSONDecodeError:
        return status, payload, headers


def must(*args, **kw):
    status, payload, headers = call(*args, **kw)
    if status >= 300:
        raise SystemExit(f"{args[0]} {args[1]} -> {status}: {payload}")
    return payload, headers


def noisy_png(width, height, seed):
    """A PNG whose pixels do not repeat, so deflate cannot shrink it to nothing."""
    rows = bytearray()
    state = (seed * 2654435761) & 0xFFFFFFFF
    for y in range(height):
        rows.append(0)  # filter type None
        for x in range(width):
            state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
            rows += bytes(((state >> 24) & 0xFF, (x * 255) // max(1, width - 1), (y * 3) & 0xFF))

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


def upload(token, channel_id, name, data):
    boundary = "----t38heavy" + os.urandom(8).hex()
    body = bytearray()
    body += f"--{boundary}\r\n".encode()
    body += f'Content-Disposition: form-data; name="channel_id"\r\n\r\n{channel_id}\r\n'.encode()
    body += f"--{boundary}\r\n".encode()
    body += f'Content-Disposition: form-data; name="files"; filename="{name}"\r\n'.encode()
    body += b"Content-Type: image/png\r\n\r\n" + data + b"\r\n"
    body += f"--{boundary}--\r\n".encode()
    info, _ = must("POST", "/files", token=token, raw=bytes(body),
                   content_type=f"multipart/form-data; boundary={boundary}")
    return info["file_infos"][0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--posts", type=int, default=4)
    ap.add_argument("--images", type=int, default=10)
    ap.add_argument("--width", type=int, default=1024)
    ap.add_argument("--height", type=int, default=768)
    args = ap.parse_args()
    if args.images > 10:
        raise SystemExit("the server caps a post at 10 file ids (docs/t38-build-note.md §2)")

    status, me, headers = call("POST", "/users/login", {"login_id": LOGIN[0], "password": LOGIN[1]})
    if status != 200:
        raise SystemExit(f"login failed: {status} {me}")
    token = headers["token"]

    teams, _ = must("GET", "/users/me/teams", token=token)
    team = next((t for t in teams if t.get("name") == TEAM), None)
    if team is None:
        raise SystemExit(f"team #{TEAM} missing — run scripts/perf_seed.py")

    status, channel, _ = call("GET", f"/teams/{team['id']}/channels/name/{CHANNEL}", token=token)
    if status != 200:
        channel, _ = must("POST", "/channels", token=token, body={
            "team_id": team["id"], "name": CHANNEL, "display_name": "T38 media heavy",
            "type": "O",
            "purpose": "T38 memory probe: a media-heavy channel for the bounded-load measurement",
        })
        print(f"created channel #{CHANNEL} {channel['id']}")
    else:
        print(f"reusing channel #{CHANNEL} {channel['id']}")

    existing, _ = must("GET", f"/channels/{channel['id']}/posts?per_page=200", token=token)
    have = {p.get("props", {}).get(KEY) for p in existing["posts"].values()}
    created, total_bytes, sizes = [], 0, []
    for i in range(args.posts):
        key = f"t38-heavy-{i}"
        if key in have:
            print(f"reusing post {key}")
            created.append(key)
            continue
        files = []
        for j in range(args.images):
            data = noisy_png(args.width, args.height, i * 100 + j)
            files.append((upload(token, channel["id"], f"heavy-{i:02d}-{j:02d}.png", data), len(data)))
            sizes.append(len(data))
            total_bytes += len(data)
        post, _ = must("POST", "/posts", token=token, body={
            "channel_id": channel["id"],
            "message": f"T38 media-heavy post {i} ({args.images} images)",
            "file_ids": [info["id"] for info, _ in files],
            "props": {KEY: key},
        })
        print(f"created {key}: {args.images} images, post {post['id']}")
        created.append(key)

    print(json.dumps({"channel_id": channel["id"], "channel_name": CHANNEL,
                      "posts": created, "images_per_post": args.images,
                      "image_bytes_total": total_bytes,
                      "image_bytes_min": min(sizes) if sizes else 0,
                      "image_bytes_max": max(sizes) if sizes else 0}, indent=2))


if __name__ == "__main__":
    main()
