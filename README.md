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

Design approved; implementation not started. See
[`docs/superpowers/specs/2026-08-08-shared-mic-design.md`](docs/superpowers/specs/2026-08-08-shared-mic-design.md)
for the full design and phased plan.

## Requirements

- A Windows host with the USB microphone attached, and a Mac on the same LAN
- [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole) installed on the Mac
- macOS 14.4 or later — the design depends on per-process Core Audio device reporting
