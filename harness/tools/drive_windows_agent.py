#!/usr/bin/env python3
"""Drive a real Windows agent from the mock Mac client.

This is the Phase 1 interoperability check: it points the Phase 0 reference
client at the C# agent and asserts the behavior protocol-v1.md requires of the
Windows side. It is a development tool, not part of the conformance suite.

Run it from `harness/` with the virtualenv interpreter explicitly:

    .venv/bin/python tools/drive_windows_agent.py \
        --host 192.168.1.50 --port 47800 \
        --pairing AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ \
        --fingerprint <the 64 hex characters the agent printed at startup> \
        --mode session

Modes:
    session  handshake, PING/PONG, idempotent START/STOP, zero audio bytes
    nack     assert START is answered with START_NACK (run the agent with --no-mic)
    lockout  five bad-token attempts, then assert even the correct token is
             refused, then assert it is accepted again after 30 seconds
"""

import argparse
import sys
import time

from sharedmic_protocol.auth import decode_pairing_string
from sharedmic_protocol.client import MockMacClient, SessionRejected
from sharedmic_protocol.tls import client_context

CONNECT_FAILURES = (ConnectionError, TimeoutError, OSError)


def connect(args, token, client_id="mock-mac"):
    client = MockMacClient(
        token,
        args.host,
        args.port,
        client_id=client_id,
        ssl_context=client_context(),
        expected_fingerprint=args.fingerprint,
    )
    hello_ack = client.connect(timeout=args.timeout)
    return client, hello_ack


def run_session(args, token):
    client, hello_ack = connect(args, token)
    try:
        print(f"HELLO_ACK          {hello_ack}")

        for seq in range(3):
            client.ping()
        print("PING/PONG x3       ok (each PONG carried the matching seq)")

        first = client.start_session()
        second = client.start_session()
        if first["sessionId"] != second["sessionId"]:
            raise SystemExit(
                f"FAIL duplicate START created a second session: "
                f"{first['sessionId']} then {second['sessionId']}"
            )
        if second["format"] != {"sampleRate": 48000, "channels": 1, "sampleFormat": "s16le"}:
            raise SystemExit(f"FAIL START_ACK format is not the fixed v1 format: {second['format']}")
        print(f"START idempotent   ok (sessionId={first['sessionId']})")

        time.sleep(2.0)
        if client.audio_frames_received != 0:
            raise SystemExit(
                f"FAIL Phase 1 must stream no audio, received {client.audio_frames_received} frames"
            )
        print("zero audio bytes   ok (2 s with an active session, nothing received)")

        client.stop_session()
        client.stop_session()
        print("STOP idempotent    ok (two STOP_ACKs)")

        client.ping()
        print("still healthy      ok (PING answered after two STOPs)")
    finally:
        client.close()

    print("\nPASS session checks")


def run_nack(args, token):
    client, hello_ack = connect(args, token)
    try:
        if hello_ack["micPresent"] is not False:
            raise SystemExit(
                "FAIL run the agent with --no-mic for this mode; HELLO_ACK reported micPresent=true"
            )
        try:
            client.start_session()
        except SessionRejected as rejected:
            if rejected.reason != "MIC_UNAVAILABLE":
                raise SystemExit(f"FAIL START_NACK reason was {rejected.reason!r}, expected MIC_UNAVAILABLE")
            print(f"START_NACK         ok (reason={rejected.reason})")
        else:
            raise SystemExit("FAIL START was accepted even though the agent reports no microphone")

        client.ping()
        print("still healthy      ok (a rejected START does not close the connection)")
    finally:
        client.close()

    print("\nPASS NACK checks")


def run_lockout(args, token):
    wrong = bytes(32)
    if wrong == token:
        wrong = bytes([1]) * 32

    for attempt in range(1, 6):
        try:
            client, _ = connect(args, wrong)
            client.close()
            raise SystemExit(f"FAIL attempt {attempt} with a wrong token authenticated")
        except CONNECT_FAILURES as failure:
            print(f"bad attempt {attempt}      refused ({type(failure).__name__})")

    try:
        client, _ = connect(args, token)
        client.close()
        raise SystemExit("FAIL the correct token authenticated during the 30 s lockout window")
    except CONNECT_FAILURES as failure:
        print(f"correct token      refused during lockout ({type(failure).__name__})  <- expected")

    print("waiting 31 s for the lockout to expire...")
    time.sleep(31)

    client, hello_ack = connect(args, token)
    client.close()
    print(f"after lockout      authenticated ok (serverId={hello_ack['serverId']})")

    print("\nPASS lockout checks")


def main(argv):
    parser = argparse.ArgumentParser(description="Drive a Windows shared-mic agent from the mock Mac client.")
    parser.add_argument("--host", required=True, help="the Windows host's address")
    parser.add_argument("--port", type=int, default=47800)
    parser.add_argument("--pairing", required=True, help="the pairing string the agent printed or the tray shows")
    parser.add_argument("--fingerprint", required=True, help="the 64-character lowercase hex fingerprint")
    parser.add_argument("--mode", choices=("session", "nack", "lockout"), default="session")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)

    token = decode_pairing_string(args.pairing)
    print(f"pairing string decoded to {len(token)} bytes")

    if args.mode == "session":
        run_session(args, token)
    elif args.mode == "nack":
        run_nack(args, token)
    else:
        run_lockout(args, token)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
