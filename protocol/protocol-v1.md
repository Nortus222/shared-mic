# shared-mic wire protocol — version 1

This document is the contract between the Windows (C#) agent and the macOS (Swift) agent. It
states the wire format, the field-level rules, and the golden vectors an implementation must
match. It does not explain *why* the protocol looks this way — for rationale, see
`docs/superpowers/specs/2026-08-08-shared-mic-design.md`, particularly §4 (Transport), §7
(Security), and §8 (Failure handling). This document states the contract only.

The reference implementation is the Python conformance harness at `harness/sharedmic_protocol/`.
It exists to make this document trustworthy, not to replace it — implement against this document,
and use the harness and the vectors in `protocol/vectors/` to check your work.

**Notation:** every normative requirement below is written as a `MUST`/`MUST NOT`, a byte layout,
or a fixed value, and is additionally tagged with how much of that requirement the harness actually
exercises today:

- **[VERIFIED]** — asserted by a passing test in `harness/tests/`, as of this document's last
  update alongside the harness.
- **[CARRIED]** — required by this contract and sourced from
  `docs/superpowers/specs/2026-08-08-shared-mic-design.md`, but not yet exercised by any harness
  test. A Phase 1 implementation must still provide it in full; the tag says only that the harness
  has not (yet) proven it, not that it is optional or uncertain.

Untagged prose (byte layouts, field lists, worked examples) is definitional rather than a
behavior to test, and is not tagged either way. Every section from §1 to §11 carries tags on its
normative requirements; if you find an untagged `MUST` in one of them, that is a documentation bug,
not a requirement you may skip.

Two tagging conventions worth knowing before you read on, because several requirements need both
halves and it would otherwise look like the tags disagree with each other:

- **A codec-level rule and its connection-level consequence are tagged separately.** "Reject a
  malformed frame" and "close the connection when you reject one" are different claims and the
  harness proves them to different depths. Where they differ, both tags appear.
- **A `[VERIFIED]` tag names the tests.** If it does not name a test, treat it as a documentation
  bug and check `harness/tests/` yourself before relying on it.

---

## 1. Scope and versioning

This document defines **protocol version 1** (`PROTOCOL_VERSION = 1`). Every control message
carries a `"v"` field. A peer that receives a control message with `"v"` other than `1` MUST close
the connection. There is no negotiation: version 1 is the only version either agent needs to speak,
and a version mismatch is treated as a hard protocol violation, not something to downgrade or
retry.

**[VERIFIED]** — `test_control.py::test_rejects_wrong_protocol_version` proves the decoder rejects a
control message whose `"v"` is not `1` (it raises `ProtocolError` rather than returning a message).
**[CARRIED]** for the *close* half: both mocks do close on that rejection (`server.py`'s `run()`
returns, which runs `_serve`'s `finally`; `client.py`'s `_reader_loop` calls `_abort()`), but no test
sends a wrong-version message over a live connection and asserts the socket goes away. A Phase 1
implementation must still close.

Changing anything in this document — a field name, a byte layout, a timer value — is a protocol
version change. It requires updating this document, both platform implementations, and the golden
vectors together. Do not treat this document as an implementation detail of either agent; it is
versioned independently of both.

---

## 2. Transport

- **One TCP connection** carries both control messages and audio, multiplexed (see §9). There is
  no separate audio socket.
- **Default port 47800.** Configurable on the Windows side; the listener binds to private
  interfaces only and is never exposed to the public Internet. **[CARRIED]** — the harness always
  binds an OS-assigned ephemeral port (`port=0`) for test isolation and never exercises the fixed
  default; a real Windows implementation must still default to 47800.
- **TLS 1.3** wraps the connection immediately after the TCP handshake. Windows is the TLS server
  (it holds the certificate and private key generated at first run); macOS is the TLS client.
  **[VERIFIED]** — `test_tls.py::test_session_works_over_tls_with_matching_pin`,
  `test_tls.py::test_tls_handshake_is_bounded_not_infinite`.
- **Trust is a pinned certificate fingerprint, not a certificate authority.** There is no CA
  anywhere in this design. During pairing, the Mac records the SHA-256 fingerprint of the server
  certificate's DER encoding, as a lowercase hex string. On every subsequent connection, after the
  TLS handshake completes, the Mac computes SHA-256 over the DER encoding of the certificate the
  server presented and compares it byte-for-byte (as lowercase hex) against the pinned value.
  **[VERIFIED]** — `test_tls.py::test_fingerprint_is_hex_sha256`,
  `test_tls.py::test_fingerprint_is_stable`, `test_tls.py::test_distinct_certs_have_distinct_fingerprints`.
- **A fingerprint mismatch is a hard stop.** The Mac closes the connection immediately. There is no
  automatic retry and no silent re-pairing — re-establishing trust requires an explicit user
  pairing action. This is deliberate: a fingerprint mismatch is the one failure mode that can mean
  an active attacker, and any form of automatic recovery here would defeat the reason pinning
  exists. **[VERIFIED]** — `test_tls.py::test_mismatched_fingerprint_is_a_hard_stop` (the harness
  proves the connection is refused; it does not and cannot prove the *absence* of an automatic
  retry policy in a future full agent, which is a UI/reconnect-logic property outside the harness's
  reach).
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

**[VERIFIED]** for the *detection* half of both rules —
`test_framing.py::test_decode_rejects_unknown_frame_type` and
`test_framing.py::test_decode_rejects_oversized_payload` prove the decoder raises rather than
returning a frame, and the encoder refuses to produce either shape.
**[CARRIED]** for the *close* half of both: no test drives a bad `type` byte or an oversized
`length` down a live socket and asserts the connection is torn down. Both mocks do implement it —
`server.py` returns out of `run()` (its `finally` closes), and `client.py`'s `_reader_loop` calls
`_abort()`, which shuts down and closes the socket rather than merely stopping the read loop — but
that is implementation, not proof. A Phase 1 implementation must close, not skip the frame and
resynchronize.

**Incremental decoding is [VERIFIED]** — `test_framing.py::test_decode_returns_none_when_header_incomplete`,
`test_decode_returns_none_when_payload_incomplete`, and
`test_decode_reports_consumed_so_stream_can_hold_two_frames` prove that a partial buffer yields "not
yet" rather than a wrong answer, and that a buffer holding two concatenated envelopes decodes to two
frames with the correct byte counts.

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
bytes belong to this frame, and the header fields have fixed width, so nothing else is needed.

**Short audio payloads are not legal. There is no partial frame in this protocol.** An `AUDIO`
envelope's `length` MUST be exactly `12 + 1920 = 1932`. A sender MUST NOT emit a partially filled
frame — not at session start, not at session end while draining, and not to flush a capture buffer
that happened to hold fewer than 960 samples. A capture path that has less than a full 20 ms of
audio waits for the rest or drops it; it never sends a short one. A receiver MUST treat an `AUDIO`
payload whose length is anything other than 1,932 bytes as a protocol violation and close the
connection (§3). This is stated explicitly because `12 + 1920` alone reads like an example rather
than a constraint, and a Windows implementation flushing a residual capture buffer at `STOP` is the
obvious way to violate it by accident.

**[VERIFIED]** for the sender rule and the layout —
`test_framing.py::test_audio_payload_header_is_twelve_bytes` and `test_audio_payload_round_trip`
pin the header size and byte order; `test_loopback.py::test_audio_frames_are_exactly_one_frame_each`
and `test_client.py::test_client_receives_full_size_audio_frames` assert every frame that crosses a
live connection carries exactly 1,920 PCM bytes; `test_vectors.py::test_audio_vectors_encode_to_expected_bytes`
byte-matches complete 1,937-byte envelopes.
**[CARRIED]** for the receiver rule: the reference decoder does *not* enforce it —
`decode_audio_payload` accepts any payload of at least 12 bytes (only
`test_audio_payload_rejects_short_header` is exercised, i.e. shorter than the header itself) and
returns whatever PCM follows. A Phase 1 receiver must be stricter than the harness here.

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

**[VERIFIED]** that the reference *generator* emits little-endian PCM —
`test_audio.py::test_frames_are_phase_continuous` is the test that would actually fail under a
byte-swapped generator, since a byte-swapped wave is discontinuous at the frame boundary;
`test_frame_is_little_endian_signed_16_bit` unpacks with a little-endian format string but only
asserts sample count and range, both of which hold for any byte order, so it does not pin
endianness by itself despite its name. `test_audio.py::test_constants_match_spec` pins sample
rate, frame samples, frame bytes, frames per second, and frame duration;
`test_control.py::test_canonical_audio_format_matches_spec` pins the remaining two rows of the
format table above, `channels` and `sampleFormat`. The envelope-level consequence is byte-matched
by `test_vectors.py::test_audio_vectors_encode_to_expected_bytes`.
**[CARRIED]** that a *receiving* implementation is held to little-endian PCM — nothing in the
harness inspects a peer's byte order; the golden vectors pin `encode_audio_payload`'s framing of
PCM bytes supplied to it, not that a receiver validates the endianness of PCM bytes it did not
generate itself.

`captureTimestampUs` is relative to session start (the first frame of a session is timestamp `0`,
and each subsequent frame's timestamp increases by `20000`, i.e. 20 ms in microseconds, matching
the 20 ms frame duration) — it is not wall-clock time and not relative to any epoch. `sequence`
resets to `0` at the start of each session (each `START_ACK`, §7) and increments by exactly 1 per
frame; a receiver uses it to detect dropped or reordered frames within a session, not across
sessions.

**[VERIFIED]** for the advancement rules — `test_loopback.py::test_timestamps_advance_by_frame_duration`
asserts every consecutive timestamp delta in a live session is exactly `20000`, and
`test_audio_sequence_has_no_gaps` asserts 25 consecutive frames carry consecutive sequence numbers
with `client.sequence_gaps == 0`.
**[CARRIED]** for the *reset to `0`* rule specifically. This is a real gap and worth naming: the
loopback tests deliberately assert the sequence run is consecutive *relative to its own first
value* (`sequences == list(range(sequences[0], sequences[0] + 25))`), not that it begins at `0`, and
`test_session_can_be_restarted` does not read the second session's first sequence number at all.
The reference server does start each session's counter at `0`, and the golden vectors pin frames
`0`/`1`/`49`, but no test would fail if a session's counter continued from the previous session's.
Implement the reset; do not infer it is covered.

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

**[VERIFIED]** — `test_control.py::test_rejects_missing_required_field`,
`test_rejects_unknown_message_type`, `test_rejects_non_object_json`, and `test_rejects_malformed_json`
prove each rejection path, on both encode and decode (the reference implementation validates in both
directions, so a harness bug surfaces loudly instead of as bytes the far end has to guess about).
`test_encodes_as_utf8_without_ascii_escaping` pins the canonical, separator-free, sorted-key UTF-8
encoding, and `test_vectors.py::test_control_vectors_decode_to_expected_message` /
`test_control_vectors_encode_to_expected_bytes` exercise the field lists below for all eleven types
against the committed vectors.

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
streaming), `deviceLabel` (string). **These three fields are the whole message — there is no
`errors` field**, which an earlier version of the design spec's §4.4 summary table implied and which
never existed in the vectors, the codec, or this section. Failure detail is
carried by `START_NACK{reason}` (§5) for a rejected activation, and by the connection closing for a
protocol violation; `STATUS` reports state, not errors.

```json
{"v":1,"type":"STATUS","micPresent":false,"active":false,"deviceLabel":"USB Microphone"}
```

Because `STATUS` answers no request, a receiver MUST NOT route it through whatever queue it uses to
match replies to outstanding requests — it will arrive interleaved with, or in the middle of, a
`START`/`STOP`/`PING` exchange, and an implementation that discards unmatched messages while
awaiting a reply will silently lose it. Two `STATUS` transitions matter operationally (design spec
§8): mic unplugged while idle (stay connected, block activation) and mic unplugged mid-session
(Windows stops capture first, so `active` is already `false` when the Mac reads the message; the Mac
enters `DEGRADED` and notifies).

**[VERIFIED]** — `test_loopback.py::test_mic_unplug_while_idle_sends_status`,
`test_mic_unplug_mid_session_stops_capture_and_sends_status` (which also asserts audio actually
stops after the `STATUS`), `test_mic_replug_sends_status_and_allows_a_new_session`, and
`test_status_is_not_mistaken_for_a_reply`, which asserts that two `STATUS` messages arriving around
a `PING` and a `START` are both delivered and counted rather than swallowed by the reply path.
`MockWindowsServer.set_mic_present()` is the trigger; `MockMacClient.wait_for_status()` /
`drain_status()` / `status_messages_received` are the client-side accessors to build against.

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

**[VERIFIED]** — `test_client.py::test_ping_gets_pong` drives a real `PING`/`PONG` over a live
connection through `MockMacClient.ping()`, which raises `ProtocolError` if the returned `seq` does
not equal the one it sent; a server echoing a constant or an incremented `seq` fails that test.
Exercised for one exchange (`seq = 1`) only — no test sends several `PING`s and checks each `PONG`
is matched to the right one.

---

## 6. Handshake

Every new TCP connection, immediately after the TLS handshake completes and before any `START`,
`STOP`, `PING`, or `STATUS` is sent or accepted, runs this exchange:

1. **Windows sends `GREETING{serverId, nonce}`.** `nonce` is freshly random per connection (32
   bytes, lowercase hex) — never reused across connections. **[VERIFIED]** —
   `test_server.py::test_server_greets_with_a_nonce`, `test_server.py::test_server_issues_nonce_per_connection`.
2. **The Mac replies `HELLO{clientId, mac}`**, where
   `mac = lowercase_hex(HMAC-SHA256(token, nonce))`. `token` is the 256-bit pairing secret
   established out-of-band during pairing (§7.1 of the design spec); `nonce` is the raw 32 bytes
   decoded from the `GREETING`'s hex `nonce` field (HMAC is computed over the raw bytes, not over
   the hex string). **The token itself never crosses the wire** — only this per-connection proof
   does, and the fresh nonce means a captured proof cannot be replayed against a future connection.
   **[VERIFIED]** — `test_auth.py`'s `auth_proof`/`verify_proof` tests plus
   `test_client.py::test_connect_completes_handshake` and
   `test_server.py::test_server_accepts_valid_proof` for the end-to-end exchange.
3. **Windows verifies `mac`** by computing the same HMAC over its own copy of `token` and the
   `nonce` it sent, and comparing in constant time. If it matches, Windows replies `HELLO_ACK`
   (§5) and the connection is authenticated. If it does not match, Windows closes the connection
   without replying. **[VERIFIED]** — `test_server.py::test_server_rejects_bad_proof_and_counts_it`,
   `test_client.py::test_wrong_token_fails_to_connect`.

**5-second deadline:** Windows gives the Mac 5 seconds from the moment the TLS handshake completes
to deliver a valid `HELLO`. If no valid `HELLO` arrives within 5 seconds — no message, an
unparseable message, a message that is not `HELLO`, or a `HELLO` whose `mac` fails verification —
Windows closes the connection. There is no partial-credit state: a peer is either fully
authenticated (has received/sent `HELLO_ACK`) or the connection is dead. **[VERIFIED]** —
`test_server.py::test_server_closes_idle_connection_after_hello_timeout` proves the "no message at
all" case, against an injected short timeout so the suite doesn't pay the real 5 s in wall time.

No `START`, `STOP`, `PING`, `STATUS`, or `AUDIO` frame is valid before authentication completes.
Windows MUST reject (by closing the connection) any such message received before a verified
`HELLO`. **[VERIFIED]** — `test_server.py::test_server_rejects_non_hello_message_before_authentication`
sends a pre-auth `PING` and asserts the connection closes. The implementation checks
`msg["type"] != "HELLO"` for any decoded control message, so this one `PING` case exercises the
same branch that would reject a pre-auth `START`/`STOP`/`STATUS` too — those three are not
separately exercised. `AUDIO` is structurally different and stricter: any frame whose envelope
`type` is not `CONTROL` is rejected unconditionally (not only pre-auth — the Mac never sends
`AUDIO` at all in this protocol, so Windows treats receiving one from the client as a protocol
violation at any point in the connection's lifetime). That broader rule is not exercised by any
current test either.

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

**[VERIFIED]** — `test_loopback.py::test_duplicate_start_is_idempotent` sends a second `START` with
no intervening `STOP` and asserts both `START_ACK`s carry the *same* `sessionId` and that
`server.sessions_started == 1`, so no second session was created. `test_duplicate_stop_succeeds`
sends `STOP` twice and requires a `STOP_ACK` for each; `test_stop_without_start_succeeds` sends
`STOP` on a connection that never started a session and requires a `STOP_ACK`.
`test_session_can_be_restarted` proves a `START` after a `STOP` opens a genuinely new session
(`sessions_started == 2`) and that audio resumes.
Two narrower claims in the prose above are **[CARRIED]**: that a duplicate `START` does not reset
the audio `sequence` counter is *implied* by `sessions_started == 1` (no second capture loop is
created) but is not observed on the wire; and the "stale `sessionId`" half of the `STOP` rule is
exercised only for the empty-string case (`MockMacClient.stop_session()` sends `""` when it holds no
session), never with a stale identifier from a previous session.

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

**[VERIFIED] — this is the single best-tested requirement in this document, and it is asserted from
both ends of the wire independently.** `test_loopback.py::test_no_audio_before_start` holds an
authenticated connection open, sleeps, exchanges a `PING`/`PONG`, and then asserts *both*
`client.audio_frames_received == 0` (the Mac saw nothing) and `server.audio_frames_sent == 0` (the
Windows side produced nothing — so this is zero capture, not merely zero transmission).
`test_audio_flows_only_between_start_and_stop` starts a session, takes 10 frames, stops it, lets the
socket settle, and asserts the received count does not move again.
`test_mic_unplug_mid_session_stops_capture_and_sends_status` asserts the same silence after capture
is lost mid-session rather than stopped by request. `test_full_lifecycle_leaves_no_sequence_gaps`
runs three full start/stop cycles and asserts no sequence gaps across any of them.
One residual, deliberately tolerated: a frame already inside `sendall()` when `STOP_ACK` was queued
can still land immediately after it, so the tests assert "audio stopped" after a short settle rather
than "audio stopped on the exact byte". The invariant that matters — an *idle* connection carries
zero audio — is asserted without tolerance.

---

## 8. Timers

| Timer | Value | Who runs it | Effect on expiry | Harness |
|---|---|---|---|---|
| `START` response | 2 s | Mac, per outstanding `START` | Treat as a failed/dead peer — do not wait indefinitely for `START_ACK`/`START_NACK` | **[CARRIED]** |
| `STOP` response | 1 s | Mac, per outstanding `STOP` | Treat the session as ended locally regardless; do not block shutdown on a `STOP_ACK` that may never arrive | **[CARRIED]** |
| `PING` interval | 15 s | Mac (sends `PING` to Windows) | Windows replies `PONG` immediately; Windows applies the same 15 s interval and dead-peer rule to *absent* `PING`s from the Mac | **[CARRIED]** |
| Peer dead | 45 s without a `PONG` (three missed heartbeats) | Both sides, watching the heartbeat | Declare the connection dead; close it and begin reconnect (Mac) or accept a new connection (Windows) | **[CARRIED]** |
| Pre-auth (`HELLO`) deadline | 5 s | Windows, per new connection | Close the connection; see §6 | **[VERIFIED]** |

**[CARRIED]** detail: the harness's `MockMacClient.start_session()`/`stop_session()` accept the 2 s
/ 1 s values as default *parameters* on their reply-wait helper, and `ping()` performs one
manually-triggered request/reply — but nothing in the harness ever lets a `START`/`STOP`/`PING`
actually go unanswered to prove the timeout fires, and there is no automatic 15 s heartbeat loop or
45 s dead-peer reaper running anywhere in `server.py` or `client.py`. This is a deliberate scope
line, not an oversight: an always-on timer loop is real-agent behavior, not test-double behavior,
and the mock exists to let both platform agents be built against a peer that behaves correctly on
the wire, not to itself be a complete implementation of every timer. **A Phase 1 (or later)
implementation of this protocol MUST still implement the full heartbeat loop, dead-peer detection,
and both response timeouts** — their absence from the harness is not license to skip them.

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
  backlog of audio. **[VERIFIED]** —
  `test_server.py::test_control_preempts_a_full_audio_backlog_and_counts_the_drop` fills the
  25-frame audio queue to capacity, queues a control message behind that backlog, and asserts the
  control message's envelope is the first thing written to the wire — not one of the backlogged
  audio frames.
- **Audio is queued in a bounded ring of 25 frames (500 ms at 50 fps) that drops the oldest frame
  on overflow and never blocks.** If the audio queue is full when a new frame is produced, the
  oldest queued frame is discarded to make room — the sender never waits for the network to catch
  up, and audio production (WASAPI capture on Windows) must never be slowed or blocked by a slow or
  stalled connection. **[VERIFIED]** — the same test offers 30 frames into a 25-capacity queue and
  asserts both that exactly 5 were dropped and that the queue's surviving contents are the *last*
  25 offered (i.e. the oldest 5, not an arbitrary 5, were the ones evicted). The "never blocks"
  half of this claim is structural (the implementation uses `queue.put_nowait`, which raises
  instead of blocking, by construction) rather than independently timed by a test.

Concretely: a writer loop should check the control queue first on every iteration; only when it is
empty does the writer send from the audio queue. A stalled network can therefore delay or lose
audio frames, but it can never delay a control message such as `STOP_ACK`.

Dropped audio frames should be counted for diagnostics — silently dropping frames in a way that
looks identical to healthy operation is a worse failure than the drop itself.

A frame that never reaches the far end leaves the sender for one of two reasons, and they MUST be
counted separately:

- **evicted on overflow** — the network could not keep up. This is a symptom worth alarming on.
- **discarded at session teardown** — the queue still held frames when `STOP` (or a mic loss, §5's
  `STATUS`) ended the session. This is intended behavior and alarming on it would be noise.

Folding the two into one counter makes the number that matters unreadable. Keeping them apart is
also what makes the arithmetic close: **offered = received + evicted + discarded**, plus at most one
frame still inside `sendall()` at the moment the counters are read.

**[VERIFIED]** — the server exposes `audio_frames_dropped` (overflow evictions, incremented exactly
once per frame actually evicted, not once per overflow attempt) and `audio_frames_discarded`
(teardown discards) alongside `audio_frames_sent` (frames offered).
`test_server.py::test_control_preempts_a_full_audio_backlog_and_counts_the_drop` pins the eviction
count at exactly 5 for 30 frames offered into a 25-slot queue, and
`test_loopback.py::test_frame_counters_reconcile_across_a_session` asserts the identity above holds
across a real start/stop cycle to within the one in-flight frame. Before `audio_frames_discarded`
existed, the `STOP` handler drained up to 25 counted-as-offered frames that then vanished from the
arithmetic entirely, and this paragraph claimed a reconciliation a reader could not actually
perform.

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

**[VERIFIED]** — `tests/test_vectors.py` runs all three conformance rules below against the
committed fixtures on every test run: `test_vector_files_exist` (1 case),
`test_control_vectors_encode_to_expected_bytes` and `test_control_vectors_decode_to_expected_message`
(11 cases each, one per control type), and `test_audio_vectors_encode_to_expected_bytes` (3 cases) —
26 test cases over 14 vectors. The reference implementation is therefore held to this section's
`MUST`s continuously; the vectors cannot drift from it unnoticed.

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

---

## 11. Pairing and trust establishment

§2 and §6 describe how an *already paired* pair of agents connects: the Mac checks a pinned
fingerprint, then proves possession of a shared token. This section specifies where those two
values come from, because both cross a human rather than the wire — the Windows tray *displays* a
pairing string and the Mac *parses* what the user typed — and a format disagreement here fails at
first user contact, before a single byte of §3 is ever exchanged.

### 11.1 The pairing token

The pairing token is **32 bytes (256 bits) from a cryptographically secure random source**,
generated by Windows at first run and never regenerated except by an explicit re-pair. It is the
HMAC key in §6 step 2. It never crosses the wire in any form. **[VERIFIED]** —
`test_auth.py::test_token_is_256_bits`, `test_tokens_are_not_repeated`.

### 11.2 The pairing string

The token is shown to the user, and typed by the user, as a **pairing string**. Its encoding is
fully specified here; do not infer it from either implementation.

**Encoding (Windows → screen):**

1. **Base32**, RFC 4648 alphabet (`A`–`Z` then `2`–`7`), applied to the 32 raw token bytes.
2. **Uppercase.** The RFC 4648 alphabet is uppercase; do not lowercase it for display.
3. **Unpadded.** 32 bytes encode to 52 base32 characters plus 4 `=` padding characters; strip the
   padding. The displayed string contains no `=`.
4. **Hyphen-grouped in runs of 8 characters**, left to right, with a single `-` (U+002D) between
   groups. 52 characters therefore produce six full groups of 8 and a final group of 4.

A pairing string is consequently always **58 characters**: 52 base32 characters + 6 hyphens. Worked
example, for the token `000102...1f` (bytes 0 through 31 in order):

```
token (hex): 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
pairing string: AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ
```

**Decoding (user's keystrokes → Mac):** the decoder is deliberately tolerant, because a human is
retyping 52 characters off a screen.

1. **Uppercase the input first.** A user typing lowercase must succeed.
2. **Delete every character that is not in the RFC 4648 base32 alphabet** (i.e. keep only `A`–`Z`
   and `2`–`7`; the regex is `[^A-Z2-7]` → remove). This is what makes hyphens, spaces, tabs, and
   stray punctuation harmless, and it means the grouping in step 4 above is presentation only — the
   Mac MUST accept the string with the hyphens removed, replaced by spaces, or regrouped.
3. **Re-pad** with `=` to the next multiple of 8 characters, then base32-decode.
4. **Validate the length: the result MUST be exactly 32 bytes.** Reject anything else. This is the
   check that turns a truncated or over-long paste into an immediate, explicable error instead of a
   token that authenticates against nothing and produces an opaque `HELLO` failure on every
   subsequent connection.
5. Reject with a user-visible error if base32 decoding fails.

**Do not add confusable-character mapping.** It is tempting to map `0`→`O` and `1`→`I`/`L`, and this
specification deliberately does not: step 2 *deletes* characters outside the alphabet, so a typed
`0` or `1` is silently dropped rather than corrected, and the step 4 length check then rejects the
result. An implementation that adds its own mapping would accept strings the other implementation
rejects, which is exactly the interoperability failure this section exists to prevent. If confusable
handling is ever wanted, it is a protocol version change (§1) and must land on both platforms
together.

**[VERIFIED]** — `test_auth.py::test_pairing_string_round_trip` (encode → decode is the identity on
a random token), `test_pairing_string_tolerates_human_transcription` (lowercased, hyphens replaced
by spaces, still decodes to the same token), `test_pairing_string_rejects_garbage`,
`test_pairing_string_rejects_wrong_length` (valid base32 that decodes to 5 bytes, rejected), and
`test_server.py::test_pairing_string_is_what_the_user_would_type` (the string is built from the same
token the server actually authenticates against).
**[CARRIED]:** the 58-character/grouping shape and the worked example above are asserted only
implicitly, via the round-trip — no test pins the group size or the total length. They are still
normative: an implementation that groups in 4s produces a string a user will mis-transcribe against
a screen showing 8s, even though both decode.

### 11.3 The device certificate

Windows generates one self-signed certificate at first run, holds the private key locally (DPAPI-
protected on a real Windows agent), and serves it on every connection (§2). The certificate profile
is load-bearing for a client implementer, so it is specified rather than left to whatever a TLS
library defaults to:

| Property | Value |
|---|---|
| Key type | EC P-256 (`secp256r1` / `prime256v1`) |
| Signature | ECDSA with SHA-256, self-signed (issuer == subject) |
| Subject | `CN = <common name>` (the reference implementation uses `shared-mic`) |
| Subject Alternative Name | **Required.** One `dNSName` entry, byte-identical to the subject CN |
| Validity | 3,650 days (10 years), starting 5 minutes in the past to absorb clock skew |
| Chain | None. There is no CA and no intermediate; the chain is one certificate long |

**The SAN is not decorative and MUST be present.** The client disables both CA verification and
hostname verification (§2 — the pin is the check), but several TLS stacks a Swift client is likely
to use, including Network.framework and `URLSession`, evaluate the certificate *before* handing it
to a custom trust callback, and some reject a certificate with no SAN at that earlier stage — so a
SAN-less certificate can fail before the pinning hook ever runs, producing a failure that looks like
a network error rather than a certificate problem. Emit the SAN even though nothing in this protocol
matches a hostname against it.

**A macOS implementer must explicitly opt out of both CA and hostname validation.** This does not
happen by default in any of these stacks and is not something to discover at integration time: the
client's only certificate check is the SHA-256-of-DER pin from §2. Getting this wrong in the safe
direction (leaving CA validation on) fails every connection against a self-signed certificate;
getting it wrong in the unsafe direction (disabling validation *without* implementing the pin) is a
silent downgrade to no authentication at all, and is the single worst mistake available in this
protocol.

**[CARRIED]** — the harness generates certificates to exactly this profile
(`harness/sharedmic_protocol/tls.py`), and `test_tls.py::test_session_works_over_tls_with_matching_pin`
proves a certificate of this shape completes a TLS 1.3 handshake and pins successfully end to end.
But no test asserts the *curve*, the *SAN's presence*, or the *validity window* individually, and
none could show that a Swift client on a different TLS stack accepts it — that is exactly the
interoperability risk this table exists to reduce, and it stays unproven until Phase 1 runs a real
Swift client against a real Windows agent.

### 11.4 Authentication rate limiting

**Failed authentication MUST be rate-limited: after 5 consecutive failed attempts, the Windows
agent MUST refuse further attempts for 30 seconds.** A "failed attempt" is any connection that
reaches §6 and does not produce a verified `HELLO` — a wrong `mac`, a malformed or non-`HELLO`
message, or the 5-second pre-auth deadline expiring. The lockout is counted per Windows agent, not
per source address; an attacker choosing source ports freely must not be able to reset it.

Without this, §6 is an unthrottled HMAC verification oracle reachable by anything that can open a
TCP connection to the listener, and the 256-bit token's strength is doing all the work against an
attacker who can guess at line rate. The listener is bound to private interfaces only (§2), which
narrows exposure but does not remove it — a compromised device on the same LAN is precisely the
threat model pinning and HMAC exist for. Both UIs should surface the lockout (design spec §8,
"Authentication failure: connection refused, rate-limited, surfaced in both UIs") rather than
failing silently, or the user's experience of a mistyped pairing string is an agent that simply
stops working for 30 seconds.

**[CARRIED]** — nothing in the harness implements or exercises this.
`MockWindowsServer` counts failures in `auth_failures` (asserted by
`test_server.py::test_server_rejects_bad_proof_and_counts_it`) and closes the connection on each
one, but it never locks out, and no test drives six failed attempts. A Phase 1 Windows
implementation MUST implement the limit in full; the harness's willingness to accept unlimited
attempts is a test-double convenience, not the contract.
