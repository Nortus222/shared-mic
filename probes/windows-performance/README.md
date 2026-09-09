# Windows performance report

The [September 8 report](../../docs/performance/2026-09-08/report.html) combines real
microphone open timings, real-agent loopback measurements, synthetic benchmarks of
production code, functional test results and a source review. It changes no product code.

`Program.cs` references the Windows agent directly. It measures normalization,
resampling, framing, queue operations and `MicCaptureService` with synthetic input.
The encoding sink mirrors `ControlConnection.OnCaptureFrame`, then drains immediately.
It excludes the WASAPI adapter, TLS, network I/O, contention and Mac rendering.
Timing percentiles describe 40 batch averages, not individual callback tails.

`loopback.py` starts a separate headless Release agent with a temporary identity and
an available loopback port. It uses the project's Python mock client over pinned TLS
and the product's pinned microphone. It measures 15 seconds idle, 20 START/STOP cycles,
30 seconds streaming and 15 seconds settled after STOP. Credentials stay in memory;
audio is consumed and discarded. The temporary agent and its identity are removed on
normal completion or an exception. Existing agent processes and settings are untouched.

The Windows CPU sample uses process CPU-time deltas, not system utilization. The
30-second sample is too short to characterize a process that records only one
15.625 ms CPU increment. Working-set endpoints are not a leak test.

## Reproduce the measurements

Run from a feature worktree. Use the .NET SDK selected from `windows/`, a Python
virtualenv containing `harness` dependencies and pytest, and the Samson Meteorite mic.
The example reuses the existing Windows virtualenv; replace that path if needed.
Run timing experiments sequentially, without simultaneous builds or tests.

```powershell
$reportDir = Join-Path (Get-Location) 'docs/performance/2026-09-08'
$reportPython = 'C:/Users/nortu/dev/shared-mic/harness/.venv/Scripts/python.exe'
New-Item -ItemType Directory -Force $reportDir | Out-Null

Push-Location windows
dotnet build ../probes/windows-performance/WindowsPerformance.csproj -c Release
dotnet build ../probes/windows-wasapi-latency/WasapiLatencyProbe/WasapiLatencyProbe.csproj -c Release
Pop-Location

$previousTiering = $env:DOTNET_TieredCompilation
try {
    $env:DOTNET_TieredCompilation = '0'
    dotnet probes/windows-performance/bin/Release/net10.0-windows/WindowsPerformance.dll |
        Set-Content -Encoding utf8 "$reportDir/benchmark.json"
} finally {
    $env:DOTNET_TieredCompilation = $previousTiering
}

# Choose the Samson Meteorite index from the probe's device list.
# This run used index 1. Do not assume device indices remain stable.
dotnet probes/windows-wasapi-latency/WasapiLatencyProbe/bin/Release/net10.0-windows/WasapiLatencyProbe.dll 20 |
    Tee-Object -FilePath "$reportDir/wasapi.txt"

& $reportPython probes/windows-performance/loopback.py "$reportDir/loopback.json"

Push-Location windows
dotnet build SharedMic.Windows.sln -c Release
dotnet test SharedMic.Windows.sln -c Release --no-build `
    --logger 'trx;LogFileName=windows-tests.trx' --results-directory $reportDir
Pop-Location

Push-Location harness
$previousPythonPath = $env:PYTHONPATH
try {
    $env:PYTHONPATH = (Get-Location).Path
    & $reportPython -m pytest -q --durations=10 --junitxml="$reportDir/harness-tests.xml"
} finally {
    $env:PYTHONPATH = $previousPythonPath
}
Pop-Location
```

Check each command's exit code before interpreting results. The committed snapshot
includes command logs, exit codes, environment metadata and raw test XML. Build time
was measured with PowerShell `Stopwatch`; it was a warm solution build because the
benchmark had already built the agent. Windows and Python functional suites ran in
parallel with each other, separately from performance measurements.

## Render and open the saved snapshot

`render_report.py` renders the September 8 evidence, including its fixed source-review
commentary. It is a snapshot renderer, not a general benchmark regression tool. For
a new baseline, refresh `environment.json`, build and test exit-code JSON, command logs
and the review text as well as measurements. Do not label a rerun with old metadata.

```powershell
py probes/windows-performance/render_report.py docs/performance/2026-09-08
Start-Process (Resolve-Path docs/performance/2026-09-08/report.html).Path
```

The HTML includes its styles and chart, so it opens without a server. Evidence links
refer to sibling files, while source links point to the measured Git commit.

Written by GPT-6 via Codex, on behalf of Ihor.
