# macOS demand-detection findings (Phase 0, spec open question 1)

**Date:** 2026-08-08
**Probe:** `probes/macos-demand/DemandProbe.swift` (throwaway; see its README)
**Question answered:** can macOS report per-process input device usage
precisely enough to scope "someone is recording" detection to one specific
device (BlackHole), instead of only the coarser "some process somewhere is
using some microphone"? If only the coarse signal exists, any unrelated app
touching any mic would start the remote stream and defeat the project's
privacy goal.

## Test machine

- macOS: **26.6.1** (build 25G76), `sw_vers`
- Hardware: Mac Studio (no built-in microphone)
- Swift: 6.3.3 (`swiftc -version`: swift-driver 1.148.6, swiftlang-6.3.3.1.3
  clang-2100.1.1.101), target `arm64-apple-macosx26.0`
- SDK: `xcrun --show-sdk-version` → 26.5
- Installed audio drivers/apps at test time: BlackHole 2ch, ManyCam,
  Microsoft Teams Audio, Parallels Access Sound, Squirrels Audio — exactly
  the clutter that makes device-scoped detection matter here instead of
  being a nicety.
- System default input device at test time was already BlackHole 2ch
  (AudioObjectID 99) — pre-existing machine state from earlier work, not
  something this probe set. The probe never writes
  `kAudioHardwarePropertyDefaultInputDevice`/`DefaultOutputDevice`; it only
  targets an `AudioUnit` instance's `CurrentDevice` property, which is
  local to that unit and does not touch system defaults.

## BlackHole identity

- UID (stable, resolved by): `BlackHole2ch_UID`
- AudioObjectID at test time (session-scoped, **not** stable across
  reboots/device replug — resolve by UID, never cache the ID): `99`

## Full device inventory (`./demand-probe --list-devices`)

```
id     uid                                       name
169    1E6D0777-0000-0000-091E-0104B53C2278       LG HDR 4K
61     1E6D0777-0000-0000-0A1E-0104B53C2278       LG HDR 4K
133    AppleUSBAudioEngine:Other World Computing:OWC Thunderbolt 3 Audio Device:21400000:1 OWC Thunderbolt 3 Audio Device
139    AppleUSBAudioEngine:Other World Computing:OWC Thunderbolt 3 Audio Device:21400000:2 OWC Thunderbolt 3 Audio Device
99     BlackHole2ch_UID                           BlackHole 2ch
127    BuiltInSpeakerDevice                       Mac Studio Speakers
117    MSLoopbackDriverDevice_UID                 Microsoft Teams Audio
145    Someabracadabramagic                       ManyCam Virtual Microphone
167    com.parallels.access.audio.virtual-microphone Parallels Access Sound
162    com.parallels.access.audio.virtual-speaker Parallels Access Sound
148    com.squirrels.SquirrelsLoopbackAudioDriver.Device Squirrels Audio
```

(An earlier revision of `--list-devices` glued long UIDs directly to the
name column with no separating space; fixed in the committed source to
always force at least one space. Raw values were unaffected either way and
were cross-checked with a second ad hoc probe during investigation.)

Supplementary per-device I/O stream check (ad hoc probe, not part of the
committed source, used only to pick a negative-control device):

| id  | name | transport | inStreams | outStreams |
|-----|------|-----------|-----------|------------|
| 169 | LG HDR 4K | displayport | 0 | 1 |
| 61  | LG HDR 4K | displayport | 0 | 1 |
| 133 | OWC Thunderbolt 3 Audio Device (engine 1) | usb | 0 | 1 |
| 139 | OWC Thunderbolt 3 Audio Device (engine 2) | usb | 1 | 0 |
| 99  | BlackHole 2ch | virtual | 1 | 1 |
| 127 | Mac Studio Speakers | built-in | 0 | 1 |
| 117 | Microsoft Teams Audio | virtual | 1 | 1 |
| 145 | ManyCam Virtual Microphone | virtual | 1 | 0 |
| 167 | Parallels Access Sound (mic) | virtual | 1 | 0 |
| 162 | Parallels Access Sound (speaker) | virtual | 0 | 1 |
| 148 | Squirrels Audio | virtual | 1 | 1 |

**No built-in microphone exists on this machine** (Mac Studio Speakers is
output-only; there is no built-in input device at all). This directly
affects Step 4 of the brief, which asked for a built-in-mic false-positive
test — see "Requires the owner" below, and see how the automated
`--self-test` adapted its negative control.

## Baseline snapshot (`./demand-probe`, nothing recording)

```
target device: BlackHole 2ch  uid=BlackHole2ch_UID  id=99
process objects reported: 40
------------------------------------------------------------------------------
  PID    runningInput  onTarget  bundle / input devices
------------------------------------------------------------------------------
------------------------------------------------------------------------------
device-scoped demandCount = 0
```

`process objects reported: 40` confirms the API returns real data to this
unsigned, ad hoc binary — an empty list here would have been a stop-ship
finding per the brief, and it did not happen. `demandCount = 0` with
nothing recording is the expected idle baseline.

## Self-test (headline result): `./demand-probe --self-test`

This is the fully automated core-API check: the probe opens a real input
`AudioUnit` (AUHAL) on BlackHole from within its own process, starts it,
and inspects **its own PID** in the process object list — the normal
reporting path deliberately excludes the probe's own PID from
`demandCount` (so a running probe doesn't count itself as demand); the
self-test bypasses that exclusion because checking its own PID is exactly
the point. It then repeats the same check on a different input device as a
negative control. No audio sample data is ever read (the input callback
never calls `AudioUnitRender`); this only starts/stops the AUHAL I/O cycle.

Because this machine has no built-in microphone, the negative control
falls back (by transport type / stream presence, never by display name) to
the first non-virtual real hardware input device found: the OWC
Thunderbolt 3 Audio Device input (AudioObjectID 139, USB transport).

Full, unedited output:

```
=== self-test: device-scoped demand detection ===
probe PID: 91856
BlackHole: BlackHole 2ch  uid=BlackHole2ch_UID  id=99
negative-control device: OWC Thunderbolt 3 Audio Device  uid=AppleUSBAudioEngine:Other World Computing:OWC Thunderbolt 3 Audio Device:21400000:2  id=139

--- positive test: this process opens input on BlackHole ---
PASS (47ms): pid=91856 runningInput=true, input devices=[99] contains target 99
after stopping BlackHole input: cleared after 45ms

--- negative test: this process opens input on OWC Thunderbolt 3 Audio Device; BlackHole must NOT appear ---
PASS (50ms): pid=91856 runningInput=true, input devices=[139] contains target 139
after stopping negative-control input: cleared after 43ms

=== self-test verdict ===
PASS: kAudioProcessPropertyDevices (input scope) correctly scoped this process's demand to the device actually opened, in both directions.
```

Exit code: `0`. (Run twice during investigation — PIDs and exact millisecond
counts differ between runs as expected since each run is a fresh process;
the pass/fail result and ~35-50ms timing order of magnitude were consistent
both times.)

### What this proves

- `kAudioHardwarePropertyProcessObjectList` and `kAudioProcessPropertyDevices`
  (input scope) are present and functional on macOS 26.6.1, an unsigned ad
  hoc Swift binary can read them, and they update within tens of
  milliseconds of a real AUHAL input stream starting/stopping.
- **Positive case:** a process running input on BlackHole is reported with
  `IsRunningInput = true` and BlackHole's `AudioObjectID` present in its
  input-scope device list.
- **Negative case:** the same process, running input on a *different*
  device, does **not** list BlackHole — the API correctly scopes to the
  device actually in use, not just "this process has a mic open somewhere."
  This is the exact assumption the whole force-on/demand-detection design
  rests on, and it held.
- State clears quickly (~35 ms) after the stream stops, which matters for
  Phase 3's decision on debounce/hangover timing.
- No microphone-permission prompt blocked or delayed either AudioUnit
  start; both `AudioOutputUnitStart` calls returned `noErr` immediately.

### What this does NOT prove, and what remains unverified

- **TCC/permission behavior is unconfirmed, not "clean."** The self-test
  ran without any visible permission dialog and without being blocked, but
  this shell's parent process may already hold microphone TCC approval
  from earlier, unrelated work on this machine (the probe cannot read
  `TCC.db` to confirm — that query itself failed with "authorization
  denied" when attempted). It is **not verified** that a signed app bundle
  launched fresh, or an unsigned CLI binary run from a terminal with no
  prior grant, behaves the same way. Phase 1 must still implement
  `NSMicrophoneUsageDescription` and real TCC handling and test it from a
  clean permission state — do not treat this probe's clean run as proof
  the permission flow is solved.
- **Only this probe's own process was tested.** The self-test proves the
  OS-level mechanism works for a process this probe controls end-to-end. It
  does *not* prove that real third-party applications (Dictation, Chrome,
  ChatGPT desktop, Zoom, Teams) go through Core Audio in a way that
  populates the same properties identically — some apps use lower-level or
  vendor-specific audio paths that could, in principle, behave differently.
  That is exactly the untestable-without-a-human part; see below.
- **No built-in mic on this hardware.** The negative control used a
  different but present device (OWC Thunderbolt 3 Audio Device) rather
  than "the built-in mic" as the brief's Step 4 literally specifies. The
  mechanism tested (device-scoped input reporting) is the same either way,
  but this is a deviation from the literal brief and is called out
  explicitly here rather than silently substituted.
- **Single-machine, single-run result.** Not run across a reboot, across
  BlackHole reinstallation, or on other Mac hardware/macOS versions.

## Requires the owner

The following matrix from the brief's Step 4 needs a human clicking
through real applications with a microphone attached, and was **not**
run — there is no way to automate speaking into Dictation, granting a
Chrome site mic access, or joining a Zoom/Teams call from this agent.
Do not read anything into this table; it is blank because it was not
measured, not because it passed.

| Application | `runningInput` | `onTarget` (BlackHole) | appear latency | clear latency |
|---|---|---|---|---|
| macOS Dictation | not measured | not measured | not measured | not measured |
| Chrome (site requesting mic) | not measured | not measured | not measured | not measured |
| ChatGPT (voice mode) | not measured | not measured | not measured | not measured |
| Zoom or Teams | not measured | not measured | not measured | not measured |
| Any app with **built-in mic** selected (false-positive check) | not measured | not measured | n/a | n/a |

### Exact steps for the owner to run this

1. Build the probe if not already built:
   ```sh
   cd probes/macos-demand
   swiftc -O -o demand-probe DemandProbe.swift
   ```
2. Open **System Settings → Sound → Input** and select **BlackHole 2ch**.
3. In one terminal, run:
   ```sh
   ./demand-probe --watch
   ```
   Leave it running; it prints a fresh snapshot every 500 ms.
4. For each application in turn (Dictation, Chrome with a site that
   requests mic access, ChatGPT desktop voice mode, Zoom/Teams):
   a. Start audio input in that application (e.g. press the Dictation
      shortcut, click "Allow" on a Chrome mic prompt, start a ChatGPT
      voice session, join/unmute in Zoom or Teams).
   b. Watch the terminal. Note the PID/bundle ID that appears, whether
      `runningInput` shows `yes`, whether `onTarget` shows `YES`, and
      roughly how many `--watch` cycles (× 500 ms) elapsed between
      starting input and the row appearing.
   c. Stop input in the application (release the Dictation shortcut, stop
      the Chrome tab's mic use, end the ChatGPT voice turn, mute/leave the
      call). Note how many cycles elapse before the row disappears or
      `runningInput` flips back to `no`.
   d. Record all four cells in the table above for that application.
5. Repeat the whole pass with **System Settings → Sound → Input** set to
   the Mac's built-in microphone if this hardware has one (this test
   machine, a Mac Studio, does not — the owner should run this leg on
   hardware that does, e.g. a MacBook). Confirm `onTarget` stays `-` and
   `device-scoped demandCount` stays `0` for every application tested.
   This is the false-positive check and per the brief is the single most
   important measurement remaining in Phase 0.
6. Fill in the table above (or a copy of it) with real numbers, and update
   the verdict below if any application disagrees with the automated
   self-test result.

## Verdict

**Yes — device-scoped demand detection works on this machine, based on
what was actually measured.** The automated `--self-test` demonstrates,
with a real AUHAL input stream and no human involvement, that
`kAudioProcessPropertyDevices` (input scope) correctly reports which
specific device a process is recording from, both positively (BlackHole
appears when BlackHole is open) and negatively (BlackHole does not appear
when a different device is open). `kAudioHardwarePropertyProcessObjectList`
returns real data (40 process objects) to an unsigned ad hoc binary, so
code signing is not a blocker for reading this API. State transitions
resolve in tens of milliseconds.

**What remains unverified and must not be treated as settled:**
1. Whether real target applications (Dictation, Chrome, ChatGPT, Zoom/Teams)
   go through Core Audio in a way that populates these same properties —
   the "Requires the owner" matrix above is empty and needs a human pass.
2. TCC/microphone-permission behavior for a freshly-launched, signed Phase
   1 app bundle — this run's clean pass-through is not proof the
   permission flow is solved; it may reflect a pre-existing grant on this
   machine that a fresh install would not have.
3. The false-positive (built-in mic) leg specifically, since this test
   machine has no built-in microphone; the automated self-test substituted
   a different real hardware input device and the negative result held for
   that substitution, but the literal "built-in mic" case per the brief is
   still open.

Recommendation for Phase 3: proceed with device-scoped detection as the
primary mechanism — the core OS API demonstrably supports it — but do not
close spec open question 1 until the owner completes the per-application
matrix above. If any of Dictation/Chrome/ChatGPT/Zoom/Teams disagrees with
this probe's finding, that application needs the force-on hold as a
fallback; nothing observed so far requires it, but nothing observed so far
rules it out either.
