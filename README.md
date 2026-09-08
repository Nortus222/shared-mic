# shared-mic

One USB microphone, physically attached to a Windows machine, usable from both Windows and macOS
at the same time — with no hardware switch and no manual device switching.

Microphone audio crosses the network **only** while macOS actually has an application asking for
input. At idle, the transport carries a heartbeat and nothing else: no capture is open on Windows,
and the byte counter reads zero.

## How it works

A Windows agent owns the USB microphone and captures it in WASAPI shared mode, so Windows
applications keep working normally. A macOS menu-bar agent watches Core Audio for processes running
input **on the shared virtual device specifically**, and asks the Windows agent to start streaming
only when one appears. When the last consumer goes away, it waits out a short debounce and stops.

```
USB mic → Windows agent ══ one TLS connection ══ macOS agent → BlackHole → your app
          (WASAPI shared)   control + audio       (demand observer)
```

## Status

**Phase 1 complete: transport and security on both agents. No audio yet** — the Windows agent
(`windows/`, C# / .NET, PR #5) and the macOS agent (`macos/`, Swift, PR #6) pair over TLS 1.3,
authenticate by HMAC challenge-response, and hold a heartbeat-monitored session, verified against
the golden vectors (239 Windows xUnit tests, 170 macOS XCTest, 101 harness tests). A `START`
returns `START_ACK` and streams nothing: no WASAPI capture, no BlackHole render, no demand
detection — those are Phases 2 and 3.

What Phase 0 delivered, and where to start reading:

- [`docs/superpowers/specs/2026-08-08-shared-mic-design.md`](docs/superpowers/specs/2026-08-08-shared-mic-design.md)
  — the full design and phased plan. Start here for *why*.
- [`protocol/protocol-v1.md`](protocol/protocol-v1.md) — the wire contract both platforms implement,
  with golden vectors in [`protocol/vectors/`](protocol/vectors/). Every normative requirement is
  tagged `[VERIFIED]` (a passing harness test asserts it) or `[CARRIED]` (required, but the harness
  does not yet prove it), so the measured/unmeasured boundary is explicit rather than implied.
- [`harness/`](harness/) — a Python reference implementation of the protocol that doubles as a
  conformance test double for both sides of the wire, with a 101-test suite. It is what Phase 1 and
  Phase 2 build against; both Phase 1 agents are developed and tested against it. `harness/README.md` lists its known limitations.
- [`docs/superpowers/probes/`](docs/superpowers/probes/) — the two throwaway probes' findings. The
  macOS demand-detection probe
  ([findings](docs/superpowers/probes/2026-08-08-macos-demand-findings.md)) changed the design: it
  ruled out `kAudioProcessPropertyIsRunningInput` as a demand gate in favour of device-list
  membership, and the owner's follow-up pass over real applications established that BlackHole need
  not be the Mac's system input device. The Windows WASAPI latency probe
  ([findings](docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md)) has now been run by the
  owner on the real Windows host, and changed the design too: it confirmed that Windows applications
  can keep using the microphone while the probe holds it — 20/20 opens with **zero conflicts** while
  Windows Voice Typing was actively using the same mic — and it measured the WASAPI open at
  **78.5 ms p50 / 93.4 ms p95 / 114.1 ms cold**, above the spec's assumed 20–80 ms, which forced the
  activation budget in §6.3 to be recomputed. That is one microphone (Samson Meteorite), one driver,
  one machine, one concurrent application, 20 cycles per run — not a general claim about WASAPI.

## Requirements

- A Windows host with the USB microphone attached, and a Mac on the same LAN
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) installed on the Mac
- macOS 14.4 or later — the design depends on per-process Core Audio device reporting
