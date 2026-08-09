# Windows WASAPI open-latency probe

Throwaway probe for Phase 0 / spec open question 2: how long does WASAPI
**shared-mode** capture actually take to open on real Windows hardware?
The design spec's activation budget assumes 20-80 ms for this stage,
inside a 300 ms p95 target for "user starts dictation" -> "first audio
captured". Because capture is deliberately closed while macOS has no
input demand (the zero-idle-bytes requirement), this open cost sits
directly on that path.

It also checks a functional goal of the whole project: that WASAPI
**shared** mode really does let this probe and another Windows
application use the microphone at the same time.

This directory is not built by CI and is not part of the shipping
product. The durable output is
`docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`.

**This probe was written on a Mac and has never been built or run.** It
targets `net10.0-windows` and NAudio, both Windows-only. It must be built
and run on the Windows host, by the owner. Read the whole file before
running it.

## Prerequisites

- Windows 10 or 11, with the USB microphone attached and enabled.
- .NET SDK capable of building `net10.0-windows` (.NET 10). If you don't
  have it and don't want to install it, see "If the SDK is missing"
  below.
- NuGet restore access for the `NAudio` package (2.2.1 pinned; see "If
  the NAudio version is wrong" below).

## Build

```powershell
cd probes\windows-wasapi-latency\WasapiLatencyProbe
dotnet build
```

### If the SDK is missing

If `dotnet build` fails with a message about not finding an SDK matching
`net10.0-windows` (missing .NET 10), open
`WasapiLatencyProbe.csproj` and change:

```xml
<TargetFramework>net10.0-windows</TargetFramework>
```

to `net9.0-windows` or `net8.0-windows`, whichever SDK you have
installed (`dotnet --list-sdks` to check). This is a throwaway probe, not
shipping code -- the WASAPI open-latency measurement is identical
regardless of which .NET version runs it. Record which target framework
you actually used in the findings doc.

### If the NAudio version is wrong

The project pins `NAudio` 2.2.1. If `dotnet restore`/`dotnet build` fails
to find that exact version, or a newer one is clearly what's current,
edit the `PackageReference` version in the `.csproj` to take the current
2.x release. **Record the exact NAudio version that actually gets
restored, and the actual capture type name (`NAudio.Wave.WasapiCapture`
in NAudio 2.x; a newer major version may have renamed it, e.g. to
`WasapiRecorder`, in the same namespace)** in the findings doc -- Phase 1
depends on knowing both. `Program.cs` is written against `WasapiCapture`;
if the installed package doesn't expose that type, rename every
`WasapiCapture` reference in `Program.cs` to whatever the installed
version calls it and note the rename in the findings doc.

## Run

```powershell
dotnet run --project WasapiLatencyProbe -- 20
```

The trailing `20` is the iteration count (default 20 if omitted). The
probe will:

1. Print the NAudio assembly version and the capture type name it's
   using.
2. List active capture devices with their friendly name and their exact
   MMDevice endpoint ID.
3. Prompt you to pick the USB microphone by index.
4. Print the device's shared-mode mix format (sample rate, bit depth,
   channel count, encoding).
5. Run the requested number of open/measure/close cycles, printing each
   run's latency (or TIMED OUT / FAILED), then a summary table:
   attempted/succeeded/timed out/failed counts, cold, min, p50, p95, max.

Each cycle constructs a fresh capture object against a freshly-fetched
device handle, starts recording, waits for the first non-empty
`DataAvailable` callback, stops, and waits briefly for the capture thread
to fully shut down before the next cycle -- so each cycle should reflect
a genuine, independent "cold" WASAPI open, matching how the real agent
opens the device on demand rather than holding it continuously.

No captured audio is ever read, logged, or written anywhere by this
probe -- only byte counts (`> 0` or not) and timings.

## Running the concurrency check (shared-mode co-access)

This is the second, equally important thing this probe checks: does
WASAPI shared mode really allow this probe and another Windows
application to use the microphone at the same time?

1. Run the probe once on its own first (as above) to get a baseline.
2. Start Windows Voice Typing: press **Win+H** with focus in any text
   field, so it activates and holds the microphone. (Any other
   application actively using the same microphone works too, e.g. a
   Teams/Zoom call or Sound Recorder -- Voice Typing is just the easiest
   to start with no setup.)
3. While Voice Typing (or the other app) is actively listening, run the
   probe again in a separate terminal, selecting the same device:
   ```powershell
   dotnet run --project WasapiLatencyProbe -- 20
   ```
4. **Expected:** every run still opens and reports a latency, same as the
   baseline. This confirms shared mode allows simultaneous access.
5. **Watch for `CONFLICT` lines and the `conflicts` count in the
   summary -- that is the real signal, not the word `FAILED`.** A genuine
   WASAPI shared-mode conflict does not throw synchronously back through
   this probe's own code, so it can never produce a `FAILED` line. NAudio
   runs the actual device-open call (`IAudioClient.Initialize`) on a
   background thread inside its own try/catch, and reports a failure
   there through the `RecordingStopped` event instead. Concretely, a real
   conflict looks like one of:
   - `run N: CONFLICT - capture stopped before any data arrived: <message>`
     printed for that run, and/or
   - `run N: TIMED OUT after 5000 ms` with no data ever arriving, if
     `RecordingStopped` is slow to fire relative to the timeout.

   If you see either of these **while Voice Typing (or the other app) is
   actively holding the device**, and you do *not* see them in the
   baseline run from step 1: stop and escalate immediately. That means
   shared mode is not actually granting concurrent access on this
   hardware/driver, which invalidates a functional goal of the whole
   project and must not be worked around silently (e.g. by switching to
   exclusive mode, or by adding retry/wait logic to paper over it).
   `FAILED`/`errorCount` in this probe only ever means something else
   went wrong before the device-open call itself (e.g. the device
   disappeared between enumeration and open) -- it is not the
   shared-mode-conflict signal.
6. Record the result (which apps were tested, the `succeeded` /
   `conflicts` / `timed out` / `failed` counts from the summary, and
   the exact text of any `CONFLICT` lines) in the findings doc.

## What to send back

After running this on the Windows host, the following values are what
downstream work (Phase 1, and closing spec open question 2) actually
needs -- fill these into
`docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`:

- Windows version (`winver` or `Get-ComputerInfo` -> `WindowsVersion`/
  `OsHardwareAbstractionLayer`, whichever you have handy).
- Microphone model (exact make/model, e.g. from Device Manager).
- The exact MMDevice endpoint ID string the probe printed for that
  microphone (copy-paste, don't retype).
- The device's shared mix format, as printed by the probe.
- The NAudio version actually restored, and the actual capture type name
  used (`WasapiCapture` unless you had to rename it -- see above).
- The .NET target framework actually used to build (net10.0-windows
  unless you retargeted -- see above).
- The full cold/min/p50/p95/max table from the summary, plus
  attempted/succeeded/conflicts/timed out/failed counts.
- The concurrency check result: pass (every run still opened and reported
  a latency while Voice Typing/another app held the device, `conflicts`
  stayed 0) or fail (`conflicts` > 0, and/or `CONFLICT` lines or
  unexplained `TIMED OUT` runs appeared, while the other app held the
  device but not in the baseline run) -- and which other application you
  used to hold the device. Note that a real conflict shows up as
  `CONFLICT`/`conflicts` (or a `TIMED OUT` run), not as `FAILED`.
- Anything that looked wrong or surprising, even if you're not sure it
  matters -- this feeds a design budget, so overreporting is better than
  underreporting.

## Known limitations

- Only one physical machine's result will be captured here initially;
  this does not characterize latency across different USB
  controllers/drivers/Windows builds.
- The probe excludes timed-out runs from the min/p50/p95/max
  calculation (they're reported separately as a count) -- a run that
  never produces a first buffer within 5 seconds isn't a latency sample,
  it's a distinct failure mode, and averaging it in would understate how
  bad it is rather than surface it.
- This measures **cold-open latency to first audio buffer**, not
  end-to-end "user starts dictation" latency -- it does not include
  network transit, remote capture packaging, or any client-side prefill.
  The probe's final summary line adds a placeholder ~100 ms for that on
  top of the measured p95, purely to show how much headroom would remain
  against the spec's 300 ms target; that 100 ms is not itself measured by
  this probe.
