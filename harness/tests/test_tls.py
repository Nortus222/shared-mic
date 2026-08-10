import socket
import threading
import time

import pytest

from sharedmic_protocol.auth import generate_token
from sharedmic_protocol.client import FingerprintMismatch, MockMacClient
from sharedmic_protocol.server import MockWindowsServer
from sharedmic_protocol.tls import (
    certificate_fingerprint,
    client_context,
    generate_self_signed_cert,
    server_context,
)


@pytest.fixture
def cert():
    return generate_self_signed_cert()


def test_generated_cert_is_pem(cert):
    cert_pem, key_pem = cert
    assert cert_pem.startswith(b"-----BEGIN CERTIFICATE-----")
    assert b"PRIVATE KEY" in key_pem


def test_fingerprint_is_hex_sha256(cert):
    fingerprint = certificate_fingerprint(cert[0])
    assert len(fingerprint) == 64
    int(fingerprint, 16)


def test_fingerprint_is_stable(cert):
    assert certificate_fingerprint(cert[0]) == certificate_fingerprint(cert[0])


def test_distinct_certs_have_distinct_fingerprints():
    a = certificate_fingerprint(generate_self_signed_cert()[0])
    b = certificate_fingerprint(generate_self_signed_cert()[0])
    assert a != b


def test_session_works_over_tls_with_matching_pin(cert):
    cert_pem, key_pem = cert
    token = generate_token()
    server = MockWindowsServer(token, ssl_context=server_context(cert_pem, key_pem))
    server.start()
    client = MockMacClient(
        token,
        "127.0.0.1",
        server.port,
        ssl_context=client_context(),
        expected_fingerprint=certificate_fingerprint(cert_pem),
    )
    try:
        assert client.connect()["type"] == "HELLO_ACK"
        client.start_session()
        assert len(client.wait_for_audio_frames(5)) == 5
    finally:
        client.close()
        server.stop()


def test_mismatched_fingerprint_is_a_hard_stop(cert):
    cert_pem, key_pem = cert
    token = generate_token()
    server = MockWindowsServer(token, ssl_context=server_context(cert_pem, key_pem))
    server.start()
    attacker_fingerprint = certificate_fingerprint(generate_self_signed_cert()[0])
    client = MockMacClient(
        token,
        "127.0.0.1",
        server.port,
        ssl_context=client_context(),
        expected_fingerprint=attacker_fingerprint,
    )
    try:
        with pytest.raises(FingerprintMismatch):
            client.connect()
        # audio_frames_received == 0 alone is a weak proxy: audio only
        # flows after START, so it would still pass even if a full
        # GREETING/HELLO/HELLO_ACK control-plane exchange had completed
        # before the mismatch was noticed. Pin down that *no* application
        # data was exchanged at all, from both ends:
        #   - server.sessions_started / auth_failures both stay at 0
        #     because the server never receives a HELLO to act on.
        #   - client._reader stays None because MockMacClient.connect()
        #     raises inside _open_socket(), before the reader thread that
        #     would read GREETING/HELLO_ACK is ever created — so the
        #     client-side control-plane loop never ran at all.
        assert client.audio_frames_received == 0
        assert server.sessions_started == 0
        assert server.auth_failures == 0
        assert client._reader is None
    finally:
        client.close()
        server.stop()


# -- carried finding 1: the TLS accept path had zero test coverage --------
#
# Task 5 fixed a hazard in MockWindowsServer._accept_loop: ssl_context.wrap_
# socket() returns a *new* socket object over the same fd, and the tracked
# connection reference must be swapped under the lock after wrapping so
# stop() closes the object the session actually uses instead of the raw,
# now-discarded pre-handshake socket. test_session_works_over_tls_with_
# matching_pin above already routes through this path once (the server is
# constructed with ssl_context=..., so _accept_loop takes the wrap branch),
# but a single connection can't tell a correct swap apart from one that
# merely happens not to matter yet (e.g. because nothing else touches
# _connections before the test tears down). This test runs the wrap-and-
# swap path across two sequential TLS connections and then relies on
# server.stop() to prove the bookkeeping is actually right: stop() walks
# self._connections and shutdown()s each one to unblock any thread parked
# in recv(), then join()s with a timeout. If the swap left a stale raw
# socket in the list (or dropped the wrapped one), stop() would either
# close the wrong object or leave a per-connection thread parked past its
# join timeout — this test would then be slow or hang instead of passing
# quickly.
def test_tls_accept_path_tracks_wrapped_connection_across_sessions(cert):
    cert_pem, key_pem = cert
    token = generate_token()
    server = MockWindowsServer(token, ssl_context=server_context(cert_pem, key_pem))
    server.start()
    fingerprint = certificate_fingerprint(cert_pem)
    try:
        for _ in range(2):
            client = MockMacClient(
                token,
                "127.0.0.1",
                server.port,
                ssl_context=client_context(),
                expected_fingerprint=fingerprint,
            )
            assert client.connect()["type"] == "HELLO_ACK"
            client.start_session()
            assert len(client.wait_for_audio_frames(3)) == 3
            client.stop_session()
            client.close()
        assert server.sessions_started == 2
        assert server.audio_frames_sent > 0
    finally:
        started = time.monotonic()
        server.stop()
        # stop() has 5s join timeouts per thread; a broken swap would make
        # this noticeably slow instead of near-instant.
        assert time.monotonic() - started < 3.0


# -- carried finding 2: the TLS handshake was no longer bounded -----------
#
# Task 6's fix reset the connect-time socket timeout to None right after
# create_connection() and before wrap_socket(), so a stalled TLS peer could
# hang the handshake forever. This test opens a plain TCP listener that
# accepts the connection but never speaks a byte of TLS, and confirms the
# client's connect() raises within its stated timeout rather than hanging.
def test_tls_handshake_is_bounded_not_infinite():
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]

    accepted: list[socket.socket] = []
    stop_stalling = threading.Event()

    def accept_and_stall():
        try:
            conn, _ = listener.accept()
        except OSError:
            return
        accepted.append(conn)
        # Deliberately never send/receive any TLS bytes; just hold the
        # connection open until the test tells us to let go.
        stop_stalling.wait(timeout=10)

    thread = threading.Thread(target=accept_and_stall, daemon=True)
    thread.start()

    token = generate_token()
    client = MockMacClient(
        token,
        "127.0.0.1",
        port,
        ssl_context=client_context(),
        expected_fingerprint="0" * 64,
    )
    started = time.monotonic()
    try:
        with pytest.raises(TimeoutError):
            client.connect(timeout=1.0)
        elapsed = time.monotonic() - started
        assert elapsed < 3.0
    finally:
        stop_stalling.set()
        client.close()
        listener.close()
        thread.join(timeout=2)
        for conn in accepted:
            conn.close()
