# shared-mic

On-demand sharing of one USB microphone physically attached to a Windows host, consumed from
macOS through a virtual audio device. Audio crosses the network only while macOS has active
microphone demand.

## Integration

- **PR target branch: `main`.** All feature PRs target `main`. Do not target any other branch.
- `main` is the integration branch. This checkout is read-only for feature work: do not implement,
  stage, commit, switch branches, or merge here.
- Feature work happens in a worktree at `.claude/worktrees/<slug>` on a dedicated feature branch.
- Never use `git stash`, force-push, or merge a PR. The owner controls integration.

## Layout

```
docs/superpowers/specs/   design specs (source of truth for what we're building)
protocol/                 protocol-v1.md — the wire contract both platforms implement
windows/                  SharedMic.Windows.sln — C# / .NET LTS agent
macos/                    SharedMic.xcodeproj — Swift menu-bar agent
```

`protocol/protocol-v1.md` is the contract between the two platforms. Changing it means changing
both implementations and the conformance harness. Treat it as an API, not an implementation detail.

## Commands

The macOS agent project is created in a later phase; there is nothing to build for it yet. The
protocol harness, both Phase 0 probes, and the Phase 1 Windows agent exist now.

**Windows agent (from `windows\`, on the Windows host).** Requires the .NET SDK pinned in
`windows/global.json` (10.0.302). The `net10.0-windows` target framework and WinForms tray mean
these do not build on macOS.

```powershell
dotnet build SharedMic.Windows.sln                   # Build succeeded. 0 Warning(s) 0 Error(s)
dotnet test SharedMic.Windows.sln                    # 228 tests
dotnet run --project SharedMic.Agent                 # tray icon plus a console log
dotnet run --project SharedMic.Agent -- --headless   # console only, Ctrl+C to quit
```

What has actually been run on this Windows host, as of 2026-08-11: `build` and `test` exactly as
above; the tray host as `dotnet run --project SharedMic.Agent -- --loopback-only --port 47899
--data-dir <temp>` (driven end to end by `drive_windows_agent.py --mode session`); and the headless
host in Task 14, launched from the built `SharedMic.Agent.exe` rather than through `dotnet run`.

Other flags: `--port N`, `--no-mic`, `--device-label TEXT`, `--data-dir PATH`, `--loopback-only`.
Phase 1 is transport and security only — `--no-mic` and `--device-label` are configuration flags,
not device queries, because there is no capture path yet.

The `.csproj` files are XML: **never put a doubled hyphen inside an `<!-- -->` comment.** It is
illegal XML and fails the build with `MSB4025`.

**Harness (from `harness/`).** Use the project virtualenv's interpreter explicitly rather than
relying on `PATH` or activation; the interpreter path is layout-specific,
`.venv\Scripts\python.exe` on Windows and `.venv/bin/python` on POSIX. Note the leading dot in
`.venv`. (Per the Phase 0 findings, the Mac used for that work had no bare `python` on `PATH` and a
system `python3` without `pytest`, and carried a stale `harness/venv` alongside `.venv`; none of
that is checkable from here.)

Of the four below, `pytest` and `drive_windows_agent.py --mode session` were run on this Windows
host; the editable install was done when the virtualenv was created, and `generate_vectors.py` has
deliberately not been run here — nothing under `protocol/` changed.

```powershell
cd harness
.venv\Scripts\python.exe -m pip install -e ".[dev]"    # already done; cryptography builds from source and takes several minutes
.venv\Scripts\python.exe -m pytest -q                  # the conformance suite (101 tests)
.venv\Scripts\python.exe tools\generate_vectors.py     # regenerate protocol/vectors/*.json — a deliberate act, see protocol-v1.md §10
.venv\Scripts\python.exe tools\drive_windows_agent.py --host 127.0.0.1 --port 47800 `
    --pairing <pairing-string> --fingerprint <hex> --mode session
```

`drive_windows_agent.py` points the mock Mac client at a running Windows agent. Its `--mode` values
are `session` (handshake, heartbeat, idempotent START/STOP, zero audio bytes), `nack` (run the agent
with `--no-mic`), and `lockout` (five bad-token attempts then the 30-second refusal). Take
`--fingerprint` from the agent's startup banner, which prints it on every start. The startup banner
prints `--pairing` **only on the run that first mints the identity** — it is a live credential and
`--headless > agent.log` would otherwise write it into a plaintext log on every launch. On later
starts take it from the tray menu, which still shows it on demand.

**macOS demand-detection probe (from `probes/macos-demand/`).** Per
`docs/superpowers/probes/2026-08-08-macos-demand-findings.md`, this was built and run on the target
Mac (macOS 26.6.1) during Phase 0. It is Swift and Core Audio, so nothing about it is checkable
from the Windows host:

```sh
cd probes/macos-demand
swiftc -O -o demand-probe DemandProbe.swift
./demand-probe --self-test   # automated; ./demand-probe --watch for live manual observation
```

**Windows WASAPI latency probe (from `probes/windows-wasapi-latency/`).** Written for
`net10.0-windows` and NAudio, both Windows-only. The owner has built and run it on the actual
Windows host (Samson Meteorite Mic, NAudio 2.2.1, 0 warnings / 0 errors); see
`docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md` for the results and
`probes/windows-wasapi-latency/README.md` for the procedure:

```powershell
cd probes\windows-wasapi-latency\WasapiLatencyProbe
dotnet build --no-incremental
dotnet run --project WasapiLatencyProbe -- 20
```

## Design constraints that are not negotiable

These come from the approved spec. Changing any of them is a spec change, not an implementation
decision.

- **Zero microphone payload while macOS has no input demand.** Verified by an idle byte counter,
  not by inspection.
- **WASAPI shared mode only.** Exclusive mode would take the mic away from Windows apps.
- **Never log or persist audio payload.** Counters and lifecycle events only.
- **The audio render callback is real-time safe.** No allocation, locks, logging, or network I/O.
  Ever. It reads a lock-free ring buffer and zero-fills on underrun.
- **Never change the Mac's default output device.** Target BlackHole explicitly by UID.
- **A pinned-certificate mismatch is a hard stop.** No auto-retry, no silent re-pair.

## Conventions

- Resolve audio devices by stable identifier — macOS device UID, Windows MMDevice endpoint ID —
  never by display name.
- Keep network code out of audio callbacks and audio code out of network paths. The three pure
  units (`PcmNormalizer`, `SessionStateMachine`, `PCMRingBuffer`) hold the tricky logic and carry
  real unit tests; everything touching Core Audio, WASAPI, or sockets is a thin shell around them.
