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

The Windows and macOS projects are created in Phase 1. Until then there is nothing to build, and
this section is deliberately empty rather than aspirational. Add real, verified commands here as
each project lands — not before.

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
