"""Stand up harness/sharedmic_protocol's MockWindowsServer over TLS for XCTest.

Run with the harness virtualenv interpreter; there is no bare `python` on this
machine and the system python3 has no dependencies installed:

    harness/.venv/bin/python macos/SharedMicTests/Support/mock_windows_server.py <harness-dir> [port]

On startup it prints exactly one JSON line to stdout describing the server, then
reads one command per line from stdin until EOF or `quit`:

    micoff | micon | drop | quit

`drop` closes every live connection without stopping the listener, which is how
the reconnect tests simulate the Windows host going away and coming back.
"""

import json
import socket
import sys
import time

harness_directory = sys.argv[1]
requested_port = int(sys.argv[2]) if len(sys.argv) > 2 else 0
sys.path.insert(0, harness_directory)

from sharedmic_protocol.auth import encode_pairing_string  # noqa: E402
from sharedmic_protocol.server import MockWindowsServer  # noqa: E402
from sharedmic_protocol.tls import (  # noqa: E402
    certificate_fingerprint,
    generate_self_signed_cert,
    server_context,
)

TOKEN = bytes(range(32))

cert_pem, key_pem = generate_self_signed_cert()
server = MockWindowsServer(
    TOKEN,
    host="127.0.0.1",
    port=requested_port,
    mic_present=True,
    device_label="Mock USB Mic",
    server_id="mock-win",
    ssl_context=server_context(cert_pem, key_pem),
)
server.start()

print(
    json.dumps(
        {
            "port": server.port,
            "fingerprint": certificate_fingerprint(cert_pem),
            "pairing": encode_pairing_string(TOKEN),
            "tokenHex": TOKEN.hex(),
        }
    ),
    flush=True,
)


def drop_connections():
    # Reaches into MockWindowsServer._connections on purpose: the mock has no
    # public "hang up on everyone" API, and simulating a mid-session network drop
    # is exactly what a reconnect test needs. This is test-harness code, not
    # agent code.
    for connection in list(server._connections):
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            connection.close()
        except OSError:
            pass


try:
    for line in sys.stdin:
        command = line.strip()
        if command == "micoff":
            server.set_mic_present(False)
        elif command == "micon":
            server.set_mic_present(True)
        elif command == "drop":
            drop_connections()
        elif command == "quit":
            break
        elif command:
            print(json.dumps({"error": f"unknown command {command!r}"}), flush=True)
        print(json.dumps({"ack": command}), flush=True)
finally:
    server.stop()
    time.sleep(0.05)
