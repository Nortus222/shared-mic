# Protocol harness

This is the Phase 0 deliverable: a reference implementation of
`protocol/protocol-v1.md` plus a conformance test double for both sides of
the wire. It is not throwaway code, and it is not either platform agent —
it is what Phase 1 and Phase 2 build against before either the Windows or
the macOS agent exists.

Three things live here:

- **`sharedmic_protocol/`** — the reference implementation: envelope
  framing (`framing.py`), control-message JSON codec (`control.py`),
  synthetic audio frame generation (`audio.py`), the auth handshake
  primitives (`auth.py`, HMAC-SHA256 challenge/response), TLS 1.3 with
  certificate-fingerprint pinning (`tls.py`), and the two mock agents
  (`server.py`'s `MockWindowsServer`, `client.py`'s `MockMacClient`).
- **`tests/`** — the conformance suite: framing round-trips, control
  codec, auth (including the pairing-string encoding), TLS pinning
  (including the hard-stop-on-mismatch behavior), the mock server and
  client individually, an end-to-end loopback suite that proves the
  zero-idle-bytes invariant and the mic hot-unplug `STATUS` path, and
  golden vector byte-matching.
- **`tools/generate_vectors.py`** — regenerates `protocol/vectors/*.json`
  from this implementation.

The wire contract itself — every message, timer, and byte layout — is
documented in `protocol/protocol-v1.md`. This harness is that document
made executable and testable.

## Install

Requires Python >= 3.11 (see `pyproject.toml`). From `harness/`:

```sh
.venv/bin/python -m pip install -e '.[dev]'
```

**Use the virtualenv's interpreter explicitly, as above, rather than
relying on `PATH` or on activation.** On this machine there is no bare
`python` on `PATH` at all, and the system `python3` has no `pytest`
installed — a plain `python -m pytest` fails outright. Every command in
this file is written that way for that reason.

On a machine that has no `.venv/` yet, create one first with
`python3 -m venv .venv`, then run the command above. On this machine
`.venv/` already exists and already has everything installed — reuse it.

If a prebuilt `cryptography` wheel is not available for your platform and
Python version, expect that dependency to build from source, which takes
several minutes. Once a virtualenv has it installed, reuse that
virtualenv rather than creating a new one or reinstalling.

## Run the tests

```sh
.venv/bin/python -m pytest -v
```

All 101 tests should pass, in roughly 8 seconds. That total includes 26
golden-vector test cases (`tests/test_vectors.py`) covering the 14
committed vectors — 11 control messages encoded, the same 11 decoded, 3
audio frames encoded, and one check that the vector files exist at all —
which byte-match the reference implementation's output against
`protocol/vectors/*.json`. The rest are the framing, control, auth, TLS,
mock-server, mock-client, and end-to-end loopback suites.

## Regenerate the golden vectors

The vectors in `protocol/vectors/` are the contract: a Windows or macOS
implementation that produces different bytes for the same message is
wrong. Regenerating them is a deliberate act, not a routine one — see
`protocol/protocol-v1.md` §10 (Conformance) for why the audio vectors in
particular should not be casually regenerated (they are meant to pin the
reference implementation's output, not chase it).

```sh
.venv/bin/python tools/generate_vectors.py
```

This overwrites `protocol/vectors/control-messages.json` and
`protocol/vectors/audio-frames.json`. Review the diff before committing —
an unexpected change means either the reference implementation changed on
purpose (update the vectors and say so in the commit message) or by
accident (fix the implementation instead).

## How Phase 1 and Phase 2 use this

The whole point of writing the harness before either platform agent is
that the Windows and macOS implementations can be built and tested
against each other's *simulated* half without both machines being in the
room.

- **Building the Windows agent (Phase 1–2):** run `MockMacClient` (or a
  small test script that drives it) against the real Windows
  `ControlConnection`/session code. `MockMacClient` covers the client
  side of every message type in the protocol — `HELLO`, `START`/`STOP`,
  `PING`, receiving unsolicited `STATUS`, sequence-gap tracking on
  incoming audio, fingerprint pinning — so the Windows agent can be
  exercised much as the real Mac client will exercise it, without a Mac
  present. It is not a complete Mac agent: see **Known limitations**
  below for what it deliberately does not do.
- **Building the macOS agent (Phase 1–2):** run `MockWindowsServer`
  against the real Mac `ControlClient`/`SessionController` code.
  `MockWindowsServer` covers the server side of every message type —
  `GREETING`, auth verification, `START_ACK`/`START_NACK`, `PONG`,
  unsolicited `STATUS` on mic hot-unplug/replug (drive it with
  `set_mic_present()`), the bounded 25-frame (500 ms) audio send queue
  with oldest-frame-drop on overflow, idle silence — so the macOS agent
  can be developed and its zero-idle-bytes and `DEGRADED` behavior
  verified without a Windows host present.
- Both mocks generate synthetic audio via `audio.sine_frame` rather than
  touching a real microphone, and both track counters (frames sent/
  received, sequence gaps, dropped frames) instead of logging payload,
  matching the "never log or persist audio" rule the real agents must
  also follow.
- Either side's protocol conformance can be checked independently: point
  a candidate implementation at the mock for the *other* side and reuse
  (or adapt) the assertions in `tests/test_loopback.py`, particularly
  `test_no_audio_before_start` and `test_audio_flows_only_between_start_and_stop`,
  which are the executable form of the project's core privacy guarantee.

## Known limitations

These are deliberate scope lines, not bugs. Read them before assuming a
behavior is covered — `protocol/protocol-v1.md` tags every requirement
`[VERIFIED]` or `[CARRIED]` for the same reason, and `[CARRIED]` means
"this harness does not prove it."

- **No timers run.** There is no 15 s heartbeat loop, no 45 s dead-peer
  reaper, and no enforcement of the 2 s `START` / 1 s `STOP` response
  timeouts — those values are default *parameters* on the client's
  reply-wait helpers, and nothing ever lets a request go unanswered to
  prove a timeout fires. The 5 s pre-auth deadline is the one timer that
  is implemented and tested. Both real agents must implement all of them
  (protocol-v1.md §8).
- **No authentication rate limiting.** `MockWindowsServer` counts
  failures in `auth_failures` and closes the connection each time, but
  accepts unlimited attempts. The 5-attempt/30 s lockout the contract
  requires (protocol-v1.md §11.4) is unimplemented here.
- **Receivers are more permissive than the contract.**
  `decode_audio_payload` accepts any payload of at least 12 bytes rather
  than requiring exactly 1,932 (protocol-v1.md §4), and neither mock is
  driven with a bad envelope `type` byte or an oversized `length` over a
  live socket, so the close-on-violation rules in §3 are implemented but
  not proven end to end.
- **`MockMacClient._await()` discards control messages that are not the
  reply it is waiting for.** `STATUS` is routed around this by its own
  queue (`wait_for_status()`, `drain_status()`,
  `status_messages_received`) precisely because it is unsolicited, but
  any *new* unsolicited message type added later would be silently
  dropped unless given the same treatment.
- **Audio is a synthetic sine wave**, generated by `audio.sine_frame`;
  no microphone is ever opened, on either side.

## Known Phase 1 cleanup

`server.py` and `client.py` each carry their own copy of the same
`select()`-poll / `recv()` / incremental-`decode_frame()` loop — roughly
50 lines duplicated, with the same subtle handling of `ValueError` from
`select()` on a concurrently-closed fd. Extracting a shared
`FrameReader` would remove the duplication and give that tricky logic
one place to live and one place to be tested.

This was deliberately **not** done in Phase 0: it is a refactor of
working, reviewed, green code at the end of a phase, and the regression
risk outweighed the benefit at that moment. It is a good first task in
Phase 1, while the suite is green and before either platform agent
depends on the mocks' internals.
