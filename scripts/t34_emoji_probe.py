#!/usr/bin/env python3
"""Probe: create one custom emoji via POST /emoji (multipart: `emoji` JSON + `image` file)."""
import json, urllib.error, urllib.request, uuid, struct, zlib

BASE = "http://127.0.0.1:8065"
LOGIN, PASSWORD = "perfprobe", "PerfProbe-Not-A-Real-Secret-1"


def png(size=40):
    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))
    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            inside = (x // 5 + y // 5) % 2 == 0
            rows += bytes((20, 90, 160) if inside else (240, 200, 40))
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def call(method, path, body=None, raw=None, ctype="application/json", token=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(f"{BASE}/api/v4{path}", data=data, method=method)
    req.add_header("Content-Type", ctype)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = resp.read()
            return resp.status, (json.loads(payload) if payload.strip() else None), dict(resp.headers)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode(errors="replace"), dict(exc.headers)


status, _, headers = call("POST", "/users/login", {"login_id": LOGIN, "password": PASSWORD})
token = headers.get("Token") or headers.get("token")
status, me, _ = call("GET", "/users/me", token=token)
print("login", status, "user", me["id"])

status, emoji, _ = call("GET", "/emoji?page=0&per_page=200&sort=", token=token)
print("list before:", status, [(e.get("name"), e.get("id")) for e in emoji] if isinstance(emoji, list) else emoji)


def create(name):
    boundary = "----t34probe" + uuid.uuid4().hex
    model = json.dumps({"name": name, "creator_id": me["id"]})
    parts = [f"--{boundary}\r\nContent-Disposition: form-data; name=\"emoji\"\r\n\r\n{model}\r\n".encode(),
             f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; filename=\"{name}.png\"\r\n"
             f"Content-Type: image/png\r\n\r\n".encode(),
             png(),
             f"\r\n--{boundary}--\r\n".encode()]
    return call("POST", "/emoji", raw=b"".join(parts),
                ctype=f"multipart/form-data; boundary={boundary}", token=token)


print("create:", create("t34parrot"))
status, emoji, _ = call("GET", "/emoji?page=0&per_page=200&sort=", token=token)
print("list after:", status, [(e.get("name"), e.get("id")) for e in emoji] if isinstance(emoji, list) else emoji)
if isinstance(emoji, list) and emoji:
    eid = emoji[0]["id"]
    status, data, hdrs = call("GET", f"/emoji/{eid}/image", token=token)
    print("image:", status, hdrs.get("Content-Type"), len(data) if isinstance(data, bytes) else data)
