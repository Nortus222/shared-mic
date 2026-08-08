# macOS demand-detection probe

Throwaway probe for Phase 0 / spec open question 1: does macOS report
per-process **input device usage** precisely enough to scope "someone is
recording" detection to one specific device (BlackHole), rather than only
"some process somewhere is recording on some microphone"?

This directory is not built by CI and is not part of the shipping product.
The durable output is
`docs/superpowers/probes/2026-08-08-macos-demand-findings.md`; this source
is expected to rot once Phase 3 either builds on its findings or replaces
this exploration with production code.

## Build

```sh
cd probes/macos-demand
swiftc -O -o demand-probe DemandProbe.swift
```

Requires Swift 6+ / an SDK with macOS 14.4+ headers (for
`kAudioProcessPropertyDevices` and `kAudioHardwarePropertyProcessObjectList`).
Check with `xcrun --show-sdk-version` if the build fails to resolve those
symbols.

The compiled `demand-probe` binary is gitignored; only the source is
committed.

## Run

```sh
./demand-probe                # one snapshot: which processes are recording,
                               # and whether they're on BlackHole
./demand-probe --watch        # same, polled twice a second, Ctrl-C to stop
./demand-probe --list-devices # full Core Audio device inventory (id/uid/name)
./demand-probe --self-test    # fully automated core-API check, no human needed
```

### `--self-test`

Four legs, all fully automated, no human involved:

1. **Self-introspection positive (BlackHole)**, run twice back to back: once
   checked via the full-sweep path (`kAudioHardwarePropertyProcessObjectList`
   enumeration, the same mechanism `report()`/`--watch` use), once via
   `kAudioHardwarePropertyTranslatePIDToProcessObject` (a targeted lookup
   that skips the enumeration sweep). Both measure how long it takes for
   the probe's own PID to show BlackHole's `AudioObjectID` in its
   `kAudioProcessPropertyDevices` (input scope) list after starting a real
   AUHAL input stream on BlackHole, and back to absent after stopping it.
   Both numbers are reported so the enumeration-sweep overhead can be seen
   directly against the isolated propagation-latency figure.
2. **Self-introspection negative control**: the same process opens a
   *different* input-capable device (built-in mic if one exists, otherwise
   the first non-virtual/real-hardware input device found -- this machine,
   a Mac Studio, has no built-in mic) and confirms BlackHole does **not**
   appear in its device list.
3. **Cross-process test**: spawns a genuinely separate helper process
   (a re-exec of this same binary with a hidden internal flag) that opens
   BlackHole, observed from the parent via the normal full-sweep path --
   this is the actual production shape (an agent watching *other*
   processes), which legs 1-2 alone do not exercise.
4. **Repeat-activation reliability**: a second, separate helper process
   opens and fully closes BlackHole *twice* in a row. Both activations must
   be independently detected by the parent.

All device selection (BlackHole, the negative control, the true built-in
mic if present) is by UID / transport type / stream presence -- never by
display name.

The self-test's input callback never touches the captured sample buffer --
it doesn't call `AudioUnitRender` at all -- so no audio is ever read,
copied, or written anywhere. It only needs the AUHAL's I/O cycle running
long enough for Core Audio to register the process as an active input
client.

`--self-test` intentionally does **not** exclude the probe's own PID from
its checks in legs 1-2 (the default/`--watch` modes do exclude the
probe's own PID, so the probe watching itself doesn't inflate demand
counts in normal use). Legs 3-4 don't need that exclusion at all since
they observe genuinely separate helper processes.

### Important finding: `kAudioProcessPropertyIsRunningInput` is not reliable across repeat activations

While building leg 4, this probe found that `kAudioProcessPropertyIsRunningInput`
correctly reports `true` only for a process's **first** input-stream
activation in its lifetime -- it silently stays `false` on the second,
third, ... activation, even while the process is actively streaming from
the device. This was confirmed both via self-introspection (multiple AUHAL
open/close cycles in the probe's own process) and cross-process (a
separate helper process doing repeat cycles, observed externally).
`kAudioProcessPropertyDevices` (input-scope device-list membership) and
the general, non-input-scoped `kAudioProcessPropertyIsRunning` were both
found to re-trigger correctly on every cycle tested.

Because of this, **every demand check in this probe (`report()`,
`--watch`, and all four `--self-test` legs) is gated on device-list
membership, not on `IsRunningInput`.** `runningInput`/`runningGeneral` are
still read and printed for visibility -- and the self-test explicitly
flags `runningInput=false despite device-list membership` inline whenever
it recurs -- but they no longer gate any pass/fail decision or
`demandCount`. See the findings doc for the full writeup; this is the
single most important finding to come out of this probe and directly
affects Phase 3's design: **do not gate demand detection on
`IsRunningInput` alone.**

## Known limitations

- Only automatable checks are covered here. Whether *specific real
  applications* (macOS Dictation, Chrome, ChatGPT desktop, Zoom/Teams)
  report the same way requires a human clicking through them with
  `--watch` running and BlackHole selected as the system input device --
  see the findings doc's "Requires the owner" section for exact steps.
- Devices are always resolved by UID, never by display name. BlackHole is
  matched against its known UID forms (`BlackHole2ch_UID`,
  `BlackHole16ch_UID`, `BlackHole64ch_UID`); if none of those are present
  the probe fails with a clear message listing what it did find, rather
  than falling back to a name match.
- The probe never changes the Mac's default input or output device; it
  only opens private AudioUnits (in its own process, or in short-lived
  helper processes it spawns and tears down) and disposes them before
  exiting.
