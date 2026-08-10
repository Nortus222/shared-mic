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

### Owner instructions: switching the system input device headlessly

The manual `--watch` matrix requires changing the Mac's system input
device. **Do that from the command line, not from System Settings.**
`switchaudio-osx` is installed for this (`brew install switchaudio-osx`):

```sh
SwitchAudioSource -c -t input                    # read the current input device
SwitchAudioSource -t input -s "BlackHole 2ch"    # set it, headlessly
```

This is not a convenience. Opening **System Settings → Sound** puts
`com.apple.Sound-Settings.extension` in the Core Audio process list holding
whatever the current default input is; with BlackHole selected, that
produced a persistent `demandCount = 1` false positive during the owner's
pass -- an artifact created purely by the act of measuring. Keeping the
Sound pane closed keeps that process out of the picture entirely.

Note that `SwitchAudioSource -s` selects by **display name**. That is fine
for an interactive measurement, but it is not how the shipping agent
resolves devices -- the design requires UID-only resolution, and so does
this probe.

The full owner procedure, the results collected so far, and what is still
unmeasured live in
`docs/superpowers/probes/2026-08-08-macos-demand-findings.md`
("Real applications, measured by the owner" and "Requires the owner").

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

### Important finding: gate on device-list membership, not on `kAudioProcessPropertyIsRunningInput`

**Every demand check in this probe (`report()`, `--watch`, and all four
`--self-test` legs) is gated on device-list membership, not on
`IsRunningInput`.** The reason is that device-list membership
(`kAudioProcessPropertyDevices`, input scope) was correct in every case
observed -- self-introspective, negative control, cross-process, repeat
activations, and the owner's manual pass over three real applications --
and it is correct regardless of how `IsRunningInput` behaves.
`runningInput`/`runningGeneral` are still read and printed for visibility,
and the self-test flags `runningInput=false despite device-list
membership` inline whenever it occurs, but they gate no pass/fail decision
and no `demandCount`.

What was observed about `IsRunningInput`, and its limits:

- **In this probe's synthetic cycles**, which dispose the
  `AudioComponentInstance` and build a fresh one for every activation, it
  read `false` at the instant device-list membership was independently
  confirmed `true` on a second-and-later activation -- both
  self-introspectively and cross-process.
- **In Raycast**, a real long-lived application observed by the owner with
  `--watch`, it read `yes` on every activation, including the second,
  third and fourth activation of the same process. **The synthetic result
  does not generalise to that application.**

So do not read this section as "the flag is broken past first activation."
It is not uniform across client shapes, which is precisely why the gate
does not use it. See the findings doc
(`docs/superpowers/probes/2026-08-08-macos-demand-findings.md`) for the
full writeup, including the instance-reuse hypothesis and the controlled
measurement that would settle it, which has not been run.

## Known limitations

- Only automatable checks are covered by `--self-test`. Whether *specific
  real applications* report the same way requires a human clicking through
  them with `--watch` running. The owner has done this for **Raycast**,
  **System Settings' Sound extension** and **Safari/WebKit**; macOS
  Dictation, Chrome/Chromium, the ChatGPT desktop app, Zoom and Teams
  remain untested, as do appear/clear latencies for any real application.
  See the findings doc's "Requires the owner" section for exact steps.
  Note that BlackHole does **not** have to be the system input device for
  an application to be observed on it -- Raycast targets BlackHole
  explicitly -- and the shipping design recommends that it is not.
- Devices are always resolved by UID, never by display name. BlackHole is
  matched against its known UID forms (`BlackHole2ch_UID`,
  `BlackHole16ch_UID`, `BlackHole64ch_UID`); if none of those are present
  the probe fails with a clear message listing what it did find, rather
  than falling back to a name match.
- The probe never changes the Mac's default input or output device; it
  only opens private AudioUnits (in its own process, or in short-lived
  helper processes it spawns and tears down) and disposes them before
  exiting.
