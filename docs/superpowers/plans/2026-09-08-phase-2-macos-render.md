# macOS Agent Phase 2 — Audio Render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Manual START/STOP from the menu renders real microphone audio: frames arriving on the Phase 1 transport flow into a jitter buffer and out through BlackHole, with measured prefill, clock-drift correction, and a validated activation path. No behavior changes to the control plane unless a task explicitly calls for one.

**Architecture:** A new pure `Audio/` layer holds the tricky logic (`PCMRingBuffer`, `DriftController`) with real unit tests; thin shells (`BlackHoleDevice`, `AudioRenderer`) touch Core Audio/AudioToolbox. `ControlClient.handleAudio` stays the single insertion point but MUST NOT do renderer work on the control queue (that queue also services the heartbeat and handshake deadline — blocking it fabricates a peer-dead timeout; Phase 1 handoff note). Audio is handed to a dedicated renderer queue. The writer opens on entry to `STARTING` and closes after `STOPPING` drains — never held open at idle, never the system input device (§3.4).

**Tech Stack:** Swift 5 / SwiftUI menu-bar app, `AudioToolbox` AUHAL output unit targeting BlackHole by UID, `xcodebuild test` suite, Phase 0 Python harness (`MockWindowsServer` with `set_mic_present()`, synthetic `sine_frame` audio) as the peer.

## Global Constraints

Every task implicitly includes all of these.

**Where work happens.** Feature work happens on branch `feat/phase-2-macos-render` (PR target `main`). Never commit in the main checkout.

**Which machine runs which step.** Everything here runs on the Mac: `~/.rvm/bin/rvm default do ruby macos/project.rb` regenerates the project after adding/removing any `.swift` file (system ruby has no `xcodeproj` gem); `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64'` runs the suite (append `2>&1 | grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)"` to skip SwiftUI host noise). Harness peer via `harness/.venv/bin/python` — no bare `python`.

**Real-time safety (spec §6.4, non-negotiable).** The render callback reads the lock-free ring buffer and zero-fills on underrun. No allocation, no locks, no logging, no network I/O — ever. `PCMRingBuffer`/`DriftController` own the *accounting semantics* as single-threaded pure value types (same precedent as `FrameBuffer`/`SessionStateMachine`); the `AudioRenderer` task owns the *lock-free handoff* and proves the callback path allocates nothing.

**Audio rules (protocol §4).** Keep the strict 1,932-byte check exactly as is; keep the `sequence == 0` fresh-session baseline and the STOP_ACK-anchored reset in `handleAudio` (Phase 1 deliberate deviation #4 — the mock can emit frame 0 before its own START_ACK). PCM is s16 **little-endian**; header big-endian. Counters only, never payload, in logs and metrics.

**Device rules (§3.4, §6.4).** Target BlackHole explicitly by UID. Never modify the Mac default output device. Mono is duplicated to both BlackHole channels. `grep -rn "AudioUnit\|CoreAudio\|AudioToolbox\|BlackHole\|kAudioProcess" macos/SharedMic` must show hits ONLY under `macos/SharedMic/Audio/` until Phase 3 adds demand detection.

**Prefill watch item (spec §6.3).** Jitter prefill is BOTH the underrun lever AND the main remaining activation-latency lever: cold-start high corner is ~229 ms, so a 120 ms prefill leaves ~11 ms headroom. Measure both effects before fixing the figure (Task 6).

## File Structure

New files this plan creates (all under `macos/`):

| Path | Responsibility |
|---|---|
| `SharedMic/Audio/PCMRingBuffer.swift` | Pure SPSC ring: wraparound, underrun zero-fill, drop-oldest overflow, drift insert/drop primitives, depth/counters |
| `SharedMic/Audio/DriftController.swift` | Pure dwell logic: 120 ms high / 40 ms low watermarks, 5 s dwell, drop/insert-one-frame verdicts (§6.5) |
| `SharedMic/Audio/BlackHoleDevice.swift` | Find BlackHole by UID, presence check, unavailable guidance error |
| `SharedMic/Audio/AudioRenderer.swift` | AUHAL output to BlackHole UID, mono→stereo dup, real-time-safe callback, open-on-STARTING / close-after-STOPPING-drain |
| `SharedMicTests/PCMRingBufferTests.swift` | Spec §10.1: SPSC interleave, wraparound, underrun zero-fill, drift insert/drop |
| `SharedMicTests/DriftControllerTests.swift` | Watermark edges, dwell timing, jitter-vs-drift discrimination |
| `SharedMicTests/AudioRendererTests.swift` | Null-device lifecycle, drain-on-stop, no-default-device-touched |

Nothing under `protocol/`, `harness/`, `docs/superpowers/specs/`, or `probes/` is modified.

---

### Task 1: PCMRingBuffer (pure) + tests — DONE FIRST, unblocks all below

Spec §6.4, §10.1. Single-threaded pure value type; thread-handoff is Task 4's job.

- [ ] **Step 1: Write the failing test.** `PCMRingBufferTests.swift`: write→read round-trip exact samples; wraparound at small capacity; underrun zero-fills and counts; overflow drops oldest and counts; `dropOneFrame`/`insertSilenceFrame` incl. empty/full edges; `depthMs` math (48 samples/ms); unsafe-buffer `read(into:)` parity with allocating read.
- [ ] **Step 2: Run it and confirm it fails.** `xcodebuild test ... -only-testing:SharedMicTests/PCMRingBufferTests` fails (type missing).
- [ ] **Step 3: Implement.** `Audio/PCMRingBuffer.swift`: preallocated `[Int16]`, head/tail/count, capacity default 50 frames (1 s, ~96 KB); `writeFrame(pcm: Data)` requires exactly 1,920 bytes (precondition — misuse is a programmer error, `ControlClient` already validated 1,932); overflow drops oldest whole frames; `read(into: UnsafeMutableBufferPointer<Int16>) -> underrunCount` zero-fills remainder without allocating; `depthMs`, `availableSamples`, counters (`totalFramesWritten/Dropped`, `totalUnderrunSamples`).
- [ ] **Step 4: Run and confirm it passes.** New tests green; full suite still green; `ruby macos/project.rb` regen shows identifier-only diff (known Phase 1 gap).
- [ ] **Step 5: Commit.**

### Task 2: DriftController (pure) + tests

Spec §6.5. Pure struct so the 5-second dwell is testable without sleeping: time is injected.

- [ ] **Step 1: Write the failing test.** `DriftControllerTests.swift`: depth > 120 ms for 5 consecutive seconds → `.dropOneFrame` once, then dwell re-arms; depth < 40 ms for 5 s → `.insertSilenceFrame`; transient spike (1 s) → `.none` (jitter, not drift); depth inside band resets dwell; verdict rate ≤ 1 per few minutes at 100 ppm simulated drift.
- [ ] **Step 2: Run it and confirm it fails.**
- [ ] **Step 3: Implement.** `Audio/DriftController.swift`: `mutating func tick(depthMs: Double, now: Date) -> DriftAction`; watermark edges are strict (`>`/`needed); dwell tracked per side independently.
- [ ] **Step 4: Run and confirm it passes.**
- [ ] **Step 5: Commit.**

### Task 3: BlackHoleDevice — UID lookup, presence, guidance

Spec §3.4, §6.4. Thin shell; no audio flows yet.

- [ ] **Step 1: Write the failing test.** Presence/absence via injected device-list seam; wrong-UID device never selected; unavailable error carries setup guidance text.
- [ ] **Step 2: Run it and confirm it fails.**
- [ ] **Step 3: Implement.** `Audio/BlackHoleDevice.swift`: resolve by UID (constant in `SharedMicProtocol` — adding `blackholeUID` there is a config addition, not a protocol change); expose `isPresent`, `deviceID`, `unavailableMessage`. Never touches the default device — assert in test that no default-device setter is reachable from this type.
- [ ] **Step 4: Run and confirm it passes.** Unit tests green; on the target Mac with BlackHole installed, `isPresent == true` observed once by the owner.
- [ ] **Step 5: Commit.**

### Task 4: AudioRenderer — AUHAL output, safe callback, lifecycle

Spec §6.4. The only type allowed to touch the render thread.

- [ ] **Step 1: Write the failing test.** `AudioRendererTests.swift` with a null/null-output seam: `open` on STARTING with BlackHole UID; callback with empty buffer outputs zeros and counts an underrun; mono input duplicated to both channels; `closeAfterDrain` plays queued frames then closes; idle close leaves no open device (assert via device-open counter).
- [ ] **Step 2: Run it and confirm it fails.**
- [ ] **Step 3: Implement.** `Audio/AudioRenderer.swift`: AUHAL output unit, explicit UID, 48 kHz stereo; callback pulls from the lock-free bridge, zero-fills, dups mono→stereo; owns the `DriftController` tick (once per render quantum is too fast — tick on a 1 s cadence with current depth); writer opens on `STARTING`, closes after `STOPPING` drains. Callback code reviewed line-by-line for allocation/locks/logging.
- [ ] **Step 4: Run and confirm it passes.** Tests green; owner smoke test on target Mac: BlackHole receives sine frames from `MockWindowsServer`, default output device unchanged (verify in System Settings before/after).
- [ ] **Step 5: Commit.**

### Task 5: Wiring — handleAudio → renderer, STARTING/STOPPING hooks

The one control-plane touch. Keep it minimal and off the control queue.

- [ ] **Step 1: Write the failing test.** `ControlClientTests` + `ConnectionCoordinatorTests` extension: authenticated session + synthetic audio → frames land in the renderer bridge (assert via injected sink), control queue never blocks (heartbeat PONG still timely under a 50 fps burst); STOP → STOPPING drains bridge → STOP_ACK → renderer closed; byte counters (`audioBytesReceived`, PCM-bytes-today counter) reconcile with frames × 1,920.
- [ ] **Step 2: Run it and confirm it fails.**
- [ ] **Step 3: Implement.** `handleAudio` validates + counts as today, then forwards PCM to the renderer queue (async, bounded — full bridge drops oldest with a counter, never back-pressures the control queue). `SessionController` effects gain `.openRenderer` on `.starting` and `.closeRendererAfterDrain` on `.stopping`; `ConnectionCoordinator` executes them. `.stopTimedOut` closes the renderer (Phase 1 note: `.idle` does not guarantee a quiet wire — the renderer close must ride the timeout path too). Fix the parked minor at `PinnedTLSTransport.swift:373-381` while here (buffered-close error delivery).
- [ ] **Step 4: Run and confirm it passes.** Full `xcodebuild test` green; mock-server sine session renders to BlackHole with zero gap-count on a clean LAN run.
- [ ] **Step 5: Commit.**

### Task 6: Set the prefill figure (measurement, target Mac)

Spec §6.3–§6.4 watch item. Not a guess — run the matrix.

- [ ] **Step 1: Run the matrix.** Prefill ∈ {40, 60, 120} ms × conditions {quiet LAN, loaded Wi-Fi}: per cell, 20 activations recording underrun count in the first 2 s AND START-to-first-playable-frame latency.
- [ ] **Step 2: Fix the figure.** Minimize prefill subject to ≈0 underruns on quiet LAN; then check the cold-start sum against 300 ms p95. If 120 ms is needed for clean audio, the budget is ~289 ms — escalate as a design question, do not silently accept.
- [ ] **Step 3: Commit the constant + table.** Prefill constant and the measurement table land together.

### Task 7: End-to-end validation on the target Mac (owner-gated)

Spec §9/§10 rows owned by the Mac side.

- [ ] **Sequence resets to 0 (protocol §4 [CARRIED]).** Two manual sessions, assert second session's first frame `sequence == 0` with no gap counted (unit-covered in Phase 1; this is the wire proof with the real Windows agent).
- [ ] **30-min drift soak.** Continuous session; record drift corrections applied, underrun count, depth trace; pass = stable indefinitely, ≤ ~1 correction per few minutes, zero drift-induced underruns.
- [ ] **Raycast speech-onset timing.** 20 Raycast activations (Phase 3 automates; here manual START is the stand-in — record as baseline, not as the §9 verdict).
- [ ] **Simultaneous capture.** Windows app + Mac render concurrently; both receive speech.
- [ ] **Byte-counter sanity.** Idle 10 min → 0 PCM bytes; session → bytes == frames × 1,920. (Menu display of the daily total is Phase 4's diagnostics view; counting is this phase.)
- [ ] **Full suite green.** `xcodebuild test` all pass, harness `pytest -q` 101 passed, no changes outside `macos/` except this plan file.

## Measurements Appendix (maps to spec §9–§10)

| Spec row | Proved by |
|---|---|
| Sequence reset to 0 per session [CARRIED] | Task 7 wire check (both agents real) |
| 95-of-100 first-word, threshold frozen | Joint with Windows Task 7 (Mac contributes prefill half) |
| START-to-first-playable < 300 ms p95 | Task 6 matrix + Task 7 check |
| 30-min drift soak, stable buffer | Task 7 soak (drift corrections, underruns) |
| Simultaneous Windows+Mac capture | Task 7 matrix |
| BlackHole unavailable → clear error | Task 3 guidance path |
| 10-min idle → 0 PCM bytes | Task 7 counter check |
| TCP-vs-UDP verdict on real Wi-Fi | Deferred per §13-Q4 — record observations only |
