#!/usr/bin/env python3
"""Seed the local throwaway Mattermost server for T34 (native channel view / post list).

Why this exists: T34's evidence needs a **real** server whose data exercises every rendering rule
this card implements, and it has to be reproducible:

  * a long history to paginate (`perf-feed`, topped up to >= 500 posts by this script), because the
    "no dropped / no duplicated posts across page boundaries" criterion is a statement about real
    page boundaries;
  * a `t34-showcase` channel with one post per markdown/GFM case (bold+italic+inline code, a link,
    fenced code in two languages, a GFM table, a blockquote, a list, emoticons, a custom emoji, an
    @-mention, a channel link, raw HTML that must NOT render), because a unit test on the parser and
    a screenshot of a running app are different claims;
  * an edited post, a deleted post (tombstone), a very long post, an image attachment and reactions,
    which are the row states the post list must draw.

Everything is idempotent and keyed on a `props.t34_key` marker written into the post itself, so
re-running reuses the posts the previous run created instead of piling up duplicates. The marker is
also how the capture script and the UI tests find "the edited post" without trusting an id copied
into a test file.

Credentials are the ones already committed for this machine's throwaway server
(`scripts/perf_seed.py`, `scripts/t33_channel_seed.py`); this script never writes a token anywhere.

Usage:
    python3 scripts/t34_post_seed.py --url http://127.0.0.1:8065
    python3 scripts/t34_post_seed.py --url http://127.0.0.1:8065 --min-posts 500
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

USERNAME = "perfprobe"
PASSWORD = "PerfProbe-Not-A-Real-Secret-1"
BOT_USERNAME = "opsbot"
BOT_PASSWORD = "OpsBot-Not-A-Real-Secret-1"
TEAM_NAME = "perf"
LONG_CHANNEL_NAME = "perf-feed"
SHOWCASE_CHANNEL_NAME = "t34-showcase"
FOLD_CHANNEL_NAME = "t34-fold"

# A deterministic gradient PNG, built with the standard library: the row must lay out a real
# thumbnail, and the server only generates one for an image bigger than a thumbnail (a 16×16 probe
# answers 404 from `/files/{id}/thumbnail`, which this fixture hit first).
def fixture_png(width: int = 240, height: int = 160) -> bytes:
    import struct
    import zlib

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    rows = bytearray()
    for y in range(height):
        rows.append(0)          # PNG filter type 0 (None)
        for x in range(width):
            rows += bytes(((x * 255) // max(1, width - 1),
                           (y * 255) // max(1, height - 1),
                           160))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


class APIError(RuntimeError):
    pass


class Client:
    def __init__(self, base: str, token: str | None = None):
        self.base = base.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, body=None, raw: bytes | None = None,
             content_type: str = "application/json"):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(f"{self.base}/api/v4{path}", data=data, method=method)
        req.add_header("Content-Type", content_type)
        req.add_header("X-Requested-With", "XMLHttpRequest")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                payload = resp.read()
                return (resp.status, (json.loads(payload) if payload.strip() else None),
                        {k.lower(): v for k, v in resp.headers.items()})
        except urllib.error.HTTPError as exc:
            payload = exc.read()
            try:
                decoded = json.loads(payload)
            except Exception:
                decoded = payload.decode(errors="replace")
            return exc.code, decoded, {k.lower(): v for k, v in exc.headers.items()}

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


def ensure_channel(client: Client, team_id: str, name: str, display_name: str, purpose: str) -> dict:
    status, payload, _ = client.call("GET", f"/teams/{team_id}/channels/name/{name}")
    if status == 200:
        return payload
    body = {"team_id": team_id, "name": name, "display_name": display_name,
            "type": "O", "purpose": purpose, "header": ""}
    payload, _ = client.must("POST", "/channels", body)
    print(f"created channel {name} ({payload['id']})")
    return payload


def ensure_member(client: Client, channel_id: str, user_id: str) -> None:
    status, _, _ = client.call("POST", f"/channels/{channel_id}/members", {"user_id": user_id})
    if status >= 300 and status != 400:      # 400 = already a member
        raise APIError(f"add {user_id} to {channel_id} -> {status}")


def recent_posts(client: Client, channel_id: str, count: int = 200) -> list[dict]:
    payload, _ = client.must("GET", f"/channels/{channel_id}/posts?per_page={count}")
    return [payload["posts"][pid] for pid in payload.get("order", []) if pid in payload.get("posts", {})]


def find_marked(posts: list[dict], key: str) -> dict | None:
    for post in posts:
        props = post.get("props") or {}
        if props.get("t34_key") == key:
            return post
    return None


def create_post(client: Client, channel_id: str, message: str, key: str,
                file_ids: list[str] | None = None) -> dict:
    body = {"channel_id": channel_id, "message": message,
            "props": {"t34_key": key, "t34_seed": "t34_post_seed.py"}}
    if file_ids:
        body["file_ids"] = file_ids
    payload, _ = client.must("POST", "/posts", body)
    return payload


def upload_png(client: Client, channel_id: str) -> str:
    boundary = "----t34fixture" + uuid.uuid4().hex
    parts = []
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"channel_id\"\r\n\r\n"
                 f"{channel_id}\r\n".encode())
    parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"files\"; "
                 f"filename=\"t34-thumbnail.png\"\r\nContent-Type: image/png\r\n\r\n".encode())
    parts.append(fixture_png())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    body = b"".join(parts)
    payload, _ = client.must("POST", "/files", raw=body,
                             content_type=f"multipart/form-data; boundary={boundary}")
    infos = payload.get("file_infos") or []
    if not infos:
        raise APIError(f"file upload returned no infos: {payload}")
    return infos[0]["id"]


def add_reaction(client: Client, user_id: str, post_id: str, emoji: str) -> None:
    status, _, _ = client.call("POST", "/reactions",
                               {"user_id": user_id, "post_id": post_id, "emoji_name": emoji})
    if status >= 300 and status != 400:      # 400 = already reacted
        raise APIError(f"reaction {emoji} on {post_id} -> {status}")


# The showcase content. `key` is the idempotency marker; the same text is what the UI test asserts.
SHOWCASE = [
    ("inline", "**bold** and *italic* and `inline code` and [a link](https://docs.mattermost.com) "
               "and ~town-square and :tada: and @opsbot and <b>not html</b> "
               "and [not a link](javascript:alert(1))"),
    ("code-swift", "A Swift block:\n\n```swift\nstruct Post: Codable {\n    let id: String\n}\n```"),
    ("code-json", "A JSON block:\n\n```json\n{\"order\": [\"p1\", \"p2\"], \"has_next\": true}\n```"),
    ("table", "A table:\n\n| Column | Value |\n|---|---|\n| alpha | 1 |\n| beta | 2 |"),
    ("quote", "> Quoted text\n> second line\n\n- first item\n- second item\n\n1. one\n2. two"),
    ("edited", "this line was edited by the seed"),
    ("long", "long post\n\n" + "\n\n".join(
        f"paragraph {i:02d}: " + ("the quick brown fox jumps over the lazy dog. " * 8)
        for i in range(1, 41))),
    # T34 review F7: a custom emoji the server owns (created by `ensure_emoji`), next to a built-in.
    ("custom-emoji", "a custom emoji :t34parrot: and a built-in :tada: beside it"),
    # The attachment post's message is set after the upload, so this entry is only a marker.
    ("attachment", "an image attachment:"),
]

# T34 review F6 lives in its own channel.
#
# The finding was that a post which is **one** markdown block was drawn in full and "Show more" revealed
# nothing (the old rule counted blocks, and a 600-line fence is one block). Proving the fix needs posts
# whose single block is thousands of points tall; keeping them in the showcase channel would make every
# other test scroll past them and made the accessibility tree needlessly heavy, so they get a channel.
# Both stay well under the server's 16 383-byte post limit: 250 lines ≈ 5.3 KB, ~4 KB of prose.
FOLD = [
    ("huge-fence", "```\n" + "\n".join(f"line {i:04d} of the log" for i in range(1, 251)) + "\n```"),
    ("huge-paragraph", "the quick brown fox jumps over the lazy dog. " * 90),
]

# The custom emoji this fixture needs. Created once per server by `ensure_emoji`; the renderer resolves
# it through `GET /emoji` and draws it from `GET /emoji/{id}/image`.
CUSTOM_EMOJI_NAME = "t34parrot"


def emoji_png(size: int = 40) -> bytes:
    """A checkerboard PNG, distinct from the attachment so the screenshot cannot confuse the two."""
    import struct
    import zlib

    def chunk(tag: bytes, payload: bytes) -> bytes:
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            rows += bytes((20, 90, 160) if (x // 5 + y // 5) % 2 == 0 else (240, 200, 40))
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + chunk(b"IEND", b""))


def ensure_emoji(client: Client, user_id: str, name: str) -> dict:
    """Create `:name:` on the server if it is not there yet, and return its emoji object.

    `POST /api/v4/emoji` is multipart with a **form value** `emoji` carrying the model as JSON and a
    file field `image` (server/channels/api4/emoji.go, `createEmoji`). A duplicate name answers 400,
    which is why the list is read first: the seed has to be idempotent.
    """
    status, listed, _ = client.call("GET", "/emoji?page=0&per_page=200&sort=")
    if status == 200 and isinstance(listed, list):
        for emoji in listed:
            if emoji.get("name") == name and not emoji.get("delete_at"):
                return emoji
    boundary = "----t34emoji" + uuid.uuid4().hex
    model = json.dumps({"name": name, "creator_id": user_id})
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"emoji\"\r\n\r\n{model}\r\n".encode(),
        (f"--{boundary}\r\nContent-Disposition: form-data; name=\"image\"; "
         f"filename=\"{name}.png\"\r\nContent-Type: image/png\r\n\r\n").encode(),
        emoji_png(),
        f"\r\n--{boundary}--\r\n".encode(),
    ]
    payload, _ = client.must("POST", "/emoji", raw=b"".join(parts),
                             content_type=f"multipart/form-data; boundary={boundary}")
    print(f"  created custom emoji :{name}: ({payload.get('id')})")
    return payload


def seed_cases(client: Client, channel: dict, cases: list, recreate: bool) -> dict:
    """Create one post per `(key, text)` case, idempotent on `props.t34_key`.

    `props` is the only marker, so a case whose text changed would otherwise keep the old message
    forever; `recreate` deletes the marked posts first. It also sweeps a UI run's leftover "live post",
    which is not fixture content and makes every later count flaky.
    """
    for post in recent_posts(client, channel["id"], count=200):
        if (post.get("message") or "").startswith("t34 ui live post"):
            client.call("DELETE", f"/posts/{post['id']}")
            print(f"  removed a leftover UI-test post ({post['id']})")
    if recreate:
        for key, _ in cases:
            post = find_marked(recent_posts(client, channel["id"], count=200), key)
            if post is not None:
                client.call("DELETE", f"/posts/{post['id']}")
                print(f"  deleted post {key} ({post['id']})")
    existing = recent_posts(client, channel["id"])
    ids = {}
    for key, text in cases:
        post = find_marked(existing, key)
        if post is None:
            post = create_post(client, channel["id"], text, key)
            print(f"  created post {key} ({post['id']})")
        ids[key] = post["id"]
    return ids


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8065")
    ap.add_argument("--min-posts", type=int, default=500,
                    help="top the long channel up to at least this many posts")
    ap.add_argument("--recreate", action="store_true",
                    help="delete the marked showcase posts first, so a changed case text is re-created")
    args = ap.parse_args()

    probe = login(args.url, USERNAME, PASSWORD)
    bot = login(args.url, BOT_USERNAME, BOT_PASSWORD)
    me, _ = probe.must("GET", "/users/me")
    bot_me, _ = bot.must("GET", "/users/me")

    status, team, _ = probe.call("GET", f"/teams/name/{TEAM_NAME}")
    if status != 200:
        print(f"the {TEAM_NAME} team does not exist on {args.url}; run scripts/perf_seed.py first",
              file=sys.stderr)
        return 1
    team_id = team["id"]

    long_channel = ensure_channel(probe, team_id, LONG_CHANNEL_NAME, "Perf Feed",
                                  "T34 long history: paginated real posts.")
    showcase = ensure_channel(probe, team_id, SHOWCASE_CHANNEL_NAME, "T34 Showcase",
                              "T34 rendering fixture: one post per markdown / row case.")
    fold_channel = ensure_channel(probe, team_id, FOLD_CHANNEL_NAME, "T34 Fold",
                                  "T34 review F6: posts that are a single markdown block.")

    for channel in (long_channel, showcase, fold_channel):
        ensure_member(probe, channel["id"], bot_me["id"])

    # The custom emoji the `custom-emoji` showcase post refers to. Created once; a re-run finds it.
    ensure_emoji(probe, me["id"], CUSTOM_EMOJI_NAME)

    # 1. Top up the long channel so a page boundary is a real boundary.
    info, _ = probe.must("GET", f"/channels/{long_channel['id']}")
    total = int(info.get("total_msg_count") or 0)
    print(f"long channel {LONG_CHANNEL_NAME} ({long_channel['id']}): {total} posts")
    added = 0
    while total + added < args.min_posts:
        index = total + added
        create_post(probe, long_channel["id"],
                    f"t34 history {index:04d}: " + ("payload " * 6) + f"#{index}",
                    key=f"history-{index:04d}")
        added += 1
    if added:
        print(f"  added {added} posts -> {total + added}")

    # 2. The showcase channel (one post per rendering case) and the fold channel (F6's single-block
    # posts), both idempotent on `props.t34_key`.
    ids: dict[str, str] = seed_cases(probe, showcase, SHOWCASE, args.recreate)
    ids.update(seed_cases(probe, fold_channel, FOLD, args.recreate))

    # A case that moved to another channel must not linger in the old one: the showcase would grow a
    # second copy of it on every re-seed, and the two channels would disagree about who owns it.
    fold_keys = {key for key, _ in FOLD}
    for post in recent_posts(probe, showcase["id"], count=200):
        if ((post.get("props") or {}).get("t34_key")) in fold_keys:
            probe.call("DELETE", f"/posts/{post['id']}")
            print(f"  removed a moved case from the showcase ({post['id']})")

    # Edited: patch the message so `edit_at` is a real server field.
    edited = find_marked(recent_posts(probe, showcase["id"]), "edited")
    if edited and not edited.get("edit_at"):
        message = "this line was edited by the seed — edited at " + str(edited["create_at"])
        probe.must("PUT", f"/posts/{edited['id']}/patch", {"id": edited["id"], "message": message})
        print("  edited the `edited` post")

    # (A pre-deleted post is deliberately not seeded: a deleted post is *absent* from a channel page,
    # so a fixture tombstone could never be observed. `post_deleted` is exercised live by the UI test,
    # which deletes a post while the channel is open.)

    # Attachment: a post is created *with* its `file_ids` (the server's patch endpoint does not
    # accept file ids, and an uploaded-but-unattached file belongs to no post). The marker post is
    # replaced if an earlier run created it without an attachment.
    attachment = find_marked(recent_posts(probe, showcase["id"]), "attachment")
    if attachment is not None:
        files = ((attachment.get("metadata") or {}).get("files") or [])
        # A file too small for the server to thumbnail (an earlier probe used 16×16) is replaced:
        # the row must draw a real thumbnail, not a 404.
        if not attachment.get("file_ids") or not files or int(files[0].get("size") or 0) < 5000:
            probe.call("DELETE", f"/posts/{attachment['id']}")
            attachment = None
    if attachment is None:
        file_id = upload_png(probe, showcase["id"])
        attachment = create_post(probe, showcase["id"], "an image attachment:", "attachment",
                                 file_ids=[file_id])
        ids["attachment"] = attachment["id"]
        print(f"  created the attachment post {attachment['id']} with image {file_id}")
    else:
        print(f"  attachment post already has files: {attachment.get('file_ids')}")

    # Reactions: two users on the inline post, so a summary reads "tada 2" and "thumbsup 1".
    for post_id, emoji, client, user_id in [
        (ids["inline"], "tada", probe, me["id"]),
        (ids["inline"], "tada", bot, bot_me["id"]),
        (ids["inline"], "thumbsup", probe, me["id"]),
        (ids["code-swift"], "eyes", probe, me["id"]),
    ]:
        add_reaction(client, user_id, post_id, emoji)

    # Opsbot replies in the showcase channel: the row's author is then not the signed-in user, which
    # is what the grouping rule (same author inside 5 minutes collapses) keys on.
    if find_marked(recent_posts(probe, showcase["id"]), "bot-note") is None:
        bot.must("POST", "/posts", {"channel_id": showcase["id"],
                                    "message": "opsbot here: `t34` fixture note.",
                                    "props": {"t34_key": "bot-note", "t34_seed": "t34_post_seed.py"}})
        print("  opsbot posted the fixture note")

    # 3. The authoritative numbers, for a test that must not trust this script.
    for channel in (long_channel, showcase, fold_channel):
        info, _ = probe.must("GET", f"/channels/{channel['id']}")
        posts = recent_posts(probe, channel["id"], count=200)
        print(f"channel {channel['name']:<14} id={channel['id']} total_msg_count="
              f"{info.get('total_msg_count')} last_post_at={info.get('last_post_at')} "
              f"recent_posts={len(posts)}")
    print("case ids:")
    for key, post_id in ids.items():
        print(f"  {key:<12} {post_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
