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

Opens a real input AudioUnit (AUHAL) on BlackHole from *within the probe
process itself*, starts it, and then checks the probe's **own PID** in the
process object list: does it show `IsRunningInput = true`, and does its
`kAudioProcessPropertyDevices` (input scope) list contain BlackHole's
`AudioObjectID`? It then repeats the same check against a second,
different input-capable device (the negative control -- built-in mic if one
exists, otherwise any other real input device present) and confirms
BlackHole does **not** appear in that case.

This machine has no built-in microphone (Mac Studio), so the negative
control automatically falls back to the first non-virtual (real hardware)
input device it finds, currently the OWC Thunderbolt 3 Audio Device input.
Device selection is always by transport type / stream presence, never by
display name.

The self-test's input callback never touches the captured sample buffer --
it doesn't call `AudioUnitRender` at all -- so no audio is ever read,
copied, or written anywhere. It only needs the AUHAL's I/O cycle running
long enough for Core Audio to register this process as an active input
client.

`--self-test` intentionally does **not** exclude the probe's own PID from
its checks (the default/`--watch` modes do exclude it, so the probe
watching itself doesn't inflate demand counts in normal use).

## Known limitations

- Only automatable checks are covered here. Whether *specific real
  applications* (macOS Dictation, Chrome, ChatGPT desktop, Zoom/Teams)
  report the same way requires a human clicking through them with
  `--watch` running and BlackHole selected as the system input device --
  see the findings doc's "Requires the owner" section for exact steps.
- Devices are always resolved by UID/AudioObjectID, never by display name.
- The probe never changes the Mac's default input or output device; it
  only opens a private AudioUnit in its own process during `--self-test`
  and disposes it before exiting.
