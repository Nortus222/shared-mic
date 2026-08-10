# Windows WASAPI open-latency findings (Phase 0, spec open question 2)

> **STATUS: RUN AND RECORDED.** The owner built and ran this probe on the
> real Windows host on 2026-08-08. Two runs of 20 cycles each: a baseline
> with nothing else holding the microphone, and a concurrent-access run
> with Windows Voice Typing actively using the same microphone. Both are
> recorded below.
>
> **Headline: shared-mode co-access is confirmed on this combination.**
> 20/20 opens succeeded with **0 conflicts** while Voice Typing held the
> device, and Voice Typing itself stayed operational throughout. This was
> a functional go/no-go for the whole project; it passed. Scope it
> honestly: **one microphone, one driver, one Windows machine, one
> concurrent application, 20 cycles.**
>
> **Still outstanding, and only the owner can supply them:** the Windows
> version, the SDK version, and the verbatim console output. See
> "Requires the owner" at the end. The two values that were blocking
> Phase 1 — the exact MMDevice endpoint ID string and the device's shared
> mix format — have since been supplied by the owner, measured by the
> probe on the real Windows host, and are recorded below under "Device
> identity" and "Shared mix format", along with the design consequences
> they carry.

**Probe:** `probes/windows-wasapi-latency/WasapiLatencyProbe/` (throwaway;
see its README)

**Question answered:** how long does WASAPI shared-mode capture actually
take to open on real Windows hardware, and does shared mode really allow
this probe and another Windows application to use the microphone at the
same time? The design spec's activation budget assumed 20-80 ms for the
open stage, inside a 300 ms p95 target for "user starts dictation" ->
"first audio captured." Because capture is deliberately closed while
macOS has no input demand, this open cost sits directly on that path and
was the largest single unknown in the budget.

## Test machine

- Windows version: **[NOT RECORDED -- the owner ran this on the Windows
  host but did not report the version string; fill in from `winver` or
  `Get-ComputerInfo`]**
- Microphone model: **Samson Meteorite Mic** (USB condenser)
- USB controller / port used, if known: **[NOT RECORDED, optional]**

## Toolchain actually used

- .NET target framework actually built: **`net10.0-windows`** (as
  committed; not retargeted)
- Build command and result: **`dotnet build --no-incremental`, 0 warnings,
  0 errors**
- `dotnet --version` of the SDK that built it: **[NOT RECORDED -- fill in]**
- NAudio version actually restored: **2.2.1** (the version pinned in the
  committed `.csproj`; no substitution was needed)
- Actual capture type name used: **`NAudio.Wave.WasapiCapture`**. This is
  inferred, not read off the probe's startup line: `Program.cs` is written
  against `WasapiCapture` and the build produced 0 errors, so that type
  resolved in NAudio 2.2.1. The probe also prints the type name at
  startup; that line is part of the missing verbatim output below.

## Device identity

- Exact MMDevice endpoint ID (copy-paste from probe output, do not
  retype): **`{0.0.1.00000000}.{dcea823c-c06f-40bf-8f35-9de9fb96acfd}`**.
  Supplied by the owner, measured by the probe on the real Windows host
  against the Samson Meteorite Mic. Phase 1's `DeviceManager` persists
  exactly this string (spec §6.1); it must be reproduced
  character-for-character, never retyped or approximated.
- Device friendly name as printed by the probe: **`Microphone (Samson
  Meteorite Mic)`**. Note that the design resolves devices by endpoint
  ID, never by friendly name, so this one is informational rather than
  load-bearing.

## Shared mix format

As printed by the probe (sample rate / bit depth / channels / encoding):

**48,000 Hz, 32-bit, 2 channels, encoding=Extensible.** Supplied by the
owner, measured by the probe on the real Windows host against the Samson
Meteorite Mic. `PcmNormalizer` (spec §6.1) converts from this format to
48 kHz / mono / s16le; whether it must resample, whether it must convert
float to int, and whether it must downmix all follow directly from it,
and all three are now known rather than assumed, on this one microphone
and this one host:

- **No resampling is needed for this device.** The mix format's sample
  rate is already 48,000 Hz — exactly the wire format's rate (spec
  §6.2). §6.1's conditional, resample "only if the mix format is not
  already 48 kHz," does not fire on this hardware, so `PcmNormalizer`'s
  common path for this microphone carries no rate-conversion step and no
  resampling dependency. Scope this narrowly: it is true of the Samson
  Meteorite on this host. A different microphone could present a
  different rate, so the conditional logic stays in the design — what
  changes here is that the common path does not exercise it.
- **Float-to-int16 conversion is confirmed required, not assumed.**
  32-bit is what §6.1 already anticipated (float32 to int16); this is
  now measured on the real device rather than inferred from the API
  surface.
- **The stereo-to-mono downmix path is live on every frame, from day
  one — and which mode is correct is not yet known.** The Samson
  Meteorite is a mono condenser microphone, but WASAPI presents its
  shared mix format as 2 channels, so §6.1's channel-mode setting
  (`mix` default, `left`, `right`) is not a defensive hedge for this
  hardware; it is load-bearing on every frame this device produces. What
  is *not* known is which mode is correct: whether the two channels
  carry identical (dual-mono) signal, where averaging (`mix`) is right,
  or signal on only one channel, where averaging costs 6 dB. Nothing
  measured so far distinguishes the two. Determining the Meteorite's
  actual channel layout is now a concrete Phase 2 task (spec §12), not a
  hypothesis — done before the default channel mode is chosen. The tray
  input level meter that §6.1 already specifies is the mechanism for
  catching it, which matters because the failure mode is silent: "the
  Mac sounds quiet," with no error anywhere, unless someone looks at the
  meter.

## Latency results

Two runs of 20 cycles each. `conflicts` (not `failed`) is the
shared-mode-conflict signal -- see "Concurrent-access check" below.

### Baseline (nothing else holding the microphone)

| metric | value |
|---|---|
| attempted | 20 |
| succeeded | 20 |
| conflicts | 0 |
| timed out | 0 |
| failed | 0 |
| cold (run 1) | 114.1 ms |
| min | 76.8 ms |
| p50 | 78.5 ms |
| p95 | 93.4 ms |
| max | 114.1 ms |

Note that `max` equals `cold`: the slowest open of the twenty was the
first one. No cycle after the first ever exceeded the cold figure.

### Concurrent access (Windows Voice Typing actively using the same mic)

| metric | value |
|---|---|
| attempted | 20 |
| succeeded | 20 |
| conflicts | 0 |
| timed out | 0 |
| failed | 0 |
| cold (run 1) | 89.0 ms |
| min | 61.2 ms |
| p50 | 62.6 ms |
| p95 | 77.7 ms |
| max | 89.0 ms |

Full, unedited console output of the run:

```
[NOT RECORDED -- the owner reported the summary statistics but not the
verbatim console output. The two summary tables above are what was
reported, transcribed exactly. The verbatim output would additionally
supply the endpoint ID, the friendly name, the mix format, and the
NAudio/capture-type startup line -- see "Requires the owner".]
```

### The concurrent run was *faster* than the baseline, on every statistic

This is the most counterintuitive number in the document, so it gets an
explanation rather than being left as a curiosity:

| statistic | baseline | with Voice Typing | difference |
|---|---|---|---|
| cold (run 1) | 114.1 ms | 89.0 ms | **-25.1 ms** |
| min | 76.8 ms | 61.2 ms | **-15.6 ms** |
| p50 | 78.5 ms | 62.6 ms | **-15.9 ms** |
| p95 | 93.4 ms | 77.7 ms | **-15.7 ms** |
| max | 114.1 ms | 89.0 ms | **-25.1 ms** |

The likely mechanism: when another client already holds the endpoint in
shared mode, the Windows audio engine for that endpoint is already
running -- the device is initialized, the engine's periodic processing
thread is live, and the shared-mode mix graph exists. Opening an
*additional* shared stream then joins a running engine instead of
spinning one up cold. The baseline run, by contrast, paid engine
start-up cost on essentially every cycle, because each cycle closes the
device and the engine winds down again before the next one.

This mechanism is a reasonable reading of the numbers, not something the
probe instrumented. The probe measures wall-clock time from
`StartRecording()` to the first non-empty `DataAvailable` callback; it
does not observe the audio engine's internal state. What *is* measured is
the 15-25 ms gap itself, consistently across all five statistics and in
the same direction.

**Practical consequence, and it matters for the design:** the worst case
for activation latency is an **idle machine with nothing else using the
microphone** -- and that is the *common* case for this product. This
system exists precisely so that nothing holds the microphone at idle;
capture is closed when macOS has no demand. So the budget must be built
on the baseline figures (cold 114.1 ms, p95 93.4 ms), not the friendlier
concurrent ones. The concurrent figures are the good case, and they are
the case that happens only when a Windows application is already
recording.

## Concurrent-access check (shared mode)

**Read this before interpreting the counts.** A genuine WASAPI
shared-mode conflict cannot produce a `FAILED` line in this probe --
NAudio runs the actual device-open call on a background thread inside
its own try/catch and reports a failure through `RecordingStopped`, not
by throwing back through this probe's own code. The real signal is the
probe's `conflicts` count / `CONFLICT` lines, and/or unexplained
`TIMED OUT` runs that only appear while the other app holds the device.
`FAILED`/`failed` in this probe means something unrelated went wrong
(e.g. the device disappeared between enumeration and open), not a
shared-mode conflict. See `probes/windows-wasapi-latency/README.md`
("Running the concurrency check" section) for the full explanation.

- Other application used to hold the device: **Windows Voice Typing
  (Win+H)**, actively using the same Samson Meteorite Mic.
- Baseline run's `conflicts`/`timed out`/`failed` counts (device not
  held by anything else): **0 / 0 / 0**, with 20/20 succeeded.
- Concurrency run's `conflicts`/`timed out`/`failed` counts (device held
  by the other app): **0 / 0 / 0**, with 20/20 succeeded.
- Effect on the other application: **Voice Typing remained operational
  throughout** the 20 cycles. It was not interrupted, muted, or evicted
  by the probe repeatedly opening and closing the same endpoint.
- **Result: PASS.** The concurrency run's counts match the baseline
  exactly, `conflicts` stayed 0, and no new `TIMED OUT`/`CONFLICT`
  activity appeared while the device was held.
- `CONFLICT` lines observed: **none, in either run.**

## What this proves

**WASAPI shared-mode co-access works on this combination.** On a Samson
Meteorite Mic, with its driver, on the owner's Windows machine, with
Windows Voice Typing as the concurrent client: the probe opened the
endpoint 20 out of 20 times while Voice Typing was actively using it,
with zero conflicts, zero timeouts and zero failures, and Voice Typing
kept working the whole time.

This retires the project's biggest functional risk. Simultaneous
Windows + Mac use of the one physical microphone is the entire premise of
the design (spec §2.1, §6.1); if Windows applications could not use the
microphone while the Mac stream was active, the design was dead and the
only alternatives were exclusive-mode ownership with manual switching, or
abandoning the approach. That question is now answered in the
affirmative, empirically, on real hardware.

**Say it at this scope and no wider.** This is not "WASAPI shared mode
works." It is: *shared-mode co-access worked on this microphone, this
driver, this machine, and this one concurrent application, over 20
cycles.* A different microphone, a driver that forces exclusive mode, or
an application that requests exclusive mode could still conflict. The
spec's acceptance criterion "Windows applications can use the physical
USB microphone while the Mac is receiving it" (§9) is now strongly
evidenced for this setup, and it remains the criterion to verify end to
end in Phase 2 with the real agent rather than this probe.

**And the timing question is answered too:** the open stage costs
**p50 78.5 ms / p95 93.4 ms / cold 114.1 ms** on an idle machine. See the
verdict below and spec §6.3 for the revised budget.

## What this does NOT prove / remains unverified

- **One machine, one microphone, one driver.** Everything here was
  measured on a single Windows host with a single Samson Meteorite Mic.
  It does not characterize latency or co-access across different USB
  controllers, drivers, microphone models, or Windows builds. A second
  machine could differ in either direction.
- **One concurrent application.** The co-access result covers Windows
  Voice Typing only. Teams, Zoom, Discord, OBS, browser `getUserMedia`,
  and anything that requests exclusive mode are all untested. An
  application that opens the endpoint in *exclusive* mode would still
  lock this probe (and the shipping agent) out; nothing here says
  otherwise.
- **20 cycles per run** is enough to see a p50 and a rough p95 and to
  make a 0-conflict result meaningful; it is not enough to characterize a
  tail. A 1-in-100 stall would very likely not appear in 20 samples.
  There is no evidence here about rare long opens.
- **Cold-open-to-first-buffer latency only.** This does not include
  network transit, remote capture packaging, or client-side prefill. The
  probe's own "headroom" line adds an unverified ~100 ms placeholder for
  that on top of the measured p95; that 100 ms is not itself measured.
  The real end-to-end activation figure is a Phase 2 measurement.
- **The engine-already-running explanation** for why the concurrent run
  was faster is an interpretation of the measured gap, not an
  instrumented finding.
- **The probe is not the agent.** It uses NAudio's `WasapiCapture` with
  its default shared-mode initialization. The Phase 2 Windows agent may
  configure the client differently (buffer duration, event-driven vs
  polled), and that can move the open cost.

## Verdict on the spec's 20-80 ms assumption

**The assumption was too optimistic and has been replaced.**

- p50 **78.5 ms** sits at the very top of the assumed 20-80 ms band.
- p95 **93.4 ms** is **13.4 ms above** the assumed ceiling.
- cold **114.1 ms** is **34.1 ms above** the assumed ceiling -- and cold
  is the realistic first activation for this product, which closes
  capture at idle by design.
- min **76.8 ms** is above the assumed *midpoint*; nothing in 20 baseline
  cycles ever came close to the 20 ms bottom of the assumed band.

In other words the assumed band's lower half never happened, and the
real distribution starts roughly where the assumption ended.

Spec §6.3 has been updated: the WASAPI row is now **78.5-93.4 ms
(measured, p50-p95)** with cold start called out separately at
**114.1 ms**, and the totals recomputed from the actual rows. The 300 ms
p95 target still holds -- see §6.3 for the arithmetic and the remaining
headroom -- but the margin is smaller than the spec previously implied,
and the first-word-clipping risk in §6.3/§9 is correspondingly tighter.
The acceptance criterion (95 of 100 activations losing no complete first
word) is unchanged and must not be softened; it is simply harder to hit
than the old budget suggested.

## Requires the owner

Two of the four values originally listed here have been supplied: the
exact MMDevice endpoint ID string and the device's shared mix format —
see "Device identity" and "Shared mix format" above. Neither of the
remaining two blocks Phase 1 or Phase 2 work; they are record-keeping:

1. The **Windows version** (`winver`) and **`dotnet --version`**, for the
   record of what this was measured on.
2. Ideally, the **verbatim console output** of both runs, which supplies
   1 and the friendly name and capture-type startup line in one paste.

Re-running the probe once and pasting the whole output produces both; no
re-measurement of the latency figures is needed.
