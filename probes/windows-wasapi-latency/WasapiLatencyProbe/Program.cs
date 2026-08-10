// Throwaway probe for spec open question 2: how long does WASAPI
// shared-mode capture actually take to open on this hardware?
//
// The spec's activation budget assumes 20-80 ms for this stage, inside a
// 300 ms p95 target for "user starts dictation" -> "first audio captured".
// Because capture is deliberately closed while idle (zero-idle-bytes
// requirement), this open cost sits directly on that path. If the real
// number is far higher, first-word clipping is a bigger problem than the
// design accounts for, and Phase 2 needs a different mitigation.
//
// This probe also checks a functional requirement of the whole project:
// WASAPI SHARED mode must let this process and another Windows
// application (e.g. Voice Typing, Win+H) use the microphone at the same
// time. See README.md for how to run that check. If shared mode fails to
// open while another app holds the device, that invalidates the design
// and must be escalated, not worked around.
//
// Audio payload is never read, logged, or persisted here -- only byte
// counts (BytesRecorded > 0) and timings.
//
// Run: dotnet run --project WasapiLatencyProbe -- [iterations]
//
// NOTE ON CORRECTNESS: this file has not been compiled (written on a Mac,
// for a Windows-only, net10.0-windows/NAudio target). It has been read
// carefully against known NAudio/WASAPI behavior, and every place that
// required an assumption about an API this agent could not verify by
// building is called out in a comment at that spot. Read those comments
// before trusting the numbers.

using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;

int iterations = args.Length > 0 && int.TryParse(args[0], out var parsedIterations) ? parsedIterations : 20;

// NAudio version and the actual capture type name, both requested by the
// findings doc because Phase 1 depends on knowing them. This is written
// against NAudio.Wave.WasapiCapture, which is correct for the pinned
// 2.2.1 release and for NAudio 2.x generally. If a newer major version
// has renamed this type (the brief mentions a possible `WasapiRecorder`),
// this line and every `new WasapiCapture(...)` / `WasapiCapture?` below
// will fail to compile -- rename them to match and note the rename here
// and in the findings doc.
var naudioAssemblyName = typeof(WasapiCapture).Assembly.GetName();
Console.WriteLine($"NAudio assembly : {naudioAssemblyName.Name} {naudioAssemblyName.Version}");
Console.WriteLine($"Capture type    : {typeof(WasapiCapture).FullName}");

var enumerator = new MMDeviceEnumerator();
var devices = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).ToList();

if (devices.Count == 0)
{
    Console.Error.WriteLine("No active capture devices found.");
    return 1;
}

Console.WriteLine("\nCapture devices:");
for (var i = 0; i < devices.Count; i++)
{
    Console.WriteLine($"  [{i}] {devices[i].FriendlyName}");
    Console.WriteLine($"      endpoint id: {devices[i].ID}");
}

Console.Write($"\nSelect device [0-{devices.Count - 1}]: ");
var selection = int.TryParse(Console.ReadLine(), out var selectedIndex) ? selectedIndex : 0;
var selectedDevice = devices[Math.Clamp(selection, 0, devices.Count - 1)];
var deviceId = selectedDevice.ID;

// Read the shared-mode mix format once, up front, purely for the findings
// doc. MMDevice.AudioClient.MixFormat is read-only -- it does not call
// AudioClient.Initialize() or Start(), so this does not count as "opening"
// the device and does not affect the timed loop below. Deliberately not
// reused for the timed opens themselves -- see the comment inside the
// loop for why.
var mixFormat = selectedDevice.AudioClient.MixFormat;
Console.WriteLine($"\nSelected device : {selectedDevice.FriendlyName}");
Console.WriteLine($"Endpoint id     : {deviceId}");
Console.WriteLine($"Shared mix fmt  : {mixFormat.SampleRate} Hz, {mixFormat.BitsPerSample}-bit, " +
                   $"{mixFormat.Channels} ch, encoding={mixFormat.Encoding}");
Console.WriteLine("(Record the endpoint id above exactly as printed -- Phase 1 persists that exact string.)");

Console.WriteLine($"\nMeasuring {iterations} open cycles.");
Console.WriteLine("Latency is measured from constructing the capture object to the first");
Console.WriteLine("DataAvailable callback carrying non-zero bytes.\n");

var results = new List<double>();
double? coldMs = null;
var timeoutCount = 0;
var errorCount = 0;
var conflictCount = 0;

for (var run = 0; run < iterations; run++)
{
    // Copy the loop variable into a per-iteration local before it is
    // captured by any closure below. `run` itself (declared in the `for`
    // header) is a single variable mutated across iterations, not
    // re-created each time -- unlike a `foreach` loop. The DataAvailable
    // closure only touches iteration-local `stopwatch`/`firstData` (both
    // declared inside this block, so they ARE fresh each iteration) and
    // is safe either way, but the RecordingStopped closure below prints
    // `runNumber` and could in principle fire late (after this iteration
    // has already advanced `run`), so it must close over a stable copy.
    var runNumber = run + 1;

    // IMPORTANT: fetch a *fresh* MMDevice for every iteration instead of
    // reusing `selectedDevice`. NAudio's MMDevice caches its AudioClient
    // wrapper on first access (including the one used above for
    // MixFormat), and WASAPI's IAudioClient::Initialize can only succeed
    // once per activation -- a second Initialize on the same IAudioClient
    // returns AUDCLNT_E_ALREADY_INITIALIZED. Constructing repeated
    // WasapiCapture instances from the same MMDevice would make every run
    // after the first fail or silently reuse stale state instead of
    // measuring a real open. This is also the behavior that matches
    // production: the real agent opens the device fresh on each on-demand
    // activation, not once and holds it.
    var freshDevice = enumerator.GetDevice(deviceId);

    var firstData = new TaskCompletionSource<double>(TaskCreationOptions.RunContinuationsAsynchronously);
    var stopped = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    var stopwatch = Stopwatch.StartNew();
    string? conflictMessage = null;

    WasapiCapture? capture = null;
    try
    {
        capture = new WasapiCapture(freshDevice);

        // Explicit even though Shared is NAudio's documented default for
        // WasapiCapture: this probe must never open in exclusive mode
        // (binding project constraint -- exclusive mode would take the
        // mic away from other Windows applications). If `ShareMode` does
        // not resolve on the installed NAudio version, delete this one
        // line; the constructor already defaults to Shared, this line
        // only guards against that default silently changing later.
        capture.ShareMode = AudioClientShareMode.Shared;

        capture.DataAvailable += (_, e) =>
        {
            if (e.BytesRecorded > 0)
            {
                firstData.TrySetResult(stopwatch.Elapsed.TotalMilliseconds);
            }
        };
        capture.RecordingStopped += (_, e) =>
        {
            // WasapiCapture's background capture thread runs the real
            // IAudioClient.Initialize() call, wrapped in its own
            // try/catch -- an Initialize-time failure (the realistic
            // shape of a shared-mode conflict: another app already holds
            // the device) is reported here, as a non-null Exception, NOT
            // thrown back through StartRecording(). That is why the
            // conflict signal is captured here rather than in the outer
            // try/catch below. Do not print from this handler: it can
            // fire after this iteration has moved on (bounded-awaited,
            // not guaranteed), which would interleave with the next
            // iteration's output. The message is stashed and printed
            // deterministically below instead, at the point this
            // iteration actually observes it.
            if (e.Exception != null)
            {
                conflictMessage = e.Exception.Message;
            }
            stopped.TrySetResult(true);
        };

        capture.StartRecording();

        var winner = await Task.WhenAny(firstData.Task, stopped.Task, Task.Delay(5000));

        if (winner == firstData.Task)
        {
            var elapsed = await firstData.Task;
            results.Add(elapsed);
            if (runNumber == 1)
            {
                coldMs = elapsed;
            }

            Console.WriteLine($"  run {runNumber,2}: {elapsed,7:F1} ms{(runNumber == 1 ? "   <- cold" : "")}");

            capture.StopRecording();

            // Wait (bounded) for the capture thread to actually finish
            // before disposing. Disposing a WasapiCapture while its
            // background capture thread is still calling into the COM
            // AudioClient/CaptureClient is a real race -- it can throw
            // during Dispose, or leave the device endpoint in a state
            // where the *next* iteration's fresh open fails or hangs. The
            // bound keeps a stuck stop from hanging the whole probe; if it
            // doesn't fire in time, Dispose() below still runs, which is
            // best-effort but no worse than an unbounded wait.
            await Task.WhenAny(stopped.Task, Task.Delay(2000));
        }
        else if (winner == stopped.Task)
        {
            // The capture stopped on its own -- before we ever called
            // StopRecording() and before any DataAvailable callback
            // fired. THIS, not a `FAILED` line from the outer try/catch,
            // is the real signal for a WASAPI shared-mode conflict (e.g.
            // another application already holding the device). See the
            // README's concurrency section: this is what to watch for
            // while Voice Typing or another app holds the microphone.
            var detail = conflictMessage ?? "(RecordingStopped fired with no exception attached)";
            Console.WriteLine($"  run {runNumber,2}: CONFLICT - capture stopped before any data arrived: {detail}");
            conflictCount++;
        }
        else
        {
            Console.WriteLine($"  run {runNumber,2}: TIMED OUT after 5000 ms");
            timeoutCount++;

            capture.StopRecording();
            await Task.WhenAny(stopped.Task, Task.Delay(2000));
        }
    }
    catch (Exception ex)
    {
        // This only catches *synchronous* failures -- e.g. GetDevice() or
        // the AudioClient activation inside the WasapiCapture constructor
        // throwing directly on this thread. It does NOT catch a WASAPI
        // Initialize-time conflict; that is the realistic shape a
        // shared-mode conflict takes, and it is handled above as CONFLICT
        // / conflictCount instead, because NAudio reports it via
        // RecordingStopped on the background capture thread rather than
        // throwing it back through StartRecording(). Do not treat this
        // FAILED path as the shared-mode-conflict signal; see README.
        Console.WriteLine($"  run {runNumber,2}: FAILED - {ex.GetType().Name}: {ex.Message}");
        errorCount++;
    }
    finally
    {
        // capture.Dispose() releases the underlying WASAPI AudioClient
        // (the same one cached on `freshDevice`), which is what actually
        // needs to be released each iteration. `freshDevice` itself
        // (the MMDevice wrapper) is not explicitly disposed here: whether
        // NAudio.CoreAudioApi.MMDevice implements IDisposable in the
        // resolved package version was not confirmed by compiling, and
        // guessing at that with an `is IDisposable` pattern risks a
        // compile error instead of a safe no-op if MMDevice turns out to
        // be sealed and non-disposable. Letting it go out of scope and be
        // GC'd is correct either way; if you want to double check, look
        // at the installed NAudio source for `class MMDevice : IDisposable`
        // and add `freshDevice.Dispose();` here if present.
        capture?.Dispose();
    }

    await Task.Delay(500);
}

// Print the attempt breakdown unconditionally, before the results.Count
// == 0 early-out below. If every run conflicts (e.g. shared mode
// genuinely failing to co-open while another app holds the device -- the
// actual failure shape the concurrency check is looking for), succeeded
// would be 0 and the summary would otherwise never print, hiding exactly
// the information that matters most for that check.
Console.WriteLine($"\n  attempted : {iterations}");
Console.WriteLine($"  succeeded : {results.Count}");
Console.WriteLine($"  conflicts : {conflictCount}   (capture stopped before any data arrived -- this," +
                   " not a `failed` line, is the shared-mode-conflict signal; see README)");
Console.WriteLine($"  timed out : {timeoutCount}");
Console.WriteLine($"  failed    : {errorCount}");

if (results.Count == 0)
{
    Console.Error.WriteLine("\nNo successful measurements -- no latency percentiles to report.");
    if (conflictCount > 0)
    {
        Console.Error.WriteLine($"{conflictCount} run(s) reported CONFLICT. If another application was " +
                                 "holding the device, this is the escalation signal described in the README " +
                                 "-- shared mode may not be granting concurrent access on this hardware.");
    }
    return 1;
}

var sorted = results.OrderBy(x => x).ToList();
double Percentile(double p) => sorted[Math.Min(sorted.Count - 1, (int)Math.Ceiling(p / 100.0 * sorted.Count) - 1)];

Console.WriteLine(coldMs.HasValue
    ? $"  cold      : {coldMs.Value,7:F1} ms"
    : "  cold      : N/A (run 1 did not succeed -- see \"run  1\" line above)");
Console.WriteLine($"  min       : {sorted.First(),7:F1} ms");
Console.WriteLine($"  p50       : {Percentile(50),7:F1} ms");
Console.WriteLine($"  p95       : {Percentile(95),7:F1} ms");
Console.WriteLine($"  max       : {sorted.Last(),7:F1} ms");
Console.WriteLine("\n  spec assumes 20-80 ms for this stage. The line below adds an assumed");
Console.WriteLine("  ~100 ms for network transit, remote capture, and prefill -- that 100 ms is");
Console.WriteLine("  an unverified placeholder from the design budget, not something this probe");
Console.WriteLine("  measures. Treat this line as illustrative arithmetic, not a measurement:");
Console.WriteLine($"  {300 - Percentile(95) - 100:F0} ms nominal headroom to the 300 ms p95 target.");

return 0;
