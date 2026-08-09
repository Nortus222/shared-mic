"""Mock Windows agent.

Speaks the server side of every message type in protocol-v1.md so the
macOS agent can be developed and tested without a Windows machine
present. Mirrors the session lifecycle from the spec, including
START/STOP idempotency, unsolicited STATUS on mic hot-unplug/replug, and
the control-before-audio send priority.

It is a test double, not a complete Windows agent: no heartbeat or
dead-peer timers run, and failed authentication is counted but not
rate-limited. See harness/README.md's "Known limitations" for the full
list and protocol-v1.md's [CARRIED] tags for what that leaves unproven.

Never logs audio payload — only counters.
"""

import queue
import secrets
import select
import socket
import threading
import time

from .audio import FRAME_DURATION_US, FRAMES_PER_SECOND, sine_frame
from .auth import generate_nonce, verify_proof
from .control import AUDIO_FORMAT, PROTOCOL_VERSION, decode_control, encode_control
from .framing import (
    FRAME_TYPE_AUDIO,
    FRAME_TYPE_CONTROL,
    ProtocolError,
    decode_frame,
    encode_audio_payload,
    encode_frame,
)

AUDIO_QUEUE_FRAMES = 25
HELLO_TIMEOUT_SECONDS = 5.0


class MockWindowsServer:
    def __init__(
        self,
        token: bytes,
        *,
        host: str = "127.0.0.1",
        port: int = 0,
        mic_present: bool = True,
        device_label: str = "Mock USB Mic",
        server_id: str = "mock-win",
        ssl_context=None,
        hello_timeout: float = HELLO_TIMEOUT_SECONDS,
    ):
        self._token = token
        self._host = host
        self._requested_port = port
        self._mic_present = mic_present
        self._device_label = device_label
        self._server_id = server_id
        self._ssl_context = ssl_context
        self._hello_timeout = hello_timeout

        self._listener: socket.socket | None = None
        self._accept_thread: threading.Thread | None = None
        self._connection_threads: list[threading.Thread] = []
        self._connections: list[socket.socket] = []
        self._sessions: list["_ServerSession"] = []
        self._running = threading.Event()
        self._lock = threading.Lock()

        self.port = 0
        self.audio_frames_sent = 0
        self.audio_frames_dropped = 0
        self.audio_frames_discarded = 0
        self.sessions_started = 0
        self.auth_failures = 0

    # -- lifecycle ----------------------------------------------------

    def start(self) -> None:
        self._listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._listener.bind((self._host, self._requested_port))
        self._listener.listen(4)
        self.port = self._listener.getsockname()[1]
        self._running.set()
        self._accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self._accept_thread.start()

    def stop(self) -> None:
        self._running.clear()
        if self._listener is not None:
            try:
                self._listener.close()
            except OSError:
                pass
        # Close every live per-connection socket so a thread parked in
        # recv() (e.g. a client that connected but never sent HELLO, or
        # a lingering test connection) is unblocked immediately instead
        # of holding the join() below for its full timeout.
        with self._lock:
            connections = list(self._connections)
        for conn in connections:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass
        if self._accept_thread is not None:
            self._accept_thread.join(timeout=5)
        for thread in list(self._connection_threads):
            thread.join(timeout=5)

    def set_mic_present(self, present: bool) -> None:
        """Simulate a USB hot-unplug/replug and notify connected peers.

        Design spec §8 gives this two distinct behaviors, and both are
        modelled here so the macOS agent's `DEGRADED` path can actually be
        developed against the mock:

        - unplugged **while idle** — Windows sends `STATUS{micPresent:
          false}`, the connection stays up, and activation is blocked
          (`START` → `START_NACK{MIC_UNAVAILABLE}`, unchanged);
        - unplugged **mid-session** — Windows stops capture *first*, then
          sends `STATUS`, so `active` is already `false` by the time the
          Mac reads it.

        Only authenticated sessions are notified: §6 forbids `STATUS`
        before `HELLO_ACK`.
        """
        with self._lock:
            self._mic_present = present
            sessions = list(self._sessions)
        for session in sessions:
            session.notify_mic_presence(present)

    # -- accept -------------------------------------------------------

    def _accept_loop(self) -> None:
        while self._running.is_set():
            try:
                conn, _ = self._listener.accept()
            except OSError:
                return
            # Track the connection immediately, before the TLS wrap or the
            # thread spawn, so a concurrent stop() can never miss it and
            # fall back to waiting out a join timeout for this connection.
            with self._lock:
                self._connections.append(conn)
            if self._ssl_context is not None:
                try:
                    wrapped = self._ssl_context.wrap_socket(conn, server_side=True)
                except OSError:
                    with self._lock:
                        if conn in self._connections:
                            self._connections.remove(conn)
                    conn.close()
                    continue
                # wrap_socket() returns a distinct object over the same fd;
                # swap the tracked reference so stop() closes the object
                # the session actually uses.
                with self._lock:
                    if conn in self._connections:
                        self._connections.remove(conn)
                    self._connections.append(wrapped)
                conn = wrapped
            thread = threading.Thread(target=self._serve, args=(conn,), daemon=True)
            with self._lock:
                self._connection_threads.append(thread)
            thread.start()

    # -- per-connection -----------------------------------------------

    def _serve(self, conn: socket.socket) -> None:
        session = _ServerSession(self, conn, hello_timeout=self._hello_timeout)
        with self._lock:
            self._sessions.append(session)
        try:
            session.run()
        finally:
            session.close()
            with self._lock:
                if conn in self._connections:
                    self._connections.remove(conn)
                if session in self._sessions:
                    self._sessions.remove(session)


class _ServerSession:
    def __init__(
        self,
        server: MockWindowsServer,
        conn: socket.socket,
        *,
        hello_timeout: float = HELLO_TIMEOUT_SECONDS,
    ):
        self._server = server
        self._conn = conn
        self._hello_timeout = hello_timeout
        self._control_q: queue.Queue = queue.Queue()
        self._audio_q: queue.Queue = queue.Queue(maxsize=AUDIO_QUEUE_FRAMES)
        self._closed = threading.Event()
        self._session_id: str | None = None
        self._audio_thread: threading.Thread | None = None
        self._writer_thread: threading.Thread | None = None
        # Read by notify_mic_presence() from the caller's thread, written
        # by run() on this session's thread. A bool assignment is atomic
        # under the GIL and the only consequence of reading a stale False
        # is one skipped STATUS on a connection that just authenticated.
        self._authenticated = False

    # -- send priority ------------------------------------------------

    def _send_control(self, msg: dict) -> None:
        self._control_q.put(encode_frame(FRAME_TYPE_CONTROL, encode_control(msg)))

    def _offer_audio(self, frame: bytes) -> None:
        """Bounded, drop-oldest. Audio must never block the writer.

        `audio_frames_dropped` is incremented exactly when an existing
        queued frame is evicted to make room for this one — i.e. once per
        frame actually dropped, not once per call. `audio_frames_sent`
        (incremented by the caller, `_audio_loop`) already counts frames
        *offered*. Together with `audio_frames_discarded` (frames still
        queued when a session ends, see `_drain_audio_queue`) these let a
        reader reconcile offered vs. dropped vs. discarded vs. what the
        far end actually received; see protocol-v1.md §9.
        """
        try:
            self._audio_q.put_nowait(frame)
        except queue.Full:
            try:
                self._audio_q.get_nowait()
            except queue.Empty:
                pass
            else:
                with self._server._lock:
                    self._server.audio_frames_dropped += 1
            try:
                self._audio_q.put_nowait(frame)
            except queue.Full:
                pass

    def _drain_audio_queue(self) -> None:
        """Discard everything still queued when a session ends.

        Counted in `audio_frames_discarded`, kept separate from
        `audio_frames_dropped` on purpose: an overflow eviction is a
        symptom (the network could not keep up), a teardown discard is
        intended behavior. Folding them together would make the one
        counter worth alarming on unreadable. Without this counter the
        offered/dropped/received reconciliation in protocol-v1.md §9 does
        not close, because these frames were counted as offered and then
        silently vanished.
        """
        discarded = 0
        while True:
            try:
                self._audio_q.get_nowait()
            except queue.Empty:
                break
            discarded += 1
        if discarded:
            with self._server._lock:
                self._server.audio_frames_discarded += discarded

    def _writer_loop(self) -> None:
        while not self._closed.is_set():
            try:
                data = self._control_q.get_nowait()
            except queue.Empty:
                try:
                    data = self._audio_q.get(timeout=0.005)
                except queue.Empty:
                    continue
            try:
                self._conn.sendall(data)
            except OSError:
                self._closed.set()
                return

    # -- audio --------------------------------------------------------

    def _audio_loop(self, session_id: str) -> None:
        index = 0
        next_due = time.monotonic()
        while not self._closed.is_set() and self._session_id == session_id:
            payload = encode_audio_payload(index, index * FRAME_DURATION_US, sine_frame(index))
            self._offer_audio(encode_frame(FRAME_TYPE_AUDIO, payload))
            with self._server._lock:
                self._server.audio_frames_sent += 1
            index += 1
            next_due += 1.0 / FRAMES_PER_SECOND
            time.sleep(max(0.0, next_due - time.monotonic()))

    # -- unsolicited state change -------------------------------------

    def notify_mic_presence(self, present: bool) -> None:
        """Send `STATUS` for a mic hot-unplug/replug. See set_mic_present()."""
        if not self._authenticated or self._closed.is_set():
            return
        if not present:
            self._end_session_for_mic_loss()
        self._send_control(
            {
                "v": PROTOCOL_VERSION,
                "type": "STATUS",
                "micPresent": present,
                "active": self._session_id is not None,
                "deviceLabel": self._server._device_label,
            }
        )

    def _end_session_for_mic_loss(self) -> None:
        """Stop capture when the mic disappears — no STOP_ACK, none was asked for.

        Clearing `_session_id` is what stops `_audio_loop`: it re-checks
        that value every 20 ms tick and returns when it no longer matches
        the session it was started for. The thread is deliberately *not*
        joined here — this runs on the caller's thread, not the session
        thread — so, exactly as with `STOP`, one frame already produced or
        already inside `sendall()` can still reach the far end just after
        the `STATUS`. Draining the queue discards the rest.
        """
        if self._session_id is None:
            return
        self._session_id = None
        self._audio_thread = None
        self._drain_audio_queue()

    # -- protocol -----------------------------------------------------

    def run(self) -> None:
        nonce = generate_nonce()
        self._writer_thread = threading.Thread(target=self._writer_loop, daemon=True)
        self._writer_thread.start()
        self._send_control(
            {
                "v": PROTOCOL_VERSION,
                "type": "GREETING",
                "serverId": self._server._server_id,
                "nonce": nonce.hex(),
            }
        )

        buf = b""
        deadline = time.monotonic() + self._hello_timeout

        while not self._closed.is_set():
            if not self._authenticated and time.monotonic() > deadline:
                return
            # Poll for readability with a short timeout instead of calling
            # conn.settimeout(): the socket is shared with _writer_loop's
            # sendall() on the same connection, and a settimeout() there
            # would also bound writes, turning a transient send stall into
            # a torn-down control channel (the opposite of what the
            # drop-oldest audio queue exists to protect). select() lets the
            # read side poll without touching the write side's blocking
            # behavior at all.
            try:
                ready, _, _ = select.select([self._conn], [], [], 0.5)
            except (OSError, ValueError):
                # OSError: the fd was valid but the OS-level select() call
                # failed (e.g. EBADF from a close mid-syscall on some
                # platforms). ValueError: select() checks fileno() itself
                # before the syscall and raises this (not OSError) when it
                # is negative — which is exactly what happens if another
                # thread (server.stop(), or a TLS peer whose fingerprint
                # check failed and tore the connection down) closes
                # self._conn in the window between the while-condition
                # check above and this call. Found via test_tls.py's
                # fingerprint-mismatch test, which closes the connection
                # unusually early in the session lifecycle and made this
                # race easy to hit.
                return
            if not ready:
                continue  # re-check the deadline and the closed flag
            try:
                chunk = self._conn.recv(65536)
            except TimeoutError:
                # Kept even though settimeout() is no longer used here: if a
                # timeout is ever reintroduced on this socket, TimeoutError
                # (a subclass of OSError) must be handled before the
                # broader OSError below, or every timeout would be treated
                # as a dead connection.
                continue
            except OSError:
                return
            if not chunk:
                return
            buf += chunk

            while True:
                try:
                    result = decode_frame(buf)
                except ProtocolError:
                    return
                if result is None:
                    break
                frame_type, payload, consumed = result
                buf = buf[consumed:]
                if frame_type != FRAME_TYPE_CONTROL:
                    return
                try:
                    msg = decode_control(payload)
                except ProtocolError:
                    return

                if not self._authenticated:
                    if msg["type"] != "HELLO" or not verify_proof(self._server._token, nonce, msg["mac"]):
                        with self._server._lock:
                            self._server.auth_failures += 1
                        return
                    with self._server._lock:
                        mic_present = self._server._mic_present
                    self._send_control(
                        {
                            "v": PROTOCOL_VERSION,
                            "type": "HELLO_ACK",
                            "serverId": self._server._server_id,
                            "micPresent": mic_present,
                            "deviceLabel": self._server._device_label,
                        }
                    )
                    # Flipped only after HELLO_ACK is on the control queue:
                    # a concurrent set_mic_present() must not be able to
                    # slip a STATUS ahead of it (§6 — nothing precedes
                    # HELLO_ACK on an authenticated connection).
                    self._authenticated = True
                    continue

                self._handle(msg)

    def _handle(self, msg: dict) -> None:
        kind = msg["type"]

        if kind == "PING":
            self._send_control({"v": PROTOCOL_VERSION, "type": "PONG", "seq": msg["seq"]})

        elif kind == "START":
            with self._server._lock:
                mic_present = self._server._mic_present
            if not mic_present:
                self._send_control(
                    {
                        "v": PROTOCOL_VERSION,
                        "type": "START_NACK",
                        "requestId": msg["requestId"],
                        "reason": "MIC_UNAVAILABLE",
                    }
                )
                return
            if self._session_id is None:
                self._session_id = secrets.token_hex(8)
                with self._server._lock:
                    self._server.sessions_started += 1
                self._audio_thread = threading.Thread(
                    target=self._audio_loop, args=(self._session_id,), daemon=True
                )
                self._audio_thread.start()
            self._send_control(
                {
                    "v": PROTOCOL_VERSION,
                    "type": "START_ACK",
                    "requestId": msg["requestId"],
                    "sessionId": self._session_id,
                    "format": AUDIO_FORMAT,
                }
            )

        elif kind == "STOP":
            ended = self._session_id
            self._session_id = None
            if self._audio_thread is not None:
                self._audio_thread.join(timeout=2)
                self._audio_thread = None
            self._drain_audio_queue()
            self._send_control(
                {
                    "v": PROTOCOL_VERSION,
                    "type": "STOP_ACK",
                    "requestId": msg["requestId"],
                    "sessionId": ended or msg["sessionId"],
                }
            )

    def close(self) -> None:
        self._closed.set()
        self._session_id = None
        if self._writer_thread is not None:
            self._writer_thread.join(timeout=2)
        try:
            self._conn.close()
        except OSError:
            pass
