"""End-to-end protocol validation: mock Mac against mock Windows.

The invariant these tests exist to protect is the reason the project
exists: no audio crosses the wire outside an explicitly started session.
"""

import time

import pytest

from sharedmic_protocol.audio import FRAME_BYTES
from sharedmic_protocol.auth import generate_token
from sharedmic_protocol.client import MockMacClient
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
    cli.connect()
    yield cli
    cli.close()


def test_no_audio_before_start(client, server):
    """The core requirement. An idle connection carries zero audio."""
    time.sleep(0.5)
    client.ping()
    assert client.audio_frames_received == 0
    assert server.audio_frames_sent == 0


def test_audio_flows_only_between_start_and_stop(client, server):
    client.start_session()
    frames = client.wait_for_audio_frames(10)
    assert len(frames) == 10

    client.stop_session()
    # A frame already inside sendall when STOP_ACK was queued can still land
    # just after it. Let the socket settle before taking the reading, so the
    # assertion tests "audio stopped" rather than "audio stopped instantly".
    time.sleep(0.2)
    client.drain_audio()
    settled = client.audio_frames_received

    time.sleep(0.5)
    assert client.audio_frames_received == settled, "audio continued after STOP_ACK"


def test_audio_sequence_has_no_gaps(client):
    client.start_session()
    frames = client.wait_for_audio_frames(25)
    sequences = [seq for seq, _, _ in frames]
    assert sequences == list(range(sequences[0], sequences[0] + 25))
    assert client.sequence_gaps == 0


def test_audio_frames_are_exactly_one_frame_each(client):
    client.start_session()
    for _, _, pcm in client.wait_for_audio_frames(10):
        assert len(pcm) == FRAME_BYTES


def test_timestamps_advance_by_frame_duration(client):
    client.start_session()
    frames = client.wait_for_audio_frames(5)
    deltas = {b[1] - a[1] for a, b in zip(frames, frames[1:])}
    assert deltas == {20000}


def test_duplicate_start_is_idempotent(client, server):
    first = client.start_session()
    second = client.start_session()
    assert first["sessionId"] == second["sessionId"]
    assert server.sessions_started == 1


def test_duplicate_stop_succeeds(client):
    client.start_session()
    client.stop_session()
    client.stop_session()


def test_stop_without_start_succeeds(client):
    client.stop_session()


def test_session_can_be_restarted(client, server):
    client.start_session()
    client.wait_for_audio_frames(3)
    client.stop_session()
    client.drain_audio()

    client.start_session()
    assert len(client.wait_for_audio_frames(3)) == 3
    assert server.sessions_started == 2


def test_frame_counters_reconcile_across_a_session(client, server):
    """Offered = received + dropped + discarded, modulo one frame in flight.

    The STOP handler throws away whatever is still queued; before those
    frames were counted they simply vanished from the arithmetic, which is
    what protocol-v1.md §9 claims a reader can do and could not.
    """
    client.start_session()
    client.wait_for_audio_frames(5)
    client.stop_session()
    time.sleep(0.2)

    unaccounted = (
        server.audio_frames_sent
        - client.audio_frames_received
        - server.audio_frames_dropped
        - server.audio_frames_discarded
    )
    assert 0 <= unaccounted <= 1, (
        f"offered={server.audio_frames_sent} received={client.audio_frames_received} "
        f"dropped={server.audio_frames_dropped} discarded={server.audio_frames_discarded}"
    )


def test_mic_unplug_while_idle_sends_status(client, server):
    """Design spec §8, "USB mic unplugged while idle"."""
    server.set_mic_present(False)
    status = client.wait_for_status()
    assert status["micPresent"] is False
    assert status["active"] is False
    assert status["deviceLabel"]
    assert client.status_messages_received == 1


def test_mic_unplug_mid_session_stops_capture_and_sends_status(client, server):
    """Design spec §8, "USB mic unplugged mid-session" — the row that drives
    the Mac into DEGRADED. Windows stops capture, then sends STATUS."""
    client.start_session()
    client.wait_for_audio_frames(3)

    server.set_mic_present(False)
    status = client.wait_for_status()
    assert status["micPresent"] is False
    assert status["active"] is False

    # As with STOP, a frame already inside sendall() can land just after
    # the STATUS. Let the socket settle, then assert audio has stopped.
    time.sleep(0.2)
    client.drain_audio()
    settled = client.audio_frames_received
    time.sleep(0.4)
    assert client.audio_frames_received == settled, "audio continued after mic loss"


def test_mic_replug_sends_status_and_allows_a_new_session(client, server):
    server.set_mic_present(False)
    client.wait_for_status()

    server.set_mic_present(True)
    replug = client.wait_for_status()
    assert replug["micPresent"] is True
    assert client.status_messages_received == 2

    assert client.start_session()["type"] == "START_ACK"


def test_status_is_not_mistaken_for_a_reply(client, server):
    """An unsolicited STATUS must not be consumed by a pending request.

    _await() discards messages it is not waiting for, so a STATUS routed
    through the reply queue would both vanish and, worse, be silently
    eaten mid-request. It has its own queue for exactly this reason.
    """
    server.set_mic_present(False)
    server.set_mic_present(True)
    client.ping()
    client.start_session()
    assert client.status_messages_received == 2
    assert [s["micPresent"] for s in client.drain_status()] == [False, True]


def test_full_lifecycle_leaves_no_sequence_gaps(client):
    for _ in range(3):
        client.start_session()
        client.wait_for_audio_frames(5)
        client.stop_session()
        client.drain_audio()
    assert client.sequence_gaps == 0
