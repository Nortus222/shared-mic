import queue
import socket
import threading
import time

import pytest

from sharedmic_protocol.auth import auth_proof, decode_pairing_string, encode_pairing_string, generate_token
from sharedmic_protocol.control import PROTOCOL_VERSION, decode_control, encode_control
from sharedmic_protocol.framing import FRAME_TYPE_CONTROL, decode_frame, encode_frame
from sharedmic_protocol.server import AUDIO_QUEUE_FRAMES, MockWindowsServer, _ServerSession


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


def test_stop_closes_lingering_client_connections(server):
    """stop() must close per-connection sockets, not just join threads.

    A client that connects and is never explicitly closed by the test
    (or crashes) must not force stop() to burn its full join timeout —
    the server has to close the socket itself to unblock the connection
    thread's recv(). Regression test for a leaked thread + socket per
    lingering connection.
    """
    sock = socket.create_connection(("127.0.0.1", server.port), timeout=5)
    try:
        _recv_control(sock)  # wait for the GREETING so the session thread is fully up
        start = time.monotonic()
        server.stop()
        elapsed = time.monotonic() - start
        assert elapsed < 2.0, f"stop() took {elapsed:.2f}s — looks like it waited on a join timeout"
    finally:
        sock.close()


def test_server_closes_idle_connection_after_hello_timeout(token):
    """A client that connects and never sends HELLO must eventually be dropped.

    The HELLO deadline exists specifically to bound how long the server
    waits for an unauthenticated client. Uses an injected, short
    `hello_timeout` instead of the real 5-second production default so this
    test exercises the identical deadline-and-recheck logic without paying
    a multi-second real sleep in the suite. Bounds are loose relative to
    that short timeout to tolerate a busy machine: the connection must not
    hang forever, and it must not close suspiciously early either.
    """
    small_timeout = 0.3
    srv = MockWindowsServer(token, hello_timeout=small_timeout)
    srv.start()
    try:
        with socket.create_connection(("127.0.0.1", srv.port), timeout=small_timeout + 5.0) as sock:
            _recv_control(sock)  # GREETING
            start = time.monotonic()
            data = sock.recv(4096)  # send nothing; wait for the server to give up
            elapsed = time.monotonic() - start
        assert data == b"", "server should have closed the connection, not sent more data"
        assert elapsed < small_timeout + 2.0, f"took {elapsed:.2f}s — looks like it never timed out"
        assert elapsed > small_timeout - 0.2, f"closed after only {elapsed:.2f}s — looks suspiciously early"
    finally:
        srv.stop()


def test_server_rejects_non_hello_message_before_authentication(server):
    """§6: no message type other than HELLO is valid before authentication.

    PING is the representative case here, but the check in
    _ServerSession.run() is `msg["type"] != "HELLO"`, not a per-type
    allowlist, so this one negative case exercises the same branch that
    would reject START/STOP/STATUS/AUDIO too.
    """
    with socket.create_connection(("127.0.0.1", server.port), timeout=5) as sock:
        _recv_control(sock)  # GREETING
        _send_control(sock, {"v": PROTOCOL_VERSION, "type": "PING", "seq": 1})
        assert sock.recv(4096) == b"", "server should have closed the connection, not replied"
    assert server.auth_failures == 1


def test_control_preempts_a_full_audio_backlog_and_counts_the_drop(token):
    """§9: control drains before audio, and overflow drops the oldest frame.

    Naturally overflowing the 25-frame audio queue would mean waiting out
    the real 50 fps production pacing in `_audio_loop` (500ms+ of real
    sleep for no added confidence, since the pacing loop is not what's
    under test). Instead this drives `_ServerSession` directly and fills
    both queues *before* the writer thread is started, so there is no race
    between "how much backlog exists" and "when the writer first looks" —
    what's under test is the writer's per-iteration priority check
    (control before audio, unconditionally), not timing. The audio filler
    payloads are deliberately opaque junk: this test never decodes them,
    only counts and identifies them by position, because a full audio
    backlog sitting unread behind a just-sent control message is exactly
    the scenario the bounded queue exists to survive.
    """
    srv = MockWindowsServer(token)
    local, remote = socket.socketpair()
    session = _ServerSession(srv, local)
    try:
        filler = [f"filler-{i}".encode() for i in range(AUDIO_QUEUE_FRAMES + 5)]
        for chunk in filler:
            session._offer_audio(chunk)
        assert srv.audio_frames_dropped == 5, "5 offers past capacity should drop exactly 5 frames"

        # The queue should hold exactly the last AUDIO_QUEUE_FRAMES chunks —
        # the oldest 5 were the ones dropped, not an arbitrary 5.
        survivors = []
        while True:
            try:
                survivors.append(session._audio_q.get_nowait())
            except queue.Empty:
                break
        assert survivors == filler[5:], "the oldest frames, not an arbitrary 5, must be the ones dropped"
        for chunk in survivors:  # put the backlog back so it's there when the writer starts
            session._audio_q.put_nowait(chunk)

        session._send_control({"v": PROTOCOL_VERSION, "type": "PING", "seq": 7})

        # Only now does the writer see a full audio backlog *and* a queued
        # control message at once.
        session._writer_thread = threading.Thread(target=session._writer_loop, daemon=True)
        session._writer_thread.start()

        remote.settimeout(2.0)
        buf = b""
        result = None
        while result is None:
            result = decode_frame(buf)
            if result is None:
                buf += remote.recv(65536)
        frame_type, payload, _ = result
        assert frame_type == FRAME_TYPE_CONTROL, "a queued control message must preempt a full audio backlog"
        assert decode_control(payload) == {"v": PROTOCOL_VERSION, "type": "PING", "seq": 7}
    finally:
        session.close()
        remote.close()
