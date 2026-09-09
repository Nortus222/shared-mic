# Phase 4 — Reliability and Polish Implementation Plan

> **Status 2026-09-08:** Mac Tasks 1–6 implemented and green (279-test suite plus new suites) in `t3code/start-issue-16`. Windows Tasks 7/9/10 implemented blind in the same commit series — `dotnet test` on the Windows host must go green before merge. Task 8 verified with no changes. Task 11 (owner-gated acceptance) remains.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both agents start on their own, survive the night, and explain themselves: login-launch on both machines, clean recovery from sleep/wake and USB replug, zero-config discovery on the LAN, and the diagnostics view plus level meter that make the privacy guarantee and the activation budget visible rather than asserted. No session-lifecycle, demand-gate, or audio-path behavior changes except where sleep/wake and replug explicitly require them (issue #16).

**Architecture:** Pure models hold the tricky logic (`DiagnosticsSnapshot` aggregation, latency-histogram buckets, peak-hold meter math) with real unit tests; thin shells touch the OS (SMAppService login item, NSWorkspace sleep/wake, NetServiceBrowser discovery, registry Run key, DNS-SD advertise). `ConnectionCoordinator` already owns every Mac-side counter the diagnostics view needs (Phase 3 handoff) — Phase 4 displays them and adds the four it lacks (reconnect count, auth failures, session durations, latency history). `AudioDemandObserver.rescanNow()` already re-resolves the BlackHole UID and rebuilds all watchers — wake recovery calls it rather than reinventing it. The Windows tray meter already reads capture peaks (Phase 2) — Phase 4 adds only the Mac menu counterpart from rendered PCM peaks.

**Tech Stack:** Swift 5 language mode (Xcode 26.6), SwiftUI `MenuBarExtra`, `ServiceManagement.SMAppService` (login item, macOS 13+, floor is 14.4), `Foundation.NetServiceBrowser` (Bonjour browse), `NSWorkspace` sleep/wake notifications, XCTest, `xcodeproj` Ruby gem. Windows: C# / .NET 10 `net10.0-windows`, WinForms tray, `Microsoft.Win32.Registry` (HKCU Run key), `dnsapi.dll` P/Invoke (`DnsServiceRegister`) for mDNS advertise, xUnit.

## Global Constraints

Every task implicitly includes all of these.

**Where work happens.** Feature work happens on branch `t3code/start-issue-16` (PR target `main`). Never commit in the main checkout.

**Which machine runs which step.** Mac track runs here: `~/.rvm/bin/rvm default do ruby macos/project.rb` regenerates the project after adding/removing any `.swift` file; `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64'` runs the suite (append `2>&1 | grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)"`). Windows track runs on the Windows host: `dotnet build` / `dotnet test` from `windows\` (the `net10.0-windows` + WinForms tray targets do not build on macOS — write the code, do not attempt to verify it here).

**No behavior changes except as tasked.** The demand predicate (`contains(BlackHole)`, own-PID skip, never `IsRunningInput`), the state machine, the debounce (1000 ms), the hold (30 min), and the wire format are frozen. Each task states its Mac/Windows track explicitly; a track marked Windows-only is implemented blind here and verified by `dotnet test` on the Windows host before merge.

**Real-time safety (spec §6.4, non-negotiable).** The render callback gains exactly one float max-compare per sample for the peak meter — no allocation, no locks, no logging. All diagnostics reads are lag-tolerant cached copies, never synchronous cross-thread queries from the render thread.

**Privacy framing (spec §2.4).** The diagnostics view exists to make "zero idle bytes" verifiable: the daily byte total stays in the menu, and every counter must reconcile with the menu rows and the Phase 3 mock-run figures.

## File Structure

New files this plan creates:

| Path | Responsibility |
|---|---|
| `macos/SharedMic/Session/DiagnosticsSnapshot.swift` | Pure §11 aggregation: latency histogram/p50/p95/max, session count + durations, jitter depth, underruns, drift corrections, renderer drops, reconnects, auth failures |
| `macos/SharedMic/App/LoginItemManager.swift` | SMAppService seam: `LoginItemState` protocol + live impl + menu toggle surface |
| `macos/SharedMic/Net/HostDiscovery.swift` | Bonjour browse seam: `DiscoveredHost` + `HostBrowser` protocol + NetServiceBrowser impl |
| `macos/SharedMicTests/DiagnosticsSnapshotTests.swift` | Histogram buckets, percentiles, duration accumulation, reconcile-by-construction |
| `macos/SharedMicTests/LoginItemManagerTests.swift` | Fake-state toggle semantics (live SMAppService never touched in tests) |
| `macos/SharedMicTests/HostDiscoveryTests.swift` | Fake-browser discovery/loss/expiry; manual entry always survives |
| `windows/SharedMic.Agent/Diagnostics/DiagnosticsSnapshot.cs` | Windows §11 aggregation over AgentMetrics + session + send-queue counters |
| `windows/SharedMic.Agent/Ui/AutostartManager.cs` | HKCU Run-key seam: status, enable, disable |
| `windows/SharedMic.Agent/Net/MdnsAdvertiser.cs` | DNS-SD advertise seam (`_sharedmic._tcp`), start/stop, TXT with port + fingerprint prefix |

---

### Task 1 (Mac): Diagnostics snapshot model + coordinator ownership

Spec §11 counters, Mac-owned half. The coordinator already owns `startedSessions`, `debounceFires`, `lastActivationLatencyMs`, `totalAudioBytes`; the renderer already owns `underrunSamples`, `dropped{Newest,Straggler,Oldest}Frames`, `drift{Drops,Inserts}{Applied,Skipped}`, `depthMs`, `enqueuedFrames`. This task adds what is missing and aggregates it into one pure snapshot.

**Files:**
- Create: `macos/SharedMic/Session/DiagnosticsSnapshot.swift`, `macos/SharedMicTests/DiagnosticsSnapshotTests.swift`
- Modify: `macos/SharedMic/Net/ConnectionCoordinator.swift` (4 new counters + `diagnosticsSnapshot()`), `macos/SharedMic/Audio/AudioRenderer.swift` (`readCounters() -> RendererCounters` on `RendererControl` with a zero default so existing fakes compile untouched)

**New coordinator counters (all on `queue`, all read via `queue.sync`):**
- `reconnectCount` — incremented when a scheduled reconnect attempt actually fires (not on arm, not on initial `startIfPaired` connect).
- `authFailureCount` — incremented on `resolvePairing(.failure(.authenticationFailed))` and on `applyFingerprintMismatch`. Wrong-host pairing still fails exactly as today; it now also counts.
- `latencySamplesMs` — bounded ring (last 50) appended in `noteFirstFrame()`; the existing `lastActivationLatencyMs` stays as the latest.
- `sessionBeganAt` / `totalSessionSeconds` — began on START_ACK receipt, accumulated on STOP_ACK receipt and in `teardownConnection()` when a session is open. A START that never ACKs is not a session and accumulates nothing.

**Renderer accumulation across sessions:** renderer counters reset in `open()`; the coordinator folds the live reading into accumulated totals in `teardownConnection()` (sync read on `rendererQueue` before the async `finalizeClose`, FIFO-ordered) and adds the current live reading at snapshot time. No double count by construction.

- [x] **Step 1: Write the failing test.** `DiagnosticsSnapshotTests.swift`: histogram buckets from samples (`<100 / 100–200 / 200–300 / >300 ms`), p50/p95/max on a known sample set, empty-samples nil handling, `totalSessionSeconds` accumulation over two sessions, renderer-across-reopen accumulation (session A counters + live session B counters, no double count).
- [x] **Step 2: Run and confirm it fails.** `xcodebuild test … -only-testing:SharedMicTests/DiagnosticsSnapshotTests` → FAIL (type missing).
- [x] **Step 3: Write the minimal implementation.** `DiagnosticsSnapshot.swift` (pure struct + `RendererCounters` struct + histogram/percentile math); coordinator counters + `diagnosticsSnapshot()`; `RendererControl.readCounters()` with zero default; `AudioRenderer.readCounters()` returning live values.
- [x] **Step 4: Run and confirm it passes.** Same line → PASS. Full suite still green.
- [x] **Step 5: Commit.** `feat(macos): coordinator-owned diagnostics snapshot (Phase 4 Task 1)`

### Task 2 (Mac): Diagnostics section in the menu

Spec §11 "displayed instead of menu-latest-only". The existing menu rows (sessions, last activation, debounce fires, byte total) stay; a diagnostics section adds the rest. Numbers must reconcile with the menu rows by construction (same snapshot source).

**Files:**
- Modify: `macos/SharedMic/App/AppModel.swift` (`@Published diagnostics: DiagnosticsSnapshot?`, refreshed in the existing 1 Hz `refreshDemandDerived()`), `macos/SharedMic/App/MenuBarView.swift` (diagnostics section), `macos/SharedMicTests/AppModelTests.swift`

- [x] **Step 1: Write the failing test.** AppModel tests: diagnostics published after refresh tick; byte total in snapshot equals `audioBytesReceived`; session count equals `sessionCount`.
- [x] **Step 2: Run and confirm it fails.** `… -only-testing:SharedMicTests/AppModelTests` → FAIL.
- [x] **Step 3: Write the minimal implementation.** AppModel polling + MenuBarView section (latency p50/p95/max + histogram, session count + total duration, jitter depth, underruns, drift corrections, renderer drops, reconnects, auth failures, demand list + system input stay where they are).
- [x] **Step 4: Run and confirm it passes.** Same line → PASS. Full suite green.
- [x] **Step 5: Commit.** `feat(macos): diagnostics section in menu (Phase 4 Task 2)`

### Task 3 (Mac): Menu input-level meter from rendered PCM peaks

Spec §6.1/§11 tray-and-menu meter, Mac half. Windows half already exists (tray `LastPeak` bar). Source of truth is rendered PCM peaks — what actually reaches BlackHole — not capture or wire bytes.

**Files:**
- Modify: `macos/SharedMic/Audio/AudioRenderer.swift` (`RenderBridge` peak-since-read in `readStereo`, `AudioRenderer.renderedPeak` read-and-clear), `macos/SharedMic/Net/ConnectionCoordinator.swift` (`renderedPeak` via `rendererQueue.sync` — main-thread callers only, documented), `macos/SharedMic/App/AppModel.swift` (1 Hz poll), `macos/SharedMic/App/MenuBarView.swift` (10-block bar, same visual language as the Windows tray), tests in `AudioRendererTests.swift` + `AppModelTests.swift`

**Real-time budget:** one float abs+max per rendered sample inside the existing copy loop. No allocation, no branches that allocate, no logging. Peak-since-read is a plain Float (single-copy atomic on arm64, lag-tolerant like every other bridge counter).

- [x] **Step 1: Write the failing test.** Bridge/render test: render a full-scale sine frame → peak ≈ 1.0; render silence → peak 0; read-and-clear semantics (second read without render is 0). Coordinator/AppModel test: peak surfaces through the 1 Hz poll.
- [x] **Step 2: Run and confirm it fails.** Renderer tests → FAIL.
- [x] **Step 3: Write the minimal implementation.** Bridge peak, renderer passthrough, coordinator accessor, model poll, menu bar.
- [x] **Step 4: Run and confirm it passes.** Renderer + AppModel suites → PASS. Full suite green.
- [x] **Step 5: Commit.** `feat(macos): rendered-PCM level meter in menu (Phase 4 Task 3)`

### Task 4 (Mac): Sleep/wake — forced re-resolve + full demand rescan

Spec §12 Phase 4. Stale `AudioObjectID`s must never survive a sleep cycle. `AudioDemandObserver.fullRescan()` already re-resolves the BlackHole UID and rebuilds every watcher — wake recovery calls `rescanNow()`, it does not reimplement it. Transport recovery rides the existing backoff (`connectionLost` → `scheduleReconnect`), and `controlClientDidAuthenticate` already re-fires demand on re-auth per the Phase 3 rule (`refireIfIdleWithDemand`) — this task exercises that path against a wake, it does not add a second refire.

**Files:**
- Modify: `macos/SharedMic/Net/ConnectionCoordinator.swift` (`handleWake()` — `rescanNow()` always; `scheduleReconnect()` only when paired with no live client and no pending attempt, preserving the existing backoff rather than resetting it), `macos/SharedMic/App/SharedMicApp.swift` or `AppModel.swift` (NSWorkspace `didWakeNotification` → `handleWake()`), `macos/SharedMicTests/ConnectionCoordinatorTests.swift` (fake observer records `rescanNow`; wake with demand held and transport lost recovers to session via the existing refire — no new state-machine edges)

- [x] **Step 1: Write the failing test.** Wake with a fake observer: `rescanNow` called exactly once; BlackHole ID change across the wake (99 → 104) drops the stale-ID demand and picks up the new ID; paired-but-disconnected wake schedules exactly one reconnect (no storm on repeated wakes); demand held across the wake re-fires after re-auth.
- [x] **Step 2: Run and confirm it fails.** Coordinator tests → FAIL (`handleWake` missing).
- [x] **Step 3: Write the minimal implementation.** `handleWake()` + NSWorkspace wiring. No `SessionController` changes.
- [x] **Step 4: Run and confirm it passes.** Coordinator suite → PASS. Full suite green. `grep -rn "IsRunningInput" macos/SharedMic/Audio` still shows diagnostics-or-tests only.
- [x] **Step 5: Commit.** `feat(macos): sleep/wake demand rescan (Phase 4 Task 4)`

### Task 5 (Mac): Login item — unpaired-but-ready, silent resume

Spec §2.1 + §12. Both agents launch at login; the Mac agent starts unpaired-but-ready and resumes stored pairings silently (the existing `startIfPaired()` already does the resume — this task only ensures it runs at login with no clicks).

**Files:**
- Create: `macos/SharedMic/App/LoginItemManager.swift` (`LoginItemState` protocol + `SMAppService`-backed live impl; tests use a fake — the live service is never touched in tests), `macos/SharedMicTests/LoginItemManagerTests.swift`
- Modify: `macos/SharedMic/App/AppModel.swift` (published `loginItemEnabled` + toggle), `macos/SharedMic/App/MenuBarView.swift` (toggle row)

- [ ] **Step 1: Write the failing test.** Fake-state toggle: enable registers, disable unregisters, initial state reflects the service, toggle failure surfaces a notice and leaves state unchanged.
- [ ] **Step 2: Run and confirm it fails.** → FAIL (type missing).
- [ ] **Step 3: Write the minimal implementation.** Seam + live impl + model + menu row. No auto-enable without user action: the toggle is explicit, the resume is silent.
- [ ] **Step 4: Run and confirm it passes.** → PASS. Full suite green.
- [ ] **Step 5: Commit.** `feat(macos): login-item toggle (Phase 4 Task 5)`

### Task 6 (Mac): Bonjour discovery in the pairing form

Spec §12. The Windows agent advertises (Task 9); the Mac browses and offers discovered hosts in the pairing form. Manual host entry stays as fallback and wrong-host pairing still fails exactly as today.

**Files:**
- Create: `macos/SharedMic/Net/HostDiscovery.swift` (`DiscoveredHost(name, host, port)`, `HostBrowser` protocol + `NetServiceBrowser` impl with resolve timeout and expiry), `macos/SharedMicTests/HostDiscoveryTests.swift`
- Modify: `macos/SharedMic/App/AppModel.swift` (published `discoveredHosts`, browse while unpaired), `macos/SharedMic/App/MenuBarView.swift` (discovered-host picker above the manual fields)

- [ ] **Step 1: Write the failing test.** Fake browser: appear → listed; disappear → removed; resolve failure → dropped with manual entry unaffected; selecting a host fills `hostField`/`portField`.
- [ ] **Step 2: Run and confirm it fails.** → FAIL.
- [ ] **Step 3: Write the minimal implementation.** Seam + browser + model + form picker. Browse only while unpaired (no background browsing while streaming).
- [ ] **Step 4: Run and confirm it passes.** → PASS. Full suite green.
- [ ] **Step 5: Commit.** `feat(macos): Bonjour discovery in pairing form (Phase 4 Task 6)`

### Task 7 (Windows): Autostart via HKCU Run key

Spec §2.1 + §12, Windows track. Agent starts at login unpaired-but-ready; stored pairing resumes silently (existing startup path — verify, do not duplicate).

**Files:**
- Create: `windows/SharedMic.Agent/Ui/AutostartManager.cs` (`IAutostartStore` seam over HKCU `Software\Microsoft\Windows\CurrentVersion\Run`, value name `SharedMicAgent`, quoted exe path), `windows/SharedMic.Agent.Tests/AutostartManagerTests.cs` (fake store: enable writes quoted path, disable removes, missing value reads disabled, unquoted/legacy value still reads enabled)
- Modify: `windows/SharedMic.Agent/Ui/TrayApp.cs` (checkbox item "Start at login"), `windows/SharedMic.Agent/Program.cs` (no new flags; headless respects the same store)

- [ ] **Step 1: Write the failing test** (`AutostartManagerTests.cs` per above).
- [ ] **Step 2: Run and confirm it fails** (`dotnet test --filter AutostartManager` → FAIL).
- [ ] **Step 3: Write the minimal implementation.**
- [ ] **Step 4: Run and confirm it passes** (`dotnet test` full suite green).
- [ ] **Step 5: Commit.** `feat(windows): login autostart toggle (Phase 4 Task 7)`

> **Status 2026-09-08:** verified against the existing suite — `EffectiveMicPresent()` re-verifies the endpoint ID on every START, `HandleMicLost` ends the session and sends STATUS on capture loss, presence-change sends STATUS, and `ControlConnectionAudioTests` + `SessionStateMachineTests` cover mid-session unplug, idle replug, and recovery. No code changes required.

### Task 8 (Windows): USB replug — endpoint-ID re-verify beyond STATUS

Spec §12, Windows track. `EffectiveMicPresent()` already re-verifies on every START (endpoint ID, never friendly name). This task closes the remaining gaps: replug-during-session (capture loss → STATUS MIC_UNAVAILABLE → existing Mac DEGRADED path, session resumes on replug via the Phase 3 refire rule) and replugged-idle (silent recovery, no session). No new wire messages.

**Files:**
- Modify: `windows/SharedMic.Agent/Audio/MicCaptureService.cs` (capture-lost surfaces once, no hot loop), `windows/SharedMic.Agent/Net/ControlConnection.cs` (STATUS on presence change already? verify and test), `windows/SharedMic.Agent.Tests/*` (replug mid-session → NACK-then-recover sequence; replug idle → presence flips with zero sessions started)

- [ ] **Step 1: Write the failing tests** (mid-session replug: STATUS MIC_UNAVAILABLE then present again, Mac refire starts a new session; idle replug: `SessionsStarted` unchanged).
- [ ] **Step 2: Run and confirm they fail.**
- [ ] **Step 3: Write the minimal implementation.** No friendly-name matching anywhere (`grep -rn "FriendlyName\|friendly" windows/SharedMic.Agent/Audio` must show display-only uses).
- [ ] **Step 4: Run and confirm they pass.** Full `dotnet test` green.
- [ ] **Step 5: Commit.** `feat(windows): USB replug re-verify (Phase 4 Task 8)`

### Task 9 (Windows): mDNS advertise `_sharedmic._tcp`

Spec §12, Windows track. Advertise the agent on the LAN so the Mac form (Task 6) can offer it. TXT carries the port and a fingerprint prefix (diagnostic aid only — pinning still happens over the pairing ceremony, never from TXT).

**Files:**
- Create: `windows/SharedMic.Agent/Net/MdnsAdvertiser.cs` (`IMdnsBackend` seam: P/Invoke `DnsServiceRegister`/`DnsServiceDeRegister` on `dnsapi.dll`; register `_sharedmic._tcp` on the agent port, deregister on stop/dispose), `windows/SharedMic.Agent.Tests/MdnsAdvertiserTests.cs` (fake backend: register on serve, deregister on stop, re-register on port change, register failure logs and never crashes the agent)

- [ ] **Step 1–5:** Same TDD rhythm as Task 7. Commit: `feat(windows): mDNS advertise (Phase 4 Task 9)`

### Task 10 (Windows): Diagnostics counters — send-queue drops + session durations

Spec §11, Windows track. `AgentMetrics` already counts connections/auth/sessions/frames; `PrioritySendQueue` already counts offered/evicted/discarded per connection. This task aggregates them into one snapshot for a tray diagnostics view and proves the Mac-visible reconciliation (session count matches Mac-initiated STARTs).

**Files:**
- Create: `windows/SharedMic.Agent/Diagnostics/DiagnosticsSnapshot.cs`, `windows/SharedMic.Agent.Tests/DiagnosticsSnapshotTests.cs`
- Modify: `windows/SharedMic.Agent/Ui/TrayApp.cs` (diagnostics menu section), session-duration tracking at the START/STOP sites

- [ ] **Step 1–5:** Same TDD rhythm. Commit: `feat(windows): diagnostics snapshot (Phase 4 Task 10)`

### Task 11: Measurements and owner-gated acceptance (no code, or instrumentation-only)

Spec §9 rows this phase owes plus the issue's acceptance list. Automation proves the plumbing; the verdicts need both machines, a night, and hands.

- [ ] **Step 1: Record the automated baselines.** Full Mac suite green, `dotnet test` green on the Windows host, `grep IsRunningInput` still gate-clean, diagnostics reconcile test (Task 1) passing against the Phase 3 mock-run figures.
- [ ] **Step 2: Overnight soak.** Both machines asleep and awake, Mac idle 8 h — byte counter stays 0, no DEGRADED notifications at idle, first Raycast activation after wake streams (exercises Task 4 end to end).
- [ ] **Step 3: USB replug matrix.** Mid-session unplug/replug with demand held → session resumes automatically; idle replug → silent recovery, no session (exercises Task 8 + the Phase 3 refire rule).
- [ ] **Step 4: Fresh-boot both machines.** Agents running with no login, paired session starts on first demand with no clicks (exercises Tasks 5 + 7).
- [ ] **Step 5: Discovery.** Windows agent appears in the Mac pairing form on a fresh LAN join; wrong-host pairing still fails exactly as today (exercises Tasks 6 + 9).
- [ ] **Step 6: File the results.** Measurements Appendix below updated with figures and run provenance; follow-ups opened for anything red.

## Measurements Appendix (maps to spec §9–§11 and issue #16)

| Spec / issue row | Proved by | Status |
|---|---|---|
| Diagnostics reconcile with menu rows + Phase 3 mock figures | Tasks 1+2 tests, Task 11 run | Automated + owner check |
| Menu level meter tracks rendered PCM | Task 3 tests, Task 11 ear check | Automated + owner check |
| Wake rescan: no stale AudioObjectIDs, refire on re-auth | Task 4 tests, Task 11 soak | Automated + owner soak |
| Login-launch both machines, silent resume, no-click first demand | Tasks 5+7, Task 11 fresh-boot | Owner-gated |
| Replug mid-session resumes; idle replug silent | Task 8 tests, Task 11 matrix | Automated + owner matrix |
| Discovery appears on fresh LAN join; wrong host fails as today | Tasks 6+9, Task 11 run | Automated + owner run |
| 8 h idle → 0 PCM bytes, no DEGRADED at idle | Unchanged Phase 2/3 counters, Task 11 soak | Owner-gated |
| First Raycast activation after wake streams | Tasks 3+4, Task 11 soak | Owner-gated |

## Phase 4 handoff (for the next owner/agent)

- WebKit-retains-BlackHole-as-default is still unmeasured (§13 Q1) — a stuck demand count of 1 with a Safari bundle ID in the diagnostics view is now attributable rather than mysterious; do not chase it with code until measured.
- Packaging/installer is explicitly out of scope (needs its own signing/distribution decision).
- If the tray/menu meters disagree about "quiet Mac" (§12 Phase 2 channel-mode watch item), the Windows session peaks (`SessionPeakLeft/Right`) vs the Mac rendered peak now isolate which side of the wire the 6 dB went missing on.
