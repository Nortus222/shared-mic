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

**Phase 0 complete: protocol and probes. No product code yet** — neither platform agent exists, and
Phase 1 creates those projects.

What Phase 0 delivered, and where to start reading:

- [`docs/superpowers/specs/2026-08-08-shared-mic-design.md`](docs/superpowers/specs/2026-08-08-shared-mic-design.md)
  — the full design and phased plan. Start here for *why*.
- [`protocol/protocol-v1.md`](protocol/protocol-v1.md) — the wire contract both platforms implement,
  with golden vectors in [`protocol/vectors/`](protocol/vectors/). Every normative requirement is
  tagged `[VERIFIED]` (a passing harness test asserts it) or `[CARRIED]` (required, but the harness
  does not yet prove it), so the measured/unmeasured boundary is explicit rather than implied.
- [`harness/`](harness/) — a Python reference implementation of the protocol that doubles as a
  conformance test double for both sides of the wire, with a 101-test suite. It is what Phase 1 and
  Phase 2 build against before either agent exists. `harness/README.md` lists its known limitations.
- [`docs/superpowers/probes/`](docs/superpowers/probes/) — the two throwaway probes' findings. The
  macOS demand-detection probe
  ([findings](docs/superpowers/probes/2026-08-08-macos-demand-findings.md)) changed the design: it
  ruled out `kAudioProcessPropertyIsRunningInput` as a demand gate in favour of device-list
  membership, and the owner's follow-up pass over real applications established that BlackHole need
  not be the Mac's system input device. The Windows WASAPI latency probe
  ([findings](docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md)) is written but has not
  been run — this repository has no Windows machine.

## Requirements

- A Windows host with the USB microphone attached, and a Mac on the same LAN
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) installed on the Mac
- macOS 14.4 or later — the design depends on per-process Core Audio device reporting
