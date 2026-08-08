import threading
import time

import pytest

from sharedmic_protocol.audio import FRAME_BYTES
from sharedmic_protocol.auth import generate_token
from sharedmic_protocol.client import MockMacClient, SessionRejected
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


@pytest.fixture
def client(token, server):
    cli = MockMacClient(token, "127.0.0.1", server.port)
    yield cli
    cli.close()


def test_connect_completes_handshake(client):
    ack = client.connect()
    assert ack["type"] == "HELLO_ACK"
    assert ack["micPresent"] is True


def test_start_session_returns_session_id(client):
    client.connect()
    ack = client.start_session()
    assert ack["type"] == "START_ACK"
    assert ack["sessionId"]
    assert ack["format"]["sampleRate"] == 48000


def test_client_receives_full_size_audio_frames(client):
    client.connect()
    client.start_session()
    frames = client.wait_for_audio_frames(5)
    assert len(frames) == 5
    assert all(len(pcm) == FRAME_BYTES for _, _, pcm in frames)


def test_ping_gets_pong(client):
    client.connect()
    client.ping()


def test_start_is_rejected_when_mic_absent(token, server):
    server.set_mic_present(False)
    cli = MockMacClient(token, "127.0.0.1", server.port)
    try:
        cli.connect()
        with pytest.raises(SessionRejected) as exc:
            cli.start_session()
        assert exc.value.reason == "MIC_UNAVAILABLE"
    finally:
        cli.close()


def test_wrong_token_fails_to_connect(server):
    cli = MockMacClient(generate_token(), "127.0.0.1", server.port)
    try:
        with pytest.raises(Exception):
            cli.connect()
    finally:
        cli.close()


def test_wait_for_audio_frames_fails_fast_when_connection_drops(client, server):
    client.connect()
    client.start_session()

    def sever():
        time.sleep(0.1)
        server.stop()

    severing = threading.Thread(target=sever, daemon=True)
    severing.start()
    try:
        start = time.monotonic()
        # Ask for far more frames than could ever arrive before the
        # severed connection is noticed, with a timeout generous enough
        # that only a fail-fast path (not the timeout itself) could
        # explain a quick failure.
        with pytest.raises(Exception):
            client.wait_for_audio_frames(10_000, timeout=5.0)
        elapsed = time.monotonic() - start
    finally:
        severing.join(timeout=2)
    assert elapsed < 2.0
