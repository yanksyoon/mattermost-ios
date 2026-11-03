"""Create-or-reuse the T50 UI fixture account and print `export` lines for the invoking shell.

The password comes from `T50_UI_PASSWORD` (the harness generates one per run); nothing is stored
by this script, and no credential is written to the repository.
"""

import json
import os
import sys
import urllib.error
import urllib.request

SERVER = os.environ.get("T50_SERVER", "http://127.0.0.1:8065")
USERNAME = os.environ.get("T50_UI_USERNAME", "t50ui")
EMAIL = USERNAME + "@example.com"
PASSWORD = os.environ.get("T50_UI_PASSWORD", "")

if not PASSWORD:
    sys.exit("set T50_UI_PASSWORD to the run's generated password")


def call(method, path, body=None, token=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(SERVER + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req) as res:
            raw = res.read()
            return res.status, (json.loads(raw) if raw else {}), res.headers
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read() or b"{}"), err.headers


status, user, _ = call("POST", "/api/v4/users",
                       {"email": EMAIL, "username": USERNAME, "password": PASSWORD})
if status not in (200, 201):
    status, user, _ = call("POST", "/api/v4/users/login",
                           {"login_id": USERNAME, "password": PASSWORD})
    if status != 200:
        sys.exit(f"{USERNAME} exists with a different password (login answered {status}). "
                 "Rename it with T50_UI_USERNAME or delete the account.")

status, user, _ = call("POST", "/api/v4/users/login", {"login_id": USERNAME, "password": PASSWORD})
if status != 200:
    sys.exit(f"login failed: {status} {user}")

print(f'export TEST_RUNNER_MM_AUTH_SERVER="{SERVER}"')
print(f'export TEST_RUNNER_MM_AUTH_LOGIN="{USERNAME}"')
print(f'export TEST_RUNNER_MM_AUTH_PASSWORD="{PASSWORD}"')
print(f'export MM_USER_ID="{user["id"]}"')
