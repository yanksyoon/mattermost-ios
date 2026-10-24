#!/usr/bin/env python3
"""t12a_hmac_probe.py - signed vs tampered send_push demo against REAL upstream proxy.
Read-only HTTP probes; never writes secrets. Uses HMAC-SHA256 over the raw body with the
given test secret to demonstrate the LOCAL request path. Real deliverable uses the
server's PushNotificationServerSecret, never a hardcoded test key."""
import hashlib, hmac, urllib.request, urllib.error

BASE = "http://127.0.0.1:8066"

def sign(secret, body):
    return hmac.new(secret.encode(), body.encode(), hashlib.sha256).hexdigest()

BODY = ('{"message":"T12a","badge":1,"platform":"apple","server_id":"commtest",'
        '"device_id":"apple:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",'
        '"type":"message","channel_id":"c","team_id":"t","version":"v2"}')

def post(path, body, sig=None):
    h = {"Content-Type": "application/json"}
    if sig:
        h["Push-Notification-Signature"] = sig
    req = urllib.request.Request(BASE + path, data=body.encode(), method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:
        return None, "ERR %s" % e

def main():
    good = sign("correct-secret-test", BODY)
    print("[A] correctly HMAC-SHA256-signed body (secret=correct-secret-test)")
    st, tx = post("/api/v1/send_push", BODY, good)
    print("    HTTP %s: %s" % (st, tx))
    print("    sig=%s..." % good[:20])

    bad_key = sign("WRONG-key", BODY)
    print("[B] TAMPERED signature (correct body, WRONG HMAC key)")
    st, tx = post("/api/v1/send_push", BODY, bad_key)
    print("    HTTP %s: %s" % (st, tx))

    body_t = BODY.replace('"message":"T12a"', '"message":"TAMPERED"')
    print("[C] TAMPERED body (message changed, sig still computed for original body)")
    st, tx = post("/api/v1/send_push", body_t, good)
    print("    HTTP %s: %s" % (st, tx))

    missing = '{"message":"x","platform":"apple","device_id":"apple:abc","type":"message"}'
    ms = sign("correct-secret-test", missing)
    print("[D] VALIDATION gate (real router): missing server_id even with valid HMAC")
    st, tx = post("/api/v1/send_push", missing, ms)
    print("    HTTP %s: %s" % (st, tx))

if __name__ == "__main__":
    main()