"""Mock Mac agent.

Speaks the client side of every message type in protocol-v1.md so the
Windows agent can be developed and tested without a Mac present. Tracks
audio sequence continuity, which is the cheapest way to catch framing
bugs, and surfaces unsolicited STATUS on its own queue.

It is a test double, not a complete Mac agent: no heartbeat, reconnect,
or response-timeout timers run, and _await() discards control messages
that are not the reply it is waiting for. See harness/README.md's "Known
limitations" for the full list.

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
        self._status_in: queue.Queue = queue.Queue()
        self._audio_in: queue.Queue = queue.Queue()
        self._session_id: str | None = None
        self._next_expected_sequence: int | None = None
        self._ping_seq = 0

        self.audio_frames_received = 0
        self.sequence_gaps = 0
        self.status_messages_received = 0

    # -- transport ----------------------------------------------------

    def _open_socket(self, timeout: float) -> None:
        raw = socket.create_connection((self._host, self._port), timeout=timeout)
        if self._ssl_context is None:
            # No handshake follows; reset to blocking immediately so the
            # connect-time timeout doesn't linger and govern this socket's
            # whole lifetime — see the TLS branch below for why that
            # matters.
            raw.settimeout(None)
            self._sock = raw
            return
        # create_connection() already leaves `timeout` set on `raw`; make
        # that explicit so the TLS handshake itself is bounded — a stalled
        # or silent peer must not be able to hang this call forever (Task
        # 6's fix reset to blocking mode *before* wrap_socket(), which
        # removed that bound). The instant wrap_socket() returns, whether
        # it succeeds or raises, drop back to blocking mode: a timeout that
        # persisted past the handshake would also govern _reader_loop's
        # recv() and _send()'s sendall(), which is the exact defect that
        # cost Tasks 5 and 6 a fix round each. Bounded only across
        # wrap_socket(), never for the connection's lifetime.
        raw.settimeout(timeout)
        try:
            wrapped = self._ssl_context.wrap_socket(raw, server_hostname=self._host)
        except OSError:
            # Covers TimeoutError too (it subclasses OSError); handling is
            # identical either way, so one clause suffices.
            raw.close()
            raise
        wrapped.settimeout(None)
        if self._expected_fingerprint is not None:
            actual = hashlib.sha256(wrapped.getpeercert(binary_form=True)).hexdigest()
            if actual != self._expected_fingerprint.lower().replace(":", ""):
                wrapped.close()
                raise FingerprintMismatch(
                    "server certificate fingerprint does not match the pinned value"
                )
        self._sock = wrapped

    def _abort(self) -> None:
        """Tear the connection down from inside the reader thread.

        `protocol-v1.md` §3 requires the receiver to *close the connection*
        on a protocol violation, not merely stop reading — a peer that
        keeps a half-open socket alive after rejecting a frame leaves the
        violating sender believing it still has a live session (the mock
        server already closes, via `_serve`'s `finally`). `close()` cannot
        be reused here because it joins the reader thread, which is the
        thread calling this.
        """
        self._closed.set()
        if self._sock is None:
            return
        try:
            self._sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self._sock.close()
        except OSError:
            pass

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
            except (OSError, ValueError):
                # ValueError alongside OSError for the same reason as
                # server.py's _ServerSession.run(): select() checks
                # fileno() itself and raises ValueError (not OSError) when
                # it is negative, which happens if close() runs on another
                # thread in the window between the while-condition check
                # above and this call.
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
                    self._abort()
                    return
                if result is None:
                    break
                frame_type, payload, consumed = result
                buf = buf[consumed:]
                if frame_type == FRAME_TYPE_CONTROL:
                    try:
                        msg = decode_control(payload)
                    except ProtocolError:
                        self._abort()
                        return
                    # STATUS is unsolicited — it answers no request. It
                    # therefore gets its own queue: _await() drops any
                    # message that is not the reply it is waiting for, so
                    # a STATUS routed through _control_in would vanish
                    # silently and uncounted.
                    if msg["type"] == "STATUS":
                        self.status_messages_received += 1
                        self._status_in.put(msg)
                    else:
                        self._control_in.put(msg)
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
        """Complete GREETING/HELLO/HELLO_ACK and return the HELLO_ACK.

        Raises TimeoutError if no reply arrives within `timeout`, or
        ConnectionError if the reader thread observes the connection close
        (e.g. a rejected auth proof) before that — callers should treat
        both as "connect failed" rather than branching on the exact type.
        """
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

    def wait_for_status(self, timeout: float = 2.0) -> dict:
        """Return the next unsolicited STATUS (§5), waiting up to `timeout`.

        This is how the macOS agent's mic-unplug handling (design spec §8:
        "USB mic unplugged while idle" and "mid-session") gets exercised
        against the mock: drive `MockWindowsServer.set_mic_present()` and
        assert on what arrives here.
        """
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for STATUS")
            if self._closed.is_set() and self._status_in.empty():
                raise ConnectionError("connection closed while waiting for STATUS")
            try:
                return self._status_in.get(timeout=min(remaining, 0.1))
            except queue.Empty:
                continue

    def drain_status(self) -> list[dict]:
        """Every STATUS received and not yet consumed, oldest first."""
        messages = []
        while True:
            try:
                messages.append(self._status_in.get_nowait())
            except queue.Empty:
                return messages

    def wait_for_audio_frames(self, count: int, timeout: float = 5.0) -> list:
        deadline = time.monotonic() + timeout
        frames = []
        while len(frames) < count:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"received {len(frames)} of {count} audio frames before timeout")
            # Same treatment as _await: poll in short slices and check
            # _closed rather than blocking for the full remaining timeout,
            # so a connection that drops mid-wait is reported promptly
            # instead of burning out the whole deadline for frames that
            # will never arrive. The empty()-before-raising guard still
            # lets a frame queued just before closure be delivered.
            if self._closed.is_set() and self._audio_in.empty():
                raise ConnectionError(
                    f"connection closed after {len(frames)} of {count} audio frames"
                )
            try:
                frames.append(self._audio_in.get(timeout=min(remaining, 0.1)))
            except queue.Empty:
                continue
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
