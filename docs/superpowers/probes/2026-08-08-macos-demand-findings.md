# macOS demand-detection findings (Phase 0, spec open question 1)

**Date:** 2026-08-08 (updated same day: fix round 1 after coordinator
review, then again after the owner ran the real-application matrix by hand
with `--watch` — see "Real applications, measured by the owner" below,
which also narrows the scope of finding 2)
**Probe:** `probes/macos-demand/DemandProbe.swift` (throwaway; see its README)
**Question answered:** can macOS report per-process input device usage
precisely enough to scope "someone is recording" detection to one specific
device (BlackHole), instead of only the coarser "some process somewhere is
using some microphone"? If only the coarse signal exists, any unrelated app
touching any mic would start the remote stream and defeat the project's
privacy goal.

## Headline: two findings, not one

1. **Device-scoped detection works.** `kAudioProcessPropertyDevices`
   (input scope) correctly reports which specific device a process has
   open, both for a process observing itself and for a genuinely separate
   process observed externally, including a false-positive check and a
   corroborating argument against "it's just reporting the system
   default" (see below).

2. **But do not gate detection on `kAudioProcessPropertyIsRunningInput`.**
   During this round of fixes, `--self-test` was extended to check a
   process's *second* activation (open BlackHole, close it, open it
   again), and found that in the probe's synthetic activation cycles,
   `IsRunningInput` reads `false` at the moment device-list membership is
   first confirmed true -- i.e. the two properties disagree at that
   instant, self-introspectively and cross-process, and independent of
   whether the property is read via full enumeration or via
   `kAudioHardwarePropertyTranslatePIDToProcessObject`.
   (A stronger claim -- that `IsRunningInput` stays `false` for the
   *entire* duration of the second-and-later synthetic activation, not just
   at the single sampled instant the committed self-test checks -- was also
   observed, repeatedly, using throwaway diagnostic scripts built during
   investigation; those are not part of the committed source, so treat
   that stronger version as investigation notes, not as something the
   committed probe itself proves. See "What this does NOT prove" below for
   the leading hypothesis about *why*.) `kAudioProcessPropertyDevices`
   (device-list membership) and the general, non-input-scoped
   `kAudioProcessPropertyIsRunning` were both found to re-trigger correctly
   on every activation tested.

   **How far that synthetic result reaches — narrowed by the owner's later
   real-application pass.** Every activation this probe performs disposes
   the previous `AudioComponentInstance` and constructs a brand-new one.
   Raycast, a real and long-lived application (PID 759, started 2026-08-07
   and confirmed by `ps` never to have restarted across any of the owner's
   `--watch` sessions), read `runningInput = yes` on **every** activation
   the owner observed, including the second, third and fourth activation of
   that same process. **The synthetic result therefore does not generalise
   to that application.** It stands as measured for the shape the probe
   exercises — dispose-and-recreate per activation — and it is positive
   evidence for the instance-reuse hypothesis recorded under "What this
   does NOT prove" below, i.e. that the behaviour is scoped to fresh
   `AudioComponentInstance`s rather than to a process's activation history.
   No claim is made here about how the flag behaves in real applications
   generally: one real application was observed, and it disagreed with the
   synthetic result.

   **The design decision is unchanged, and it does not depend on the
   synthetic result generalising.** Gate demand detection on device-list
   membership. That predicate was correct for every process and every
   device observed anywhere in this document — synthetic and real, first
   activation and repeat, self-introspective and cross-process — and it is
   correct whether or not `IsRunningInput` turns out to be reliable. Adding
   `IsRunningInput` as a required conjunct buys nothing that device-list
   membership does not already give, and would make the gate depend on a
   flag whose behaviour is demonstrably not uniform across client shapes
   (`false` in this probe's dispose-and-recreate cycles, `yes` in Raycast).
   The probe gates everything -- `report()`, `--watch`, and all
   `--self-test` legs -- on device-list membership, and this is re-verified
   below (leg 4). **Phase 3 must gate demand detection on
   `kAudioProcessPropertyDevices` (input-scope) membership. `IsRunningInput`
   may be read and displayed as a diagnostic; it must not be a required
   conjunct.**

## Test machine

- macOS: **26.6.1** (build 25G76), `sw_vers`
- Hardware: Mac Studio (no built-in microphone)
- Swift: 6.3.3 (`swiftc -version`: swift-driver 1.148.6, swiftlang-6.3.3.1.3
  clang-2100.1.1.101), target `arm64-apple-macosx26.0`
- SDK: `xcrun --show-sdk-version` → 26.5
- Installed audio drivers/apps at test time: BlackHole 2ch, ManyCam,
  Microsoft Teams Audio, Parallels Access Sound, Squirrels Audio — exactly
  the clutter that makes device-scoped detection matter here rather than
  being a nicety.
- System default input device at test time was already BlackHole 2ch
  (AudioObjectID 99) — pre-existing machine state from earlier work, not
  something this probe set (see the corroboration note under leg 2 below
  for why this incidentally strengthens one of the results). The probe
  never writes `kAudioHardwarePropertyDefaultInputDevice`/
  `DefaultOutputDevice`; it only targets an `AudioUnit` instance's
  `CurrentDevice` property, which is local to that unit and does not touch
  system defaults.

## BlackHole identity

- UID (matched exactly, never by display name):
  `BlackHole2ch_UID` (the probe also recognizes `BlackHole16ch_UID` and
  `BlackHole64ch_UID` for other BlackHole channel-count variants, though
  only the 2ch device is installed on this machine)
- AudioObjectID at test time (session-scoped, **not** stable across
  reboots/device replug — resolve by UID, never cache the ID): `99`

Fix note: an earlier version of the probe matched `$0.uid.contains("BlackHole")
|| $0.name.contains("BlackHole")`, which included a display-name fallback
in violation of this task's "resolve by UID, never display name"
constraint (the UID branch happened to always match first on this
machine, so it never actually misfired, but the code did not do what it
claimed). The lookup is now UID-only against the three known BlackHole UID
forms, and fails with a clear message listing all devices found (by name
*and* UID, for debugging) if none match.

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
`--self-test` adapted its negative control to the OWC Thunderbolt 3 Audio
Device input (id 139, USB transport, real hardware, distinct from
BlackHole's virtual transport).

## Baseline snapshot (`./demand-probe`, nothing recording)

```
target device: BlackHole 2ch  uid=BlackHole2ch_UID  id=99
process objects reported: 40
------------------------------------------------------------------------------
  PID    runningInput  onTarget  bundle / input devices
------------------------------------------------------------------------------
device-scoped demandCount = 0  (gated on device-list membership, not on runningInput -- see findings doc)
```

`process objects reported: 40` confirms the API returns real data to this
unsigned, ad hoc binary. `demandCount = 0` with nothing recording is the
expected idle baseline. (The trailing note on `demandCount` was added
after the `IsRunningInput` finding below; the gating logic itself changed,
the reported baseline value did not.)

## Self-test: four legs, all automated

`--self-test` now runs four legs:

1. **Self-introspection positive (BlackHole)**, twice: once timed via the
   full-sweep path (same mechanism as `report()`/`--watch`), once via
   `kAudioHardwarePropertyTranslatePIDToProcessObject` (a targeted,
   single-object lookup). Both must detect BlackHole in the probe's own
   input-device list; the two timings are reported side by side.
2. **Self-introspection negative control**: the same process opens the
   OWC Thunderbolt 3 Audio Device instead; BlackHole must not appear.
3. **Cross-process test**: a genuinely separate helper process (spawned
   via `Process`, a re-exec of the same binary with a hidden internal
   flag) opens BlackHole; the parent observes it via the normal
   full-sweep path used by `report()`/`--watch`. This is the actual
   production shape — an agent watching *other* processes, which legs 1-2
   alone never exercise (they only ever check the probe's own PID).
4. **Repeat-activation reliability**: a second, separate helper process
   opens and fully closes BlackHole *twice*. Both activations must be
   independently detected by the parent. This leg is what surfaced the
   `IsRunningInput` finding above.

All detection in every leg (and in `report()`/`--watch`) is gated on
device-list membership, not on `IsRunningInput` — see the headline finding.
`runningInput`/`runningGeneral` (the general, non-scoped
`kAudioProcessPropertyIsRunning`) are still read and printed for
visibility, and the self-test prints an explicit inline note whenever
`runningInput` disagrees with device-list membership.

Full, unedited output of `./demand-probe --self-test` (run twice for
reproducibility; both runs below):

```
=== self-test: device-scoped demand detection ===
probe PID: 99909
BlackHole: BlackHole 2ch  uid=BlackHole2ch_UID  id=99
system default input device id: 99 (== BlackHole -- see negative-control corroboration note below)
negative-control device: OWC Thunderbolt 3 Audio Device  uid=AppleUSBAudioEngine:Other World Computing:OWC Thunderbolt 3 Audio Device:21400000:2  id=139

--- leg 1: self-introspection positive (BlackHole) -- full-sweep vs targeted timing ---
  [full-sweep] PASS (58ms): pid=99909 input devices=[99] contains target 99 (runningInput=true, runningGeneral=true)
  [full-sweep] after stopping: cleared after 58ms
  [targeted]   PASS (5ms): pid=99909 input devices=[99] contains target 99 (runningInput=false, runningGeneral=true)  [note: runningInput=false despite device-list membership -- see IsRunningInput finding]
  [targeted]   after stopping: cleared after 3ms

--- leg 2: self-introspection negative control (OWC Thunderbolt 3 Audio Device); BlackHole must NOT appear (targeted lookup) ---
PASS (4ms): pid=99909 input devices=[139] contains target 139 (runningInput=true, runningGeneral=true)
after stopping negative-control input: cleared after 3ms

note: the system default input device is BlackHole (id 99) for the entirety of leg 2. If kAudioProcessPropertyDevices had actually been reporting "the system default input" rather than "the device this AUHAL instance opened", BlackHole would have appeared in this leg's result even though only OWC Thunderbolt 3 Audio Device was open. It did not -- corroborating evidence the property is genuinely per-stream-scoped, not a coarse system-wide signal.

--- leg 3: cross-process test -- a different process opens BlackHole, observed via the normal full-sweep path ---
helper PID: 99911
PASS (622ms): pid=99911 input devices=[99] contains target 99 (runningInput=true, runningGeneral=true)
after SIGTERM-ing the helper (no graceful teardown -- also checks OS cleanup on ungraceful exit): cleared after 67ms

--- leg 4: repeat-activation reliability -- a different process opens+closes BlackHole twice; both activations must be detected ---
helper PID: 99912 (will run two open/close cycles)
cycle 1: PASS (543ms): pid=99912 input devices=[99] contains target 99 (runningInput=true, runningGeneral=true)
cycle 1 cleared: cleared after 1524ms
cycle 2: PASS (1166ms): pid=99912 input devices=[99] contains target 99 (runningInput=false, runningGeneral=true)  [note: runningInput=false despite device-list membership -- see IsRunningInput finding]
cycle 2 cleared: cleared after 1490ms

=== self-test verdict ===
PASS: kAudioProcessPropertyDevices (input-scope device-list membership) correctly scoped demand to the device actually opened, for self-introspection, a genuinely separate process, and repeat activations by that process. IMPORTANT CAVEAT: kAudioProcessPropertyIsRunningInput was found NOT to reliably re-trigger past a process's first input activation -- see any "[note: runningInput=false despite device-list membership]" lines above and the findings doc. Demand detection must be gated on device-list membership, not on IsRunningInput.
```

Exit code: `0` on every run (three total during this fix round; PID and
exact millisecond figures vary run to run as expected, the pass/fail
pattern — including which lines show the `runningInput=false` note — was
identical every time).

### Timing contrast: full-sweep vs targeted lookup (addresses the "the timing numbers are not what the document says they are" review finding)

Leg 1 measures the same kind of transition (BlackHole appearing in the
probe's own input-device list) two different ways:

- **Full-sweep** (`kAudioHardwarePropertyProcessObjectList`, ~40 objects
  on this machine, 4-5 properties read on each): **58ms** to detect
  appearance, **58ms** to detect clearing, in the run shown above.
- **Targeted** (`kAudioHardwarePropertyTranslatePIDToProcessObject`, one
  object, one lookup + 4-5 property reads): **5ms** to detect appearance,
  **3ms** to detect clearing.

The full-sweep figure is what a real polling implementation modeled on
this probe's `report()`/`--watch` would actually experience, since a real
agent doesn't know in advance which PID it's looking for — it has to
enumerate. The targeted figure isolates Core Audio's genuine
state-propagation latency from that enumeration cost, and is roughly an
order of magnitude smaller. **Neither number should be read as a
precise, guaranteed latency** — both were measured with 10ms poll
granularity on one idle machine, once — but the gap between them (tens of
ms difference, both real, both reproducible) is itself useful
information: if Phase 3 needs faster confirmation than a full sweep
provides, translating a known/suspected PID directly is measurably
cheaper, at the cost of needing to already know which PID to check.

### Cross-process corroboration (addresses "test a second, independent process")

Leg 3 and leg 4 are the first point in this probe's development where a
result comes from a **genuinely separate OS process**, not
self-introspection. This matters because self-introspection could in
principle be an artifact of a process reading its own audio state through
some different, more-privileged path than it would use to read another
process's state. Legs 3 and 4 rule that out: a spawned helper process
(different PID, same executable, running independently) was correctly
detected opening BlackHole (leg 3) and correctly detected on both of two
separate activations (leg 4), with `kAudioProcessPropertyDevices` clearing
correctly between them every time.

**Correction (this was wrong in the previous revision of this document):**
leg 3's figure was 622ms, against leg 1's full-sweep figure of ~58ms.
622 / 58 ≈ 10.7 — that is one order of magnitude *higher* than the
self-introspection full-sweep figure, not "the same order of magnitude" as
an earlier draft of this document claimed. That was a real error: a probe
artifact stated as if it were a measured API property, the exact class of
mistake already corrected once in fix round 1's Finding 2.

The correct reading is that leg 3/4's ~500-1200ms figures are dominated by
overhead that has nothing to do with Core Audio property propagation:
`Process.run()` forking and exec'ing a fresh process, the Swift runtime
loading in that new process, and then the full `AudioUnit` setup sequence
(`AudioComponentInstanceNew`, two `EnableIO` calls, `CurrentDevice`,
`SetInputCallback`, `AudioUnitInitialize`, `AudioOutputUnitStart`) all
happening before the stream is even open, let alone detected. **The
cross-process figures characterize "cold helper-process launch through
first detected activation," not steady-state detection latency for an
already-running application**, and must not be read as the latter. The
targeted self-introspection figures from leg 1 (~5-6ms appear, ~3-4ms
clear) remain the closest approximation this probe has to genuine Core
Audio propagation latency, precisely because they don't pay any
process-launch cost — the AudioUnit is opened directly in an
already-running process.

### Default-input corroboration (new, per coordinator review)

The system's default input device was already BlackHole (AudioObjectID 99)
for the entire test session, including during leg 2's negative control,
where the probe opened a *different* device (OWC Thunderbolt 3 Audio
Device) and BlackHole was required to **not** appear. If
`kAudioProcessPropertyDevices` had actually been reporting "the system's
current default input device" rather than "the device this specific
process/stream actually opened," BlackHole would have leaked into leg 2's
result purely because it was the system default — even though the probe
never touched it in that leg. It did not leak. This is independent,
incidental evidence (not something the probe had to construct) that the
property is genuinely per-stream-scoped rather than a coarse system-wide
signal, and it strengthens the "does not misfire on unrelated system
state" case beyond what the deliberate negative-control test alone shows.

## What this proves

- `kAudioHardwarePropertyProcessObjectList`,
  `kAudioHardwarePropertyTranslatePIDToProcessObject`, and
  `kAudioProcessPropertyDevices` (input scope) are present and functional
  on macOS 26.6.1; an unsigned ad hoc Swift binary can read them.
- **Positive case, self and cross-process:** a process running input on
  BlackHole is reported with BlackHole's `AudioObjectID` present in its
  input-scope device list, whether that process is the observer itself or
  a genuinely separate process.
- **Negative case:** a process running input on a *different* device does
  **not** list BlackHole, including under the default-input corroboration
  above.
- **Repeat activations are correctly detected — by device-list
  membership, not by `IsRunningInput`.** This is the corrected, re-verified
  version of the core assumption the whole design rests on.
- State clears in the tens-of-milliseconds to low-hundreds-of-milliseconds
  range after a stream stops (see timing contrast above for which number
  to trust for what purpose).
- No microphone-permission prompt blocked or delayed any `AudioOutputUnitStart`
  call across all runs and legs.
- **On three real processes** (Raycast, the System Settings Sound
  extension, and the Safari/WebKit GPU process), device-list membership
  was likewise correct in every row the owner observed — including a
  two-device list — and nothing lingered on BlackHole after use. See
  "Real applications, measured by the owner" for exactly what was
  observed and what was not.

## What this does NOT prove, and what remains unverified

- **`IsRunningInput`'s behaviour in this probe's synthetic cycles is
  characterized on this machine, but its root cause inside Core Audio is
  not. The leading hypothesis is instance reuse, not process history. It
  now has one piece of positive evidence — Raycast — but the direct
  measurement that would settle it has still NOT been run.** Every activation in
  this probe -- including every "repeat" activation in legs 1 and 4 --
  calls `makeInputUnit()` and constructs a **brand-new**
  `AudioComponentInstance` each time: dispose the old unit, create a new
  one, `EnableIO`, `SetInputCallback`, `AudioUnitInitialize`, start. A real
  client such as Dictation, Chrome, or anything built on `AVAudioEngine`
  is far more likely to hold **one** engine/unit object for its whole
  session and call stop/start (or record/pause) on that same instance
  repeatedly, never disposing and recreating it between activations. So
  the observed "sticky false" behavior may be an artifact of how the HAL
  re-registers a *new* `AudioComponentInstance` for a process that already
  has one on record, rather than a genuine "this process's Nth activation"
  property. That distinction is load-bearing: if the defect is
  instance-scoped, real long-lived apps that reuse one engine object might
  re-trigger `IsRunningInput` correctly every time, and the flag would be
  salvageable as a secondary signal; if it is process-scoped (as this
  probe's synthetic dispose/recreate cycles exercise), it is not, for any
  client shape.

  **The owner's Raycast observation is evidence for the instance-reuse
  side of that, and it is the only such evidence there is.** One
  long-lived real process reported `runningInput = yes` on four-plus
  separate activations, which is what the instance-reuse hypothesis
  predicts and what the process-history hypothesis does not. It is not a
  confirmation: Raycast's internal audio-client shape was not inspected,
  only one application was observed this way, and the two hypotheses were
  not separated by a controlled measurement.

  **The controlled measurement that would settle it was still not run and
  should be the first thing Phase 3 checks**, before relying on or ruling out
  `IsRunningInput` for anything: build one `AudioUnit` instance, call
  `AudioOutputUnitStart`/`AudioOutputUnitStop` on that *same* instance
  twice (no `AudioComponentInstanceDispose`/recreate in between), and
  observe whether `IsRunningInput` re-triggers `true` on the second
  `Start`. This was deliberately not implemented in this fix round --
  documenting the hypothesis precisely was judged worth more than a
  rushed extra leg, and it does not change this probe's gating
  recommendation either way: device-list membership works regardless of
  which hypothesis turns out to be correct.

  Beyond instance reuse, other unexplored explanations remain possible
  too: a general Core Audio HAL behavior unrelated to AUHAL specifically,
  or something specific to unsigned/ad hoc processes. This probe did not
  have the tooling to inspect Core Audio's internals directly and did not
  try alternate input-unit configurations (e.g. `AudioQueue` instead of
  raw AUHAL, or a signed helper) to rule those out.
- **TCC/permission behavior is unconfirmed, not "clean."** No prompt
  appeared or blocked any run, but this terminal's process may already
  hold microphone TCC approval from earlier, unrelated work on this
  machine (reading `TCC.db` directly to confirm failed with "authorization
  denied," as expected without Full Disk Access). It is **not verified**
  that a signed app bundle launched fresh, or an unsigned CLI binary run
  from a terminal with no prior grant, behaves the same way. Phase 1 must
  still implement `NSMicrophoneUsageDescription` and real TCC handling and
  test it from a clean permission state.
- **The automated legs tested only this probe's own processes** (the probe
  itself and helper processes that are literally re-execs of the same
  binary). Three real processes were observed separately, by hand, in the
  owner's pass below — Raycast, `com.apple.Sound-Settings.extension`, and
  `com.apple.WebKit.GPU`. **macOS Dictation, Chrome/Chromium, the ChatGPT
  desktop app, Zoom and Teams were not tested at all**, by either route.
  Nothing here shows how they populate these properties, or whether they
  exhibit the repeat-activation `IsRunningInput` behaviour the synthetic
  legs saw — see "Requires the owner" below.
- **No built-in mic on this hardware.** The negative control used a
  different but present device (OWC Thunderbolt 3 Audio Device) rather
  than "the built-in mic" as the brief's Step 4 literally specifies.
- **Single-machine result**, run repeatedly in one session but not across
  a reboot, a BlackHole reinstall, or other Mac hardware/macOS versions.

## Real applications, measured by the owner

The brief's Step 4 matrix needs a human clicking through real
applications; it cannot be automated from this agent. The owner has now
run part of it by hand. **Three** real processes were observed. Everything
below is what was seen; the applications not listed were not tested, and
their absence from the table means "not measured," not "passed."

### Session environment

- macOS **26.6.1**, Mac Studio (the same machine as the automated legs
  above).
- BlackHole 2ch, `uid=BlackHole2ch_UID`, `AudioObjectID` **99**.
- Other input devices present: OWC Thunderbolt 3 Audio Device (id 139),
  Microsoft Teams Audio, ManyCam Virtual Microphone, Parallels Access
  Sound, Squirrels Audio.
- Core Audio process-object count ranged **40–42** depending on what was
  running.
- All observations via `./demand-probe --watch`. **No appear/clear
  latencies were recorded** in this pass — the owner recorded state, not
  timing, so the latency columns of the original matrix stay unmeasured
  for real applications.
- Single machine, one sitting per application, no reboot.

### Baseline

With nothing recording and System Settings closed, the table was **empty**
and `demandCount` was **0**, stable across many polls.

### What each observed process did

| Process | Bundle ID | PID | Activations observed | `runningInput` while active | `onTarget` while active | Input-device list while idle | Appear / clear latency |
|---|---|---|---|---|---|---|---|
| Raycast | `com.raycast-x.macos` | 759 | 4+, across four separate `--watch` sessions, same long-lived process throughout | `yes` on **every** activation, including the 2nd, 3rd and 4th | `YES`, `[BlackHole 2ch]` | absent from the list, or `no / - / []` | not recorded |
| System Settings Sound pane | `com.apple.Sound-Settings.extension` | 91262 | n/a — it is not "activating"; it holds the current **system default input** for as long as the pane is open | `no` (never observed running input) | `YES` only while BlackHole *was* the system default input; `-` once the default was changed to OWC | n/a — present in the process list only while System Settings is open | not recorded |
| Safari / WebKit GPU process | `com.apple.WebKit.GPU` | 23059 | 1 capture observed | `yes` | `YES`, `[OWC Thunderbolt 3 Audio Device, BlackHole 2ch]` | `no / - / [OWC Thunderbolt 3 Audio Device]` — it **retains the then-current system default device** in its input-device list while not running input | not recorded |

**Raycast (`com.raycast-x.macos`, PID 759).** `ps` confirms the process
started 2026-08-07 and was never restarted across any of the runs, so
every activation after the first is a repeat activation of one long-lived
process. Observed across four separate `--watch` sessions. On each
activation the row went from absent, or `no / - / []`, to
`yes / YES / [BlackHole 2ch]`, and `demandCount` incremented. On each
release it went back to `no / - / []`, or the row dropped off the list
entirely; **no lingering was ever observed**. `runningInput` read `yes` on
every one of those activations — see finding 2 above for what that does
and does not mean for the synthetic result. Raycast targets BlackHole
**explicitly, independent of the system default input**: it was observed
holding `[BlackHole 2ch]` while the system default input was the OWC
device. That is the property the recommended configuration in the design
spec (§3.4) rests on.

**System Settings Sound pane (`com.apple.Sound-Settings.extension`, PID
91262).** Present in the process list only while System Settings is open;
when it was closed the process disappeared from the list entirely (object
count dropped 42 → 41 → 40). It holds whatever device is currently the
**system default input**: it showed `[BlackHole 2ch]` with `onTarget=YES`
while BlackHole was the default, and
`[OWC Thunderbolt 3 Audio Device]` with `onTarget=-` after the default was
changed to OWC. It is therefore a false positive **only** when BlackHole is
the selected system input *and* the Sound pane is open. In that
combination it put the idle baseline at `demandCount = 1`
**persistently**, for as long as the pane stayed open — a debounce would
not help, because the condition does not clear on its own.

**Safari / WebKit GPU process (`com.apple.WebKit.GPU`, PID 23059).** While
idle it showed `no / - / [OWC Thunderbolt 3 Audio Device]` — it retains
the system default device in its input-device list while not running
input. Raycast never did this (Raycast shows `[]` when idle), so this is a
per-application behaviour, not a general one. While capturing it showed
`yes / YES / [OWC Thunderbolt 3 Audio Device, BlackHole 2ch]` — a
multi-device list, which the `contains BlackHole` predicate counted
correctly, giving `demandCount = 2` alongside Raycast. After the owner
stopped the mic use, the process dropped off the list entirely:
**BlackHole did not linger**, and `demandCount` returned to 0 and stayed
there.

**Not tested for WebKit, and it matters:** whether WebKit would retain
*BlackHole* in that idle device list if **BlackHole** were the system
default input. The device it was observed retaining was the default at the
time (OWC), so the observation says nothing about the BlackHole-as-default
case — which is exactly the configuration the design originally assumed.
If WebKit retains the default while idle and BlackHole is the default,
Safari would sit on the demand predicate whenever it is running, without
recording anything. This was not measured and must not be assumed either
way.

### What the owner's pass shows

- Device-scoped detection worked on real, third-party and Apple processes,
  not only on this probe's own re-execs: the `contains BlackHole`
  predicate was correct for every row observed, including WebKit's
  two-device list.
- Repeat activations of one long-lived real process (Raycast, 4+) were
  each detected, and each release cleared.
- Two distinct false-positive *shapes* exist in the wild and were seen:
  a process that holds the **system default input** while open (Sound
  Settings), and a process that **retains the default in its idle device
  list** (WebKit). Both are avoided in practice if BlackHole is not the
  system default input — see the design spec §3.4 — but neither is
  eliminated by anything in the code.
- Nothing observed lingered on BlackHole after the corresponding
  application stopped using it.

## Requires the owner

Still not measured. Do not read anything into these rows; they are blank
because they were not run.

| Application | Session | `runningInput` | `onTarget` (BlackHole) | appear latency | clear latency |
|---|---|---|---|---|---|
| macOS Dictation | 1st | not measured | not measured | not measured | not measured |
| macOS Dictation | 2nd | not measured | not measured | not measured | not measured |
| Chrome / Chromium (site requesting mic) | 1st | not measured | not measured | not measured | not measured |
| Chrome / Chromium (site requesting mic) | 2nd | not measured | not measured | not measured | not measured |
| ChatGPT desktop (voice mode) | 1st | not measured | not measured | not measured | not measured |
| ChatGPT desktop (voice mode) | 2nd | not measured | not measured | not measured | not measured |
| Zoom | 1st / 2nd | not measured | not measured | not measured | not measured |
| Teams | 1st / 2nd | not measured | not measured | not measured | not measured |
| Safari/WebKit **idle, with BlackHole as system default input** (does it retain BlackHole?) | n/a | not measured | not measured | n/a | n/a |
| Raycast, Sound Settings, WebKit — appear/clear **latencies** | n/a | n/a | n/a | not measured | not measured |
| Any app with a true **built-in mic** selected (false-positive check; this machine has none) | n/a | not measured | not measured | n/a | n/a |

### Exact steps for the owner to run the rest

1. Build the probe if not already built:
   ```sh
   cd probes/macos-demand
   swiftc -O -o demand-probe DemandProbe.swift
   ```
2. Set the system input device **from the command line, not from System
   Settings**. `switchaudio-osx` is installed for this
   (`brew install switchaudio-osx`):
   ```sh
   SwitchAudioSource -c -t input                    # read the current input device
   SwitchAudioSource -t input -s "BlackHole 2ch"    # set it, headlessly
   ```
   This matters: opening **System Settings → Sound** is what put
   `com.apple.Sound-Settings.extension` on BlackHole and produced the
   persistent `demandCount = 1` false positive recorded above. Leaving the
   Sound pane closed keeps that process out of the picture entirely.
   Note that `SwitchAudioSource -s` selects by **display name**, which is
   fine for an interactive owner-run measurement but is not how the
   shipping agent resolves devices (spec: UID only).
3. In one terminal, run:
   ```sh
   ./demand-probe --watch
   ```
   Leave it running; it prints a fresh snapshot every 500 ms. The printed
   `demandCount` is gated on device-list membership, not on
   `runningInput` — trust the `onTarget`/`demandCount` columns, and treat
   `runningInput` as informational.
4. For each remaining application (Dictation, Chrome with a site that
   requests mic access, ChatGPT desktop voice mode, Zoom, Teams), run
   **two separate recording sessions**:
   a. Start audio input in that application.
   b. Watch the terminal. Note the PID/bundle ID that appears, whether
      `runningInput` shows `yes`, whether `onTarget` shows `YES`, the full
      input-device list, and roughly how many `--watch` cycles (× 500 ms)
      elapsed between starting input and the row appearing.
   c. Stop input in the application. Note how many cycles elapse before
      the row disappears or `onTarget` flips back to `-`.
   d. Repeat a–c **without restarting the application**, and record the
      same fields for the second session.
   e. Also record the application's row **while idle but running** — the
      WebKit result above shows that an idle process may still carry a
      device in its list, and that shape is what turns into a false
      positive when the device happens to be BlackHole.
5. Close the remaining WebKit gap specifically: with `SwitchAudioSource -t
   input -s "BlackHole 2ch"`, open Safari, do **not** record anything, and
   check whether `com.apple.WebKit.GPU` appears with `[BlackHole 2ch]` in
   its idle device list. A `YES` here means Safari alone is enough to hold
   the demand predicate on when BlackHole is the default input, and is a
   direct argument for the §3.4 configuration rather than merely a
   convenience.
6. Repeat the pass with the system input set to a true **built-in
   microphone** on hardware that has one (this Mac Studio does not).
   Confirm `onTarget` stays `-` and `demandCount` stays `0` for every
   application tested.
7. Fill in the table above with real values, and update the verdict below
   if any application disagrees with what is already recorded.

## Verdict

**Yes — device-scoped demand detection works on this machine, based on
what was actually measured, provided it is gated correctly.** The
automated `--self-test` demonstrates, with real AUHAL input streams and no
human involvement, that `kAudioProcessPropertyDevices` (input scope)
correctly reports which specific device a process is recording from —
positively, negatively, cross-process, and across repeat activations —
when detection is gated on device-list membership. The owner's manual pass
extends that to three real processes (Raycast across 4+ activations of one
long-lived process, the System Settings Sound extension, and the
Safari/WebKit GPU process including a two-device list), where the same
predicate was correct in every row observed.

**The gate is device-list membership, and it does not need `IsRunningInput`
to be reliable.** In this probe's synthetic cycles — which dispose and
recreate an `AudioComponentInstance` per activation —
`kAudioProcessPropertyIsRunningInput` read `false` at the instant
device-list membership was independently confirmed `true`. In Raycast, a
real long-lived process, it read `yes` on every activation observed,
including the fourth. The flag therefore behaves differently across client
shapes, and no single rule about it is supported by what was measured.
Device-list membership needs no such rule: it was correct in every case
observed, synthetic and real, and it is correct whether or not
`IsRunningInput` is reliable. That is the reason for the design decision,
and it is why the decision is unaffected by the Raycast result. **Phase 3
must gate demand detection on `kAudioProcessPropertyDevices` (input-scope)
membership. `IsRunningInput` may be read and displayed as a diagnostic; it
must not be a required conjunct.**

**Measured false positives, and the configuration that avoids them.** Two
processes were observed carrying a device they were not recording from:
`com.apple.Sound-Settings.extension` holds the current system default
input while the Sound pane is open (a persistent `demandCount = 1` when
BlackHole is the default — a debounce would not clear it), and
`com.apple.WebKit.GPU` retains the then-current default in its idle
device list. Both attach to *the system default input*. Raycast targets
BlackHole explicitly and independently of the default. So leaving the
system default input on the real hardware microphone, and letting Raycast
target BlackHole, removes both observed false-positive shapes. This is a
recommended configuration, not a guarantee: any application that
explicitly targets BlackHole will still register, which is the mechanism
working as designed.

**What remains unverified and must not be treated as settled:**
1. macOS Dictation, Chrome/Chromium, the ChatGPT desktop app, Zoom and
   Teams were **not tested at all** — not by the automated legs and not by
   the owner's pass. Nothing here says how they populate these properties,
   on a first session or a repeat one.
2. Whether `com.apple.WebKit.GPU` would retain **BlackHole** in its idle
   device list if BlackHole were the system default input. The device it
   was observed retaining was the default at the time (OWC). This is the
   configuration the original design assumed, so the gap is
   design-relevant, not academic.
3. Appear/clear latencies for real applications. The owner's pass recorded
   state, not timing; every real-application latency cell is unmeasured.
4. TCC/microphone-permission behavior for a freshly-launched, signed Phase
   1 app bundle with no prior grant.
5. The false-positive (true built-in mic) leg specifically, since this
   test machine has none; the automated self-test substituted a different
   real hardware input device and the negative result held for that
   substitution.
6. Why `IsRunningInput` behaves as it does. The leading hypothesis remains
   **instance reuse** — this probe always disposes and recreates a fresh
   `AudioComponentInstance` between activations, while a real app is more
   likely to reuse one instance across its whole session. Raycast's
   behaviour is consistent with that hypothesis and is the only evidence
   for it; the controlled same-instance stop/restart measurement described
   in "What this does NOT prove" has still not been run, and should be
   Phase 3's first check before relying on or ruling out `IsRunningInput`
   for anything.

Recommendation for Phase 3: proceed with device-scoped detection as the
primary mechanism, gated on `kAudioProcessPropertyDevices` membership —
the core OS API demonstrably supports it, including across repeat
activations, cross-process, and on the real applications observed. Do
**not** use `IsRunningInput` as a gate. Spec open question 1 is answered
for Raycast, the owner's primary application, and remains open for the
untested applications listed above; keep it open until enough of that
matrix is filled in to matter for the way the system will actually be
used.
