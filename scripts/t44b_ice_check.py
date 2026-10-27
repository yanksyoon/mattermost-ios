#!/usr/bin/env python3
"""T44b: a focused ICE connectivity check against the Calls SFU's media port, from this host.

`scripts/t44_calls_probe.py` runs the same check inside its reachability block; this script is the
narrow diagnostic used while opening the media path on the fixture, because it can also check an
extra `host:port` that the SFU does not advertise as such (the relay's published port).

Why a *credentialed* binding request and not a bare STUN one: the plugin demultiplexes every session
on one UDP port with a ufrag mux (`webrtc.NewICEUDPMux`), which routes an inbound datagram to an ICE
agent by the STUN `USERNAME` attribute. A binding request without `USERNAME`/`MESSAGE-INTEGRITY`
cannot be routed to any agent, so it is dropped — identically whether the port is open or closed.
T44's `MEDIA PATH: 0/3` was measured with such a request, which is why it could not see the port
being published (see docs/t44b-calls-media-path.md).

The check runs while the session is still joined: the SFU tears its ICE agent down on `leave`, so a
check issued after the session ends measures nothing.

    python3 scripts/t44b_ice_check.py --url http://127.0.0.1:8065
    python3 scripts/t44b_ice_check.py --url http://127.0.0.1:8065 --also 127.0.0.1:8443 --json

Exit code 0 when at least one candidate answers. Nothing is written to the server beyond joining and
leaving a call in the probe channel, exactly like the T44 probe.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import t44_calls_probe as probe  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8065")
    parser.add_argument("--channel", default=probe.CHANNEL_NAME)
    parser.add_argument("--also", action="append", default=[],
                        help="extra host:port to check, e.g. --also 127.0.0.1:8443")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    print(f"T44b ICE connectivity check against {args.url}")
    token, me = probe.login(args.url, probe.ADMIN_LOGIN, probe.ADMIN_PASSWORD)
    print(f"      signed in as {me.get('username')} ({me.get('id')})")
    prefix, _ = probe.plugin_prefix(args.url, token)
    channel = probe.ensure_channel(args.url, token, args.channel)
    print(f"      plugin prefix {prefix}, channel {channel.get('name')} ({channel['id']})")

    local_ufrag, _ = probe.sdp_credentials(probe.OFFER_SDP)
    local_ufrag = local_ufrag or "t44a"

    extras: list[tuple[str, int]] = []
    for extra in args.also:
        host, _, port = extra.rpartition(":")
        if host and port.isdigit():
            extras.append((host, int(port)))

    results: list[dict[str, Any]] = []
    missing_credentials = False

    def during(result: dict[str, Any]) -> None:
        """Runs inside run_session, before `leave`: the SFU drops the ICE agent when we leave."""
        nonlocal missing_credentials
        answer = result.get("answer") or ""
        remote_ufrag, remote_pwd = probe.sdp_credentials(answer)
        print(f"      offer answered: {len(answer)} bytes, {len(result['candidates'])} candidate(s)")
        print(f"      server ufrag {remote_ufrag} / local ufrag {local_ufrag}")
        if not answer or not remote_ufrag or not remote_pwd:
            missing_credentials = True
            return
        targets: list[tuple[str, int]] = []
        for text in result["candidates"]:
            parsed = probe.parse_candidate(text)
            print(f"DATA  candidate  —  {text}")
            if parsed and parsed not in targets:
                targets.append(parsed)
        for target in extras:
            if target not in targets:
                targets.append(target)
        print("\n--- credentialed binding requests (ICE connectivity check), from this host ---")
        for host, port in targets:
            outcome = probe.ice_check(host, port, local_ufrag, remote_ufrag, remote_pwd)
            results.append(outcome)
            if outcome["reply"]:
                print(f"REPLY  {outcome['target']}  —  {outcome['stun_type']} in {outcome['ms']} ms, "
                      f"message-integrity={outcome['authenticated']}, mapped={outcome.get('mapped')}")
            else:
                print(f"SILENT {outcome['target']}  —  no reply ({outcome['why']})")

    probe.run_session(args.url, token, prefix, channel["id"], "msgpack", seconds=4.0, hook=during)

    if missing_credentials:
        print("FAIL  the SFU answered without usable ICE credentials — nothing to check against")
        return 2
    answered = [r for r in results if r["reply"]]
    print()
    print(f"ICE PATH: {len(answered)}/{len(results)} advertised candidate(s) answered a credentialed "
          f"binding request" + ("" if answered else " — the SFU's ICE port is not reachable from here"))
    if args.json:
        print(json.dumps({"url": args.url, "results": results}, indent=2))
    return 0 if answered else 1


if __name__ == "__main__":
    sys.exit(main())
