import socket

import pytest

from sharedmic_protocol.auth import auth_proof, decode_pairing_string, encode_pairing_string, generate_token
from sharedmic_protocol.control import PROTOCOL_VERSION, decode_control, encode_control
from sharedmic_protocol.framing import FRAME_TYPE_CONTROL, decode_frame, encode_frame
from sharedmic_protocol.server import MockWindowsServer


@pytest.fixture
def token():
    return generate_token()


@pytest.fixture
def server(token):
    srv = MockWindowsServer(token)
    srv.start()
    yield srv
    srv.stop()


def _recv_control(sock):
    buf = b""
    while True:
        result = decode_frame(buf)
        if result is not None:
            frame_type, payload, _ = result
            assert frame_type == FRAME_TYPE_CONTROL
            return decode_control(payload)
        chunk = sock.recv(4096)
        assert chunk, "server closed connection unexpectedly"
        buf += chunk


def _send_control(sock, msg):
    sock.sendall(encode_frame(FRAME_TYPE_CONTROL, encode_control(msg)))


def test_server_greets_with_a_nonce(server):
    with socket.create_connection(("127.0.0.1", server.port), timeout=5) as sock:
        greeting = _recv_control(sock)
    assert greeting["type"] == "GREETING"
    assert len(greeting["nonce"]) > 0


def test_server_accepts_valid_proof(server, token):
    with socket.create_connection(("127.0.0.1", server.port), timeout=5) as sock:
        greeting = _recv_control(sock)
        _send_control(
            sock,
            {
                "v": PROTOCOL_VERSION,
                "type": "HELLO",
                "clientId": "test-mac",
                "mac": auth_proof(token, bytes.fromhex(greeting["nonce"])),
            },
        )
        ack = _recv_control(sock)
    assert ack["type"] == "HELLO_ACK"
    assert ack["micPresent"] is True


def test_server_rejects_bad_proof_and_counts_it(server):
    with socket.create_connection(("127.0.0.1", server.port), timeout=5) as sock:
        _recv_control(sock)
        _send_control(
            sock,
            {"v": PROTOCOL_VERSION, "type": "HELLO", "clientId": "attacker", "mac": "00" * 32},
        )
        assert sock.recv(4096) == b""
    assert server.auth_failures == 1


def test_server_issues_nonce_per_connection(server):
    nonces = []
    for _ in range(2):
        with socket.create_connection(("127.0.0.1", server.port), timeout=5) as sock:
            nonces.append(_recv_control(sock)["nonce"])
    assert nonces[0] != nonces[1]


def test_pairing_string_is_what_the_user_would_type(token):
    assert decode_pairing_string(encode_pairing_string(token)) == token
