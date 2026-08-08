"""Mock Mac agent.

Speaks the full protocol so the Windows agent can be developed and tested
without a Mac present. Tracks audio sequence continuity, which is the
cheapest way to catch framing bugs.

Never logs audio payload — only counters.
"""

import hashlib
import queue
import secrets
import select
import socket
import threading
import time

from .auth import auth_proof
from .control import AUDIO_FORMAT, PROTOCOL_VERSION, decode_control, encode_control
from .framing import (
    FRAME_TYPE_AUDIO,
    FRAME_TYPE_CONTROL,
    ProtocolError,
    decode_audio_payload,
    decode_frame,
    encode_frame,
)


class SessionRejected(Exception):
    def __init__(self, reason: str):
        super().__init__(f"session rejected: {reason}")
        self.reason = reason


class FingerprintMismatch(Exception):
    """The server certificate did not match the pinned fingerprint."""


class MockMacClient:
    def __init__(
        self,
        token: bytes,
        host: str,
        port: int,
        *,
        client_id: str = "mock-mac",
        ssl_context=None,
        expected_fingerprint: str | None = None,
    ):
        self._token = token
        self._host = host
        self._port = port
        self._client_id = client_id
        self._ssl_context = ssl_context
        self._expected_fingerprint = expected_fingerprint

        self._sock: socket.socket | None = None
        self._reader: threading.Thread | None = None
        self._closed = threading.Event()
        self._control_in: queue.Queue = queue.Queue()
        self._audio_in: queue.Queue = queue.Queue()
        self._session_id: str | None = None
        self._next_expected_sequence: int | None = None
        self._ping_seq = 0

        self.audio_frames_received = 0
        self.sequence_gaps = 0

    # -- transport ----------------------------------------------------

    def _open_socket(self, timeout: float) -> None:
        raw = socket.create_connection((self._host, self._port), timeout=timeout)
        if self._ssl_context is None:
            self._sock = raw
            return
        wrapped = self._ssl_context.wrap_socket(raw, server_hostname=self._host)
        if self._expected_fingerprint is not None:
            actual = hashlib.sha256(wrapped.getpeercert(binary_form=True)).hexdigest()
            if actual != self._expected_fingerprint.lower().replace(":", ""):
                wrapped.close()
                raise FingerprintMismatch(
                    "server certificate fingerprint does not match the pinned value"
                )
        self._sock = wrapped

    def _reader_loop(self) -> None:
        buf = b""
        while not self._closed.is_set():
            # Poll for readability with a bounded timeout instead of a bare
            # blocking recv(). close() is not guaranteed to interrupt a
            # recv() already blocked in another thread on this platform
            # (observed intermittently: shutdown()+close() sometimes leaves
            # this thread parked until the join() timeout, sometimes not).
            # select() re-checks the closed flag every 0.5s regardless, so
            # the thread exits promptly and deterministically either way.
            # settimeout() is deliberately avoided: it is socket-level and
            # would also govern this thread's use of the socket alongside
            # any concurrent send.
            try:
                ready, _, _ = select.select([self._sock], [], [], 0.5)
            except OSError:
                break
            if not ready:
                continue
            try:
                chunk = self._sock.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while True:
                try:
                    result = decode_frame(buf)
                except ProtocolError:
                    self._closed.set()
                    return
                if result is None:
                    break
                frame_type, payload, consumed = result
                buf = buf[consumed:]
                if frame_type == FRAME_TYPE_CONTROL:
                    try:
                        self._control_in.put(decode_control(payload))
                    except ProtocolError:
                        self._closed.set()
                        return
                else:
                    sequence, timestamp_us, pcm = decode_audio_payload(payload)
                    if (
                        self._next_expected_sequence is not None
                        and sequence != self._next_expected_sequence
                    ):
                        self.sequence_gaps += 1
                    self._next_expected_sequence = sequence + 1
                    self.audio_frames_received += 1
                    self._audio_in.put((sequence, timestamp_us, pcm))
        self._closed.set()

    def _send(self, msg: dict) -> None:
        if self._sock is None:
            raise RuntimeError("client is not connected")
        self._sock.sendall(encode_frame(FRAME_TYPE_CONTROL, encode_control(msg)))

    def _await(self, msg_type: str, timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"timed out waiting for {msg_type}")
            # Poll in short slices rather than blocking for the full
            # remaining timeout: a connection the reader thread already
            # found dead (bad auth, malformed frame, peer hangup) should
            # be reported immediately instead of making the caller wait
            # out the whole deadline (observed: 5s per call with a single
            # blocking get()) for a message that will never arrive.
            if self._closed.is_set() and self._control_in.empty():
                raise ConnectionError(
                    f"connection closed while waiting for {msg_type}"
                )
            try:
                msg = self._control_in.get(timeout=min(remaining, 0.1))
            except queue.Empty:
                continue
            if msg["type"] == msg_type:
                return msg
            if msg_type == "START_ACK" and msg["type"] == "START_NACK":
                raise SessionRejected(msg["reason"])

    # -- protocol -----------------------------------------------------

    def connect(self, timeout: float = 5.0) -> dict:
        self._open_socket(timeout)
        self._reader = threading.Thread(target=self._reader_loop, daemon=True)
        self._reader.start()
        greeting = self._await("GREETING", timeout)
        self._send(
            {
                "v": PROTOCOL_VERSION,
                "type": "HELLO",
                "clientId": self._client_id,
                "mac": auth_proof(self._token, bytes.fromhex(greeting["nonce"])),
            }
        )
        return self._await("HELLO_ACK", timeout)

    def start_session(self, timeout: float = 2.0) -> dict:
        self._send(
            {
                "v": PROTOCOL_VERSION,
                "type": "START",
                "requestId": secrets.token_hex(8),
                "preferredFormat": AUDIO_FORMAT,
            }
        )
        ack = self._await("START_ACK", timeout)
        self._session_id = ack["sessionId"]
        return ack

    def stop_session(self, timeout: float = 1.0) -> dict:
        self._send(
            {
                "v": PROTOCOL_VERSION,
                "type": "STOP",
                "requestId": secrets.token_hex(8),
                "sessionId": self._session_id or "",
            }
        )
        ack = self._await("STOP_ACK", timeout)
        self._session_id = None
        self._next_expected_sequence = None
        return ack

    def ping(self, timeout: float = 5.0) -> None:
        self._ping_seq += 1
        self._send({"v": PROTOCOL_VERSION, "type": "PING", "seq": self._ping_seq})
        pong = self._await("PONG", timeout)
        if pong["seq"] != self._ping_seq:
            raise ProtocolError(f"PONG seq {pong['seq']} does not match PING {self._ping_seq}")

    def wait_for_audio_frames(self, count: int, timeout: float = 5.0) -> list:
        deadline = time.monotonic() + timeout
        frames = []
        while len(frames) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"received {len(frames)} of {count} audio frames before timeout")
            try:
                frames.append(self._audio_in.get(timeout=remaining))
            except queue.Empty:
                raise TimeoutError(
                    f"received {len(frames)} of {count} audio frames before timeout"
                ) from None
        return frames

    def drain_audio(self) -> int:
        drained = 0
        while True:
            try:
                self._audio_in.get_nowait()
                drained += 1
            except queue.Empty:
                return drained

    def close(self) -> None:
        self._closed.set()
        if self._sock is not None:
            # On macOS, close()ing a socket from another thread does not
            # unblock a thread parked in that socket's recv() the way it
            # does on Linux — the reader thread would stay blocked past
            # the join() below, and never actually terminate. shutdown()
            # first (as server.py's stop() already does for the same
            # reason) forces the pending recv() to return immediately.
            try:
                self._sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                self._sock.close()
            except OSError:
                pass
        if self._reader is not None:
            self._reader.join(timeout=2)
