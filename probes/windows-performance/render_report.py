"""Render the checked-in measurement files as one self-contained HTML report."""

import html
import json
import math
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

folder = Path(sys.argv[1])


def read(name):
    raw = (folder / name).read_bytes()
    return raw.decode("utf-16") if raw.startswith((b"\xff\xfe", b"\xfe\xff")) else raw.decode("utf-8-sig")


def data(name):
    return json.loads(read(name))


def esc(value):
    return html.escape(str(value))


def percentile(values, p):
    return sorted(values)[math.ceil(len(values) * p) - 1]


env = data("environment.json")
bench = data("benchmark.json")
loop = data("loopback.json")
build = data("build.json")
trx = ET.fromstring(read("windows-tests.trx"))
ns = {"t": "http://microsoft.com/schemas/VisualStudio/TeamTest/2010"}
counts = trx.find("t:ResultSummary/t:Counters", ns).attrib
pytest = ET.fromstring(read("harness-tests.xml")).find("testsuite").attrib
wasapi_text = read("wasapi.txt")
opens = [float(value) for value in re.findall(r"run\s+\d+:\s+([\d.]+) ms", wasapi_text)]
assert len(opens) == 20, "WASAPI did not produce 20 successful measurements"
assert build["exitCode"] == 0 and data("windows-tests.json")["exitCode"] == 0
assert data("harness-tests.json")["exitCode"] == 0
capture = next(r for r in bench["results"] if r["name"].endswith("48000 Hz / 20 ms input"))
active = loop["active"]
activation95 = percentile(loop["activationMs"], 0.95)
source = f"https://github.com/Nortus222/shared-mic/blob/{env['sourceCommit']}/"


def link(path, line):
    return f'<a href="{source}{path}#L{line}">{esc(Path(path).name)}:{line}</a>'


def table(headers, rows):
    return '<div class="scroll"><table><thead><tr>' + ''.join(f'<th>{h}</th>' for h in headers) + \
        '</tr></thead><tbody>' + ''.join('<tr>' + ''.join(f'<td>{c}</td>' for c in row) + '</tr>'
                                       for row in rows) + '</tbody></table></div>'


bench_table = table(["Operation", "Median batch mean, µs", "p95 batch mean, µs", "Bytes / operation", "Gen 0 / 1 / 2"], [
    [esc(r["name"]), f'{r["medianUs"]:.3f}', f'{r["p95BatchMeanUs"]:.3f}',
     f'{r["allocatedBytesPerOperation"]:,.0f}',
     f'{r["gen0Collections"]} / {r["gen1Collections"]} / {r["gen2Collections"]}']
    for r in bench["results"]])
runtime_table = table(["Phase", "Duration", "Audio frames", "CPU, one core", "CPU, machine", "Working set, start → end"], [
    [label, f'{loop[key]["seconds"]:.2f} s', str(loop[key]["audioFrames"]),
     f'{loop[key]["cpuPercentOneCore"]:.3f}%', f'{loop[key]["cpuPercentMachine"]:.3f}%',
     f'{loop[key]["workingSetBeforeBytes"] / 1048576:.1f} → {loop[key]["workingSetAfterBytes"] / 1048576:.1f} MiB']
    for key, label in [("idle", "Connected, before START"), ("active", "Streaming"), ("stopped", "Settled after STOP")]])
latency_table = table(["Measurement", "Samples", "First", "Median", "p95", "Maximum"], [
    [label, str(len(values)), *[f'{v:.1f} ms' for v in [values[0], percentile(values, .5), percentile(values, .95), max(values)]]]
    for label, values in [("WASAPI construction → first nonempty callback", opens),
                          ("START call → first frame consumed by Python client", loop["activationMs"])]] )

bars = ''.join(f'<rect x="{58 + i * 32}" y="{205 - value}" width="21" height="{value}" rx="3" '
               f'fill="{"#d88535" if i == 0 else "#277d8f"}"><title>Open {i+1}: {value:.1f} ms</title></rect>'
               f'<text x="{68+i*32}" y="226" text-anchor="middle">{i+1}</text>' for i, value in enumerate(opens))
chart = f'''<svg viewBox="0 0 730 250" role="img" aria-label="Twenty WASAPI open latency measurements. First open 130.2 milliseconds; other opens between 76.8 and 79.5 milliseconds.">
<g font-size="11" fill="#617184" font-family="system-ui">
{''.join(f'<line x1="48" x2="706" y1="{205-v}" y2="{205-v}" stroke="#e1e7ef"/><text x="40" y="{209-v}" text-anchor="end">{v}</text>' for v in [0,50,100,150])}
<text x="16" y="30">ms</text>{bars}<text x="380" y="247" text-anchor="middle">Open cycle</text></g></svg>'''

slowest = sorted(trx.findall("t:Results/t:UnitTestResult", ns),
                 key=lambda x: x.attrib["duration"], reverse=True)[:5]
test_table = table(["Longest Windows tests", "Recorded duration"],
                   [[esc(t.attrib["testName"]), esc(t.attrib["duration"])] for t in slowest])
verification = dict(windows=counts, harness=pytest, build=build,
                    windowsWallSeconds=data("windows-tests.json")["wallSeconds"])
(folder / "verification.json").write_text(json.dumps(verification, indent=2) + "\n", encoding="utf-8")

report = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Shared Mic · Performance report · {env['localDate']}</title>
<style>
:root{{--ink:#182d43;--muted:#56687b;--teal:#176c7b;--line:#dde5ed;--paper:#fff;--bg:#f2f5f8}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--ink);font:15px/1.65 system-ui,-apple-system,Segoe UI,sans-serif}}
header{{background:#102d43;color:#fff;padding:54px max(24px,calc((100% - 1120px)/2)) 42px}}
.eyebrow{{letter-spacing:.13em;text-transform:uppercase;font-size:11px;color:#8fd1d8;font-weight:700}}
h1{{font-size:clamp(32px,5vw,50px);line-height:1.12;margin:12px 0 18px;letter-spacing:-.035em}}
header p{{max-width:780px;color:#c5d5e2;font-size:17px}}.meta{{font:12px/1.8 ui-monospace,Consolas,monospace;color:#a8bfce}}
main{{max-width:1170px;margin:auto;padding:28px 24px 50px}}.cards{{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-bottom:24px}}
.card,section{{background:var(--paper);border:1px solid var(--line);border-radius:12px}}.card{{padding:22px}}
.card .label{{font-size:12px;color:var(--muted)}}.metric{{font-size:32px;font-weight:700;letter-spacing:-.04em;line-height:1.5}}
.card small{{display:block;color:var(--muted);font-size:12px}}section{{padding:28px 30px;margin:20px 0}}h2{{font-size:23px;margin:0 0 12px;letter-spacing:-.02em}}
h3{{font-size:17px;margin:22px 0 7px}}p{{margin:9px 0 15px}}a{{color:var(--teal);text-underline-offset:3px}}.note{{border-left:3px solid #d88535;background:#fff8ed;padding:14px 18px;margin:18px 0}}
.small{{font-size:13px;color:var(--muted)}}.tag{{font-size:11px;font-weight:700;letter-spacing:.04em;color:var(--teal);text-transform:uppercase}}
.scroll{{overflow-x:auto}}table{{width:100%;border-collapse:collapse;font-size:13px;margin:14px 0}}th{{color:var(--muted);text-align:left;font-weight:600;background:#f4f7fa}}td,th{{padding:11px 12px;border-bottom:1px solid var(--line)}}td:not(:first-child){{font-variant-numeric:tabular-nums;white-space:nowrap}}
svg{{display:block;max-width:800px;width:100%;margin:0 auto}}.grid{{display:grid;grid-template-columns:1fr 1fr;gap:28px}}code,pre{{font:12px/1.65 ui-monospace,Consolas,monospace}}pre{{background:#102d43;color:#e2edf4;padding:18px;border-radius:8px;overflow:auto}}li{{margin:8px 0}}footer{{font-size:12px;color:var(--muted);padding:10px 4px}}
@media(max-width:760px){{.cards{{grid-template-columns:1fr 1fr}}.grid{{grid-template-columns:1fr}}section{{padding:22px 18px}}main{{padding:20px 12px}}}}
@media print{{body{{background:white}}header{{padding:24px;background:white;color:var(--ink)}}header p,.meta{{color:var(--muted)}}main{{padding:0}}section,.card{{break-inside:avoid}}.scroll{{overflow:visible}}table{{font-size:10px}}}}
</style></head><body>
<header><div class="eyebrow">Shared Mic / Windows measurement baseline</div><h1>Performance report</h1>
<p>The measured Windows processing cost is small relative to each 20 ms audio frame. Capture startup and Mac buffering deserve the next measurements. End-to-end LAN targets remain unverified.</p>
<div class="meta">{env['localDate']} · {esc(env['cpu'].strip())}<br>Source {env['sourceCommit'][:12]} · Release · {esc(bench['runtime'])}</div></header>
<main><div class="cards">
<div class="card"><div class="label">WASAPI open · p95</div><div class="metric">{percentile(opens,.95):.1f} ms</div><small>20 / 20 successful hardware opens</small></div>
<div class="card"><div class="label">Local TLS activation · p95</div><div class="metric">{activation95:.1f} ms</div><small>START to received audio; no Mac playback</small></div>
<div class="card"><div class="label">Live audio cadence</div><div class="metric">{active['framesPerSecond']:.2f} fps</div><small>{active['sequenceGaps']} sequence gaps in {active['seconds']:.1f} seconds</small></div>
<div class="card"><div class="label">Idle microphone payload</div><div class="metric">{loop['idle']['pcmBytes'] + loop['stopped']['pcmBytes']} B</div><small>15 seconds before START and after STOP</small></div></div>

<section><span class="tag">Measured on this host</span><h2>Hardware and activation latency</h2>
<p>The Samson Meteorite microphone opened successfully in shared mode for all 20 probe cycles, with zero conflicts, timeouts or synchronous failures. Its shared format was 48 kHz, 32-bit, two channels. No concurrent application was deliberately started for a co-access check.</p>
{latency_table}{chart}
<p class="small">Percentiles use nearest rank. The first hardware open is highlighted. “First” means first in this process, not first after a machine reboot. With 20 samples, p95 is the second-highest value and excludes the first-open maximum.</p>
<div class="note">The design asks for activation below 300 ms p95 and steady-state end-to-end delay below 150 ms p95. Local TLS reception excludes LAN transit, demand detection, BlackHole prefill and render scheduling. It cannot certify either target.</div>
<p class="small">The August probe recorded 78.5 ms median, 93.4 ms p95 and 114.1 ms first-open latency. This run is a new baseline, not a controlled regression comparison. The old probe's final “~100 ms” headroom calculation is an unmeasured placeholder and is excluded from these conclusions.</p></section>

<section><span class="tag">Real agent + local TLS</span><h2>Streaming cost and idle behavior</h2>{runtime_table}
<p>Active reception averaged <strong>{active['framesPerSecond']:.2f} frames/s</strong> against the protocol's 50 frames/s, with <strong>{active['sequenceGaps']} sequence gaps</strong> during the active interval. The fixed format carries 96,000 PCM bytes/s and 96,850 framed bytes/s, or 0.775 Mbit/s before TLS, TCP and IP overhead.</p>
<p class="small">GetProcessTimes measures cumulative agent CPU time. One-core percentage is CPU seconds / elapsed seconds × 100; machine percentage divides by {env['logicalProcessors']} logical processors. The active CPU delta was only {active['cpuSeconds']*1000:.3f} ms, so counter granularity makes this a coarse sample; zero idle CPU means no recorded increment, not literally no CPU work. A longer trace is needed to assess the design's average CPU target below 2%. Working set is sampled at interval boundaries. This short run does not establish peak memory, leak freedom or long-term CPU use. The headless agent excludes tray UI overhead.</p>
<p class="small">The client sent PING every five seconds to keep the measurement alive, rather than the product's 15-second cadence. Only AUDIO payload counters were measured; heartbeat/network idle bandwidth below 1 KB/min was not verified. The post-STOP interval starts after a 500 ms settling period, so it does not measure immediate teardown latency. Audio was discarded in memory.</p></section>

<section><span class="tag">Synthetic production-code benchmark</span><h2>Audio processing and allocations</h2>{bench_table}
<p>The 48 kHz capture-service path took <strong>{capture['medianUs']:.2f} µs median</strong> per 20 ms frame, about {capture['medianUs']/200:.3f}% of that frame interval. Its allocation rate projects to <strong>{capture['allocatedBytesPerOperation']*50/1e6:.2f} MB/s</strong> at 50 frames/s. This projection excludes the WASAPI input array, TLS and socket work.</p>
<p>The simulated stalled sender retained {bench['queueCheck']['depth']} queue entries and evicted {bench['queueCheck']['evicted']} of {bench['queueCheck']['offered']} offers. The probe reuses one frame array, so this confirms the 25-entry audio queue bound, not distinct payload memory. At 50 frames/s, the queue permits up to 500 ms of application backlog; it does not bound socket or receiver queues.</p>
<p class="small">Each operation has 5,000 warm-up calls and 40 batches of 1,000 calls. Table timings are quantiles of batch averages, not individual callback p95/p99. Allocations come from GetAllocatedBytesForCurrentThread; GC counts exclude the forced collections before measurement. The 100 ms input operation produces five frames. Synthetic inputs are precomputed, and an immediate, uncontended dequeue replaces TLS transmission. Tiered compilation was disabled for this microbenchmark to avoid optimization transitions during timing; the live agent used its normal settings. Single process, single run, ordinary desktop background load.</p></section>

<section><span class="tag">Source review · not observed runtime failures</span><h2>Priorities for follow-up</h2>
<h3>1. Validate the Mac render buffer's concurrent depth updates</h3>
<p>RenderBridge stores depth in a plain <code>count</code>. Producer and consumer threads both modify it; the memory barriers do not make those read-modify-write updates atomic. Lost updates could affect depth, underruns and audio correctness. Use an atomic single-producer/single-consumer design and stress concurrent access before trusting its counters. {link('macos/SharedMic/Audio/AudioRenderer.swift',118)}, {link('macos/SharedMic/Audio/AudioRenderer.swift',147)}, {link('macos/SharedMic/Audio/AudioRenderer.swift',178)}.</p>
<h3>2. Measure recovery after an audio burst</h3>
<p>The Mac bridge holds up to 1,000 ms and evicts toward 800 ms only after exceeding 900 ms. Ordinary drift correction removes 20 ms at most once per five seconds above 120 ms. With matched input/output rates, reducing 800 ms to 120 ms needs 34 corrections, about 170 seconds. This is arithmetic from policy constants, not an observed delay. Test burst recovery separately from clock drift before changing the policy. {link('macos/SharedMic/Audio/AudioRenderer.swift',105)}, {link('macos/SharedMic/Audio/AudioRenderer.swift',577)}, {link('macos/SharedMic/Audio/DriftController.swift',24)}.</p>
<h3>3. Profile capture callback tails before removing copies</h3>
<p>Windows allocates a float input array, copies each pending group with <code>GetRange().ToArray()</code>, normalizes and encodes under synchronous callback execution. The measured processing cost is low, but the allocations and locks can produce GC or contention tails absent from the average. Profile individual callbacks during a long session before replacing these copies with a preallocated handoff. {link('windows/SharedMic.Agent/Audio/WasapiAudioCapture.cs',102)}, {link('windows/SharedMic.Agent/Audio/MicCaptureService.cs',209)}, {link('windows/SharedMic.Agent/Net/ControlConnection.cs',601)}.</p>
<h3>4. Bound pending work before the Mac renderer</h3>
<p>Every incoming frame schedules an asynchronous renderer task retaining PCM, plus a coordinator task. The renderer's bounded ring only applies after those tasks execute. A stalled dispatch queue can therefore accumulate stale PCM outside that ring. Measure queue delay under a deliberate renderer stall; a bounded handoff may be warranted. {link('macos/SharedMic/Net/ConnectionCoordinator.swift',564)}.</p>
<p class="small">These are proposed follow-ups. No production implementation changed in this report.</p></section>

<section><span class="tag">Verification</span><h2>Tests and build</h2>
<div class="grid"><div><h3>{counts['passed']} Windows tests passed</h3><p>{counts['failed']} failed; {int(counts['total'])-int(counts['executed'])} not executed. Release suite, {verification['windowsWallSeconds']:.2f} seconds command wall time including the test runner.</p></div>
<div><h3>{pytest['tests']} protocol harness tests passed</h3><p>{pytest['failures']} failures; {pytest['errors']} errors; {pytest['skipped']} skipped. JUnit suite duration {float(pytest['time']):.2f} seconds.</p></div></div>
<p>The full Windows solution build succeeded in {build['wallSeconds']:.2f} seconds command wall time, with three existing CS0067 unused-event warnings in TrayAudioTests and no errors. The agent had already been built for the benchmark, so this is a warm build, not a clean-build benchmark. SDK {esc(build['sdk'])} satisfied the repository's latestFeature roll-forward policy.</p>
{test_table}<p class="small">Test duration includes intentional waits and functional checks. It is not a product latency benchmark. The two suites ran concurrently with each other, after the standalone benchmarks and before the live-agent measurement.</p></section>

<section><span class="tag">Scope and reproduction</span><h2>What this report does and does not establish</h2>
<p>{esc(env['os'])} {esc(env['osVersion'])}; {env['memoryBytes']/1073741824:.2f} GiB visible RAM; {env['logicalProcessors']} logical processors; {esc(bench['architecture'])}. Measurements ran on the current feature worktree at source commit <code>{env['sourceCommit']}</code>. The baseline is dated September 8 in America/Los_Angeles; raw timestamps use UTC September 9.</p>
<ul><li>Measured: Windows shared-mode open latency, local TLS activation, short-run agent CPU and working set, idle audio counters, synthetic processing cost and allocations.</li>
<li>Unverified: Mac build/tests and CPU, real demand-to-playback latency, LAN jitter and retransmission, BlackHole underruns, audio quality, long-session drift, renderer concurrency, concurrent microphone use and end-to-end idle network bandwidth.</li>
<li>There is no earlier controlled benchmark for this source revision. No performance regression or improvement percentage is claimed.</li></ul>
<p>Reproduction commands and measurement definitions are in <a href="../../../probes/windows-performance/README.md">the probe README</a>. This HTML contains its own CSS and chart and works without a server or network. Source links use the measured Git commit.</p>
<p class="small">Evidence: <a href="benchmark.json">microbenchmark JSON</a> · <a href="loopback.json">live-agent JSON</a> · <a href="wasapi.txt">hardware probe log</a> · <a href="verification.json">verification summary</a> · <a href="windows-tests.txt">Windows test log</a> · <a href="harness-tests.txt">harness test log</a> · <a href="solution-build.txt">build log</a> · <a href="environment.json">environment</a>.</p></section>
<footer>Written by {esc(env['model'])} via {esc(env['harness'])}, on behalf of Ihor. Generated from local measurements; no audio payload or pairing credentials are included.</footer>
</main></body></html>'''
(folder / "report.html").write_text(report, encoding="utf-8")
print(folder / "report.html")
