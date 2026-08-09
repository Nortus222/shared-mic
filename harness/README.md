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
  codec, auth, TLS pinning (including the hard-stop-on-mismatch
  behavior), the mock server and client individually, an end-to-end
  loopback suite that proves the zero-idle-bytes invariant, and golden
  vector byte-matching.
- **`tools/generate_vectors.py`** — regenerates `protocol/vectors/*.json`
  from this implementation.

The wire contract itself — every message, timer, and byte layout — is
documented in `protocol/protocol-v1.md`. This harness is that document
made executable and testable.

## Install

Requires Python >= 3.11 (see `pyproject.toml`). From `harness/`:

```sh
python -m pip install -e '.[dev]'
```

On a machine with no `python`/`pip3` with a prebuilt `cryptography` wheel
available, expect the `cryptography` dependency to build from source,
which can take several minutes. Once a virtualenv has it installed,
reuse that virtualenv rather than creating a new one or reinstalling.

## Run the tests

```sh
python -m pytest -v
```

All 96 tests should pass. This includes 26 golden-vector cases
(`tests/test_vectors.py`) that byte-match the reference implementation's
output against `protocol/vectors/*.json`, plus the framing, control,
auth, TLS, mock-server, mock-client, and end-to-end loopback suites.

If `python -m pytest` on your `PATH` isn't the interpreter you installed
into (for example, the system `python3` has no `pytest` and there is no
bare `python`), invoke the virtualenv's interpreter explicitly instead of
relying on `PATH` or activation:

```sh
.venv/bin/python -m pytest -v
```

## Regenerate the golden vectors

The vectors in `protocol/vectors/` are the contract: a Windows or macOS
implementation that produces different bytes for the same message is
wrong. Regenerating them is a deliberate act, not a routine one — see
`protocol/protocol-v1.md` §10 (Conformance) for why the audio vectors in
particular should not be casually regenerated (they are meant to pin the
reference implementation's output, not chase it).

```sh
python tools/generate_vectors.py
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
  `ControlConnection`/session code. `MockMacClient` speaks the full
  client side of the protocol — `HELLO`, `START`/`STOP`, sequence-gap
  tracking on incoming audio, fingerprint pinning — so the Windows agent
  can be exercised exactly as the real Mac client will exercise it,
  without a Mac present.
- **Building the macOS agent (Phase 1–2):** run `MockWindowsServer`
  against the real Mac `ControlClient`/`SessionController` code.
  `MockWindowsServer` speaks the full server side — `GREETING`, auth
  verification, `START_ACK`/`START_NACK`, the bounded 25-frame
  (500 ms) audio send queue with oldest-frame-drop on overflow, idle
  silence — so the macOS agent can be developed and its zero-idle-bytes
  behavior verified without a Windows host present.
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
