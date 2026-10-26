#!/usr/bin/env python3
"""Seed the local throwaway Mattermost server with T38's attachment fixture.

Why this exists: T38's acceptance criterion is a claim about a **real** post rendered by the running
app — "a post with 10 image attachments, 3 files and a PDF renders and opens each correctly" — and
the screenshot evidence in `docs/` has to show server data, not a fixture. So the fixture is created
through the same public API a browser would use (`POST /files` multipart, then `POST /posts` with
`file_ids`), and the post carries everything the card names, plus the two hostile cases:

  * 10 PNG images of different aspect ratios (so the grid's cell rule is exercised by real bytes);
  * 3 files with no native reader: `notes.txt` (text reader), `data.csv` (text reader) and
    `bundle.zip` (no reader → the safe "not previewed" screen);
  * 1 PDF (the PDFKit reader);
  * 1 `payload.html` uploaded **with `mime_type: image/png`** — the case the classifier must refuse
    on the *name* rather than trusting the server's claim (measured: the server stores whatever
    content type the uploader sent, so this is reachable input, not a hypothetical);
  * 1 oversized text file (`dump.log`, 300 KB) for the text reader's byte cap.

Idempotency: the post is keyed on `props.t38_key`, so re-running reuses the existing post instead of
creating a second one. The script prints the post id and each file id as JSON — the UI test and the
capture script read the fixture from the channel itself, never from a copied id.

Credentials are the throwaway dev account already committed for this machine's server
(`scripts/perf_seed.py`); no token is written anywhere.

Usage:
    python3 scripts/t38_attachment_seed.py --url http://127.0.0.1:8065
    python3 scripts/t38_attachment_seed.py --url http://127.0.0.1:8065 --reset
"""

from __future__ import annotations

import argparse
import io
import json
import struct
import sys
import urllib.error
import urllib.request
import uuid
import zipfile
import zlib

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
CHANNEL_NAME = "t38-files"
CHANNEL_DISPLAY = "T38 attachments"
CHANNEL_PURPOSE = "T38 fixture: a post with 10 images, 3 files, a PDF and two hostile files"
POST_KEY_IMAGES = "t38-images"
POST_KEY_FILES = "t38-files"


def ensure_post(client: Client, channel_id: str, key: str, message: str,
                files: list[tuple[str, str, bytes]], reset: bool) -> dict:
    """Create (or reuse) one post carrying `files`, keyed on `props.<key>` for idempotency."""
    posts = recent_posts(client, channel_id)
    existing = next((p for p in posts if (p.get("props") or {}).get("t38_key") == key), None)
    if existing and not reset:
        print(f"reusing post {existing['id']} ({key})")
        return {"post_id": existing["id"], "file_ids": existing.get("file_ids", []), "reused": True}
    if existing and reset:
        status, body, _ = client.call("DELETE", f"/posts/{existing['id']}")
        if status >= 300:
            raise APIError(f"could not delete the old {key} post: {status} {body}")
        print(f"deleted old post {existing['id']} ({key})")

    infos = []
    for name, content_type, data in files:
        info = upload(client, channel_id, name, content_type, data)
        infos.append(info)
        print(f"  uploaded {name} ({info.get('size')} bytes, {info.get('mime_type')}) -> {info['id']}")

    file_ids = [info["id"] for info in infos]
    if len(file_ids) > 10:
        raise APIError(f"{key} would carry {len(file_ids)} files; the server's hard cap is 10 per post")
    post, _ = client.must("POST", "/posts", {
        "channel_id": channel_id,
        "message": message,
        "file_ids": file_ids,
        "props": {"t38_key": key, "t38_seed": "t38_attachment_seed.py"},
    })
    return {"post_id": post["id"], "file_ids": file_ids, "reused": False,
            "files": [{"id": info["id"], "name": info.get("name"),
                       "mime_type": info.get("mime_type"), "size": info.get("size")} for info in infos]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--reset", action="store_true",
                        help="delete the existing T38 fixture posts before recreating them")
    args = parser.parse_args()

    client = login(args.url, USERNAME, PASSWORD)
    teams = [t for t in client.must("GET", "/users/me/teams")[0] if t.get("name") == TEAM_NAME]
    if not teams:
        raise SystemExit(f"team #{TEAM_NAME} is missing — run scripts/perf_seed.py first")
    team_id = teams[0]["id"]
    channel = ensure_channel(client, team_id)
    fixtures = fixture_files()

    images = ensure_post(client, channel["id"], POST_KEY_IMAGES,
                         "T38 fixture A: ten image attachments (the server's hard cap is ten per post).",
                         fixtures["images"], args.reset)
    files = ensure_post(client, channel["id"], POST_KEY_FILES,
                        "T38 fixture B: three files, a PDF, a page saved as .html and an oversized log.",
                        fixtures["files"], args.reset)

    print(json.dumps({"channel_id": channel["id"], "channel_name": CHANNEL_NAME,
                      "images": images, "files": files}, indent=2))
    return 0


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/") + "/api/v4"
        self.token = token

    def call(self, method: str, path: str, body=None, raw: bytes | None = None,
             content_type: str = "application/json"):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            request.add_header("Authorization", "Bearer " + self.token)
        if data is not None:
            request.add_header("Content-Type", content_type)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = response.read()
                headers = {k.lower(): v for k, v in response.headers.items()}
            try:
                return response.status, json.loads(payload), headers
            except json.JSONDecodeError:
                return response.status, payload, headers
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            try:
                return exc.code, json.loads(payload), {k.lower(): v for k, v in exc.headers.items()}
            except json.JSONDecodeError:
                return exc.code, payload.decode(errors="replace"), {k.lower(): v for k, v in exc.headers.items()}

    def must(self, method: str, path: str, body=None, raw: bytes | None = None,
             content_type: str = "application/json"):
        status, payload, headers = self.call(method, path, body, raw, content_type)
        if status >= 300:
            raise APIError(f"{method} {path} -> {status}: {payload}")
        return payload, headers


def login(base: str, login_id: str, password: str) -> Client:
    status, payload, headers = Client(base).call("POST", "/users/login",
                                                 {"login_id": login_id, "password": password})
    if status != 200 or not headers.get("token"):
        raise APIError(f"login as {login_id} failed: {status} {payload}")
    return Client(base, headers["token"])


# ---------------------------------------------------------------------------- fixture payloads

def fixture_png(width: int, height: int, tint: int) -> bytes:
    """A real PNG, built with the standard library (no Pillow on this host).

    Truecolour, 8 bits, no interlace: a horizontal gradient tinted per file so ten thumbnails in one
    grid are visibly ten different images rather than ten copies of one.
    """
    rows = bytearray()
    for y in range(height):
        rows.append(0)  # PNG filter type 0 (None)
        for x in range(width):
            rows += bytes(((x * 255) // max(1, width - 1),
                           (y * 255) // max(1, height - 1),
                           tint))

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 6)) + chunk(b"IEND", b""))


def fixture_pdf() -> bytes:
    """A minimal single-page PDF that a real parser (PDFKit) accepts.

    Hand-built rather than generated: the fixture must not depend on a toolchain, and the byte layout
    has to be exactly what the PDF reader is tested against.
    """
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length 78 >>\nstream\nBT /F1 24 Tf 72 760 Td (T38 attachment fixture) Tj ET\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(out.tell())
        out.write(f"{index} 0 obj\n".encode() + body + b"\nendobj\n")
    xref = out.tell()
    out.write(f"xref\n0 {len(objects) + 1}\n".encode())
    out.write(b"0000000000 65535 f \n")
    for offset in offsets:
        out.write(f"{offset:010d} 00000 n \n".encode())
    out.write(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    return out.getvalue()


def fixture_zip() -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("README.txt", "T38 fixture archive.\n")
        archive.writestr("data/rows.csv", "a,b\n1,2\n")
    return buffer.getvalue()


HOSTILE_HTML = (b"<!doctype html><html><head><title>t38 hostile</title></head>"
                b"<body><script>document.title='EXECUTED'</script>"
                b"<p>If you can read this inside the app, the file was interpreted.</p>"
                b"</body></html>")


def fixture_files() -> dict[str, list[tuple[str, str, bytes]]]:
    """`{"images": [...], "files": [...]}` — (name, content type, bytes) per post."""
    images = [
        ("t38-shot-01.png", "image/png", fixture_png(640, 480, 40)),
        ("t38-shot-02.png", "image/png", fixture_png(480, 640, 70)),
        ("t38-shot-03.png", "image/png", fixture_png(800, 200, 100)),
        ("t38-shot-04.png", "image/png", fixture_png(300, 300, 130)),
        ("t38-shot-05.png", "image/png", fixture_png(1024, 768, 160)),
        ("t38-shot-06.png", "image/png", fixture_png(200, 500, 190)),
        ("t38-shot-07.png", "image/png", fixture_png(600, 600, 220)),
        ("t38-shot-08.png", "image/png", fixture_png(360, 240, 250)),
        ("t38-shot-09.png", "image/png", fixture_png(720, 405, 12)),
        ("t38-shot-10.png", "image/png", fixture_png(500, 500, 204)),
    ]
    files = [
        ("t38-notes.txt", "text/plain",
         b"T38 text attachment.\n\nThe text reader shows these bytes as characters and never runs them.\n"),
        ("t38-data.csv", "text/csv", b"id,value\n1,alpha\n2,beta\n3,gamma\n"),
        ("t38-bundle.zip", "application/zip", fixture_zip()),
    ]
    pdf = [("t38-report.pdf", "application/pdf", fixture_pdf())]
    hostile = [
        # A page. The server normalises the stored `mime_type` to `text/html; charset=utf-8` (measured:
        # it sniffs rather than trusting the upload's content type), so this is hostile by name *and*
        # by MIME — the classifier refuses it on the name first.
        ("t38-payload.html", "image/png", HOSTILE_HTML),
        # A text file far past the reader's 256 KB cap (≈ 337 KB), so the "showing the first N" note
        # is real rather than aspirational.
        ("t38-dump.log", "text/plain", b"line " + b"x" * 60 + b"\n" + (b"0123456789" * 30 + b"\n") * 1400),
    ]
    # Two posts, not one: 10 is a **hard** server limit per post ("Attachments per message 10",
    # Mattermost product limits; `POST /posts` answers 400 `model.post.is_valid.file_ids.app_error`
    # with "uploads are limited to 10 files maximum" for 16 file ids — measured on 9.11.19 here).
    return {"images": images, "files": files + pdf + hostile}


# ---------------------------------------------------------------------------- server helpers

def ensure_channel(client: Client, team_id: str) -> dict:
    status, payload, _ = client.call("GET", f"/teams/{team_id}/channels/name/{CHANNEL_NAME}")
    if status == 200:
        return payload
    body = {"team_id": team_id, "name": CHANNEL_NAME, "display_name": CHANNEL_DISPLAY,
            "type": "O", "purpose": CHANNEL_PURPOSE, "header": ""}
    payload, _ = client.must("POST", "/channels", body)
    print(f"created channel #{CHANNEL_NAME} ({payload['id']})")
    return payload


def upload(client: Client, channel_id: str, name: str, content_type: str, data: bytes) -> dict:
    boundary = "----t38fixture" + uuid.uuid4().hex
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"channel_id\"\r\n\r\n"
        f"{channel_id}\r\n".encode(),
        (f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; "
         f"filename=\"{name}\"\r\nContent-Type: {content_type}\r\n\r\n").encode(),
        data,
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    payload, _ = client.must("POST", "/files", raw=b"".join(parts),
                             content_type=f"multipart/form-data; boundary={boundary}")
    infos = payload.get("file_infos") or []
    if not infos:
        raise APIError(f"upload of {name} returned no file_infos: {payload}")
    return infos[0]


def recent_posts(client: Client, channel_id: str, count: int = 60) -> list[dict]:
    payload, _ = client.must("GET", f"/channels/{channel_id}/posts?per_page={count}")
    return [payload["posts"][pid] for pid in payload.get("order", []) if pid in payload.get("posts", {})]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--reset", action="store_true",
                        help="delete the existing T38 fixture posts before recreating them")
    args = parser.parse_args()

    client = login(args.url, USERNAME, PASSWORD)
    teams = [t for t in client.must("GET", "/users/me/teams")[0] if t.get("name") == TEAM_NAME]
    if not teams:
        raise SystemExit(f"team #{TEAM_NAME} is missing — run scripts/perf_seed.py first")
    team_id = teams[0]["id"]
    channel = ensure_channel(client, team_id)
    fixtures = fixture_files()

    images = ensure_post(client, channel["id"], POST_KEY_IMAGES,
                         "T38 fixture A: ten image attachments (the server's hard cap is ten per post).",
                         fixtures["images"], args.reset)
    files = ensure_post(client, channel["id"], POST_KEY_FILES,
                        "T38 fixture B: three files, a PDF, a page saved as .html and an oversized log.",
                        fixtures["files"], args.reset)

    print(json.dumps({"channel_id": channel["id"], "channel_name": CHANNEL_NAME,
                      "images": images, "files": files}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
