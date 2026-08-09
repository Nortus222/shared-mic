# Windows WASAPI open-latency findings (Phase 0, spec open question 2)

> **STATUS: NOT YET FILLED IN.**
> This probe (`probes/windows-wasapi-latency/`) targets `net10.0-windows`
> and NAudio, both Windows-only, and was written on a Mac. It has **never
> been built or run**. Every value below is an empty, explicitly-marked
> slot, not a placeholder number -- none of it should be read as a result
> until the owner runs the probe on the Windows host and fills this
> document in. See `probes/windows-wasapi-latency/README.md` for exact
> build/run instructions and the "what to send back" list.
>
> **Outstanding values, all of them:** Windows version, microphone model,
> exact MMDevice endpoint ID, device shared mix format, NAudio version and
> actual capture type name, .NET target framework actually used, the
> cold/p50/p95/max latency table, the concurrent-access result, and the
> verdict on the spec's 20-80 ms assumption.

**Probe:** `probes/windows-wasapi-latency/WasapiLatencyProbe/` (throwaway;
see its README)

**Question answered:** how long does WASAPI shared-mode capture actually
take to open on real Windows hardware, and does shared mode really allow
this probe and another Windows application to use the microphone at the
same time? The design spec's activation budget assumes 20-80 ms for the
open stage, inside a 300 ms p95 target for "user starts dictation" ->
"first audio captured." Because capture is deliberately closed while
macOS has no input demand, this open cost sits directly on that path and
is the largest single unknown in the budget.

## Test machine

- Windows version: **[NOT MEASURED -- fill in, e.g. `winver` or
  `Get-ComputerInfo`]**
- Microphone model: **[NOT MEASURED -- exact make/model]**
- USB controller / port used, if known: **[NOT MEASURED, optional]**

## Toolchain actually used

- .NET target framework actually built: **[NOT MEASURED -- `net10.0-windows`
  unless retargeted per the README; record which]**
- `dotnet --version` of the SDK that built it: **[NOT MEASURED]**
- NAudio version actually restored: **[NOT MEASURED -- pinned to 2.2.1 in
  the committed `.csproj`; record what actually resolved]**
- Actual capture type name used: **[NOT MEASURED -- `NAudio.Wave.WasapiCapture`
  as written, unless the installed NAudio major version renamed it; the
  probe prints this at startup]**

## Device identity

- Exact MMDevice endpoint ID (copy-paste from probe output, do not
  retype): **[NOT MEASURED]**
- Device friendly name as printed by the probe: **[NOT MEASURED]**

## Shared mix format

As printed by the probe (sample rate / bit depth / channels / encoding):

**[NOT MEASURED]**

## Latency results

Attempted/succeeded/conflicts/timed out/failed counts and the
cold/min/p50/p95/max table, exactly as printed by the probe's summary.
Note: `conflicts` (not `failed`) is the shared-mode-conflict signal --
see "Concurrent-access check" below.

| metric | value |
|---|---|
| attempted | **[NOT MEASURED]** |
| succeeded | **[NOT MEASURED]** |
| conflicts | **[NOT MEASURED]** |
| timed out | **[NOT MEASURED]** |
| failed | **[NOT MEASURED]** |
| cold (run 1) | **[NOT MEASURED]** |
| min | **[NOT MEASURED]** |
| p50 | **[NOT MEASURED]** |
| p95 | **[NOT MEASURED]** |
| max | **[NOT MEASURED]** |

Full, unedited console output of the run (paste verbatim once available):

```
[NOT MEASURED -- paste the full probe output here, unedited]
```

## Concurrent-access check (shared mode)

Whether the probe still opened successfully while another Windows
application (e.g. Voice Typing, Win+H) held the same microphone.

**Read this before filling in "Result" below.** A genuine WASAPI
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

- Other application used to hold the device: **[NOT MEASURED]**
- Baseline run's `conflicts`/`timed out`/`failed` counts (device not
  held by anything else): **[NOT MEASURED]**
- Concurrency run's `conflicts`/`timed out`/`failed` counts (device held
  by the other app): **[NOT MEASURED]**
- Result (pass: concurrency run's counts match the baseline, `conflicts`
  stayed 0 / fail: `conflicts` > 0 or new `TIMED OUT`/`CONFLICT` activity
  appeared only while the device was held): **[NOT MEASURED]**
- If any `CONFLICT` line appeared, paste its exact text here and treat
  this as an escalation, not something to work around:
  **[NOT MEASURED]**

## What this proves

**[NOT YET DETERMINED -- fill in once the probe has been run.]**

## What this does NOT prove / remains unverified

- Only ever tested on whatever single machine/microphone the owner runs
  this on first -- does not characterize latency across different USB
  controllers, drivers, or Windows builds.
- Cold-open-to-first-buffer latency only; does not include network
  transit, remote capture packaging, or client-side prefill. The probe's
  own "headroom" line adds an unverified ~100 ms placeholder for that on
  top of the measured p95 -- that 100 ms is not itself measured.
- The concurrency check exercises one other application (whichever the
  owner picks, e.g. Voice Typing) opening the device at the same time as
  this probe; it does not exhaustively test every application that might
  hold the microphone.

## Verdict on the spec's 20-80 ms assumption

**[NOT YET DETERMINED -- fill in once p95 is measured.]**

If p95 substantially exceeds 80 ms, say so plainly here and flag that the
activation budget in the spec needs revising before Phase 2 -- that is a
useful, reportable probe result, not a failure of the probe.
