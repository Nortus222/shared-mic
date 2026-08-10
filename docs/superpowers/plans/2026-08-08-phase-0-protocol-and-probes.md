# Phase 0 — Protocol and Probes Implementation Plan

> ## ⚠️ THIS PLAN HAS BEEN EXECUTED. IT IS A HISTORICAL RECORD, NOT A SPECIFICATION.
>
> Phase 0 is complete. This document is kept as the record of what was *planned*; several of its
> verbatim code samples were **found to be defective while executing it**, and were corrected in the
> deliverables. Do not copy code out of this plan. If you want to know what Phase 0 actually
> produced, read these instead:
>
> - `protocol/protocol-v1.md` — the wire contract, with per-requirement verified/carried tags
> - `harness/` — the reference implementation and its 101-test conformance suite
> - `docs/superpowers/probes/` — what each probe actually measured
> - `docs/superpowers/specs/2026-08-08-shared-mic-design.md` — the design, updated by what was learned
>
> **The single most important correction: the demand-detection gate specified in this plan is
> wrong and must not be implemented.** Task 10's probe code below gates demand on
> `row.runningInput && onTarget` (see the annotations at Task 10 Step 1 and Step 4). Running that
> probe on the target Mac disproved the `runningInput` conjunct: on a process's second and later
> input activation, `kAudioProcessPropertyIsRunningInput` reads `false` at the instant device-list
> membership is confirmed `true`, so a gate requiring it detects an application's first use of the
> microphone and then silently misses every later one for that process's lifetime. Demand is gated
> on `kAudioProcessPropertyDevices` (input-scope) membership **alone**. Authoritative sources:
> design spec §5.1 and `docs/superpowers/probes/2026-08-08-macos-demand-findings.md`.
>
> **Commands in this plan do not run as written on this machine.** Every `python …` invocation
> below must be `.venv/bin/python …` from `harness/`: there is no bare `python` on this machine's
> `PATH`, and the system `python3` has no `pytest`. See `CLAUDE.md` and `harness/README.md` for the
> commands that were actually run.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a proven wire protocol, a reference implementation that doubles as a conformance test harness, and two throwaway probes that retire the project's remaining technical risks before any production code is written.

**Architecture:** A Python reference implementation of the protocol serves three purposes at once — it forces the protocol to be concrete, it validates the protocol against itself via loopback, and it becomes the test double that lets the Windows and macOS agents be built independently in later phases. Two standalone probes answer the two open empirical questions: whether macOS reports per-process input devices well enough for device-scoped demand detection, and how long WASAPI shared-mode capture actually takes to open on the target hardware.

**Tech Stack:** Python 3.11+ with pytest and `cryptography` (harness); Swift with CoreAudio (macOS probe); C# on .NET 10 with NAudio (Windows probe).

## Global Constraints

Every task's requirements implicitly include this section. Values are copied verbatim from `docs/superpowers/specs/2026-08-08-shared-mic-design.md`.

- **Protocol version:** `1`
- **Default port:** TCP `47800`
- **Envelope framing:** `uint8 type` + `uint32 length` + payload, network byte order (big-endian). `type` 1 = CONTROL, 2 = AUDIO.
- **Audio payload:** `uint32 sequence` + `uint64 captureTimestampUs` + PCM bytes. No inner length field.
- **Audio format:** 48,000 Hz, 1 channel, 16-bit signed **little-endian** PCM. 20 ms frames = 960 samples = **1,920 bytes**. 50 frames/sec.
- **Authentication:** server sends `GREETING{serverId, nonce}`; client replies `HELLO{v, clientId, mac}` where `mac = HMAC-SHA256(token, nonce)` as lowercase hex. The token never crosses the wire.
- **Timeouts:** `START` 2 s, `STOP` 1 s, `PING` every 15 s, peer declared dead after 45 s.
- **Send queue:** control unbounded and always drained first; audio bounded at 25 frames, dropping oldest on overflow, never blocking.
- **Idempotency:** duplicate `START` while active returns the current session info; duplicate `STOP` while idle returns success.
- **Audio payload is never logged or persisted.** Counters and lifecycle events only. This applies to the harness too — it is easier to add a debug dump than to remove a habit.
- **macOS 14.4+** is required for `kAudioProcessPropertyDevices`. Target machine is macOS 26.6.1.

## File Structure

```
protocol/
  protocol-v1.md                        the wire contract, written once proven (Task 8)
  vectors/control-messages.json         golden encodings both implementations must match
  vectors/audio-frames.json
harness/
  pyproject.toml                        package metadata, pytest config, deps
  sharedmic_protocol/framing.py         envelope + audio frame codec (pure)
  sharedmic_protocol/control.py         control message types, validation, JSON codec (pure)
  sharedmic_protocol/auth.py            token, nonce, HMAC proof (pure)
  sharedmic_protocol/audio.py           synthetic PCM generation (pure)
  sharedmic_protocol/tls.py             self-signed cert generation, fingerprint pinning
  sharedmic_protocol/server.py          mock Windows agent
  sharedmic_protocol/client.py          mock Mac agent
  tests/                                one test module per unit, plus loopback and vectors
probes/
  macos-demand/DemandProbe.swift        throwaway; enumerates per-process input by device
  macos-demand/README.md
  windows-wasapi-latency/               throwaway; measures shared-mode open latency
docs/superpowers/probes/                probe findings — these outlive the probes
```

The four pure modules (`framing`, `control`, `auth`, `audio`) contain no I/O and no sockets. `server.py` and `client.py` are thin shells around them. This mirrors the boundary discipline the spec requires of the real agents, and it is what makes the loopback test meaningful.

**Probes are throwaway; their findings are not.** The probe source is deleted or left to rot after Phase 0. The markdown in `docs/superpowers/probes/` is the durable output and feeds directly into Phase 1.

---

### Task 1: Harness scaffold and framing codec

**Files:**
- Create: `harness/pyproject.toml`
- Create: `harness/sharedmic_protocol/__init__.py`
- Create: `harness/sharedmic_protocol/framing.py`
- Test: `harness/tests/test_framing.py`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `FRAME_TYPE_CONTROL: int = 1`, `FRAME_TYPE_AUDIO: int = 2`
  - `MAX_PAYLOAD: int = 1048576`
  - `encode_frame(frame_type: int, payload: bytes) -> bytes`
  - `decode_frame(buf: bytes) -> tuple[int, bytes, int] | None` — returns `(frame_type, payload, bytes_consumed)`, or `None` when `buf` holds an incomplete frame
  - `encode_audio_payload(sequence: int, timestamp_us: int, pcm: bytes) -> bytes`
  - `decode_audio_payload(payload: bytes) -> tuple[int, int, bytes]`
  - `ProtocolError(Exception)`

- [ ] **Step 1: Create the package scaffold**

Create `harness/pyproject.toml`:

```toml
[project]
name = "sharedmic-protocol"
version = "0.1.0"
description = "Reference implementation and conformance harness for the shared-mic wire protocol"
requires-python = ">=3.11"
dependencies = ["cryptography>=42"]

[project.optional-dependencies]
dev = ["pytest>=8"]

[tool.pytest.ini_options]
testpaths = ["tests"]
```

Create an empty `harness/sharedmic_protocol/__init__.py`.

Then install the test dependencies:

Run: `cd harness && .venv/bin/python -m pip install pytest 'cryptography>=42'`
Expected: successful install. Both are needed before any test in this plan can run.

> **Corrected during execution.** This step was written as `python -m pip install …`, which cannot
> run here — there is no bare `python` on this machine's `PATH`. The same substitution applies to
> every `python -m pytest …` and `python tools/…` line in the rest of this plan, which are left as
> originally written. `cryptography` builds from source on this machine and takes several minutes;
> once the virtualenv has it, reuse that virtualenv rather than reinstalling.

- [ ] **Step 2: Write the failing test**

Create `harness/tests/test_framing.py`:

```python
import pytest

from sharedmic_protocol.framing import (
    FRAME_TYPE_AUDIO,
    FRAME_TYPE_CONTROL,
    ProtocolError,
    decode_audio_payload,
    decode_frame,
    encode_audio_payload,
    encode_frame,
)


def test_envelope_round_trip():
    data = encode_frame(FRAME_TYPE_CONTROL, b'{"type":"PING"}')
    assert decode_frame(data) == (FRAME_TYPE_CONTROL, b'{"type":"PING"}', len(data))


def test_envelope_is_five_byte_header_big_endian():
    data = encode_frame(FRAME_TYPE_AUDIO, b"\x00\x01\x02")
    assert data[:5] == b"\x02\x00\x00\x00\x03"


def test_decode_returns_none_when_header_incomplete():
    assert decode_frame(b"\x01\x00\x00") is None


def test_decode_returns_none_when_payload_incomplete():
    data = encode_frame(FRAME_TYPE_CONTROL, b"hello")
    assert decode_frame(data[:-1]) is None


def test_decode_reports_consumed_so_stream_can_hold_two_frames():
    stream = encode_frame(FRAME_TYPE_CONTROL, b"one") + encode_frame(FRAME_TYPE_CONTROL, b"two")
    frame_type, payload, consumed = decode_frame(stream)
    assert payload == b"one"
    assert decode_frame(stream[consumed:]) == (FRAME_TYPE_CONTROL, b"two", 8)


def test_decode_rejects_unknown_frame_type():
    with pytest.raises(ProtocolError, match="frame type"):
        decode_frame(b"\x09\x00\x00\x00\x01x")


def test_decode_rejects_oversized_payload():
    with pytest.raises(ProtocolError, match="payload too large"):
        decode_frame(b"\x01\xff\xff\xff\xffx")


def test_audio_payload_round_trip():
    pcm = b"\x11\x22" * 960
    assert decode_audio_payload(encode_audio_payload(7, 123456789, pcm)) == (7, 123456789, pcm)


def test_audio_payload_header_is_twelve_bytes():
    pcm = b"\x00\x00" * 960
    assert len(encode_audio_payload(1, 2, pcm)) == 12 + 1920


def test_audio_payload_rejects_short_header():
    with pytest.raises(ProtocolError, match="audio payload"):
        decode_audio_payload(b"\x00" * 11)
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd harness && python -m pytest tests/test_framing.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'sharedmic_protocol.framing'`

- [ ] **Step 4: Write the implementation**

Create `harness/sharedmic_protocol/framing.py`:

```python
"""Wire framing for the shared-mic protocol.

Pure functions only: no sockets, no logging, no I/O. Everything here is
covered by golden vectors that both platform implementations must match.
"""

import struct

FRAME_TYPE_CONTROL = 1
FRAME_TYPE_AUDIO = 2
_VALID_FRAME_TYPES = (FRAME_TYPE_CONTROL, FRAME_TYPE_AUDIO)

MAX_PAYLOAD = 1048576

_ENVELOPE = struct.Struct("!BI")
_AUDIO_HEADER = struct.Struct("!IQ")

ENVELOPE_SIZE = _ENVELOPE.size
AUDIO_HEADER_SIZE = _AUDIO_HEADER.size


class ProtocolError(Exception):
    """Raised when bytes on the wire violate the protocol."""


def encode_frame(frame_type: int, payload: bytes) -> bytes:
    if frame_type not in _VALID_FRAME_TYPES:
        raise ProtocolError(f"unknown frame type {frame_type}")
    if len(payload) > MAX_PAYLOAD:
        raise ProtocolError("payload too large")
    return _ENVELOPE.pack(frame_type, len(payload)) + payload


def decode_frame(buf: bytes) -> tuple[int, bytes, int] | None:
    """Decode one frame from the head of buf.

    Returns (frame_type, payload, bytes_consumed), or None if buf does not
    yet hold a complete frame. Raises ProtocolError on malformed input.
    """
    if len(buf) < ENVELOPE_SIZE:
        return None
    frame_type, length = _ENVELOPE.unpack_from(buf, 0)
    if frame_type not in _VALID_FRAME_TYPES:
        raise ProtocolError(f"unknown frame type {frame_type}")
    if length > MAX_PAYLOAD:
        raise ProtocolError("payload too large")
    end = ENVELOPE_SIZE + length
    if len(buf) < end:
        return None
    return frame_type, buf[ENVELOPE_SIZE:end], end


def encode_audio_payload(sequence: int, timestamp_us: int, pcm: bytes) -> bytes:
    return _AUDIO_HEADER.pack(sequence, timestamp_us) + pcm


def decode_audio_payload(payload: bytes) -> tuple[int, int, bytes]:
    if len(payload) < AUDIO_HEADER_SIZE:
        raise ProtocolError("audio payload shorter than header")
    sequence, timestamp_us = _AUDIO_HEADER.unpack_from(payload, 0)
    return sequence, timestamp_us, payload[AUDIO_HEADER_SIZE:]
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd harness && python -m pytest tests/test_framing.py -v`
Expected: PASS — 10 passed

- [ ] **Step 6: Commit**

```bash
git add harness/
git commit -m "feat(protocol): add wire framing codec with golden-path tests

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Control message codec

**Files:**
- Create: `harness/sharedmic_protocol/control.py`
- Test: `harness/tests/test_control.py`

**Interfaces:**
- Consumes: `ProtocolError` from `sharedmic_protocol.framing`
- Produces:
  - `PROTOCOL_VERSION: int = 1`
  - `REQUIRED_FIELDS: dict[str, tuple[str, ...]]`
  - `encode_control(msg: dict) -> bytes` — validates, then UTF-8 JSON
  - `decode_control(payload: bytes) -> dict` — parses, then validates
  - `AUDIO_FORMAT: dict` — the canonical `{"sampleRate": 48000, "channels": 1, "sampleFormat": "s16le"}`

- [ ] **Step 1: Write the failing test**

Create `harness/tests/test_control.py`:

```python
import pytest

from sharedmic_protocol.control import (
    AUDIO_FORMAT,
    PROTOCOL_VERSION,
    decode_control,
    encode_control,
)
from sharedmic_protocol.framing import ProtocolError


def test_ping_round_trip():
    msg = {"v": PROTOCOL_VERSION, "type": "PING", "seq": 3}
    assert decode_control(encode_control(msg)) == msg


def test_start_round_trip_carries_format():
    msg = {
        "v": PROTOCOL_VERSION,
        "type": "START",
        "requestId": "r-1",
        "preferredFormat": AUDIO_FORMAT,
    }
    assert decode_control(encode_control(msg))["preferredFormat"] == AUDIO_FORMAT


def test_canonical_audio_format_matches_spec():
    assert AUDIO_FORMAT == {"sampleRate": 48000, "channels": 1, "sampleFormat": "s16le"}


def test_rejects_unknown_message_type():
    with pytest.raises(ProtocolError, match="unknown control type"):
        encode_control({"v": 1, "type": "LAUNCH_MISSILES"})


def test_rejects_wrong_protocol_version():
    with pytest.raises(ProtocolError, match="version"):
        decode_control(b'{"v": 2, "type": "PING", "seq": 1}')


def test_rejects_missing_required_field():
    with pytest.raises(ProtocolError, match="missing required field 'nonce'"):
        encode_control({"v": 1, "type": "GREETING", "serverId": "win-1"})


def test_rejects_non_object_json():
    with pytest.raises(ProtocolError, match="object"):
        decode_control(b'["not", "an", "object"]')


def test_rejects_malformed_json():
    with pytest.raises(ProtocolError, match="malformed JSON"):
        decode_control(b"{not json")


def test_encodes_as_utf8_without_ascii_escaping():
    payload = encode_control(
        {"v": 1, "type": "HELLO_ACK", "serverId": "win-1", "micPresent": True, "deviceLabel": "Røde"}
    )
    assert "Røde".encode("utf-8") in payload
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd harness && python -m pytest tests/test_control.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'sharedmic_protocol.control'`

- [ ] **Step 3: Write the implementation**

Create `harness/sharedmic_protocol/control.py`:

```python
"""Control message types, validation, and JSON codec.

Pure: no sockets, no I/O. Validation happens on both encode and decode so
that a bug in the harness surfaces as a loud failure rather than as bytes
the other side has to guess about.
"""

import json

from .framing import ProtocolError

PROTOCOL_VERSION = 1

AUDIO_FORMAT = {"sampleRate": 48000, "channels": 1, "sampleFormat": "s16le"}

REQUIRED_FIELDS: dict[str, tuple[str, ...]] = {
    "GREETING": ("serverId", "nonce"),
    "HELLO": ("clientId", "mac"),
    "HELLO_ACK": ("serverId", "micPresent", "deviceLabel"),
    "START": ("requestId", "preferredFormat"),
    "START_ACK": ("requestId", "sessionId", "format"),
    "START_NACK": ("requestId", "reason"),
    "STOP": ("requestId", "sessionId"),
    "STOP_ACK": ("requestId", "sessionId"),
    "STATUS": ("micPresent", "active", "deviceLabel"),
    "PING": ("seq",),
    "PONG": ("seq",),
}


def _validate(msg: dict) -> dict:
    if not isinstance(msg, dict):
        raise ProtocolError("control message must be a JSON object")
    msg_type = msg.get("type")
    if msg_type not in REQUIRED_FIELDS:
        raise ProtocolError(f"unknown control type {msg_type!r}")
    if msg.get("v") != PROTOCOL_VERSION:
        raise ProtocolError(f"unsupported protocol version {msg.get('v')!r}")
    for field in REQUIRED_FIELDS[msg_type]:
        if field not in msg:
            raise ProtocolError(f"{msg_type} missing required field {field!r}")
    return msg


def encode_control(msg: dict) -> bytes:
    return json.dumps(_validate(msg), ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def decode_control(payload: bytes) -> dict:
    try:
        msg = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"malformed JSON control payload: {exc}") from exc
    return _validate(msg)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd harness && python -m pytest tests/test_control.py -v`
Expected: PASS — 9 passed

- [ ] **Step 5: Commit**

```bash
git add harness/
git commit -m "feat(protocol): add control message codec with per-type validation

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Authentication primitives

**Files:**
- Create: `harness/sharedmic_protocol/auth.py`
- Test: `harness/tests/test_auth.py`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `TOKEN_BYTES: int = 32`
  - `generate_token() -> bytes`
  - `encode_pairing_string(token: bytes) -> str` — unpadded base32, grouped for transcription
  - `decode_pairing_string(text: str) -> bytes` — tolerant of spaces, hyphens, and case
  - `generate_nonce() -> bytes`
  - `auth_proof(token: bytes, nonce: bytes) -> str` — lowercase hex HMAC-SHA256
  - `verify_proof(token: bytes, nonce: bytes, proof: str) -> bool` — constant-time

- [ ] **Step 1: Write the failing test**

Create `harness/tests/test_auth.py`:

```python
import pytest

from sharedmic_protocol.auth import (
    TOKEN_BYTES,
    auth_proof,
    decode_pairing_string,
    encode_pairing_string,
    generate_nonce,
    generate_token,
    verify_proof,
)


def test_token_is_256_bits():
    assert len(generate_token()) == TOKEN_BYTES == 32


def test_tokens_are_not_repeated():
    assert generate_token() != generate_token()


def test_pairing_string_round_trip():
    token = generate_token()
    assert decode_pairing_string(encode_pairing_string(token)) == token


def test_pairing_string_tolerates_human_transcription():
    token = generate_token()
    text = encode_pairing_string(token)
    assert decode_pairing_string(text.lower().replace("-", " ")) == token


def test_pairing_string_rejects_garbage():
    with pytest.raises(ValueError):
        decode_pairing_string("not-a-valid-token")


def test_proof_verifies_with_correct_token_and_nonce():
    token, nonce = generate_token(), generate_nonce()
    assert verify_proof(token, nonce, auth_proof(token, nonce))


def test_proof_fails_with_wrong_token():
    nonce = generate_nonce()
    assert not verify_proof(generate_token(), nonce, auth_proof(generate_token(), nonce))


def test_proof_fails_with_replayed_nonce():
    token = generate_token()
    proof_for_old_nonce = auth_proof(token, generate_nonce())
    assert not verify_proof(token, generate_nonce(), proof_for_old_nonce)


def test_proof_is_lowercase_hex_sha256():
    proof = auth_proof(generate_token(), generate_nonce())
    assert len(proof) == 64
    assert proof == proof.lower()
    int(proof, 16)


def test_verify_rejects_malformed_proof_without_raising():
    token, nonce = generate_token(), generate_nonce()
    assert not verify_proof(token, nonce, "short")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd harness && python -m pytest tests/test_auth.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'sharedmic_protocol.auth'`

- [ ] **Step 3: Write the implementation**

Create `harness/sharedmic_protocol/auth.py`:

```python
"""Pairing token and challenge-response authentication.

The token never crosses the wire. The server issues a fresh nonce per
connection and the client proves possession with HMAC-SHA256, which makes
a captured proof useless against the next connection.
"""

import base64
import hashlib
import hmac
import os
import re

TOKEN_BYTES = 32
NONCE_BYTES = 32

_GROUP_SIZE = 8
_NON_BASE32 = re.compile(r"[^A-Z2-7]")


def generate_token() -> bytes:
    return os.urandom(TOKEN_BYTES)


def generate_nonce() -> bytes:
    return os.urandom(NONCE_BYTES)


def encode_pairing_string(token: bytes) -> str:
    """Base32, uppercase, unpadded, hyphen-grouped so a human can retype it."""
    raw = base64.b32encode(token).decode("ascii").rstrip("=")
    return "-".join(raw[i : i + _GROUP_SIZE] for i in range(0, len(raw), _GROUP_SIZE))


def decode_pairing_string(text: str) -> bytes:
    cleaned = _NON_BASE32.sub("", text.upper())
    padding = "=" * (-len(cleaned) % 8)
    try:
        token = base64.b32decode(cleaned + padding)
    except Exception as exc:
        raise ValueError(f"invalid pairing string: {exc}") from exc
    if len(token) != TOKEN_BYTES:
        raise ValueError(f"pairing string decodes to {len(token)} bytes, expected {TOKEN_BYTES}")
    return token


def auth_proof(token: bytes, nonce: bytes) -> str:
    return hmac.new(token, nonce, hashlib.sha256).hexdigest()


def verify_proof(token: bytes, nonce: bytes, proof: str) -> bool:
    if not isinstance(proof, str):
        return False
    return hmac.compare_digest(auth_proof(token, nonce), proof)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd harness && python -m pytest tests/test_auth.py -v`
Expected: PASS — 10 passed

- [ ] **Step 5: Commit**

```bash
git add harness/
git commit -m "feat(protocol): add pairing token and HMAC challenge-response auth

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Synthetic audio generation

**Files:**
- Create: `harness/sharedmic_protocol/audio.py`
- Test: `harness/tests/test_audio.py`

**Interfaces:**
- Consumes: nothing
- Produces:
  - `SAMPLE_RATE: int = 48000`, `FRAME_SAMPLES: int = 960`, `FRAME_BYTES: int = 1920`, `FRAMES_PER_SECOND: int = 50`, `FRAME_DURATION_US: int = 20000`
  - `sine_frame(frame_index: int, freq_hz: float = 440.0, amplitude: float = 0.5) -> bytes` — 1920 bytes, phase-continuous across consecutive indices

- [ ] **Step 1: Write the failing test**

Create `harness/tests/test_audio.py`:

```python
import struct

from sharedmic_protocol.audio import (
    FRAME_BYTES,
    FRAME_DURATION_US,
    FRAME_SAMPLES,
    FRAMES_PER_SECOND,
    SAMPLE_RATE,
    sine_frame,
)


def test_constants_match_spec():
    assert (SAMPLE_RATE, FRAME_SAMPLES, FRAME_BYTES) == (48000, 960, 1920)
    assert FRAMES_PER_SECOND == 50
    assert FRAME_DURATION_US == 20000


def test_frame_is_exactly_one_frame_of_pcm():
    assert len(sine_frame(0)) == FRAME_BYTES


def test_frame_is_little_endian_signed_16_bit():
    samples = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0))
    assert len(samples) == FRAME_SAMPLES
    assert all(-32768 <= s <= 32767 for s in samples)


def test_sine_starts_at_zero_crossing():
    first = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0))[0]
    assert first == 0


def test_frames_are_phase_continuous():
    """Frame N+1 must continue the wave, not restart it.

    A restarted wave would produce a click every 20 ms and would mask real
    discontinuity bugs during listening tests.
    """
    tail = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0))[-1]
    head = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(1))[0]
    step = 2 * 32767 * 0.5 * 3.14159 * 440.0 / SAMPLE_RATE
    assert abs(head - tail) < step * 2


def test_amplitude_is_respected():
    quiet = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0, amplitude=0.1))
    loud = struct.unpack(f"<{FRAME_SAMPLES}h", sine_frame(0, amplitude=0.9))
    assert max(loud) > max(quiet) * 5
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd harness && python -m pytest tests/test_audio.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'sharedmic_protocol.audio'`

- [ ] **Step 3: Write the implementation**

Create `harness/sharedmic_protocol/audio.py`:

```python
"""Synthetic PCM for the harness.

A phase-continuous sine wave, so that a listening test hears a clean tone
and any discontinuity is a real bug rather than an artifact of the
generator.
"""

import math
import struct

SAMPLE_RATE = 48000
FRAME_SAMPLES = 960
FRAME_BYTES = FRAME_SAMPLES * 2
FRAMES_PER_SECOND = SAMPLE_RATE // FRAME_SAMPLES
FRAME_DURATION_US = 1_000_000 // FRAMES_PER_SECOND

_PACK = struct.Struct(f"<{FRAME_SAMPLES}h")


def sine_frame(frame_index: int, freq_hz: float = 440.0, amplitude: float = 0.5) -> bytes:
    start = frame_index * FRAME_SAMPLES
    peak = amplitude * 32767.0
    samples = [
        int(peak * math.sin(2.0 * math.pi * freq_hz * (start + n) / SAMPLE_RATE))
        for n in range(FRAME_SAMPLES)
    ]
    return _PACK.pack(*samples)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd harness && python -m pytest tests/test_audio.py -v`
Expected: PASS — 6 passed

- [ ] **Step 5: Commit**

```bash
git add harness/
git commit -m "feat(harness): add phase-continuous synthetic PCM generator

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Mock Windows server

**Files:**
- Create: `harness/sharedmic_protocol/server.py`
- Test: `harness/tests/test_server.py`

**Interfaces:**
- Consumes: `framing`, `control`, `auth`, `audio` from Tasks 1–4
- Produces:
  - `MockWindowsServer(token: bytes, *, host: str = "127.0.0.1", port: int = 0, mic_present: bool = True, device_label: str = "Mock USB Mic", server_id: str = "mock-win", ssl_context=None)`
  - `.start() -> None` — binds, begins accepting in a background thread
  - `.stop() -> None` — closes everything and joins threads
  - `.port -> int` — the bound port, valid after `start()`
  - `.audio_frames_sent -> int`, `.sessions_started -> int`, `.auth_failures -> int`
  - `.set_mic_present(present: bool) -> None`

- [ ] **Step 1: Write the failing test**

Create `harness/tests/test_server.py`:

```python
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd harness && python -m pytest tests/test_server.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'sharedmic_protocol.server'`

- [ ] **Step 3: Write the implementation**

Create `harness/sharedmic_protocol/server.py`:

```python
"""Mock Windows agent.

Speaks the full protocol so the macOS agent can be developed and tested
without a Windows machine present. Mirrors the session lifecycle from the
spec, including START/STOP idempotency and the control-before-audio send
priority.

Never logs audio payload — only counters.
"""

import queue
import secrets
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
    ):
        self._token = token
        self._host = host
        self._requested_port = port
        self._mic_present = mic_present
        self._device_label = device_label
        self._server_id = server_id
        self._ssl_context = ssl_context

        self._listener: socket.socket | None = None
        self._accept_thread: threading.Thread | None = None
        self._connection_threads: list[threading.Thread] = []
        self._running = threading.Event()
        self._lock = threading.Lock()

        self.port = 0
        self.audio_frames_sent = 0
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
        if self._accept_thread is not None:
            self._accept_thread.join(timeout=5)
        for thread in list(self._connection_threads):
            thread.join(timeout=5)

    def set_mic_present(self, present: bool) -> None:
        with self._lock:
            self._mic_present = present

    # -- accept -------------------------------------------------------

    def _accept_loop(self) -> None:
        while self._running.is_set():
            try:
                conn, _ = self._listener.accept()
            except OSError:
                return
            if self._ssl_context is not None:
                try:
                    conn = self._ssl_context.wrap_socket(conn, server_side=True)
                except OSError:
                    conn.close()
                    continue
            thread = threading.Thread(target=self._serve, args=(conn,), daemon=True)
            self._connection_threads.append(thread)
            thread.start()

    # -- per-connection -----------------------------------------------

    def _serve(self, conn: socket.socket) -> None:
        session = _ServerSession(self, conn)
        try:
            session.run()
        finally:
            session.close()


class _ServerSession:
    def __init__(self, server: MockWindowsServer, conn: socket.socket):
        self._server = server
        self._conn = conn
        self._control_q: queue.Queue = queue.Queue()
        self._audio_q: queue.Queue = queue.Queue(maxsize=AUDIO_QUEUE_FRAMES)
        self._closed = threading.Event()
        self._session_id: str | None = None
        self._audio_thread: threading.Thread | None = None
        self._writer_thread: threading.Thread | None = None

    # -- send priority ------------------------------------------------

    def _send_control(self, msg: dict) -> None:
        self._control_q.put(encode_frame(FRAME_TYPE_CONTROL, encode_control(msg)))

    def _offer_audio(self, frame: bytes) -> None:
        """Bounded, drop-oldest. Audio must never block the writer."""
        try:
            self._audio_q.put_nowait(frame)
        except queue.Full:
            try:
                self._audio_q.get_nowait()
            except queue.Empty:
                pass
            try:
                self._audio_q.put_nowait(frame)
            except queue.Full:
                pass

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
        authenticated = False
        deadline = time.monotonic() + HELLO_TIMEOUT_SECONDS

        while not self._closed.is_set():
            if not authenticated and time.monotonic() > deadline:
                return
            try:
                chunk = self._conn.recv(65536)
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

                if not authenticated:
                    if msg["type"] != "HELLO" or not verify_proof(self._server._token, nonce, msg["mac"]):
                        with self._server._lock:
                            self._server.auth_failures += 1
                        return
                    authenticated = True
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
            while True:
                try:
                    self._audio_q.get_nowait()
                except queue.Empty:
                    break
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd harness && python -m pytest tests/test_server.py -v`
Expected: PASS — 5 passed

- [ ] **Step 5: Commit**

```bash
git add harness/
git commit -m "feat(harness): add mock Windows server with priority send queue

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Mock Mac client

**Files:**
- Create: `harness/sharedmic_protocol/client.py`
- Test: `harness/tests/test_client.py`

**Interfaces:**
- Consumes: `framing`, `control`, `auth` from Tasks 1–3; `MockWindowsServer` from Task 5 (tests only)
- Produces:
  - `MockMacClient(token: bytes, host: str, port: int, *, client_id: str = "mock-mac", ssl_context=None, expected_fingerprint: str | None = None)`
  - `.connect(timeout: float = 5.0) -> dict` — completes GREETING/HELLO/HELLO_ACK, returns the `HELLO_ACK`
  - `.start_session(timeout: float = 2.0) -> dict` — sends `START`, returns `START_ACK` or raises `SessionRejected`
  - `.stop_session(timeout: float = 1.0) -> dict` — sends `STOP`, returns `STOP_ACK`
  - `.ping(timeout: float = 5.0) -> None`
  - `.wait_for_audio_frames(count: int, timeout: float = 5.0) -> list[tuple[int, int, bytes]]`
  - `.drain_audio() -> int` — discards any queued audio frames, returns how many
  - `.close() -> None`
  - `.audio_frames_received -> int`, `.sequence_gaps -> int`
  - `SessionRejected(Exception)` with `.reason: str`
  - `FingerprintMismatch(Exception)`

- [ ] **Step 1: Write the failing test**

Create `harness/tests/test_client.py`:

```python
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd harness && python -m pytest tests/test_client.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'sharedmic_protocol.client'`

- [ ] **Step 3: Write the implementation**

Create `harness/sharedmic_protocol/client.py`:

```python
"""Mock Mac agent.

Speaks the full protocol so the Windows agent can be developed and tested
without a Mac present. Tracks audio sequence continuity, which is the
cheapest way to catch framing bugs.

Never logs audio payload — only counters.
"""

import hashlib
import queue
import secrets
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
            try:
                msg = self._control_in.get(timeout=remaining)
            except queue.Empty:
                raise TimeoutError(f"timed out waiting for {msg_type}") from None
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
            try:
                self._sock.close()
            except OSError:
                pass
        if self._reader is not None:
            self._reader.join(timeout=2)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd harness && python -m pytest tests/test_client.py -v`
Expected: PASS — 6 passed

- [ ] **Step 5: Commit**

```bash
git add harness/
git commit -m "feat(harness): add mock Mac client with sequence-gap tracking

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Loopback lifecycle test

This task adds no production code. It proves the protocol is implementable and self-consistent, and it encodes the spec's central privacy invariant as an executable assertion.

**Files:**
- Test: `harness/tests/test_loopback.py`

**Interfaces:**
- Consumes: `MockWindowsServer` (Task 5), `MockMacClient` (Task 6)
- Produces: nothing consumed by later tasks

- [ ] **Step 1: Write the failing test**

Create `harness/tests/test_loopback.py`:

```python
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


def test_full_lifecycle_leaves_no_sequence_gaps(client):
    for _ in range(3):
        client.start_session()
        client.wait_for_audio_frames(5)
        client.stop_session()
        client.drain_audio()
    assert client.sequence_gaps == 0
```

- [ ] **Step 2: Run the tests**

Run: `cd harness && python -m pytest tests/test_loopback.py -v`
Expected: PASS — 10 passed.

If any fail, the defect is in Task 5 or Task 6, not in this test. Fix the implementation; do not weaken the assertions. `test_no_audio_before_start` and `test_audio_flows_only_between_start_and_stop` encode the project's central requirement — if either cannot be made to pass, stop and escalate rather than adjusting the test.

- [ ] **Step 3: Run the whole suite to confirm nothing regressed**

Run: `cd harness && python -m pytest -v`
Expected: PASS — 56 passed

- [ ] **Step 4: Commit**

```bash
git add harness/
git commit -m "test(harness): add loopback lifecycle tests asserting the idle-silence invariant

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: TLS transport and fingerprint pinning

**Files:**
- Create: `harness/sharedmic_protocol/tls.py`
- Test: `harness/tests/test_tls.py`

**Interfaces:**
- Consumes: `MockWindowsServer` and `MockMacClient` (their `ssl_context` and `expected_fingerprint` parameters already exist from Tasks 5–6)
- Produces:
  - `generate_self_signed_cert(common_name: str = "shared-mic") -> tuple[bytes, bytes]` — returns `(cert_pem, key_pem)`
  - `certificate_fingerprint(cert_pem: bytes) -> str` — lowercase hex SHA-256 of the DER
  - `server_context(cert_pem: bytes, key_pem: bytes) -> ssl.SSLContext`
  - `client_context() -> ssl.SSLContext` — verification disabled at the CA level because trust comes from the pinned fingerprint, not from a CA

- [ ] **Step 1: Write the failing test**

Create `harness/tests/test_tls.py`:

```python
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
        assert client.audio_frames_received == 0
    finally:
        client.close()
        server.stop()
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd harness && python -m pytest tests/test_tls.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'sharedmic_protocol.tls'`

- [ ] **Step 3: Install the dependency**

Run: `cd harness && python -m pip install 'cryptography>=42' pytest`
Expected: successful install.

- [ ] **Step 4: Write the implementation**

Create `harness/sharedmic_protocol/tls.py`:

```python
"""Self-signed device certificates and fingerprint pinning.

Trust comes from the fingerprint pinned during pairing, not from a
certificate authority. CA verification is therefore disabled on purpose;
the pin is the check, and it is enforced in MockMacClient after the
handshake completes.
"""

import datetime
import hashlib
import ssl
import tempfile
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

CERT_VALIDITY_DAYS = 3650


def generate_self_signed_cert(common_name: str = "shared-mic") -> tuple[bytes, bytes]:
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=CERT_VALIDITY_DAYS))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(common_name)]), critical=False)
        .sign(key, hashes.SHA256())
    )
    cert_pem = certificate.public_bytes(serialization.Encoding.PEM)
    key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return cert_pem, key_pem


def certificate_fingerprint(cert_pem: bytes) -> str:
    der = x509.load_pem_x509_certificate(cert_pem).public_bytes(serialization.Encoding.DER)
    return hashlib.sha256(der).hexdigest()


def server_context(cert_pem: bytes, key_pem: bytes) -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    directory = Path(tempfile.mkdtemp(prefix="sharedmic-tls-"))
    cert_path, key_path = directory / "cert.pem", directory / "key.pem"
    cert_path.write_bytes(cert_pem)
    key_path.write_bytes(key_pem)
    context.load_cert_chain(certfile=str(cert_path), keyfile=str(key_path))
    return context


def client_context() -> ssl.SSLContext:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd harness && python -m pytest tests/test_tls.py -v`
Expected: PASS — 6 passed

- [ ] **Step 6: Run the whole suite**

Run: `cd harness && python -m pytest -v`
Expected: PASS — 62 passed

- [ ] **Step 7: Commit**

```bash
git add harness/
git commit -m "feat(harness): add TLS transport with certificate fingerprint pinning

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Golden vectors and the protocol document

The document is written last, once the protocol has been proven by working code. Writing it first would have produced a description of something that does not exist.

**Files:**
- Create: `harness/tools/generate_vectors.py`
- Create: `protocol/vectors/control-messages.json`
- Create: `protocol/vectors/audio-frames.json`
- Create: `protocol/protocol-v1.md`
- Test: `harness/tests/test_vectors.py`

**Interfaces:**
- Consumes: `framing`, `control`, `audio` (Tasks 1, 2, 4)
- Produces: the vector files, which the Windows and macOS implementations must parse and produce byte-identically in Phases 1–2

- [ ] **Step 1: Write the failing test**

Create `harness/tests/test_vectors.py`:

```python
import json
from pathlib import Path

import pytest

from sharedmic_protocol.control import decode_control, encode_control
from sharedmic_protocol.framing import decode_frame, encode_audio_payload, encode_frame

VECTORS = Path(__file__).resolve().parents[2] / "protocol" / "vectors"


def _load(name):
    return json.loads((VECTORS / name).read_text())


def test_vector_files_exist():
    assert (VECTORS / "control-messages.json").is_file()
    assert (VECTORS / "audio-frames.json").is_file()


@pytest.mark.parametrize("case", _load("control-messages.json") if VECTORS.is_dir() else [])
def test_control_vectors_encode_to_expected_bytes(case):
    expected = bytes.fromhex(case["hex"])
    assert encode_frame(1, encode_control(case["message"])) == expected


@pytest.mark.parametrize("case", _load("control-messages.json") if VECTORS.is_dir() else [])
def test_control_vectors_decode_to_expected_message(case):
    _, payload, _ = decode_frame(bytes.fromhex(case["hex"]))
    assert decode_control(payload) == case["message"]


@pytest.mark.parametrize("case", _load("audio-frames.json") if VECTORS.is_dir() else [])
def test_audio_vectors_encode_to_expected_bytes(case):
    payload = encode_audio_payload(
        case["sequence"], case["timestampUs"], bytes.fromhex(case["pcmHex"])
    )
    assert encode_frame(2, payload) == bytes.fromhex(case["hex"])
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd harness && python -m pytest tests/test_vectors.py -v`
Expected: FAIL — `test_vector_files_exist` fails because `protocol/vectors/` does not exist yet.

- [ ] **Step 3: Write the vector generator**

Create `harness/tools/generate_vectors.py`:

```python
"""Generate golden wire vectors from the reference implementation.

Run from the harness directory:  python tools/generate_vectors.py

These files are the contract. A Windows or macOS implementation that
produces different bytes for the same message is wrong, and this is how
that gets caught without needing both machines in the room.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from sharedmic_protocol.audio import sine_frame  # noqa: E402
from sharedmic_protocol.control import AUDIO_FORMAT, PROTOCOL_VERSION  # noqa: E402
from sharedmic_protocol.control import encode_control  # noqa: E402
from sharedmic_protocol.framing import (  # noqa: E402
    FRAME_TYPE_AUDIO,
    FRAME_TYPE_CONTROL,
    encode_audio_payload,
    encode_frame,
)

OUT = Path(__file__).resolve().parents[2] / "protocol" / "vectors"

CONTROL_MESSAGES = [
    {"v": PROTOCOL_VERSION, "type": "GREETING", "serverId": "win-desktop", "nonce": "00" * 32},
    {"v": PROTOCOL_VERSION, "type": "HELLO", "clientId": "mac-studio", "mac": "ab" * 32},
    {
        "v": PROTOCOL_VERSION,
        "type": "HELLO_ACK",
        "serverId": "win-desktop",
        "micPresent": True,
        "deviceLabel": "USB Microphone",
    },
    {
        "v": PROTOCOL_VERSION,
        "type": "START",
        "requestId": "req-0001",
        "preferredFormat": AUDIO_FORMAT,
    },
    {
        "v": PROTOCOL_VERSION,
        "type": "START_ACK",
        "requestId": "req-0001",
        "sessionId": "sess-0001",
        "format": AUDIO_FORMAT,
    },
    {
        "v": PROTOCOL_VERSION,
        "type": "START_NACK",
        "requestId": "req-0002",
        "reason": "MIC_UNAVAILABLE",
    },
    {"v": PROTOCOL_VERSION, "type": "STOP", "requestId": "req-0003", "sessionId": "sess-0001"},
    {"v": PROTOCOL_VERSION, "type": "STOP_ACK", "requestId": "req-0003", "sessionId": "sess-0001"},
    {
        "v": PROTOCOL_VERSION,
        "type": "STATUS",
        "micPresent": False,
        "active": False,
        "deviceLabel": "USB Microphone",
    },
    {"v": PROTOCOL_VERSION, "type": "PING", "seq": 1},
    {"v": PROTOCOL_VERSION, "type": "PONG", "seq": 1},
]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    control = [
        {
            "name": msg["type"],
            "message": msg,
            "hex": encode_frame(FRAME_TYPE_CONTROL, encode_control(msg)).hex(),
        }
        for msg in CONTROL_MESSAGES
    ]
    (OUT / "control-messages.json").write_text(json.dumps(control, indent=2) + "\n")

    audio = []
    for index in (0, 1, 49):
        pcm = sine_frame(index)
        audio.append(
            {
                "name": f"frame-{index}",
                "sequence": index,
                "timestampUs": index * 20000,
                "pcmHex": pcm.hex(),
                "hex": encode_frame(
                    FRAME_TYPE_AUDIO, encode_audio_payload(index, index * 20000, pcm)
                ).hex(),
            }
        )
    (OUT / "audio-frames.json").write_text(json.dumps(audio, indent=2) + "\n")

    print(f"wrote {len(control)} control vectors and {len(audio)} audio vectors to {OUT}")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Generate the vectors**

Run: `cd harness && python tools/generate_vectors.py`
Expected: `wrote 11 control vectors and 3 audio vectors to .../protocol/vectors`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd harness && python -m pytest tests/test_vectors.py -v`
Expected: PASS — 26 passed (1 existence check, 11 control encode, 11 control decode, 3 audio encode)

- [ ] **Step 6: Write the protocol document**

Create `protocol/protocol-v1.md` documenting exactly what the code does. It must contain, in this order:

1. **Scope and versioning** — protocol version 1; a peer receiving `v` other than 1 closes the connection.
2. **Transport** — one TCP connection, default port 47800, TLS 1.3, server certificate pinned by SHA-256 fingerprint at pairing. Fingerprint mismatch closes the connection and must not auto-retry.
3. **Envelope** — the byte layout from `framing.py`, with the worked example `01 00 00 00 0f` + payload, and the 1 MiB payload ceiling.
4. **Audio frames** — the 12-byte header, 1,920-byte PCM payload, 48 kHz mono s16le **little-endian PCM inside a big-endian header** (call this out explicitly; it is the single most likely implementation mistake).
5. **Control messages** — one subsection per type, listing required fields, direction, and a JSON example copied from the vectors.
6. **Handshake** — the `GREETING` → `HELLO` → `HELLO_ACK` exchange, the HMAC-SHA256 construction, and the 5-second HELLO deadline.
7. **Session lifecycle** — `START`/`START_ACK`/`START_NACK`/`STOP`/`STOP_ACK`, and the idempotency rules verbatim from the Global Constraints.
8. **Timers** — `START` 2 s, `STOP` 1 s, `PING` 15 s, peer dead at 45 s.
9. **Send priority** — control drains before audio; the audio queue is bounded at 25 frames and drops oldest.
10. **Conformance** — how to run the vectors, and the rule that any implementation must byte-match `protocol/vectors/*.json`.

Cross-reference the spec at `docs/superpowers/specs/2026-08-08-shared-mic-design.md` for rationale; this document states the contract only.

- [ ] **Step 7: Run the whole suite**

Run: `cd harness && python -m pytest -v`
Expected: PASS — 88 passed (62 from Tasks 1–8, plus 26 vector cases)

- [ ] **Step 8: Commit**

```bash
git add harness/ protocol/
git commit -m "feat(protocol): add golden wire vectors and protocol-v1 contract document

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: macOS demand-detection probe

**Throwaway code, durable findings.** This probe answers spec open question 1. It is deleted after Phase 0; `docs/superpowers/probes/2026-08-08-macos-demand-findings.md` is what survives.

**Files:**
- Create: `probes/macos-demand/DemandProbe.swift`
- Create: `probes/macos-demand/README.md`
- Create: `docs/superpowers/probes/2026-08-08-macos-demand-findings.md`

**Interfaces:**
- Consumes: nothing
- Produces: findings that determine whether Phase 3 can rely on device-scoped detection, or whether the force-on hold must cover named applications

- [ ] **Step 1: Write the probe**

Create `probes/macos-demand/DemandProbe.swift`:

```swift
// Throwaway probe for spec open question 1: does macOS report per-process
// input device usage well enough to scope demand detection to one device?
//
// Build: swiftc -O -o demand-probe DemandProbe.swift
// Run:   ./demand-probe            one snapshot
//        ./demand-probe --watch    poll twice a second until Ctrl-C

import CoreAudio
import Foundation

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

func objectIDs(_ objectID: AudioObjectID,
               _ selector: AudioObjectPropertySelector,
               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> [AudioObjectID] {
    var addr = address(selector, scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
}

func uint32Value(_ objectID: AudioObjectID,
                 _ selector: AudioObjectPropertySelector,
                 _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
    var addr = address(selector, scope)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
}

func int32Value(_ objectID: AudioObjectID,
                _ selector: AudioObjectPropertySelector) -> Int32? {
    var addr = address(selector)
    var value: Int32 = 0
    var size = UInt32(MemoryLayout<Int32>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
}

func stringValue(_ objectID: AudioObjectID,
                 _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var value: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, pointer)
    }
    guard status == noErr else { return nil }
    return value as String?
}

struct Device {
    let id: AudioObjectID
    let uid: String
    let name: String
}

func allDevices() -> [Device] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).map {
        Device(id: $0,
               uid: stringValue($0, kAudioDevicePropertyDeviceUID) ?? "<no uid>",
               name: stringValue($0, kAudioObjectPropertyName) ?? "<no name>")
    }
}

struct ProcessInfoRow {
    let pid: Int32
    let bundleID: String
    let runningInput: Bool
    let inputDeviceIDs: [AudioObjectID]
}

func processRows() -> [ProcessInfoRow] {
    objectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
        .map { processObject in
            ProcessInfoRow(
                pid: int32Value(processObject, kAudioProcessPropertyPID) ?? -1,
                bundleID: stringValue(processObject, kAudioProcessPropertyBundleID) ?? "<none>",
                runningInput: (uint32Value(processObject, kAudioProcessPropertyIsRunningInput) ?? 0) != 0,
                inputDeviceIDs: objectIDs(processObject,
                                          kAudioProcessPropertyDevices,
                                          kAudioObjectPropertyScopeInput)
            )
        }
}

func report(target: Device, devicesByID: [AudioObjectID: Device]) {
    let rows = processRows()
    let ourPID = ProcessInfo.processInfo.processIdentifier

    print("target device: \(target.name)  uid=\(target.uid)  id=\(target.id)")
    print("process objects reported: \(rows.count)")
    print(String(repeating: "-", count: 78))
    print("  PID  runningInput  onTarget  bundle / input devices")

    var demandCount = 0
    for row in rows where row.runningInput || !row.inputDeviceIDs.isEmpty {
        let onTarget = row.inputDeviceIDs.contains(target.id)
        // ⚠️ SUPERSEDED — DO NOT COPY THIS LINE. Executing this plan disproved the
        // `row.runningInput` conjunct: it reads false on a process's second and later
        // input activation, at the instant `onTarget` is confirmed true, so this gate
        // detects an app's first use of the mic and silently misses every later one.
        // The shipped probe gates on `onTarget && row.pid != ourPID` alone. See design
        // spec §5.1 and docs/superpowers/probes/2026-08-08-macos-demand-findings.md.
        let counts = row.runningInput && onTarget && row.pid != ourPID
        if counts { demandCount += 1 }
        let deviceNames = row.inputDeviceIDs
            .map { devicesByID[$0]?.name ?? "id=\($0)" }
            .joined(separator: ", ")
        print(String(format: "%5d  %-12@  %-8@  %@",
                     row.pid,
                     row.runningInput ? "yes" : "no" as NSString,
                     onTarget ? "YES" : "-" as NSString,
                     "\(row.bundleID)  [\(deviceNames)]" as NSString))
    }
    print(String(repeating: "-", count: 78))
    print("device-scoped demandCount = \(demandCount)")
    print("")
}

// -- main ---------------------------------------------------------------

let devices = allDevices()
let devicesByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })

guard let target = devices.first(where: { $0.uid.contains("BlackHole") || $0.name.contains("BlackHole") })
else {
    print("BlackHole not found. Devices present:")
    devices.forEach { print("  \($0.name)  uid=\($0.uid)") }
    exit(1)
}

if CommandLine.arguments.contains("--watch") {
    print("watching every 500 ms; Ctrl-C to stop\n")
    while true {
        report(target: target, devicesByID: devicesByID)
        Thread.sleep(forTimeInterval: 0.5)
    }
} else {
    report(target: target, devicesByID: devicesByID)
}
```

- [ ] **Step 2: Build the probe**

Run: `cd probes/macos-demand && swiftc -O -o demand-probe DemandProbe.swift`
Expected: compiles with no errors.

If `kAudioProcessPropertyDevices` or `kAudioHardwarePropertyProcessObjectList` fail to resolve, the SDK is older than macOS 14.4 — check `xcrun --show-sdk-version` before assuming the API is missing.

- [ ] **Step 3: Take a baseline snapshot with nothing recording**

Run: `cd probes/macos-demand && ./demand-probe`
Expected: BlackHole is found, and `device-scoped demandCount = 0`.

If `process objects reported: 0`, stop and investigate before continuing — an empty process list means the API is not returning data to an unsigned binary, and that finding changes Phase 3's design. Record it either way.

- [ ] **Step 4: Test each target application**

For each of macOS Dictation, Chrome (any site requesting the mic), ChatGPT voice, and Zoom or Teams:

1. Run `./demand-probe --watch` in one terminal.
2. Select **BlackHole 2ch** as the Mac's input device in System Settings → Sound.
3. Start audio input in the application.
4. Record whether the app appears with `runningInput=yes`, whether `onTarget=YES`, and how long after starting input it appeared.
5. Stop input and record how quickly the row clears.

> **⚠️ SUPERSEDED — this instruction encodes the same defective gate as the code above.** Step 4
> reads as though `runningInput=yes` is part of what makes an app count as demand. It is not, and
> requiring it is what this probe disproved. When running the manual pass, record `runningInput`
> only as a **diagnostic** column alongside `onTarget`, and treat `onTarget=YES` alone as demand.
> Also test **repeat** activations of each app, not just the first — the first activation is
> precisely the case in which the two properties agree and the defect is invisible. See design spec
> §5.1 and `docs/superpowers/probes/2026-08-08-macos-demand-findings.md`.

Then repeat with the Mac's input set to the **built-in microphone** instead, and confirm `onTarget` is `-` and `demandCount` stays `0`. This is the false-positive test, and it is the single most important measurement in Phase 0.

- [ ] **Step 5: Record the findings**

Create `docs/superpowers/probes/2026-08-08-macos-demand-findings.md` with: macOS version, the exact BlackHole UID, a table of application × (`runningInput`, `onTarget`, appear latency, clear latency), the built-in-mic false-positive result, and a verdict — either "device-scoped detection is sound, proceed with Phase 3 as specified" or a specific list of applications needing the force-on hold as a fallback.

Record what was actually observed, including anything that did not work. A probe that reports only good news has not been run properly.

- [ ] **Step 6: Commit**

```bash
git add probes/macos-demand/ docs/superpowers/probes/
git commit -m "feat(probe): add macOS device-scoped demand detection probe and findings

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: Windows WASAPI open-latency probe

**This task must be run on the Windows host.** It cannot be executed or verified from the Mac. The agent writes the code; the owner runs it and reports the numbers, which then get recorded.

**Files:**
- Create: `probes/windows-wasapi-latency/WasapiLatencyProbe/Program.cs`
- Create: `probes/windows-wasapi-latency/WasapiLatencyProbe/WasapiLatencyProbe.csproj`
- Create: `probes/windows-wasapi-latency/README.md`
- Create: `docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`

**Interfaces:**
- Consumes: nothing
- Produces: the measured WASAPI open latency that validates or invalidates the 20–80 ms line in the spec's activation budget

- [ ] **Step 1: Write the project file**

Create `probes/windows-wasapi-latency/WasapiLatencyProbe/WasapiLatencyProbe.csproj`:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="NAudio" Version="2.2.1" />
  </ItemGroup>
</Project>
```

- [ ] **Step 2: Write the probe**

Create `probes/windows-wasapi-latency/WasapiLatencyProbe/Program.cs`:

```csharp
// Throwaway probe for spec open question 2: how long does WASAPI
// shared-mode capture actually take to open on this hardware?
//
// The spec's activation budget assumes 20-80 ms. If the real number is
// far higher, first-word clipping is a bigger problem than the design
// accounts for, and Phase 2 needs a different mitigation.
//
// Run: dotnet run --project WasapiLatencyProbe -- [iterations]

using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;

int iterations = args.Length > 0 && int.TryParse(args[0], out var parsed) ? parsed : 20;

var enumerator = new MMDeviceEnumerator();
var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).ToList();

if (devices.Count == 0)
{
    Console.Error.WriteLine("No active capture devices found.");
    return 1;
}

Console.WriteLine("Capture devices:");
for (var i = 0; i < devices.Count; i++)
{
    Console.WriteLine($"  [{i}] {devices[i].FriendlyName}");
    Console.WriteLine($"      endpoint id: {devices[i].ID}");
}

Console.Write($"\nSelect device [0-{devices.Count - 1}]: ");
var selection = int.TryParse(Console.ReadLine(), out var index) ? index : 0;
var device = devices[Math.Clamp(selection, 0, devices.Count - 1)];

Console.WriteLine($"\nMeasuring {iterations} open cycles on: {device.FriendlyName}");
Console.WriteLine("Latency is measured from constructing the capture object to the first");
Console.WriteLine("DataAvailable callback carrying non-zero bytes.\n");

var results = new List<double>();

for (var run = 0; run < iterations; run++)
{
    var firstData = new TaskCompletionSource<double>(TaskCreationOptions.RunContinuationsAsynchronously);
    var stopwatch = Stopwatch.StartNew();

    using var capture = new WasapiCapture(device);
    capture.DataAvailable += (_, e) =>
    {
        if (e.BytesRecorded > 0)
        {
            firstData.TrySetResult(stopwatch.Elapsed.TotalMilliseconds);
        }
    };

    capture.StartRecording();

    if (await Task.WhenAny(firstData.Task, Task.Delay(5000)) != firstData.Task)
    {
        Console.WriteLine($"  run {run + 1,2}: TIMED OUT after 5000 ms");
        capture.StopRecording();
        continue;
    }

    var elapsed = await firstData.Task;
    results.Add(elapsed);
    Console.WriteLine($"  run {run + 1,2}: {elapsed,7:F1} ms{(run == 0 ? "   <- cold" : "")}");

    capture.StopRecording();
    await Task.Delay(500);
}

if (results.Count == 0)
{
    Console.Error.WriteLine("\nNo successful measurements.");
    return 1;
}

var sorted = results.OrderBy(x => x).ToList();
double Percentile(double p) => sorted[Math.Min(sorted.Count - 1, (int)Math.Ceiling(p / 100.0 * sorted.Count) - 1)];

Console.WriteLine($"\n  samples : {sorted.Count}");
Console.WriteLine($"  cold    : {results[0],7:F1} ms");
Console.WriteLine($"  min     : {sorted.First(),7:F1} ms");
Console.WriteLine($"  p50     : {Percentile(50),7:F1} ms");
Console.WriteLine($"  p95     : {Percentile(95),7:F1} ms");
Console.WriteLine($"  max     : {sorted.Last(),7:F1} ms");
Console.WriteLine($"\n  spec assumes 20-80 ms. Budget headroom to the 300 ms p95 target:");
Console.WriteLine($"  {300 - Percentile(95) - 100:F0} ms remaining after ~100 ms of transit, capture, and prefill.");

return 0;
```

- [ ] **Step 3: Build the probe on the Windows host**

Run on Windows: `cd probes\windows-wasapi-latency && dotnet build`
Expected: build succeeds.

If `WasapiCapture` does not resolve, check the installed NAudio version — in NAudio 2.x the type is `NAudio.Wave.WasapiCapture`, and a newer major version may expose it as `WasapiRecorder` in the same namespace. Pin whichever the installed package provides and note the actual name in the findings; Phase 1 needs it.

- [ ] **Step 4: Run the probe with the USB microphone selected**

Run on Windows: `dotnet run --project WasapiLatencyProbe -- 20`
Expected: 20 measurements plus a summary. Record the printed endpoint ID of the USB microphone — Phase 1 persists exactly that string.

- [ ] **Step 5: Run the concurrency check**

Start Windows Voice Typing (Win+H) or any application using the same microphone, then run the probe again while that application holds the device.

Expected: the probe still opens successfully, confirming shared mode allows simultaneous access. If it fails, that invalidates a functional goal in the spec and must be escalated immediately rather than worked around.

- [ ] **Step 6: Record the findings**

Create `docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md` with: Windows version, microphone model, the exact MMDevice endpoint ID, the device's shared mix format, the cold/p50/p95/max latency table, the concurrent-access result, the NAudio version and actual capture type name, and a verdict on whether the spec's 20–80 ms assumption holds.

If p95 substantially exceeds 80 ms, say so plainly and flag that the activation budget in the spec needs revising before Phase 2 — that is a useful probe result, not a failure.

- [ ] **Step 7: Commit**

```bash
git add probes/windows-wasapi-latency/ docs/superpowers/probes/
git commit -m "feat(probe): add Windows WASAPI shared-mode open latency probe and findings

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: Phase 0 closeout

**Files:**
- Modify: `docs/superpowers/specs/2026-08-08-shared-mic-design.md` (§13 Open questions)
- Modify: `CLAUDE.md` (Commands section)
- Create: `harness/README.md`

**Interfaces:**
- Consumes: findings from Tasks 10 and 11
- Produces: a spec whose open questions are answered, so Phase 1 planning starts from measured fact

- [ ] **Step 1: Write the harness README**

Create `harness/README.md` covering: what the harness is (reference implementation and test double), how to install (`python -m pip install -e '.[dev]'`), how to run tests (`python -m pytest`), how to regenerate vectors, and how Phase 1 and Phase 2 will use `MockWindowsServer` and `MockMacClient` to develop each platform without the other present.

- [ ] **Step 2: Update the spec's open questions**

Replace §13 questions 1 and 2 with the measured answers from the probe findings, linking to both findings documents. Leave questions 3 and 4 open — they are answered by Phase 2 measurement, not by Phase 0.

If a probe contradicted a spec assumption, change the affected spec section too and say so explicitly in the commit message. The spec is the source of truth and must not be left stating something the probes disproved.

- [ ] **Step 3: Fill in the CLAUDE.md commands section**

Replace the placeholder paragraph in `CLAUDE.md` under "Commands" with the real, verified commands: harness install, harness test, vector regeneration, and both probe build/run lines.

- [ ] **Step 4: Run the full suite one final time**

Run: `cd harness && python -m pytest -v`
Expected: PASS — 88 passed (62 from Tasks 1–8, plus 26 vector cases)

- [ ] **Step 5: Commit**

```bash
git add harness/README.md CLAUDE.md docs/superpowers/specs/
git commit -m "docs: close out Phase 0 with probe findings and verified commands

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Phase 0 Definition of Done

- [ ] `cd harness && python -m pytest` passes with 88 tests
- [ ] `protocol/protocol-v1.md` documents every message, timer, and byte layout the harness implements
- [ ] `protocol/vectors/*.json` exist and the harness byte-matches them
- [ ] The loopback suite proves no audio crosses the wire outside a started session
- [ ] Both probe findings documents exist and contain real measured numbers, not estimates
- [ ] Spec §13 questions 1 and 2 are answered; questions 3 and 4 remain open for Phase 2
- [ ] `CLAUDE.md` lists commands that have actually been run

**Explicitly not in Phase 0:** no Windows agent, no macOS agent, no BlackHole rendering, no real microphone capture, no menu bar or tray UI. Phase 0 produces a proven contract and two answers. Nothing it builds ships.
