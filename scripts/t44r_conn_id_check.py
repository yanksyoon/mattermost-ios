#!/usr/bin/env python3
"""T44r check: which `connID` belongs to *this* socket, and why the probe takes it from `hello`.

The plugin's `join` ack is published to the **user**, not the connection
(`p.publishWebSocketEvent(wsEventJoin, …, &WebSocketBroadcast{UserID: userID,
ReliableClusterSend: true})`, `server/websocket.go:830-832` at v0.29.8), so with two live
sessions of the same account a socket receives *both* acks and cannot tell which one is its own.
That is precisely the ambiguity that made the old check 8 unreliable. The core server's own
`hello` event, sent to this socket alone, carries `data.connection_id` — and the plugin's ack for
*our* join repeats it.

This script proves the two halves of that:
  1. the server **ignores** a client-supplied `?connection_id=` (it answers with one it assigns),
     so an id cannot simply be declared by the caller;
  2. `hello.connection_id` == the `connID` in the join ack for this connection — the fact the
     probe's attribution (and therefore its negative checks) rests on.

    python3 scripts/t44r_conn_id_check.py --url http://127.0.0.1:8065

Exit code 0 only when both hold. With two sessions of the account live, this script's `hello` id
still equals its own ack and differs from the other session's ack — which is the whole point.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time

import t44_calls_probe as P


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--channel", default=P.CHANNEL_NAME)
    args = parser.parse_args()

    token, me = P.login(args.url, P.ADMIN_LOGIN, P.ADMIN_PASSWORD)
    prefix, _ = P.plugin_prefix(args.url, token)
    channel = P.ensure_channel(args.url, token, args.channel)
    wanted = "t44r" + os.urandom(22).hex()[:22]
    print(f"signed in as {me.get('username')}; channel {channel['name']} ({channel['id']})")
    print(f"client-supplied ?connection_id={wanted}")

    ws = P.WSClient(args.url, token, query="connection_id=" + wanted)
    heard_hello = None
    ack = None
    foreign_acks: list[str] = []
    try:
        start = time.time()
        deadline = start + 12.0
        sent = False
        while time.time() < deadline:
            frame = ws.receive(deadline)
            if frame is None:
                break
            event = frame.get("event", "")
            data = frame.get("data") or {}
            if event == "hello" and not sent:
                heard_hello = data.get("connection_id")
                print(f"hello.connection_id = {heard_hello}")
                ws.send_text(json.dumps({"seq": 1, "action": prefix + "join",
                                         "data": {"channelID": channel["id"]}}))
                sent = True
                continue
            if event == prefix + "join":
                conn = data.get("connID")
                if heard_hello and conn != heard_hello:
                    foreign_acks.append(str(conn))
                    print(f"join ack connID = {conn}  (another live session of this account)")
                    continue
                ack = conn
                print(f"join ack connID = {conn}")
                # Keep reading briefly: any *other* ack that shows up now is the ambiguity the
                # probe guards against, and it is worth printing.
                deadline = min(deadline, time.time() + 2.0)
                continue
        try:
            ws.send_text(json.dumps({"seq": 9, "action": prefix + "leave",
                                     "data": {"channelID": channel["id"]}}))
            time.sleep(0.2)
        except Exception:
            pass
    finally:
        ws.close()

    check1 = heard_hello is not None and heard_hello != wanted
    check2 = heard_hello is not None and ack == heard_hello
    print()
    print(("PASS  " if check1 else "FAIL  ")
          + "the server assigns the connection id (a client-supplied ?connection_id= is ignored)")
    print(("PASS  " if check2 else "FAIL  ")
          + "the join ack for this socket repeats hello.connection_id")
    if foreign_acks:
        print(f"DATA  {len(foreign_acks)} foreign join ack(s) also arrived on this socket "
              f"(user-scoped broadcast): {foreign_acks[:4]}")
    else:
        print("DATA  no foreign join ack arrived on this socket (no other session of the "
              "account was live)")
    print(f"{int(check1) + int(check2)} PASS / {2 - int(check1) - int(check2)} FAIL")
    return 0 if check1 and check2 else 1


if __name__ == "__main__":
    sys.exit(main())
