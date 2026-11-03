#!/usr/bin/env python3
"""Measure the profile-edit contract on the pinned Mattermost 9.11.19 fixture.

T50 has to know, before it writes a line of Swift, exactly what the server does with:

  * `PUT /users/{id}/patch` — which fields are patchable, what the limits are, and what an
    over-limit or empty value answers (the client's validation must refuse what the server refuses,
    with the server's own sentence);
  * `POST /users/{id}/image` / `DELETE /users/{id}/image` — the multipart field name, the accepted
    bytes, and the answer for an account with no picture;
  * `GET /custom_profile_attributes/fields` and the value endpoints — whether this server has the
    feature at all (it is license-gated; a Team Edition server answers 404/501), which is the gate
    the card requires the client to record honestly.

    python3 scripts/t50_profile_probe.py

The probe creates (or reuses) `t50probe` by open sign-up, so it carries no credential. It restores
the account's fields at the end: the fixture's baseline is what the next run measures from.
"""

import hashlib
import json
import os
import sys
import urllib.error
import urllib.request

SERVER = os.environ.get("MM_PROBE_SERVER", "http://127.0.0.1:8065")
LOGIN = os.environ.get("MM_PROBE_LOGIN", "t50probe")
PASSWORD = os.environ.get("MM_PROBE_PASSWORD", "T50probe!pass")
EMAIL = os.environ.get("MM_PROBE_EMAIL", "t50probe@example.com")

# A 2x2 PNG, blue. Small enough to paste, real enough for the server's image decoder to accept it.
PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000002000000020806000000f478d4fa"
    "0000001b49444154789c63606060f80f040000ffff0300010500017a4f0e4b0000"
    "000049454e44ae426082"
)


def call(method, path, token=None, body=None, raw=None, content_type=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    request = urllib.request.Request(SERVER + "/api/v4" + path, data=data, method=method)
    request.add_header("Content-Type", content_type or "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            payload = response.read()
            return response.status, payload, dict(response.headers)
    except urllib.error.HTTPError as error:
        return error.code, error.read(), dict(error.headers)


def show(label, status, payload, limit=320):
    text = payload.decode(errors="replace") if isinstance(payload, bytes) else str(payload)
    print(f"{label}: {status} {text[:limit]}")


def login():
    status, payload, headers = call("POST", "/users/login",
                                    body={"login_id": LOGIN, "password": PASSWORD})
    if status == 200:
        session = json.loads(payload)
        return session["id"], session.get("token") or headers.get("Token")
    print(f"login answered {status}; trying open sign-up")
    status, payload, _ = call("POST", "/users",
                              body={"email": EMAIL, "username": LOGIN, "password": PASSWORD})
    if status not in (200, 201):
        sys.exit(f"sign-up answered {status}: {payload[:300]}")
    user = json.loads(payload)
    status, payload, headers = call("POST", "/users/login",
                                    body={"login_id": LOGIN, "password": PASSWORD})
    if status != 200:
        sys.exit(f"login after sign-up answered {status}: {payload[:300]}")
    session = json.loads(payload)
    return session["id"], session.get("token") or headers.get("Token")


def multipart(field, filename, data, mime="image/png"):
    boundary = "----t50probe" + hashlib.sha256(data).hexdigest()[:16]
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n'
        f"Content-Type: {mime}\r\n\r\n"
    ).encode() + data + f"\r\n--{boundary}--\r\n".encode()
    return body, f"multipart/form-data; boundary={boundary}"


def patch(token, user_id, body, label):
    status, payload, _ = call("PUT", f"/users/{user_id}/patch", token=token, body=body)
    show(label, status, payload)
    return status, payload


def main():
    user_id, token = login()
    print(f"session: user={user_id} token={'yes' if token else 'no'}")

    status, payload, _ = call("GET", f"/users/{user_id}", token=token)
    show("GET /users/{id}", status, payload, 500)
    original = json.loads(payload)

    # ---- 1. The patch endpoint -------------------------------------------------------------
    print("\n== PUT /users/{id}/patch ==")
    patch(token, user_id, {"position": "T50 probe position"}, "position")

    # Empty first name: does the server accept it, or does it require a value?
    patch(token, user_id, {"first_name": ""}, "first_name empty")

    # The limits. Each answer is the server's own sentence, which is what the client will show.
    for field, limit in (("first_name", 64), ("last_name", 64), ("nickname", 64),
                         ("position", 128), ("email", 254)):
        patch(token, user_id, {field: "x" * (limit + 1)}, f"{field} {limit + 1} chars")
        patch(token, user_id, {field: "x" * limit}, f"{field} {limit} chars")

    # A field the patch does not carry: omitted, not nulled.
    patch(token, user_id, {"nickname": "t50nick"}, "nickname")
    status, payload, _ = call("GET", f"/users/{user_id}", token=token)
    after = json.loads(payload)
    print(f"omitted fields kept: position={after.get('position')!r} nickname={after.get('nickname')!r}")

    # Email validation is the server's, and its sentence is what the inline rule has to show.
    patch(token, user_id, {"email": "not-an-email"}, "email invalid")
    # A read-only field: does the patch silently ignore it, or refuse?
    patch(token, user_id, {"username": "t50renamed"}, "username (read-only?)")
    status, payload, _ = call("GET", f"/users/{user_id}", token=token)
    print(f"username after patch attempt: {json.loads(payload).get('username')!r}")

    # ---- 2. The avatar ---------------------------------------------------------------------
    print("\n== avatar ==")
    status, payload, _ = call("GET", f"/users/{user_id}/image", token=token)
    print(f"GET /users/{{id}}/image before upload: {status} bytes={len(payload)}")
    status, payload, _ = call("GET", f"/users/{user_id}/profile_image", token=token)
    print(f"GET /users/{{id}}/profile_image before upload: {status} bytes={len(payload)}")

    body, content_type = multipart("image", "t50.png", PNG)
    status, payload, _ = call("POST", f"/users/{user_id}/image", token=token,
                              raw=body, content_type=content_type)
    show("POST /users/{id}/image", status, payload)

    status, payload, _ = call("GET", f"/users/{user_id}/image", token=token)
    print(f"GET /users/{{id}}/image after upload: {status} bytes={len(payload)} "
          f"sha256={hashlib.sha256(payload).hexdigest()[:16]}")
    status, payload, _ = call("GET", f"/users/{user_id}/profile_image", token=token)
    print(f"GET /users/{{id}}/profile_image after upload: {status} bytes={len(payload)} "
          f"sha256={hashlib.sha256(payload).hexdigest()[:16]}")

    status, payload, _ = call("DELETE", f"/users/{user_id}/image", token=token)
    show("DELETE /users/{id}/image", status, payload)
    status, payload, _ = call("GET", f"/users/{user_id}/image", token=token)
    print(f"GET /users/{{id}}/image after delete: {status} bytes={len(payload)}")

    # ---- 3. Custom profile attributes (license-gated) --------------------------------------
    print("\n== custom profile attributes ==")
    for path in ("/custom_profile_attributes/fields",
                 f"/users/{user_id}/custom_profile_attributes"):
        status, payload, _ = call("GET", path, token=token)
        show(f"GET {path}", status, payload, 200)

    status, payload, _ = call("PUT", f"/users/{user_id}/custom_profile_attributes",
                              token=token, body={"values": {}})
    show("PUT /users/{id}/custom_profile_attributes", status, payload, 200)

    # ---- 4. Restore the baseline -----------------------------------------------------------
    print("\n== restore ==")
    patch(token, user_id, {
        "first_name": original.get("first_name", ""),
        "last_name": original.get("last_name", ""),
        "nickname": original.get("nickname", ""),
        "position": original.get("position", ""),
    }, "restore")
    status, payload, _ = call("GET", f"/users/{user_id}", token=token)
    restored = json.loads(payload)
    print(f"restored: position={restored.get('position')!r} nickname={restored.get('nickname')!r} "
          f"first_name={restored.get('first_name')!r}")


if __name__ == "__main__":
    main()
