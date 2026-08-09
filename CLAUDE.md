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

The Windows and macOS agent projects are created in Phase 1; there is nothing to build for them
yet. The protocol harness and both Phase 0 probes exist now. Every command below has actually been
run on this machine — see `harness/README.md` and `docs/superpowers/probes/` for more detail.

**Harness (from `harness/`).** There is no bare `python` on this machine's `PATH`, and the system
`python3` has no `pytest` installed — use the project virtualenv's interpreter explicitly rather
than relying on `PATH` or activation:

```sh
cd harness
.venv/bin/python -m pip install -e '.[dev]'   # install (already done in .venv; cryptography builds from source and takes several minutes)
.venv/bin/python -m pytest -v                 # run the conformance suite (96 tests)
.venv/bin/python tools/generate_vectors.py    # regenerate protocol/vectors/*.json — a deliberate act, see protocol-v1.md §10
```

**macOS demand-detection probe (from `probes/macos-demand/`).** Built and run on the target Mac
(macOS 26.6.1); see `docs/superpowers/probes/2026-08-08-macos-demand-findings.md` for full results:

```sh
cd probes/macos-demand
swiftc -O -o demand-probe DemandProbe.swift
./demand-probe --self-test   # automated; ./demand-probe --watch for live manual observation
```

**Windows WASAPI latency probe (from `probes/windows-wasapi-latency/`).** Written for
`net10.0-windows` and NAudio, both Windows-only. **Not yet built or run anywhere** — this repo has
no Windows machine. Do not treat the commands below as verified; they are what the owner runs on
the actual Windows host, from `probes/windows-wasapi-latency/README.md` and
`docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`:

```powershell
cd probes\windows-wasapi-latency\WasapiLatencyProbe
dotnet build
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
