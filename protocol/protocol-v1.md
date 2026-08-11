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
- **"Private interfaces" is a concrete address set, not a judgement call.** An interface qualifies
  if the address being bound is in one of: IPv4 RFC 1918 (`10.0.0.0/8`, `172.16.0.0/12`,
  `192.168.0.0/16`), IPv4 loopback (`127.0.0.0/8`), IPv4 link-local (`169.254.0.0/16`), IPv6
  loopback (`::1/128`), IPv6 link-local (`fe80::/10`), or IPv6 unique-local (`fc00::/7`). Every
  other address — a globally routable IPv4 or IPv6 address, or a carrier-grade NAT address
  (`100.64.0.0/10`) — MUST NOT be bound. **Binding a wildcard address (`0.0.0.0` or `::`) does not
  satisfy this rule**, because a wildcard bind covers every interface including public ones; an
  implementation MUST enumerate the host's interfaces and bind the qualifying addresses
  individually. This set is stated because "private" otherwise resolves differently in two
  implementations, and the side that resolves it more loosely is the one that exposes the listener.
  **[CARRIED]** — `MockWindowsServer` binds `127.0.0.1` by default, which is inside the set but
  exercises none of the rest of it; nothing in the harness enumerates interfaces or rejects a
  public address.
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

**Implementation note (macOS / `Network.framework`): a rejected pin does not surface as an error,
and the default behavior is to retry forever.** This is the one place where an implementer can
believe they have built the hard stop above and have in fact built an indefinite retry loop against
a peer that may be an attacker. When the `sec_protocol_options_set_verify_block` callback answers
`false`, `NWConnection` does **not** transition to `.failed`. It transitions to
**`.waiting(-9808: "bad certificate format")`** and keeps retrying on its own schedule, with no
further call into the verify block and no terminal event. Two consequences are normative for a
macOS implementation:

- **A connection state that merely *waits* MUST be treated as terminal for a pin failure.** After
  the verify block has refused a certificate, the implementation MUST cancel the connection on the
  first `.waiting` it observes rather than letting `Network.framework` retry. Waiting for `.failed`
  is waiting for an event that never arrives, and the retry loop it leaves running is exactly the
  automatic recovery the bullet above forbids.
- **The refusal reason MUST be recorded out of band, because the transport will not carry it.**
  `-9808` (`errSSLBadCert`) says nothing about pinning — the same code covers unrelated certificate
  problems — so the reason the verify block said no MUST be stored by the verify block itself (for
  example in a lock-protected property on the transport, read by the `.waiting` handler) rather
  than reconstructed from the `NWError`. An implementation that infers "pin mismatch" from `-9808`
  will misreport unrelated certificate failures as attacks and vice versa.

`URLSession` and other stacks surface a rejected trust evaluation differently; the requirement that
a pin failure is terminal and explicable applies to all of them, and this note names the API and
the error code because on `Network.framework` specifically the failure is silent.
**[CARRIED]** — the Python harness's client is a `ssl`-module socket client that raises
`FingerprintMismatch` synchronously out of `connect()`, so nothing here is or can be exercised by
`test_tls.py`; this note describes a platform behavior the harness has no way to model.

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

**Coverage gap — the mock will pass a receiver that is wrong about this.** The harness is the
conformance oracle for both platforms, and on this specific rule it is a lax one: because
`decode_audio_payload` accepts any payload of 12 bytes or more, a receiver that also accepts a
1,000-byte or a 5,000-byte `AUDIO` payload will exchange audio with the mock indefinitely and never
fail a test. Nothing on the Python side will tell an implementer that their receiver is too
permissive. **Test the exact-1,932-byte check locally**, with a unit test that feeds the decoder a
short payload, an over-long payload, and an exactly-1,932-byte payload and asserts the first two
are rejected as protocol violations (§3: close the connection) and only the third is accepted. Do
not treat a green run against the harness as evidence on this point.

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

**`clientId` is a display label and is explicitly untrusted.** It arrives before anything has been
verified, from a peer that has proved nothing, and it is trivially forgeable. Windows MUST NOT use
it to select which paired device's token to check (§6 verifies against every stored token in turn —
there is no lookup by identifier), MUST NOT use it to grant, scope, or deny anything, and MUST NOT
let it override the identity the HMAC proof establishes. Its only legitimate uses are logging and
diagnostics, and even there it should be rendered as what the peer *claimed* rather than as who the
peer *is*. If Windows shows a name for a connected Mac in its UI, that name MUST come from the
paired-device list entry the proof matched (§11.1), not from this field.

This is stated at length because `clientId` is exactly the field an implementer reaches for when
multiple Macs are paired and something needs to tell them apart. It cannot do that job. The
verified token is the identity; `clientId` is decoration.

**[CARRIED]** — nothing in the harness exercises this. `MockWindowsServer` never reads `clientId`
at all (it is required to be *present* by `control.py`'s `REQUIRED_FIELDS` and is otherwise
ignored), so a Windows implementation that trusted the field completely would still pass every
test.

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

**Defined `reason` values.** Two are defined by this document:

- `MIC_UNAVAILABLE` — the microphone is absent or cannot be opened (§7).
- `SESSION_IN_USE` — the microphone is present and working, but **another paired Mac holds the
  active session** (§7). This is a "busy", not a fault: nothing is broken, and the request may
  succeed later without any user action on the Windows side.

A receiver MUST accept a `reason` string it does not recognise and treat it as a generic refusal
rather than as a protocol violation — `reason` is an open string, and refusing to parse an unknown
value would turn a future reason code into a dropped connection. **[CARRIED]** — no test sends an
unrecognised reason.

**Optional field: `holderName` (string).** When `reason` is `SESSION_IN_USE`, Windows SHOULD
include `holderName`, carrying the friendly name of the paired device that currently holds the
session, taken from the paired-device list (§11.1), so the requesting Mac can tell its user *which*
machine has the microphone rather than only that something does.

`holderName` is **advisory and non-authoritative**. It is a user-chosen label, not an identity: it
may be stale, may be empty, may be identical to another paired device's name, and is not
authenticated in any way by the receiving Mac. A Mac MUST NOT use it for any purpose other than
displaying it to the user — not to route, not to key state, not to decide whether to retry.

`holderName` is **not** a required field, and both its presence and its absence are well-formed:

- A `START_NACK` **without** `holderName` MUST be accepted normally. §5's "missing a required field
  is a protocol violation" rule covers only the required fields listed above. When it is absent or
  empty — Windows has no name for the holder, has chosen not to disclose one, or is an
  implementation that predates this field — the Mac MUST still surface the refusal to the user with
  generic wording ("another paired Mac is using the microphone"), and MUST NOT infer anything from
  the absence: not a different severity, not a different retry policy, and above all not a guess at
  the holder's identity assembled from `clientId` values or addresses it has seen elsewhere.
- A `START_NACK` **carrying** `holderName` MUST NOT be rejected for carrying it. This is also true
  of a `START_NACK` carrying `holderName` alongside some other `reason`; the field is simply
  ignored where it is not meaningful.

```json
{"v":1,"type":"START_NACK","requestId":"req-0002","reason":"SESSION_IN_USE","holderName":"Ihor's MacBook Pro"}
```

**[CARRIED]** — none of this is exercised. `MockWindowsServer` emits exactly one `START_NACK`
shape, `{requestId, reason: "MIC_UNAVAILABLE"}`, and has no paired-device list to draw a name from;
`control.py` neither requires nor rejects extra fields, so the codec accepts `holderName` without
knowing it exists. The `START_NACK` case in `protocol/vectors/control-messages.json` carries no
`holderName` and stays byte-exact (§10) — the optional field does not change any committed vector.

### STOP

Direction: Mac → Windows. Ends the active audio session.

Required fields: `requestId` (string, echoed in `STOP_ACK`), `sessionId` (string — the session
being stopped).

`sessionId` is required in the sense that the field MUST be present; it is not required to be
non-empty. **A client that holds no session identifier — it never started one, or a previous `STOP`
already ended it, or it reconnected and does not know whether its earlier `START` landed — MUST
send `sessionId` as the empty string `""`.** The empty string satisfies "present"; omitting the
field entirely is a missing required field and therefore a protocol violation (§5, above). This is
the only case where the empty string is a legal `sessionId`, and it exists so that the idle `STOP`
that §7 requires to succeed has a well-defined encoding rather than each implementation inventing
one. **[VERIFIED]** that the empty string is accepted: `MockMacClient.stop_session()` sends
`self._session_id or ""`, so `test_loopback.py::test_stop_without_start_succeeds` puts a
`STOP` carrying `"sessionId": ""` on a live connection and requires a `STOP_ACK` back — a server
that rejected the empty string would fail that test. **[CARRIED]** that a client MUST choose the
empty string rather than some other filler; nothing forces that choice from the far end.

```json
{"v":1,"type":"STOP","requestId":"req-0003","sessionId":"sess-0001"}
```

### STOP_ACK

Direction: Windows → Mac. Confirms the session has ended and audio has stopped.

Required fields: `requestId` (string, matches the triggering `STOP`), `sessionId` (string — the
session that was ended).

**When no session was active, "the session that was ended" has no referent, so the server echoes
the request.** The rule is: if a session was active, `STOP_ACK.sessionId` is that session's
identifier — which may differ from the `sessionId` the client sent, since §7 does not reject a
`STOP` on `sessionId` mismatch. If no session was active, `STOP_ACK.sessionId` MUST be the
`sessionId` field of the `STOP` being answered, echoed verbatim, which is the empty string `""` for
a client that held no session. The server never synthesizes an identifier and never omits the
field. A client MUST NOT treat a `STOP_ACK` as unmatched because its `sessionId` differs from the
one it sent — `requestId` is what matches a reply to its request.

**[CARRIED]** — this is what the reference does (`MockWindowsServer._handle`'s `STOP` branch sends
`"sessionId": ended or msg["sessionId"]`: the ended session if there was one, the request's value
otherwise), and `test_loopback.py::test_duplicate_stop_succeeds` and `test_stop_without_start_succeeds`
both drive the no-session path — but neither reads the returned `sessionId`. `MockMacClient.stop_session()`
awaits a `STOP_ACK` and never compares its `sessionId` to anything, so a server that returned a
synthesized identifier here would pass the whole suite. The contract matches the reference's code,
not a test.

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

**`active` describes the host, not the recipient.** With more than one Mac paired (§11.1) there is
still exactly one session (§7), so `active` reports whether *that* session — the host's single
microphone session, whoever holds it — is currently streaming. A Mac MUST NOT read `active: true`
as "I hold the session". A Mac holds a session only if it received a `START_ACK` it has not since
ended, and it MUST track that itself; `active: true` on a connection that never started one means
some *other* paired Mac is streaming.

This protocol has no "the microphone is free now" notification. Windows is not required to send
`STATUS` when a session starts or ends, and a Mac refused with `START_NACK{SESSION_IN_USE}` (§5)
therefore learns that the microphone became available only by issuing another `START` when its own
demand signal says to. Do not build a Mac that waits for a push that this contract never promised.
**[CARRIED]** — the reference sends `STATUS` on mic presence changes only, and its `active` value
is derived per connection because each of its connections owns an independent session (§7's
coverage gap); no test observes `STATUS` on one connection while a different connection streams.

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

### A well-formed control message arriving in the wrong direction

The `Direction:` line on each type above is a statement about which peer sends it, not a
validation rule the receiver enforces. **A control message that is well-formed for its type — the
`"v"` is `1`, the `"type"` is one of the eleven, every required field for that type is present —
but that arrives in the direction opposite to the one listed, and after authentication has
completed, MUST be ignored silently.** The receiver does not reply to it, does not treat it as a
protocol violation, and MUST NOT close the connection. Examples: a `GREETING` or a `START_ACK`
reaching Windows from the Mac; a `START` or a `HELLO` reaching the Mac from Windows.

This is deliberately more forgiving than the rest of the document, and the reason is that a
disagreement here costs a working connection over a message that changes nothing. Two rules
nearby are unaffected and still close the connection: a message whose `"type"` is not one of the
eleven, or that is missing a required field, or whose `"v"` is not `1`, is a protocol violation
(§1, §5, §3); and an `AUDIO` frame from the Mac is a protocol violation at any point in the
connection's lifetime (§6). Pre-authentication is also unaffected — before a verified `HELLO`,
anything that is not `HELLO` closes the connection (§6). This rule governs only the
post-authentication, well-formed, wrong-direction case.

**[CARRIED]** — the reference implements exactly this on both sides, but no test drives it.
`MockWindowsServer._handle` is an `if`/`elif` chain over `PING`/`START`/`STOP` with no `else`, so
any other well-formed type falls through and is dropped. `MockMacClient._reader_loop` routes
`STATUS` to its own queue and everything else to `_control_in`, where `_await()` discards any
message that is not the reply it is waiting for. Neither side counts or reports the message; an
implementation that logs and counts it instead is conformant and is the better choice for
diagnosability.

---

## 6. Handshake

Every new TCP connection, immediately after the TLS handshake completes and before any `START`,
`STOP`, `PING`, or `STATUS` is sent or accepted, runs this exchange:

1. **Windows sends `GREETING{serverId, nonce}`.** `nonce` is freshly random per connection (32
   bytes, lowercase hex) — never reused across connections. **[VERIFIED]** —
   `test_server.py::test_server_greets_with_a_nonce`, `test_server.py::test_server_issues_nonce_per_connection`.
2. **The Mac replies `HELLO{clientId, mac}`**, where
   `mac = lowercase_hex(HMAC-SHA256(token, nonce))`. `token` is the 256-bit pairing secret issued
   to *this* Mac when it was paired (§11.1; §7.1 of the design spec); `nonce` is the raw 32 bytes
   decoded from the `GREETING`'s hex `nonce` field (HMAC is computed over the raw bytes, not over
   the hex string). **The token itself never crosses the wire** — only this per-connection proof
   does, and the fresh nonce means a captured proof cannot be replayed against a future connection.
   **[VERIFIED]** — `test_auth.py`'s `auth_proof`/`verify_proof` tests plus
   `test_client.py::test_connect_completes_handshake` and
   `test_server.py::test_server_accepts_valid_proof` for the end-to-end exchange.
3. **Windows verifies `mac` against every paired device's token in turn.** For each entry in the
   paired-device list (§11.1), Windows computes the same HMAC over that entry's `token` and the
   `nonce` it sent, and compares in constant time. **The first entry that matches identifies the
   device**, and Windows replies `HELLO_ACK` (§5); the connection is now authenticated *as that
   device*, and the friendly name Windows shows for this connection is that entry's name. If no
   stored token matches, Windows closes the connection without replying. There is no lookup step
   and no identifier to look up by: `HELLO` carries nothing Windows can trust before verification
   (see `clientId`, §5), so trial verification over the list is the whole mechanism. The list is
   small — a household's worth of Macs — and the cost is a handful of HMAC-SHA256 computations per
   connection attempt. **[VERIFIED]** for the single-token case —
   `test_server.py::test_server_rejects_bad_proof_and_counts_it`,
   `test_client.py::test_wrong_token_fails_to_connect`. **[CARRIED]** for trial verification over
   several tokens: `MockWindowsServer` holds exactly one `token` and calls `verify_proof` against
   it once, so nothing in the harness has a list to iterate.

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

**A second Mac connecting while one is already authenticated.** More than one Mac may be paired
(§11.1), and **Windows MUST serve every authenticated connection concurrently.** A newly
authenticated connection does not displace an older one: Windows MUST NOT close, silence, or
otherwise degrade a live authenticated connection because another device authenticated, and each
connection independently exchanges `START`/`STOP`/`PING`/`STATUS` for as long as it stays open.

What is exclusive is the *microphone*, not the connection. There is one microphone, so **at most
one active session exists across all connections at any moment** (§7), and the collision between
two Macs that both want it is resolved there — by refusing the second one's `START` with
`START_NACK{requestId, reason: "SESSION_IN_USE"}` (§5) — not by tearing down a connection.

**An earlier revision of this document specified the opposite, and that rule is withdrawn.** It
read: "a Windows agent MUST serve at most one authenticated Mac at a time, and a newly
authenticated connection supersedes the older one." **Supersession MUST NOT be implemented.** It is
named here rather than deleted silently because a Windows agent built from a stale copy of this
section would disconnect whichever Mac connected first every time another paired Mac woke up, and
the symptom — Macs mysteriously dropping each other — would be read as a network fault rather than
as a contract violation.

One property of the withdrawn rule is retained in a different form: an *unauthenticated* peer can
still affect nothing. It holds no session, receives no `STATUS`, and cannot influence any other
connection; a peer that opens a connection and sends nothing until the 5-second deadline simply
gets closed (above).

**[CARRIED]. The reference matches the connection half of this rule and contradicts the session
half — do not take the harness's behavior as the contract here.** `MockWindowsServer` calls
`listen(4)` and spawns an independent `_ServerSession` thread per accepted connection, so it does
serve authenticated connections concurrently and never supersedes. But each of those sessions has
its own `_session_id` and its own audio loop with no coordination between them: two authenticated
clients would both get `START_ACK`s and both receive audio, which §7 forbids. That is a test-double
property — the harness has no physical microphone to contend over — not a statement about the
protocol. No harness test drives two authenticated clients at once; see §7's coverage gap.

---

## 7. Session lifecycle

`START` and `STOP` are the only session control messages, and both are **idempotent**:

- **A duplicate `START` from the connection that already holds the session** (i.e. a second `START`
  arrives on that connection before any `STOP`) does not start a second session. Windows returns
  `START_ACK` carrying the **existing** `sessionId` and format — it does not reset the audio
  `sequence` counter or restart capture. This is what makes it safe for the Mac to retry `START`
  after a reconnect without first knowing whether the previous `START` actually landed. A `START`
  arriving on a *different* connection while a session is active is not a duplicate and is not
  idempotent; it is refused with `START_NACK{SESSION_IN_USE}` (below).
- **A duplicate `STOP` while idle** (i.e. a `STOP` arrives with no session active, whether because
  none was ever started or because a previous `STOP` already ended it) still succeeds: Windows
  replies `STOP_ACK`. The `sessionId` in a `STOP` sent with no session active MAY be an empty
  string or a stale value from a previous session — Windows does not reject `STOP` on `sessionId`
  mismatch; `STOP` always means "make sure no session is active" for the current connection, not
  "end specifically this session ID".

  **"For the current connection" is load-bearing now that several Macs may be connected.** A `STOP`
  ends a session only if the connection it arrived on is the one that holds it. A `STOP` from any
  other connection — whatever `sessionId` it carries, including the identifier of the session
  another device actually holds — MUST NOT stop capture, MUST NOT end that session, and MUST NOT
  disturb the holder in any way; Windows replies `STOP_ACK` (there was nothing of that connection's
  to end, so the idle-`STOP` rule applies unchanged) and does nothing else. Otherwise any paired
  Mac could end any other paired Mac's session with one message.

  This is not in tension with §5 listing `sessionId` as a required field on `STOP` and `STOP_ACK`.
  Required means **present**, not non-empty. A client holding no session identifier sends
  `"sessionId": ""` — omitting the field is still a protocol violation — and Windows answers a
  `STOP` that ended nothing with `STOP_ACK` carrying the request's `sessionId` echoed verbatim
  (so `""` for that client). If a session *was* active, `STOP_ACK` carries the identifier of the
  session that actually ended, which need not equal the one the client sent. §5's `STOP` and
  `STOP_ACK` entries state the same rule from the field's side.

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

**One session, many connections.** Several paired Macs (§11.1) may be connected and authenticated at the same time (§6). **At most one
active microphone session exists across all of them.** The session is a property of the Windows
agent, not of a connection — there is one microphone — and it is *held by* exactly one connection at
a time. Six requirements follow, and all six are **[CARRIED]**; see the coverage gap below.

1. **Exclusivity.** Windows MUST NOT have two sessions active at once, and MUST NOT stream `AUDIO`
   frames on two connections at once. A connection that holds no session MUST receive zero audio
   bytes, exactly as an idle connection does today.
2. **Refusal, not queueing or preemption.** A `START` arriving on a connection while a *different*
   connection holds the session MUST be answered with
   `START_NACK{requestId, reason: "SESSION_IN_USE"}` (§5), immediately. Windows MUST NOT queue the
   request to be granted when the microphone frees up, MUST NOT preempt the holder, and MUST NOT
   grant on some notion of priority. The refusal SHOULD carry `holderName` so the requesting Mac can
   name the machine that has it (§5). The requesting Mac's own demand signal decides whether and
   when to try again.
3. **Ownership.** The session belongs to the connection that received its `START_ACK`. Only that
   connection can end it by request, and only its `STOP` is answered with the session's real
   `sessionId`. `sessionId` is not a capability: possessing or guessing another connection's
   `sessionId` grants nothing (see the `STOP` rule above).
4. **A session ends when its control connection closes — not only on `STOP`.** This is a hard
   requirement, not a cleanup nicety. Whenever the connection holding the session goes away for any
   reason — a clean TLS/TCP close, a reset, a TLS failure, the Mac's process exiting, the Mac
   sleeping, or Windows itself closing the connection for a protocol violation (§3, §5, §6) —
   Windows MUST stop capture, discard the queued audio for that session (§9's
   `audio_frames_discarded`), and release the microphone, **at the moment it observes the close**.
   No `STOP` will arrive and none is required; `STOP_ACK` is not sent to a closed connection.
   Without this rule a Mac that crashes or drops mid-session locks every other paired Mac out —
   `START_NACK{SESSION_IN_USE}` for a holder that no longer exists — until the 45-second dead-peer
   timer (§8) eventually fires. The 45-second timer is the backstop for the case where the socket
   stays open but the peer is gone; it is not the mechanism for the ordinary case, and an
   implementation that releases the session only on that timer is not conformant.
5. **Dead-peer detection ends that peer's session too.** When Windows declares a connection dead
   under §8's 45-second silence rule, it MUST release that connection's session by the same path as
   (4) before or as it closes the connection. A dead peer that still nominally holds the microphone
   is the same lockout, arrived at more slowly.
6. **Release is complete, and the next `START` starts a genuinely new session.** Once released, the
   microphone is available to any authenticated connection, first `START` served. That `START` gets
   a fresh `sessionId` and a `sequence` counter starting at `0` (§4) — the new holder inherits
   nothing from the old one, and MUST NOT be sent frames left over from it.

**Coverage gap — the conformance harness cannot catch a multi-device implementation bug, of any
kind, in any of this.** This is the largest such gap in the document and it is worth being blunt
about, because a Phase 1 implementer's instinct is to treat a green harness run as evidence:

- **There is no paired-device list.** `MockWindowsServer` is constructed with a single `token` and
  verifies every `HELLO` against that one value (`verify_proof(self._server._token, ...)`). It has
  no friendly names, no `pairedAt`, and nothing to revoke. A Windows agent that supports exactly one
  paired device passes the whole suite.
- **`clientId` is never read.** Nothing in the harness would notice an implementation that used it
  as an identity (§5).
- **Every connection gets its own independent session.** Each accepted connection runs its own
  `_ServerSession` with its own `_session_id` and its own `_audio_loop`, and there is no shared
  session state anywhere in `server.py`. `sessions_started` counts across connections but gates
  nothing. Two authenticated clients would both receive `START_ACK` and both receive audio — so the
  mock actively models the behavior requirement (1) forbids, and `START_NACK{SESSION_IN_USE}` is a
  message the reference server can never emit.
- **No test opens two authenticated connections at once.** Not one. Every loopback test drives a
  single `MockMacClient`.

The consequence, stated plainly: **an implementation that gets all of this wrong — one shared
token, `clientId` as identity, unlimited concurrent sessions, sessions that outlive their
connections — still passes the conformance suite with 101 green tests.** Test it locally instead.
The tests worth writing are: two paired devices, each authenticating with its own token, and a
third token that authenticates as nothing; one device revoked while the other keeps working; a
second device's `START` refused with `SESSION_IN_USE` while the first streams; a `STOP` from a
non-holder leaving the holder's audio uninterrupted; and — the one that matters most — the holder's
socket killed without a `STOP`, followed by a successful `START` from the other device *immediately*,
not 45 seconds later.

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
`START_ACK`, never after the corresponding `STOP_ACK` has been sent, and never on a connection that
does not hold the session. This is the protocol-level expression of the project's core privacy
requirement: audio crosses the wire only while a session is explicitly active, and an idle
connection MUST carry zero audio bytes. With several Macs connected, every connection except the
one holding the session is an idle connection by this definition, and the zero-bytes rule applies to
each of them individually.

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
| `PING` interval | 15 s | Mac only — `PING` is Mac → Windows (§5), and Windows never sends one | Windows replies `PONG` immediately | **[CARRIED]** |
| Peer dead (Mac) | 45 s without a `PONG` (three missed heartbeats) | Mac, watching for replies to the `PING`s it sent | Declare the connection dead; treat any session it held as ended; close it and begin reconnect | **[CARRIED]** |
| Peer dead (Windows) | 45 s of silence — no complete frame of any type received | Windows, watching the connection, not any one message type | Declare the connection dead; **release that connection's session if it held one** (§7); close it and keep accepting connections | **[CARRIED]** |
| Pre-auth (`HELLO`) deadline | 5 s | Windows, per new connection | Close the connection; see §6 | **[VERIFIED]** |

**The dead-peer rule is asymmetric, because the heartbeat is.** §5 defines `PING` as Mac → Windows
only, so "45 s without a `PONG`" has no referent on the Windows side — Windows sends no `PING` and
therefore has no `PONG` to miss. The two halves are:

- **The Mac** sends `PING` every 15 s and declares the peer dead after 45 s with no `PONG`. Its
  timer is driven by the heartbeat it owns.
- **Windows** declares the peer dead after 45 s of *silence*: no complete frame of any type
  decoded from the connection in that window. The timer resets on every completely decoded frame —
  a `PING`, a `START`, a `STOP`, anything — not only on the `PING`s the Mac is expected to send.
  Resetting on a *complete* frame rather than on received bytes is deliberate: a peer dribbling a
  partial envelope forever must not be able to hold the connection open.

The 45 s value is the same on both sides; only the thing being timed differs. A Windows
implementation that literally waits for a `PONG` will never fire its timer and will hold dead
connections open indefinitely.

**With several Macs paired, the Windows dead-peer timer also holds the microphone hostage, and that
raises its stakes.** A dead connection that still owns the session blocks every other paired Mac
with `START_NACK{SESSION_IN_USE}` (§7) for as long as it is believed alive, so expiry MUST release
the session, not merely close the socket — that is what the table's "release that connection's
session" means. Note the ordering this implies with §7's rule that a session ends when its
connection closes: an ordinary crash, sleep, or process exit closes the socket, and Windows sees
that immediately, so the microphone is free in milliseconds. This timer covers only the case where
no close is observable — a Mac that vanished off the network, a wedged process holding the socket
open — and 45 s of one Mac blocking the others is the accepted cost of that residual case. It is
not the normal path, and an implementation that lets it become the normal path (by releasing the
session only here) has turned a millisecond handover into a 45-second one.

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

**Coverage gap — every row of this table except the last is invisible to the conformance harness.**
This is the one section of the document with no `[VERIFIED]` timing behavior at all, and the
practical consequence is worth stating plainly: **an implementation whose heartbeat interval, 45 s
dead-peer window, 2 s `START` timeout, or 1 s `STOP` timeout is simply wrong — off by an order of
magnitude, or absent — will pass the entire harness suite.** The mock answers every `START`,
`STOP`, and `PING` promptly, so no timeout is ever reached; and no clock or timer loop exists
anywhere in `server.py` or `client.py` for a wrong value to disagree with. A green run against the
harness is evidence about bytes on the wire and about session semantics; it is no evidence at all
about timing.

**Test these locally, with an injected clock.** Each timer belongs in a unit test that drives time
forward under the implementation's control rather than sleeping — a fake or virtual clock the test
advances — and asserts the timer fires at the specified value and does not fire before it. Testing
them by waiting in wall time makes the suite slow enough that the tests get deleted, which is how a
timer silently reverts to whatever the platform's default was. The §6 pre-auth deadline is the
model to copy: the harness test for it exists precisely because `MockWindowsServer` accepts an
injected short `hello_timeout` instead of paying the real 5 seconds.

The heartbeat is deliberately slow (15 s) — it exists to keep connection-alive UI state honest and
NAT/firewall state fresh, not to detect a dead peer quickly. When it actually matters — a session
is being requested — the 2-second `START` timeout detects a dead or non-responding peer far faster
than any practical heartbeat interval would.

---

## 9. Send priority

A single TCP/TLS connection carries both control and audio, so the sender needs a rule for what
goes on the wire first when both are pending. **Both queues and both rules below are per
connection**, not per agent: with several Macs connected (§6) each connection has its own control
queue and its own 25-frame audio ring, and only the connection holding the session ever has audio
to put in one (§7). The rule:

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

### 11.1 The paired-device list and its tokens

A pairing token is **32 bytes (256 bits) from a cryptographically secure random source**. It is the
HMAC key in §6 step 2, and it never crosses the wire in any form. **[VERIFIED]** —
`test_auth.py::test_token_is_256_bits`, `test_tokens_are_not_repeated`.

**Windows maintains a list of paired devices, not a single token.** More than one Mac may be
paired. Each entry in the list holds, at minimum:

| Field | Value |
|---|---|
| `token` | 32 bytes from a CSPRNG, **generated fresh for this device** at the moment it is paired |
| Friendly name | A short human-readable label for the device, shown in the tray (design spec §11) and sent as `holderName` in `START_NACK{SESSION_IN_USE}` (§5). Chosen by the user or defaulted by Windows; not unique, not an identifier |
| Paired-at | The timestamp at which the entry was created, so the tray can show the list in a meaningful order and an unrecognised entry can be reasoned about |

The rules on that list are **[CARRIED]** in full — the harness has no list at all (see §7's coverage
gap):

- **A fresh token per device.** Pairing a second Mac MUST generate a new 32-byte token; it MUST NOT
  hand out the first device's token, and MUST NOT derive one device's token from another's.
  Re-pairing an existing device issues it a new token and leaves every other entry untouched.
- **No lookup key, because there is nothing to look up by.** The list is not indexed by anything
  the wire carries. `HELLO` arrives before any verification and its `clientId` is untrusted (§5);
  the *only* way a device is identified is by which stored token verifies its proof (§6 step 3).
  An implementation that stores a device identifier and uses it to pick a token has built an
  authentication bypass, because the peer chooses that identifier.
- **Individually revocable.** Removing one entry MUST NOT invalidate, rotate, or otherwise affect
  any other entry's token — every other paired Mac keeps connecting with no user action. Revoking
  an entry MUST also close any live connection authenticated against it, and MUST release that
  connection's session if it held one (§7), so revocation takes effect immediately rather than at
  that device's next reconnect.
- **Tokens are secrets at rest.** Every token in the list MUST be stored with at least the same
  protection as the certificate private key (§11.3 — DPAPI on a real Windows agent). A list of
  256-bit keys in plaintext on disk is the same failure as one 256-bit key in plaintext on disk,
  multiplied.
- **The certificate is per host, not per device.** §11.3's self-signed certificate is generated
  once at first run and served on every connection; every paired Mac pins the same fingerprint.
  Pairing a second Mac MUST NOT regenerate it — doing so would break the first Mac's pin and, by
  §2, present it with the one failure mode that means an active attacker.

### 11.2 The pairing string

The token is shown to the user, and typed by the user, as a **pairing string**. Its encoding is
fully specified here; do not infer it from either implementation.

**Multiple paired devices do not change this format in any way.** Each device is paired with its
own token (§11.1), and that token is displayed and typed using exactly the encoding below — the same
58-character shape, the same alphabet, the same tolerant decode. In particular the pairing string
carries **no device identifier, no index into the paired-device list, and no checksum or prefix that
would let Windows tell which device a typed string belongs to.** It is 32 bytes of secret and
nothing else. That is deliberate: the string is the whole credential, and adding a lookup key to it
would create exactly the untrusted-identifier path §6 step 3 exists to avoid. Windows learns which
device is connecting by trial verification, never by parsing something a peer supplied.

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
| Validity | `notBefore` = 5 minutes before generation (to absorb clock skew); `notAfter` = 3,650 days (10 years) after generation. See the note below — the window is 3,650 days *plus* 5 minutes |
| Chain | None. There is no CA and no intermediate; the chain is one certificate long |

**On the validity window.** "3,650 days, starting 5 minutes in the past" is ambiguous between two
readings — a 3,650-day span shifted 5 minutes earlier, and a span of 3,650 days plus 5 minutes —
and the two differ in where `notAfter` lands. The contract means the second: both endpoints are
computed from the moment of generation, `notBefore = now - 5 minutes` and
`notAfter = now + 3650 days`, so the certificate is valid for 3,650 days and 5 minutes in total.
The 5 minutes exists only to keep a client whose clock is slightly behind the Windows host from
rejecting a certificate generated moments ago; it is not meant to shorten the 10-year life. A test
asserting the window should allow slack rather than an exact equality against 3,650 days.
**[CARRIED]** — `harness/sharedmic_protocol/tls.py` builds exactly this
(`.not_valid_before(now - timedelta(minutes=5))`, `.not_valid_after(now + timedelta(days=CERT_VALIDITY_DAYS))`),
but no test reads either field.

**The SAN is not decorative and MUST be present.** The client disables both CA verification and
hostname verification (§2 — the pin is the check), but several TLS stacks a Swift client is likely
to use — `URLSession` and `SecTrustEvaluate`-based paths among them — evaluate the certificate
before handing it to a custom trust callback, and some reject a certificate with no SAN at that
earlier stage, producing a failure that looks like a network error rather than a certificate
problem. Emit the SAN even though nothing in this protocol matches a hostname against it.

Be precise about the evidence for that, because this document has been read as claiming more than
it can support: **on `Network.framework` with a `sec_protocol_options_set_verify_block`, the
pre-callback evaluation stage does not run, so a SAN-less certificate would not fail there** — the
risk described above does not materialise on the one path Phase 1 actually verified. The
requirement stands anyway, and is not weakened: it is load-bearing on the other stacks, an
implementation may switch stacks, and a certificate that only works under one client's trust
configuration is a trap for the next one. Emit the SAN. Just do not implement it in the belief that
`Network.framework` is where it will bite you.

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

**One connection is one attempt, however many tokens were tried.** §6 step 3 verifies a `HELLO`'s
proof against every entry in the paired-device list (§11.1), so a connection that fails to
authenticate has failed *n* HMAC comparisons. That is still exactly **one** failed attempt for this
counter. An implementation that increments per token tried would lock a household with five paired
Macs out after a single mistyped pairing string, and the lockout would tighten as more devices were
paired. Likewise, a successful authentication by *any* paired device resets the count to `0`; the
count is a property of the agent, not of a device. **[CARRIED]** — `MockWindowsServer` increments
`auth_failures` once per failed connection, which is the right granularity, but it has one token
and never locks out, so nothing exercises the multi-token case.

**The lockout resets the failure count; it does not extend.** Applying the lockout sets the
consecutive-failure count back to `0`, and connections arriving during the 30-second window are
refused *without being counted as failures* — so a peer hammering the listener gets a series of
fixed 30-second lockouts (5 attempts, 30 s, 5 attempts, 30 s, …) rather than one window that grows
without bound. A single successful authentication also resets the count to `0`; that is what
"consecutive" means. This is stated because both readings satisfy the `MUST` above and two
implementations that chose differently would disagree observably — a user who mistypes their
pairing string five times must get their agent back after 30 seconds, not be locked out for longer
each time they retry. **[CARRIED]** — see the coverage note below; nothing in the harness
implements a lockout, so nothing exercises either reading.

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
