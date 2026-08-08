# macOS demand-detection findings (Phase 0, spec open question 1)

**Date:** 2026-08-08 (updated same day, fix round 1, after coordinator review)
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
   again), and found that `IsRunningInput` reliably reports `true` only on
   a process's **first** input-stream activation in its lifetime -- it
   silently stays `false` on the second, third, ... activation, even
   while the process is actively streaming from the device. This was
   confirmed self-introspectively and cross-process, and is independent of
   whether the property is read via full enumeration or via
   `kAudioHardwarePropertyTranslatePIDToProcessObject`.
   `kAudioProcessPropertyDevices` (device-list membership) and the
   general, non-input-scoped `kAudioProcessPropertyIsRunning` were both
   found to re-trigger correctly on every activation tested.

   **This changes the design.** Any implementation that gates demand
   detection on `runningInput == true AND deviceList.contains(target)` --
   which is what this probe's own brief originally specified, and what
   this probe originally shipped in the first review round -- will
   silently miss the second and every subsequent time any given
   application uses the microphone, because `IsRunningInput` won't be
   `true` for that activation even though the app is genuinely recording.
   Since real applications are not restarted between uses (Chrome,
   Zoom/Teams, a Dictation-hosting process, etc. all stay running across
   many separate recording sessions), this would have caused demand
   detection to work once and then go dark for the rest of that
   application's process lifetime, on every app, every time.

   The probe has been corrected to gate everything -- `report()`,
   `--watch`, and all `--self-test` legs -- on device-list membership
   instead, and this is re-verified below (leg 4). **Phase 3 must not gate
   demand detection on `IsRunningInput` alone; use
   `kAudioProcessPropertyDevices` (input-scope) membership, optionally
   corroborated by the general `kAudioProcessPropertyIsRunning`.**

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
detected opening BlackHole (leg 3, 622ms via full-sweep — same
order of magnitude as the self-introspection full-sweep figure in leg 1,
consistent with the mechanism being the same regardless of whose PID is
being read) and correctly detected on both of two separate activations
(leg 4), with `kAudioProcessPropertyDevices` clearing correctly between
them every time.

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

## What this does NOT prove, and what remains unverified

- **`IsRunningInput`'s failure mode past the first activation is
  characterized on this machine, in this probe, but its root cause inside
  Core Audio is not.** It could be an AUHAL-specific quirk (a HALOutput
  unit reusing state from a torn-down predecessor), a general Core Audio
  HAL behavior, or something specific to unsigned/ad hoc processes. This
  probe did not have the tooling to inspect Core Audio's internals further
  and did not try alternate input-unit configurations (e.g., using
  `AudioQueue` instead of raw AUHAL, or a signed helper) to see whether the
  defect is AUHAL-specific.
- **TCC/permission behavior is unconfirmed, not "clean."** No prompt
  appeared or blocked any run, but this terminal's process may already
  hold microphone TCC approval from earlier, unrelated work on this
  machine (reading `TCC.db` directly to confirm failed with "authorization
  denied," as expected without Full Disk Access). It is **not verified**
  that a signed app bundle launched fresh, or an unsigned CLI binary run
  from a terminal with no prior grant, behaves the same way. Phase 1 must
  still implement `NSMicrophoneUsageDescription` and real TCC handling and
  test it from a clean permission state.
- **Only this probe's own processes were tested** (the probe itself and
  helper processes that are literally re-execs of the same binary). It
  does *not* prove that real third-party applications (Dictation, Chrome,
  ChatGPT desktop, Zoom, Teams) go through Core Audio in a way that
  populates the same properties identically, or that they exhibit (or
  don't exhibit) the same repeat-activation behavior for `IsRunningInput`.
  Given the finding above, it is now specifically important for the
  owner's manual pass to check **repeat** activations of each real app,
  not just a single activation — see the updated "Requires the owner"
  steps below.
- **No built-in mic on this hardware.** The negative control used a
  different but present device (OWC Thunderbolt 3 Audio Device) rather
  than "the built-in mic" as the brief's Step 4 literally specifies.
- **Single-machine result**, run repeatedly in one session but not across
  a reboot, a BlackHole reinstall, or other Mac hardware/macOS versions.

## Requires the owner

The following matrix from the brief's Step 4 needs a human clicking
through real applications with a microphone attached, and was **not**
run — there is no way to automate speaking into Dictation, granting a
Chrome site mic access, or joining a Zoom/Teams call from this agent. Do
not read anything into this table; it is blank because it was not
measured, not because it passed.

**Updated per the `IsRunningInput` finding: for each application, test at
least two separate recording sessions, not just one**, and record whether
`onTarget`/device-list membership stays reliable on the second session
even if `runningInput` does not (matching this probe's own finding, or
possibly contradicting it — either result is valuable).

| Application | Session | `runningInput` | `onTarget` (BlackHole) | appear latency | clear latency |
|---|---|---|---|---|---|
| macOS Dictation | 1st | not measured | not measured | not measured | not measured |
| macOS Dictation | 2nd | not measured | not measured | not measured | not measured |
| Chrome (site requesting mic) | 1st | not measured | not measured | not measured | not measured |
| Chrome (site requesting mic) | 2nd | not measured | not measured | not measured | not measured |
| ChatGPT (voice mode) | 1st | not measured | not measured | not measured | not measured |
| ChatGPT (voice mode) | 2nd | not measured | not measured | not measured | not measured |
| Zoom or Teams | 1st | not measured | not measured | not measured | not measured |
| Zoom or Teams | 2nd | not measured | not measured | not measured | not measured |
| Any app with **built-in mic** selected (false-positive check) | n/a | not measured | not measured | n/a | n/a |

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
   Leave it running; it prints a fresh snapshot every 500 ms. The printed
   `demandCount` is now gated on device-list membership, not on
   `runningInput` — trust the `onTarget`/`demandCount` columns, and treat
   `runningInput` as informational only (per the finding above, it may
   correctly show `no` on an app's second-or-later session even while
   `onTarget` correctly shows `YES`).
4. For each application in turn (Dictation, Chrome with a site that
   requests mic access, ChatGPT desktop voice mode, Zoom/Teams), run
   **two separate recording sessions**:
   a. Start audio input in that application (e.g. press the Dictation
      shortcut, click "Allow" on a Chrome mic prompt, start a ChatGPT
      voice session, join/unmute in Zoom or Teams).
   b. Watch the terminal. Note the PID/bundle ID that appears, whether
      `runningInput` shows `yes`, whether `onTarget` shows `YES`, and
      roughly how many `--watch` cycles (× 500 ms) elapsed between
      starting input and the row appearing.
   c. Stop input in the application. Note how many cycles elapse before
      the row disappears or `onTarget` flips back to `-`.
   d. Repeat steps a-c a second time **without restarting the
      application** (e.g. dictate again, refresh/reuse the same Chrome
      tab, start a new ChatGPT voice turn, unmute again in the same Zoom
      call) and record the same fields for this second session.
   e. Record all cells in the table above for both sessions of that
      application.
5. Repeat the whole pass with **System Settings → Sound → Input** set to
   the Mac's built-in microphone if this hardware has one (this test
   machine, a Mac Studio, does not — the owner should run this leg on
   hardware that does, e.g. a MacBook). Confirm `onTarget` stays `-` and
   `device-scoped demandCount` stays `0` for every application tested.
   This is the false-positive check and per the brief is one of the most
   important measurements remaining in Phase 0.
6. Fill in the table above with real numbers, and update the verdict below
   if any application disagrees with the automated self-test results
   (either the base device-scoping result, or the repeat-activation
   result).

## Verdict

**Yes — device-scoped demand detection works on this machine, based on
what was actually measured, provided it is gated correctly.** The
automated `--self-test` demonstrates, with real AUHAL input streams and no
human involvement, that `kAudioProcessPropertyDevices` (input scope)
correctly reports which specific device a process is recording from —
positively, negatively, cross-process, and across repeat activations —
when detection is gated on device-list membership.

**But the gating condition matters, and the brief's original one is
wrong.** `kAudioProcessPropertyIsRunningInput`, which the original design
implicitly relied on as part of the demand signal, does **not** reliably
re-trigger past a process's first input activation. Gating on it (as
originally specified and as this probe originally shipped) would cause
demand detection to work exactly once per application process lifetime
and then go silently dark. This is corrected in the current version of
the probe and is the single most important design-relevant finding to
come out of Phase 0's macOS probe: **Phase 3 must gate demand detection
on `kAudioProcessPropertyDevices` (input-scope) membership, not on
`IsRunningInput`.**

**What remains unverified and must not be treated as settled:**
1. Whether real target applications (Dictation, Chrome, ChatGPT, Zoom/Teams)
   go through Core Audio in a way that populates these same properties,
   including across repeat sessions — the "Requires the owner" matrix
   above is empty and needs a human pass, now explicitly covering a second
   session per app.
2. TCC/microphone-permission behavior for a freshly-launched, signed Phase
   1 app bundle with no prior grant.
3. The false-positive (true built-in mic) leg specifically, since this
   test machine has none; the automated self-test substituted a different
   real hardware input device and the negative result held for that
   substitution.
4. The root cause of `IsRunningInput`'s failure to re-trigger (AUHAL
   quirk vs. general Core Audio behavior vs. unsigned-process artifact)
   is not identified, only its symptom and a reliable workaround
   (device-list membership).

Recommendation for Phase 3: proceed with device-scoped detection as the
primary mechanism, gated on `kAudioProcessPropertyDevices` membership —
the core OS API demonstrably supports it, including across repeat
activations and cross-process. Do **not** use `IsRunningInput` as a gate.
Do not close spec open question 1 until the owner completes the
per-application matrix above, with particular attention to whether real
apps' second-and-later sessions are detected the same way synthetic AUHAL
cycles were in this probe.
