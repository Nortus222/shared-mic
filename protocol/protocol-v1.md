# shared-mic wire protocol — version 1

This document is the contract between the Windows (C#) agent and the macOS (Swift) agent. It
states the wire format, the field-level rules, and the golden vectors an implementation must
match. It does not explain *why* the protocol looks this way — for rationale, see
`docs/superpowers/specs/2026-08-08-shared-mic-design.md`, particularly §4 (Transport), §7
(Security), and §8 (Failure handling). This document states the contract only.

The reference implementation is the Python conformance harness at `harness/sharedmic_protocol/`.
It exists to make this document trustworthy, not to replace it — implement against this document,
and use the harness and the vectors in `protocol/vectors/` to check your work.

---

## 1. Scope and versioning

This document defines **protocol version 1** (`PROTOCOL_VERSION = 1`). Every control message
carries a `"v"` field. A peer that receives a control message with `"v"` other than `1` MUST close
the connection. There is no negotiation: version 1 is the only version either agent needs to speak,
and a version mismatch is treated as a hard protocol violation, not something to downgrade or
retry.

Changing anything in this document — a field name, a byte layout, a timer value — is a protocol
version change. It requires updating this document, both platform implementations, and the golden
vectors together. Do not treat this document as an implementation detail of either agent; it is
versioned independently of both.

---

## 2. Transport

- **One TCP connection** carries both control messages and audio, multiplexed (see §9). There is
  no separate audio socket.
- **Default port 47800.** Configurable on the Windows side; the listener binds to private
  interfaces only and is never exposed to the public Internet.
- **TLS 1.3** wraps the connection immediately after the TCP handshake. Windows is the TLS server
  (it holds the certificate and private key generated at first run); macOS is the TLS client.
- **Trust is a pinned certificate fingerprint, not a certificate authority.** There is no CA
  anywhere in this design. During pairing, the Mac records the SHA-256 fingerprint of the server
  certificate's DER encoding, as a lowercase hex string. On every subsequent connection, after the
  TLS handshake completes, the Mac computes SHA-256 over the DER encoding of the certificate the
  server presented and compares it byte-for-byte (as lowercase hex) against the pinned value.
- **A fingerprint mismatch is a hard stop.** The Mac closes the connection immediately. There is no
  automatic retry and no silent re-pairing — re-establishing trust requires an explicit user
  pairing action. This is deliberate: a fingerprint mismatch is the one failure mode that can mean
  an active attacker, and any form of automatic recovery here would defeat the reason pinning
  exists.
- Everything after the TLS handshake — every byte described in §3 onward — flows inside the
  encrypted TLS stream. Nothing in this protocol is ever sent in the clear.

---

## 3. Envelope

Every message on the wire, after the TLS handshake, is one envelope:

```
uint8   type     // 1 = CONTROL, 2 = AUDIO
uint32  length   // payload byte count, BIG-ENDIAN
bytes   payload  // exactly `length` bytes
```

The envelope header is **5 bytes**: 1 byte for `type`, 4 bytes for `length`. `length` is
**big-endian** (network byte order) and counts only the payload that follows — it does not include
itself or the type byte.

`type` MUST be `1` (`CONTROL`) or `2` (`AUDIO`). Any other value is a protocol violation; the
receiver MUST close the connection rather than attempt to resynchronize.

**Payload ceiling: `length` MUST NOT exceed 1,048,576 bytes (1 MiB).** A `length` above this is a
protocol violation and the receiver MUST close the connection. This bounds a single malformed or
malicious `length` field's ability to make a receiver allocate or wait for an unbounded amount of
data; no legitimate message (the largest is one audio frame at 1,932 bytes, §4) comes remotely
close to it.

There is no inner length field anywhere in this protocol. Earlier drafts included one on the audio
payload; it was removed because two length fields that can disagree is a defect waiting to be
written. The envelope's `length` is authoritative for both message types.

Multiple envelopes are simply concatenated on the wire — there is no delimiter between them beyond
the next envelope's own 5-byte header. A receiver reads bytes into a buffer and repeatedly attempts
to decode one envelope from the front of it; if fewer than 5 bytes are buffered, or fewer than
`5 + length` bytes are buffered, it waits for more data before decoding.

### Worked example

A `CONTROL` frame (`type = 1`) whose JSON payload is the 15-byte UTF-8 string `{"type":"PING"}`:

```
01 00 00 00 0f 7b 22 74 79 70 65 22 3a 22 50 49 4e 47 22 7d
└┬┘ └────┬────┘ └────────────────────┬────────────────────┘
type=1  length=15 (0x0f)          payload: {"type":"PING"}
```

Byte by byte: `01` is the type (`CONTROL`). `00 00 00 0f` is the big-endian `uint32` length, 15.
The remaining 15 bytes are the ASCII/UTF-8 payload `{"type":"PING"}` — `7b`=`{`, `22`=`"`,
`74 79 70 65`=`type`, `22`=`"`, `3a`=`:`, `22`=`"`, `50 49 4e 47`=`PING`, `22`=`"`, `7d`=`}`.

---

## 4. Audio frames

An `AUDIO` frame's envelope `payload` (i.e. everything after the 5-byte envelope header, when
`type = 2`) is:

```
uint32  sequence             // frame counter, BIG-ENDIAN, starts at 0 per session, increments by 1
uint64  captureTimestampUs   // microseconds since session START, BIG-ENDIAN
bytes   pcm                  // 1,920 bytes of s16le PCM — see byte order note below
```

The audio payload header is **12 bytes** (4-byte `sequence` + 8-byte `captureTimestampUs`), both
**big-endian**, immediately followed by exactly **1,920 bytes** of PCM. There is no length field
inside the audio payload — the envelope's `length` (§3) already tells the receiver exactly how many
bytes belong to this frame (`12 + 1920 = 1932` for a full frame), and the header fields have fixed
width, so nothing else is needed.

Audio format, fixed for protocol version 1 — no negotiation of any of these values is possible; a
peer that cannot honor them must reject the session (`START_NACK`, §7) rather than send nonconforming
audio:

| Property | Value |
|---|---|
| Sample rate | 48,000 Hz |
| Channels | 1 (mono) |
| Sample format | 16-bit signed PCM |
| Frame duration | 20 ms |
| Samples per frame | 960 |
| PCM bytes per frame | 1,920 |
| Frames per second | 50 |
| Total envelope size per audio frame | 5 (envelope) + 12 (audio header) + 1,920 (PCM) = 1,937 bytes |

### The single most likely implementation mistake

**The PCM samples themselves are little-endian, even though they sit inside a big-endian
envelope and a big-endian audio header.** `sequence` and `captureTimestampUs` are big-endian
(network byte order, consistent with the envelope). The 960 16-bit PCM samples that follow are
each **little-endian** (`s16le` — the `le` in the format name is not decorative). Do not apply the
same byte-order logic to the header and the PCM: encoding or decoding the PCM as big-endian will
compile, will not raise an error, and will produce audibly wrong (and, at the vector level,
byte-for-byte wrong) output. Verify this against `protocol/vectors/audio-frames.json` before
trusting a capture or render path — a reversed-endianness bug in PCM sounds like heavy static, not
like a crash.

`captureTimestampUs` is relative to session start (the first frame of a session is timestamp `0`,
and each subsequent frame's timestamp increases by `20000`, i.e. 20 ms in microseconds, matching
the 20 ms frame duration) — it is not wall-clock time and not relative to any epoch. `sequence`
resets to `0` at the start of each session (each `START_ACK`, §7) and increments by exactly 1 per
frame; a receiver uses it to detect dropped or reordered frames within a session, not across
sessions.

---

## 5. Control messages

A `CONTROL` frame's envelope `payload` (`type = 1`) is a single UTF-8-encoded JSON object, with no
line breaks or padding — exactly the bytes `json.dumps(msg, sort_keys=True,
separators=(",", ":"))` would produce (§10 explains why key order matters and how it is fixed).

Every control message has two fields present on all types:

- `"v"` (integer) — protocol version, always `1` for this document. See §1.
- `"type"` (string) — the message type, one of the eleven listed below.

Beyond `"v"` and `"type"`, each type has its own required fields, listed below. A control message
missing a required field for its type is a protocol violation. All JSON examples below are copied
verbatim from `protocol/vectors/control-messages.json` (with the `"message"` object shown; the
`"hex"` field there is the exact matching wire encoding).

### GREETING

Direction: Windows → Mac. Sent immediately after the TLS handshake completes, before
authentication. Carries the server's identity and a fresh random nonce for the HMAC challenge
(§6).

Required fields: `serverId` (string), `nonce` (string, lowercase hex, 32 bytes / 64 hex chars).

```json
{"v":1,"type":"GREETING","serverId":"win-desktop","nonce":"0000000000000000000000000000000000000000000000000000000000000000"}
```

### HELLO

Direction: Mac → Windows. The Mac's reply to `GREETING`, carrying its authentication proof. See §6
for how `mac` is computed.

Required fields: `clientId` (string), `mac` (string, lowercase hex HMAC-SHA256, 32 bytes / 64 hex
chars).

```json
{"v":1,"type":"HELLO","clientId":"mac-studio","mac":"abababababababababababababababababababababababababababababababab"}
```

### HELLO_ACK

Direction: Windows → Mac. Sent once `HELLO`'s proof verifies. Authentication is complete once this
arrives; the connection may now exchange `START`/`STOP`/`PING`/`STATUS`.

Required fields: `serverId` (string), `micPresent` (boolean), `deviceLabel` (string).

```json
{"v":1,"type":"HELLO_ACK","serverId":"win-desktop","micPresent":true,"deviceLabel":"USB Microphone"}
```

### START

Direction: Mac → Windows. Requests an active audio session.

Required fields: `requestId` (string, caller-chosen, echoed back in the matching `START_ACK` or
`START_NACK`), `preferredFormat` (object — for protocol version 1 this is always exactly
`{"sampleRate":48000,"channels":1,"sampleFormat":"s16le"}`, since no other format is negotiable;
see §4).

```json
{"v":1,"type":"START","requestId":"req-0001","preferredFormat":{"sampleRate":48000,"channels":1,"sampleFormat":"s16le"}}
```

### START_ACK

Direction: Windows → Mac. Confirms a session is active, assigning a session identifier that scopes
the audio `sequence` counter (§4).

Required fields: `requestId` (string, matches the triggering `START`), `sessionId` (string),
`format` (object, same shape as `preferredFormat`, the format actually in use).

```json
{"v":1,"type":"START_ACK","requestId":"req-0001","sessionId":"sess-0001","format":{"sampleRate":48000,"channels":1,"sampleFormat":"s16le"}}
```

### START_NACK

Direction: Windows → Mac. Rejects a session request.

Required fields: `requestId` (string, matches the triggering `START`), `reason` (string, e.g.
`MIC_UNAVAILABLE`).

```json
{"v":1,"type":"START_NACK","requestId":"req-0002","reason":"MIC_UNAVAILABLE"}
```

### STOP

Direction: Mac → Windows. Ends the active audio session.

Required fields: `requestId` (string, echoed in `STOP_ACK`), `sessionId` (string — the session
being stopped; see §7 for what to send when no session is active).

```json
{"v":1,"type":"STOP","requestId":"req-0003","sessionId":"sess-0001"}
```

### STOP_ACK

Direction: Windows → Mac. Confirms the session has ended and audio has stopped.

Required fields: `requestId` (string, matches the triggering `STOP`), `sessionId` (string — the
session that was ended).

```json
{"v":1,"type":"STOP_ACK","requestId":"req-0003","sessionId":"sess-0001"}
```

### STATUS

Direction: Windows → Mac. Unsolicited notification of a state change (e.g. the USB microphone was
unplugged or replugged) — not a reply to any specific request.

Required fields: `micPresent` (boolean), `active` (boolean, whether a session is currently
streaming), `deviceLabel` (string).

```json
{"v":1,"type":"STATUS","micPresent":false,"active":false,"deviceLabel":"USB Microphone"}
```

### PING / PONG

Direction: `PING` is Mac → Windows; `PONG` is Windows → Mac, sent in immediate reply. Heartbeat;
see §8 for timing.

Required fields (both): `seq` (integer). A `PONG`'s `seq` MUST equal the `seq` of the `PING` it
answers.

```json
{"v":1,"type":"PING","seq":1}
```
```json
{"v":1,"type":"PONG","seq":1}
```

---

## 6. Handshake

Every new TCP connection, immediately after the TLS handshake completes and before any `START`,
`STOP`, `PING`, or `STATUS` is sent or accepted, runs this exchange:

1. **Windows sends `GREETING{serverId, nonce}`.** `nonce` is freshly random per connection (32
   bytes, lowercase hex) — never reused across connections.
2. **The Mac replies `HELLO{clientId, mac}`**, where
   `mac = lowercase_hex(HMAC-SHA256(token, nonce))`. `token` is the 256-bit pairing secret
   established out-of-band during pairing (§7.1 of the design spec); `nonce` is the raw 32 bytes
   decoded from the `GREETING`'s hex `nonce` field (HMAC is computed over the raw bytes, not over
   the hex string). **The token itself never crosses the wire** — only this per-connection proof
   does, and the fresh nonce means a captured proof cannot be replayed against a future connection.
3. **Windows verifies `mac`** by computing the same HMAC over its own copy of `token` and the
   `nonce` it sent, and comparing in constant time. If it matches, Windows replies `HELLO_ACK`
   (§5) and the connection is authenticated. If it does not match, Windows closes the connection
   without replying.

**5-second deadline:** Windows gives the Mac 5 seconds from the moment the TLS handshake completes
to deliver a valid `HELLO`. If no valid `HELLO` arrives within 5 seconds — no message, an
unparseable message, a message that is not `HELLO`, or a `HELLO` whose `mac` fails verification —
Windows closes the connection. There is no partial-credit state: a peer is either fully
authenticated (has received/sent `HELLO_ACK`) or the connection is dead.

No `START`, `STOP`, `PING`, `STATUS`, or `AUDIO` frame is valid before authentication completes.
Windows MUST reject (by closing the connection) any such message received before a verified
`HELLO`.

---

## 7. Session lifecycle

`START` and `STOP` are the only session control messages, and both are **idempotent**:

- **A duplicate `START` while a session is already active** (i.e. a second `START` arrives before
  any `STOP`) does not start a second session. Windows returns `START_ACK` carrying the
  **existing** `sessionId` and format — it does not reset the audio `sequence` counter or restart
  capture. This is what makes it safe for the Mac to retry `START` after a reconnect without first
  knowing whether the previous `START` actually landed.
- **A duplicate `STOP` while idle** (i.e. a `STOP` arrives with no session active, whether because
  none was ever started or because a previous `STOP` already ended it) still succeeds: Windows
  replies `STOP_ACK`. The `sessionId` in a `STOP` sent with no session active MAY be an empty
  string or a stale value from a previous session — Windows does not reject `STOP` on `sessionId`
  mismatch; `STOP` always means "make sure no session is active" for the current connection, not
  "end specifically this session ID".

Normal flow:

```
Mac                              Windows
 ── START{requestId} ──────────→
                              (open capture; if the mic is absent, verify BEFORE
                               starting anything)
 ←──── START_ACK{requestId, sessionId, format} ─── (mic present: session now active)
       -- or --
 ←──── START_NACK{requestId, reason} ───────────── (mic absent: reason=MIC_UNAVAILABLE)

 (AUDIO frames stream from Windows → Mac, sequence 0, 1, 2, ... while active)

 ── STOP{requestId, sessionId} ─→
                              (stop capture; drain in-flight frames)
 ←──── STOP_ACK{requestId, sessionId} ────────────
```

No `AUDIO` frame may be sent outside an active session — i.e. never before the corresponding
`START_ACK`, and never after the corresponding `STOP_ACK` has been sent. This is the protocol-level
expression of the project's core privacy requirement: audio crosses the wire only while a session
is explicitly active, and an idle connection MUST carry zero audio bytes.

---

## 8. Timers

| Timer | Value | Who runs it | Effect on expiry |
|---|---|---|---|
| `START` response | 2 s | Mac, per outstanding `START` | Treat as a failed/dead peer — do not wait indefinitely for `START_ACK`/`START_NACK` |
| `STOP` response | 1 s | Mac, per outstanding `STOP` | Treat the session as ended locally regardless; do not block shutdown on a `STOP_ACK` that may never arrive |
| `PING` interval | 15 s | Mac (sends `PING` to Windows) | Windows replies `PONG` immediately; Windows applies the same 15 s interval and dead-peer rule to *absent* `PING`s from the Mac |
| Peer dead | 45 s without a `PONG` (three missed heartbeats) | Both sides, watching the heartbeat | Declare the connection dead; close it and begin reconnect (Mac) or accept a new connection (Windows) |
| Pre-auth (`HELLO`) deadline | 5 s | Windows, per new connection | Close the connection; see §6 |

The heartbeat is deliberately slow (15 s) — it exists to keep connection-alive UI state honest and
NAT/firewall state fresh, not to detect a dead peer quickly. When it actually matters — a session
is being requested — the 2-second `START` timeout detects a dead or non-responding peer far faster
than any practical heartbeat interval would.

---

## 9. Send priority

A single TCP/TLS connection carries both control and audio, so the sender needs a rule for what
goes on the wire first when both are pending. The rule:

- **Control messages are queued unboundedly and are always drained before any audio frame.**
  Control traffic is tiny and rare (JSON objects on the order of tens to low hundreds of bytes); an
  unbounded queue for it is safe. A `STOP_ACK` or a `STATUS` update must never be stuck behind a
  backlog of audio.
- **Audio is queued in a bounded ring of 25 frames (500 ms at 50 fps) that drops the oldest frame
  on overflow and never blocks.** If the audio queue is full when a new frame is produced, the
  oldest queued frame is discarded to make room — the sender never waits for the network to catch
  up, and audio production (WASAPI capture on Windows) must never be slowed or blocked by a slow or
  stalled connection.

Concretely: a writer loop should check the control queue first on every iteration; only when it is
empty does the writer send from the audio queue. A stalled network can therefore delay or lose
audio frames, but it can never delay a control message such as `STOP_ACK`.

Dropped audio frames should be counted for diagnostics — silently dropping frames in a way that
looks identical to healthy operation is a worse failure than the drop itself.

---

## 10. Conformance

An implementation of this protocol — Windows or macOS — is conformant only if it produces and
accepts the exact bytes described above. This is checked mechanically against two fixture files
committed alongside this document:

- `protocol/vectors/control-messages.json` — 11 cases, one per control message type in §5.
- `protocol/vectors/audio-frames.json` — 3 cases (audio frame indices 0, 1, and 49 of a
  synthetic session), covering the first frame, the second frame (to catch off-by-one errors in
  sequence/timestamp advancement), and a frame late enough to exercise multi-digit sequence/
  timestamp encoding.

Each vector case has: the logical message or frame parameters, and `"hex"` — the exact expected
wire bytes, as lowercase hex, of the complete envelope (§3) for that message.

**Conformance rule for audio frames: compare bytes.** An implementation's `encode_frame(2,
encode_audio_payload(sequence, timestampUs, pcm))` for a vector's `sequence`/`timestampUs`/`pcmHex`
MUST equal that vector's `hex`, byte for byte. Audio framing has no ambiguity to canonicalize away
(§4's fixed-width header, network byte order, and fixed frame size leave nothing to reorder), so
bytewise comparison is the correct and only check.

**Conformance rule for control messages: compare parsed messages, and separately compare bytes
against a canonical (sorted-key) encoder.** This project's JSON encoder produces its bytes with
object keys sorted lexicographically (`sort_keys=True`, or the equivalent in your language's JSON
library) specifically so that two implementations which build the same logical message with fields
in a different order still produce byte-identical wire output. Given that, an implementation MUST
satisfy both of the following against `control-messages.json`:

1. **Decode conformance:** parsing a vector's `"hex"` bytes and JSON-decoding the payload MUST
   yield an object equal (field-for-field, ignoring key order and JSON whitespace) to that vector's
   `"message"`.
2. **Encode conformance:** encoding a vector's `"message"` object with your implementation's
   control-message encoder, using sorted (canonical) key order, MUST produce bytes identical to
   that vector's `"hex"`.

If your implementation's JSON library cannot easily guarantee sorted-key output on encode, decode
conformance (1) is the check that actually matters for interoperability — two peers only need to
agree on the *parsed meaning* of a control message, since each message is decoded into structured
fields before use, never compared as raw bytes at runtime. Encode conformance (2) exists to keep
the fixture files themselves byte-exact and regenerable from the reference implementation, and to
catch encoders that silently omit or rename required fields.

**Running the vectors against the reference implementation:**

```
cd harness
.venv/bin/python -m pytest tests/test_vectors.py -v
```

**Regenerating the vectors** (only a deliberate act — see the note below) from the reference
implementation:

```
cd harness
.venv/bin/python tools/generate_vectors.py
```

### A note on regenerating audio vectors

`protocol/vectors/audio-frames.json` is generated from `sine_frame()`, a synthetic sine-wave
generator built on `math.sin`. `math.sin` is backed by the platform's libm, which is not
guaranteed bit-identical (correctly rounded) across operating systems or Python versions, and the
generator truncates its float-to-int16 conversion toward zero. Regenerating this file on a
different machine than it was last generated on could, in principle, flip an individual PCM sample
by ±1 in the least significant bit.

This does not threaten cross-platform conformance: the real Windows and macOS agents never
generate a sine wave — they capture live microphone audio. What these vectors freeze is **framing**
— the envelope, the header byte order, and the header/PCM boundary — using the committed PCM bytes
purely as an input fixture, not as a value either agent is expected to reproduce. Treat the
committed `protocol/vectors/audio-frames.json` as the source of truth once committed; regenerating
it is a deliberate, reviewed act (e.g. changing the frame indices sampled or the audio format),
not something to do routinely or as a side effect of an unrelated change.
