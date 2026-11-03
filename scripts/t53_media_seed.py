#!/usr/bin/env python3
"""Seed the local throwaway Mattermost server with T53's media fixture.

Why this exists: T53's acceptance criterion is a claim about a **real** post rendered by the running
app — "the video plays past 1 s, the audio player advances" — so both files are uploaded through the
same public API a browser uses (`POST /files` multipart, then `POST /posts` with `file_ids`). Nothing
is mocked and no binary is committed: the two payloads are generated on this host with ffmpeg at run
time (H.264/AAC mp4 and MP3), because a 8-second 320×240 clip is a few hundred KB and does not belong
in git.

It also prints the three measurements the T53 decision rests on, so the numbers in
`docs/t53-build-note.md` can be re-derived at any time:

  * the server's own `FileInfo` for each upload (does it carry a `metadata` duration?),
  * `GET /files/{video}/thumbnail` — does the pinned 9.11.19 server generate a poster frame for an
    mp4, or answer 404?
  * `GET /files/{video}` with `Range: bytes=0-1` and the response's `Accept-Ranges` — whether a
    byte-range reader (the AVURLAsset header path) could work at all.

Idempotency: the post is keyed on `props.t53_key`; re-running reuses it. `--reset` deletes and
recreates. Credentials are the throwaway dev account committed for this machine's server
(`scripts/perf_seed.py`); no token is written anywhere.

Usage:
    python3 scripts/t53_media_seed.py --url http://127.0.0.1:8065
    python3 scripts/t53_media_seed.py --url http://127.0.0.1:8065 --reset
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
CHANNEL_NAME = "t53-media"
CHANNEL_DISPLAY = "T53 media"
CHANNEL_PURPOSE = "T53 fixture: one mp4 and one mp3, played by the native attachment viewer"
POST_KEY = "t53-media"


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/") + "/api/v4"
        self.token = token

    def call(self, method: str, path: str, body=None, raw: bytes | None = None,
             content_type: str = "application/json", extra_headers: dict[str, str] | None = None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            request.add_header("Authorization", "Bearer " + self.token)
        if data is not None:
            request.add_header("Content-Type", content_type)
        for key, value in (extra_headers or {}).items():
            request.add_header(key, value)
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                payload = response.read()
                headers = {k.lower(): v for k, v in response.headers.items()}
                status = response.status
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            headers = {k.lower(): v for k, v in exc.headers.items()}
            status = exc.code
            return status, payload, headers
        try:
            return status, json.loads(payload), headers
        except json.JSONDecodeError:
            return status, payload, headers

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


# ---------------------------------------------------------------------------- media generation


def ffmpeg_binary() -> str:
    """An ffmpeg that can encode H.264 and MP3.

    This host has two: `/usr/local/bin/ffmpeg` is an older build with no `libx264`/`libmp3lame`
    (measured: `-preset` is rejected and only `h264_videotoolbox`/`aac` are listed), while the
    Homebrew one has both. `FFMPEG=/path/to/ffmpeg` overrides.
    """
    override = os.environ.get("FFMPEG")
    if override:
        return override
    for candidate in ("/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if os.path.exists(candidate):
            return candidate
    return "ffmpeg"


def ffmpeg(*args: str) -> None:
    result = subprocess.run([ffmpeg_binary(), "-hide_banner", "-loglevel", "error", "-y", *args],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise APIError(f"ffmpeg failed: {result.stderr.strip()}")


def media_files(directory: str) -> list[tuple[str, str, bytes]]:
    """Return `(name, content type, bytes)` for the fixture's video and audio.

    8 seconds is long enough for the live test's "played past 1 s" assertion and short enough that
    the whole fixture is a few hundred KB. The tone makes the audio audible/inspectable; the moving
    test pattern makes a poster frame visibly a frame rather than black.
    """
    video_path = os.path.join(directory, "t53-clip.mp4")
    audio_path = os.path.join(directory, "t53-tone.mp3")
    ffmpeg("-f", "lavfi", "-i", "testsrc=duration=8:size=320x240:rate=15",
           "-f", "lavfi", "-i", "sine=frequency=440:duration=8",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "veryfast", "-crf", "30",
           "-c:a", "aac", "-b:a", "48k", "-shortest", "-movflags", "+faststart", video_path)
    ffmpeg("-f", "lavfi", "-i", "sine=frequency=440:duration=8",
           "-c:a", "libmp3lame", "-b:a", "48k", audio_path)
    with open(video_path, "rb") as handle:
        video = handle.read()
    with open(audio_path, "rb") as handle:
        audio = handle.read()
    return [("t53-clip.mp4", "video/mp4", video), ("t53-tone.mp3", "audio/mpeg", audio)]


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
    boundary = "----t53fixture" + uuid.uuid4().hex
    parts = [
        (f"--{boundary}\r\nContent-Disposition: form-data; name=\"channel_id\"\r\n\r\n"
         f"{channel_id}\r\n").encode(),
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


def ensure_post(client: Client, channel_id: str, files, reset: bool) -> dict:
    posts = recent_posts(client, channel_id)
    existing = next((p for p in posts if (p.get("props") or {}).get("t53_key") == POST_KEY), None)
    if existing and not reset:
        print(f"reusing post {existing['id']} ({POST_KEY})")
        return {"post_id": existing["id"], "file_ids": existing.get("file_ids", []), "reused": True}
    if existing and reset:
        status, body, _ = client.call("DELETE", f"/posts/{existing['id']}")
        if status >= 300:
            raise APIError(f"could not delete the old {POST_KEY} post: {status} {body}")
        print(f"deleted old post {existing['id']} ({POST_KEY})")

    infos = []
    for name, content_type, data in files:
        info = upload(client, channel_id, name, content_type, data)
        infos.append(info)
        print(f"  uploaded {name} ({info.get('size')} bytes, {info.get('mime_type')}) -> {info['id']}")
    file_ids = [info["id"] for info in infos]
    post, _ = client.must("POST", "/posts", {
        "channel_id": channel_id,
        "message": "T53 fixture: one mp4 and one mp3 played by the native attachment viewer.",
        "file_ids": file_ids,
        "props": {"t53_key": POST_KEY, "t53_seed": "t53_media_seed.py"},
    })
    return {"post_id": post["id"], "file_ids": file_ids, "reused": False}


def measurements(client: Client, file_ids: list[str]) -> dict:
    """The three facts the transport decision rests on, read from the server itself."""
    out: dict[str, object] = {"files": {}, "thumbnail": {}, "range": {}}
    for file_id in file_ids:
        status, info, _ = client.call("GET", f"/files/{file_id}/info")
        out["files"][file_id] = {"status": status, "info": info if isinstance(info, dict) else None}

        status, body, headers = client.call("GET", f"/files/{file_id}/thumbnail")
        out["thumbnail"][file_id] = {
            "status": status,
            "content_type": headers.get("content-type"),
            "bytes": len(body) if isinstance(body, bytes) else 0,
        }

        status, body, headers = client.call("GET", f"/files/{file_id}",
                                            extra_headers={"Range": "bytes=0-1"})
        out["range"][file_id] = {
            "status": status,
            "accept_ranges": headers.get("accept-ranges"),
            "content_range": headers.get("content-range"),
            "bytes": len(body) if isinstance(body, bytes) else 0,
        }
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--reset", action="store_true",
                        help="delete the existing T53 fixture post before recreating it")
    args = parser.parse_args()

    client = login(args.url, USERNAME, PASSWORD)
    teams = [t for t in client.must("GET", "/users/me/teams")[0] if t.get("name") == TEAM_NAME]
    if not teams:
        raise SystemExit(f"team #{TEAM_NAME} is missing — run scripts/perf_seed.py first")
    team_id = teams[0]["id"]
    channel = ensure_channel(client, team_id)

    with tempfile.TemporaryDirectory(prefix="t53-media-") as directory:
        files = media_files(directory)
        post = ensure_post(client, channel["id"], files, args.reset)

    probes = measurements(client, post["file_ids"])
    print(json.dumps({"channel_id": channel["id"], "channel_name": CHANNEL_NAME,
                      "post": post, "measurements": probes}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
