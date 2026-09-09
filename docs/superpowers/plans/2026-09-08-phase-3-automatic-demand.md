# macOS Agent — Phase 3 (Automatic Demand) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the manual Start/Stop scaffolding with automatic demand-driven sessions on the merged Phase 2 path. Microphone audio flows only while a real consumer holds BlackHole open: a device-scoped `AudioDemandObserver` drives the existing session machinery, plus the safety controls that make automation trustworthy (kill switch, force-on hold, conditional notifications).

**Architecture:** A pure demand predicate (`DemandSnapshot` — UID-matched, own-PID-skipped, `contains(BlackHole)`), a thin Core Audio shell (`AudioDemandObserver`) over a test-seamed `CoreAudioQuery`, an extended pure `SessionController` (new `stopPending` debounce node, `disabled` kill-switch state, hold-aware demand, DEGRADED-notify-only-with-demand), a `ConnectionCoordinator` that owns the debounce/hold timers and persists only DISABLED, and a `MenuBarView` with no Start/Stop. No control-plane or audio-path behavior changes except the activation trigger.

**Tech Stack:** Swift 5 language mode (Xcode 26.6 / Swift 6.3 toolchain), Core Audio (`AudioObjectGetPropertyData`, `kAudioHardwarePropertyProcessObjectList`, `kAudioHardwarePropertyTranslatePIDToProcessObject`, `kAudioProcessPropertyDevices` input scope), SwiftUI `MenuBarExtra`, XCTest, `xcodeproj` Ruby gem, Phase 0 demand probe at `probes/macos-demand/DemandProbe.swift` as the API reference.

---

## Global Constraints

Every task implicitly includes all of these. Values are copied verbatim from `docs/superpowers/specs/2026-08-08-shared-mic-design.md` and `docs/superpowers/probes/2026-08-08-macos-demand-findings.md`.

**Scope of Phase 3 — automatic demand only (spec §5).**
In: `AudioDemandObserver` (per-process BlackHole input-scope membership, UID matching only, PID-skipping path, own-PID skip, `contains` predicate for multi-device lists); full state machine STARTING / ACTIVE (`streaming`) / STOP_PENDING (1000 ms debounce, 500–2000 configurable) / STOPPING / DEGRADED wired to observer events; `Disabled` kill-switch state; `Held` force-on indication with 30-minute auto-expire and remaining-time display; notification only on DEGRADED-with-demand, silent at idle (§5.5); menu shows demand process count + bundle IDs and the current system input device (§11, §3.4); demand-detection latency and debounce-fire instrumentation for §9.

**Explicitly out of scope (Phase 4):** login-launch, sleep/wake, USB replug beyond existing STATUS handling, mDNS/Bonjour discovery, diagnostics view, packaging, level meter. No Windows changes unless a measurement says otherwise.

**Demand-gate correctness (spec §5.1, probe findings):**
- Gate on `kAudioProcessPropertyDevices` (input scope) membership containing BlackHole's object ID. `kAudioProcessPropertyIsRunningInput` MUST NOT be a required conjunct — it may be read and displayed as a diagnostic, never as a gate.
- Resolve BlackHole by UID only (`BlackHole2ch_UID` preferred, `BlackHole16ch_UID` / `BlackHole64ch_UID` fallbacks) — never by display name. Cache the `AudioObjectID` at startup; re-resolve on device-list change (IDs are not stable across reboot/replug).
- Always skip our own PID. The predicate is `contains(BlackHole)`, not `== [BlackHole]` — multi-device lists (WebKit reported two devices at once) are normal.
- Listener-first, targeted-poll fallback: register on `kAudioHardwarePropertyProcessObjectList` plus per-process `Devices`; where listener registration fails for a property, look up that specific process with `kAudioHardwarePropertyTranslatePIDToProcessObject` and poll only that process at 100 ms — never a full sweep as the fallback.

**State-machine rules (spec §5.2–§5.5):**
- START is immediate on demand; only STOP is debounced. Debounce default 1000 ms, configurable 500–2000 ms. Retained as cheap insurance; Phase 3 measures whether it fires at all (it is no defence against the persistent Sound-Settings shape).
- DISABLED persists across restarts. Entering it sends STOP immediately; while in it, no START is ever sent regardless of demand; never auto-leaves (only explicit enable or unpair/re-pair path leaves it).
- Force-on hold auto-expires after 30 minutes (configurable duration, but expiry itself is not configurable away). Remaining time shown in the menu. An override that can be left on indefinitely is the always-on hot mic this project exists to eliminate.
- Notification fires on entering DEGRADED while demand (or hold) is active; stays silent at idle. Do not add an idle-time alert to compensate (the §3.4 configuration already narrows the blast radius).
- The agent MUST NOT change the system input or output device. The §3.4 recommended configuration (system input = real hardware mic, BlackHole targeted explicitly by apps like Raycast) is surfaced in the menu so misconfiguration is visible, not enforced by changing devices.

**Configuration truth (§3.4, house note):** This Mac currently has BlackHole 2ch as the default input, against the §3.4 recommendation. The Sound-Settings/WebKit false-positive analysis assumes it is not. The menu MUST surface the current system input device; the owner-gated acceptance matrix MUST include the §3.4-configured pass (default = real hardware mic).

---

## File Structure

**Created by this plan:**

| Path | Responsibility |
|---|---|
| `macos/SharedMic/Audio/DemandSnapshot.swift` | Pure demand model: `DemandingProcess` (pid, bundleID), `DemandSnapshot` (processes holding BlackHole, `hasDemand`), `containsBlackHole` predicate + own-PID skip. No Core Audio. |
| `macos/SharedMic/Audio/CoreAudioQuery.swift` | `CoreAudioQuery` protocol (the seam): BlackHole resolve, process-object list, per-process devices/bundle/pid, targeted PID lookup, listener registration. `LiveCoreAudioQuery` implements it with real Core Audio; `FakeCoreAudioQuery` (tests) does not. |
| `macos/SharedMic/Audio/AudioDemandObserver.swift` | Listener-first observer over `CoreAudioQuery`: emits `DemandSnapshot` on change, falls back to targeted 100 ms poll per unlistenable process, re-resolves BlackHole UID on device change. |
| `macos/SharedMic/Audio/SystemInputDevice.swift` | Reads the current system input device (UID + name) for the §3.4 menu display. No writes, ever. |
| `macos/SharedMic/Session/DemandSettings.swift` | Pure persisted settings: kill-switch DISABLED flag, stop-debounce ms (clamped 500–2000, default 1000), hold duration (default 30 min). Backed by an injectable store (UserDefaults in production, in-memory in tests). Hold-active state itself is NOT persisted. |

**Modified by this plan:**

| Path | Change |
|---|---|
| `macos/SharedMic/Session/SessionController.swift` | New states `stopPending(sessionId:)`, `disabled`; hold-aware demand (`holdActive` flag + `demandChanged(hasDemand:)` / `holdBegan` / `holdExpired` events); `demandGone` → `stopPending` + `armStopDebounce`, `stopDebounceExpired` → `stopping`; `userDisabled` from every state → STOP-then-`disabled` (or direct `disabled` at idle); `userEnabled` → `idle`; connection-loss while session-active → `degraded` with demand-conditional notify; silent-at-idle preserved. Manual `userRequestedStart/Stop` events KEPT during migration but no longer called by UI (removed in Task 5). |
| `macos/SharedMic/Net/ConnectionCoordinator.swift` | Owns observer + debounce timer + hold timer; translates snapshots to `demandChanged`; persists DISABLED; exposes `demandSnapshot`, `holdRemaining`, `stopDebounceMs`, `debounceFireCount`, `lastActivationLatencyMs`, `sessionCount`; drops `requestStart/requestStop` public API. |
| `macos/SharedMic/App/AppModel.swift` | Drops `startSession/stopSession` + `canStart/canStop`; adds `disable/enable`, `beginHold/cancelHold`, publishes demand list, hold remaining, system input, debounce setting. |
| `macos/SharedMic/App/MenuBarView.swift` | Deletes Start/Stop buttons; adds Disabled/Held status, kill-switch toggle, 30-min hold button + remaining, demand count + bundle IDs, system-input row with §3.4 warning, debounce display. |
| `macos/SharedMic/Audio/BlackHoleDevice.swift` | No logic change; reused for UID constants by the observer (or re-exported if moved). |

**Never modified by this plan:** `protocol/`, `harness/`, `probes/`, `windows/`, `docs/superpowers/specs/`, other plans.

---

### Task 1: Pure demand model — snapshot, predicate, own-PID skip

The gate in its testable form, with no Core Audio. Everything downstream (observer, controller, UI) speaks `DemandSnapshot`.

**Files:**
- Create: `macos/SharedMic/Audio/DemandSnapshot.swift`
- Test: `macos/SharedMicTests/DemandSnapshotTests.swift`

**Interfaces:**
- `public struct DemandingProcess: Equatable { pid: Int32, bundleID: String }`
- `public struct DemandSnapshot: Equatable { processes: [DemandingProcess], hasDemand: Bool }` — `hasDemand == !processes.isEmpty`
- `public enum DemandGate { static func snapshot(blackHoleID: AudioObjectID, rows: [(pid: Int32, bundleID: String, inputDevices: [AudioObjectID])], ownPID: Int32) -> DemandSnapshot }` — `contains(blackHoleID)`, skip `ownPID`, UID matching happens upstream (caller passes the resolved ID).

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/DemandSnapshotTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class DemandSnapshotTests: XCTestCase {
    let blackHole: AudioObjectID = 99
    let other: AudioObjectID = 139

    func testEmptyRowsHaveNoDemand() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [], ownPID: 1000)
        XCTAssertFalse(snap.hasDemand)
        XCTAssertEqual(snap.processes, [])
    }

    func testContainsPredicateCountsMultiDeviceLists() {
        // WebKit shape: two devices at once must still count (contains, not ==).
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [
            (pid: 501, bundleID: "com.apple.WebKit.GPU", inputDevices: [other, blackHole])
        ], ownPID: 1000)
        XCTAssertTrue(snap.hasDemand)
        XCTAssertEqual(snap.processes, [DemandingProcess(pid: 501, bundleID: "com.apple.WebKit.GPU")])
    }

    func testOwnPIDIsAlwaysSkipped() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [
            (pid: 1000, bundleID: "com.sharedmic.SharedMic", inputDevices: [blackHole])
        ], ownPID: 1000)
        XCTAssertFalse(snap.hasDemand)
    }

    func testNonBlackHoleDevicesDoNotCount() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [
            (pid: 502, bundleID: "com.apple.WebKit.GPU", inputDevices: [other])
        ], ownPID: 1000)
        XCTAssertFalse(snap.hasDemand)
    }

    func testMixedRowsReportOnlyHolders() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [
            (pid: 501, bundleID: "a", inputDevices: [other]),
            (pid: 502, bundleID: "b", inputDevices: [blackHole]),
            (pid: 1000, bundleID: "self", inputDevices: [blackHole])
        ], ownPID: 1000)
        XCTAssertTrue(snap.hasDemand)
        XCTAssertEqual(snap.processes, [DemandingProcess(pid: 502, bundleID: "b")])
    }
}
```

- [ ] **Step 2: Run and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/DemandSnapshotTests`
Expected: FAIL — `cannot find 'DemandGate' in scope` (or missing file).

- [ ] **Step 3: Write the minimal implementation**

Create `macos/SharedMic/Audio/DemandSnapshot.swift`: the two structs plus the `contains` + own-PID-skip predicate. No Core Audio import. No `IsRunningInput` anywhere in the file.

- [ ] **Step 4: Run and confirm it passes**

Run: same `xcodebuild test` line as Step 2.
Expected: PASS — `** TEST SUCCEEDED **`, 5 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Audio/DemandSnapshot.swift macos/SharedMicTests/DemandSnapshotTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): pure demand snapshot and BlackHole-contains predicate

Device-scoped gate in testable form: contains(BlackHole) over input-scope
device lists with our own PID always skipped. Multi-device lists count;
non-BlackHole devices and self-hits do not. IsRunningInput is deliberately
absent — it must never become a conjunct.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: AudioDemandObserver — listener-first Core Audio shell over a test seam

The only place Core Audio is touched for demand. Production path mirrors `probes/macos-demand/DemandProbe.swift`; tests never touch Core Audio.

**Files:**
- Create: `macos/SharedMic/Audio/CoreAudioQuery.swift`, `macos/SharedMic/Audio/AudioDemandObserver.swift`
- Test: `macos/SharedMicTests/AudioDemandObserverTests.swift`

**Interfaces:**
- `public protocol CoreAudioQuery: AnyObject { var ownPID: Int32 { get }; func resolveBlackHole() -> AudioObjectID?; func processObjectIDs() -> [AudioObjectID]; func pid(for object: AudioObjectID) -> Int32?; func bundleID(for object: AudioObjectID) -> String; func inputDeviceIDs(for object: AudioObjectID) -> [AudioObjectID]; func processObject(forPID pid: Int32) -> AudioObjectID?; func addProcessListListener(_ block: @escaping () -> Void) -> Bool; func addDeviceListener(processObject: AudioObjectID, block: @escaping () -> Void) -> Bool }`
- `public final class LiveCoreAudioQuery: CoreAudioQuery` — real Core Audio (TranslatePIDToProcessObject for the targeted path, UID-only BlackHole resolve via `BlackHoleDevice.knownUIDs`).
- `public final class AudioDemandObserver` — `init(query: CoreAudioQuery, pollInterval: TimeInterval = 0.1, onChange: @escaping (DemandSnapshot) -> Void)`; `func start()`, `func stop()`; `var current: DemandSnapshot { get }`. Emits only on change. Re-resolves BlackHole when the process list changes. Processes whose device-listener registration fails go on the targeted 100 ms poll list (TranslatePID path), never a full-sweep fallback.

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/AudioDemandObserverTests.swift` with a `FakeCoreAudioQuery` (in-memory process objects, scriptable listener blocks, records targeted-poll usage):

```swift
import XCTest
@testable import SharedMic

final class AudioDemandObserverTests: XCTestCase {
    // FakeCoreAudioQuery: blackHoleID = 99; processes as (objectID -> pid/bundle/devices);
    // addDeviceListener returns false for objects in `unlistenable`; processObject(forPID:)
    // records calls so the test can assert the fallback targeted exactly that PID.

    func testEmitsDemandWhenBlackHoleAppears() { /* start at idle, add holder, expect hasDemand with bundle */ }
    func testSkipsOwnPID() { /* self holding BlackHole never emits demand */ }
    func testRequiresUIDMatchNotName() { /* device with BlackHole's NAME but another ID does not count */ }
    func testUnlistenableProcessFallsBackToTargetedPollOnly() { /* listener refused -> TranslatePID poll of that PID delivers the change; assert no full-sweep rescan beyond the targeted read */ }
    func testHandlesMultiDeviceLists() { /* [other, blackHole] counts */ }
    func testReResolvesBlackHoleIDOnDeviceChange() { /* BlackHole ID changes 99 -> 104, old ID no longer counts, new ID does */ }
    func testEmitsOnlyOnChange() { /* repeated identical polls produce one emission */ }
}
```

- [ ] **Step 2: Run and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/AudioDemandObserverTests`
Expected: FAIL — missing types.

- [ ] **Step 3: Write the minimal implementation**

Create `CoreAudioQuery.swift` (protocol + `LiveCoreAudioQuery` using the probe's exact property calls: `kAudioHardwarePropertyDevices` for resolve, `kAudioHardwarePropertyProcessObjectList` for enumeration, `kAudioProcessPropertyPID` / `kAudioProcessPropertyBundleID` / `kAudioProcessPropertyDevices`+input-scope for rows, `kAudioHardwarePropertyTranslatePIDToProcessObject` for the targeted path; UID-only matching against `BlackHoleDevice.knownUIDs`) and `AudioDemandObserver.swift` (listener registration on start, per-process add/remove as the list changes, targeted 100 ms `DispatchSourceTimer` only for refused processes, `DemandGate.snapshot` for the predicate, change-only emission on a private serial queue).

- [ ] **Step 4: Run and confirm it passes**

Run: same `xcodebuild test` line as Step 2.
Expected: PASS — `** TEST SUCCEEDED **`, 7 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Audio/CoreAudioQuery.swift macos/SharedMic/Audio/AudioDemandObserver.swift macos/SharedMicTests/AudioDemandObserverTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): listener-first AudioDemandObserver with targeted-poll fallback

Device-scoped demand over a test seam: process-list + per-process device
listeners, own-PID skip, contains(BlackHole) predicate, UID-only resolve
with re-resolve on device change. Refused listeners fall back to a targeted
TranslatePIDToProcessObject poll of that process at 100ms, never a sweep.
IsRunningInput is not read for gating.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Full session state machine — stop-pending debounce, disabled, hold, conditional notify

Extends the pure machine. No sockets, no timers, no UI — the coordinator performs the returned actions.

**Files:**
- Modify: `macos/SharedMic/Session/SessionController.swift`
- Test: `macos/SharedMicTests/SessionControllerTests.swift` (extend), new `macos/SharedMicTests/SessionDemandTests.swift` for the demand/hold/debounce matrix (or extend in place — prefer a new file so the Phase 1 tests stay readable).

**Interfaces (additive; existing events/actions keep their meaning):**
- `AgentState` adds `case stopPending(sessionId: String)` and `case disabled`. `displayName`: `"Stop pending"` (transient; UI may render as Streaming), `"Disabled"`. `Held` is a UI indication (Task 5), not a machine node: spec §5.2 routes force-on through STARTING/ACTIVE, while §11 requires a Held display — the coordinator exposes `holdRemaining` and the menu renders `Held (mm:ss)` whenever a hold is active.
- `SessionEvent` adds `demandChanged(hasDemand: Bool)`, `holdBegan`, `holdExpired`, `stopDebounceExpired`, `userDisabled`, `userEnabled`.
- `SessionAction` adds `armStopDebounce(seconds: TimeInterval)`, `cancelStopDebounce`.
- `SessionController` adds `var hasDemand: Bool { get }`, `var holdActive: Bool { get }`, `var stopDebounceSeconds: TimeInterval` (init-injectable, default 1.0, clamped 0.5–2.0).

Transition deltas (all else unchanged):
- `idle + demandChanged(true)` → `starting` (same actions as `userRequestedStart`; respects mic-present else notify, respects `disabled` = impossible since disabled is a separate state).
- `streaming + demandChanged(false)` with no hold → `stopPending` + `armStopDebounce`; with hold → stay `streaming`.
- `stopPending + demandChanged(true)` / `holdBegan` → `streaming` + `cancelStopDebounce`.
- `stopPending + stopDebounceExpired` → `stopping` (same actions as `userRequestedStop`, incl. `closeRendererAfterDrain`).
- `starting + demandChanged(false)` with no hold → `stopping` (no debounce on the way up — START is immediate, abandoning it is too).
- `userDisabled` from `idle/disconnected/connecting/degraded` → `disabled` (+ `cancelStopDebounce`); from `starting/streaming/stopPending/stopping` → `stopping`-then-`disabled`: emit the normal STOP actions and record pending-disabled so `stopAcked/stopTimedOut` lands in `disabled` instead of `idle`. While `disabled`, every event except `userEnabled`/`unpairedByUser`/`paired`/`fingerprintMismatch` is a no-op and no START is ever emitted.
- `holdBegan` in `idle` (mic present, connected) → `starting`; in `stopPending` → `streaming` + `cancelStopDebounce`; elsewhere no-op besides setting the flag.
- `holdExpired` with no demand in `streaming` → `stopPending` + `armStopDebounce`; with no demand in `idle` → stay `idle`.
- DEGRADED notify gating: entering `degraded` emits `notify` ONLY when `hasDemand || holdActive` (transport lost mid-session with demand, START timeout with demand, mic loss mid-session with demand). Idle-path entries (`connectionLost` from idle, mic absent at idle) stay silent. `connectionLost` from `starting/streaming/stopPending/stopping` → `degraded` (not `disconnected`) + `scheduleReconnect` (+ conditional notify).
- `degraded + authenticated`-reconnect path (existing `authenticated` → `idle`): coordinator re-fires demand after reconnect (Task 4), so the machine needs no new reconnect-demand event.

- [ ] **Step 1: Write the failing tests**

New `macos/SharedMicTests/SessionDemandTests.swift`: demand starts immediately; demand loss arms (not sends) STOP; demand return cancels; debounce expiry sends STOP; debounce clamped to 500–2000; disable from streaming sends STOP and lands disabled; disabled never emits sendStart on demand; enable returns to idle; hold forces start and suppresses debounce; hold expiry without demand debounces; DEGRADED notifies with demand and stays silent at idle; connection loss mid-session → degraded, at idle → disconnected silent.

- [ ] **Step 2: Run and confirm they fail**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/SessionDemandTests`
Expected: FAIL — missing events/states.

- [ ] **Step 3: Write the minimal implementation**

Extend `SessionController.swift` per the deltas above. Keep `userRequestedStart/Stop` working (coordinator no longer sends them after Task 4, UI no longer offers them after Task 5, but the machine still honors them so Phase 1/2 tests keep passing unmodified). Clamp `stopDebounceSeconds` to 0.5–2.0 in `init` and on set.

- [ ] **Step 4: Run and confirm both suites pass**

Run: `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/SessionControllerTests -only-testing:SharedMicTests/SessionDemandTests`
Expected: PASS — `** TEST SUCCEEDED **`, all Phase 1 cases unmodified and green plus the new matrix.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Session/SessionController.swift macos/SharedMicTests/SessionDemandTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): demand-driven session machine with debounce, disabled, hold

STOP_PENDING debounce (default 1s, clamped 0.5-2s) on the stop path only;
DISABLED kill-switch with STOP-on-entry and no auto-leave; hold-aware demand
so force-on suppresses the debounce; DEGRADED notifies only with demand or
hold active and stays silent at idle. Manual start/stop events retained for
compat but no longer driven.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Coordinator wiring — observer, debounce/hold timers, persistence, metrics

The only place timers and persistence live. The machine stays pure.

**Files:**
- Create: `macos/SharedMic/Session/DemandSettings.swift`
- Modify: `macos/SharedMic/Net/ConnectionCoordinator.swift`
- Test: `macos/SharedMicTests/ConnectionCoordinatorTests.swift` (extend) + new `macos/SharedMicTests/DemandSettingsTests.swift`

**Interfaces:**
- `public struct DemandSettings { var disabled: Bool; var stopDebounceMs: Int (500–2000, default 1000); var holdSeconds: TimeInterval (default 1800) }` + `public protocol DemandSettingsStore { func load() -> DemandSettings; func save(_ s: DemandSettings) }` + `UserDefaultsDemandSettingsStore` + `InMemoryDemandSettingsStore`.
- `ConnectionCoordinator`:
  - `init(store:clientId:makeRenderer:demandSettings:demandObserver:)` — new params defaulted so Phase 1/2 call sites compile; observer defaults to a live `AudioDemandObserver` started on `startIfPaired`/pair-auth, stopped on unpair/shutdown (injectable fake in tests).
  - Removes public `requestStart()/requestStop()` (the Phase 1 scaffolding). Internal `nextRequestId` reuse for demand-driven START/STOP.
  - Owns `stopDebounceTimer` (fires `stopDebounceExpired`), `holdTimer` (fires `holdExpired`, publishes remaining), `disabled` persistence (save on `userDisabled`/`userEnabled`, restore at init → starts `disabled`, control connection still comes up for status).
  - Translates observer snapshots → `demandChanged(hasDemand:)`; re-fires current demand after every `authenticated` (reconnect-with-demand → STARTING per §5.2).
  - Handles `armStopDebounce/cancelStopDebounce` actions.
  - Metrics: `sessionCount`, `debounceFireCount` (incremented only when the debounce actually fires — the spec's "measure whether it fires at all"), `lastActivationLatencyMs` (START sent → first playable frame; first audio byte through `audioSink` after START_ACK), `demandSnapshot` (last observer snapshot for the menu), `holdRemaining` (nil when no hold). No audio payload logged or persisted, ever.
  - Notification gating rides the machine (Task 3): the coordinator performs `notify` actions unchanged.

- [ ] **Step 1: Write the failing tests**

`DemandSettingsTests`: defaults (1000 ms, 30 min, enabled); clamping (499→500, 2001→2000); DISABLED round-trips through the store; hold-active never persists (fresh load has no hold).
Coordinator extensions (fake observer + in-memory settings, real mock server where needed): demand snapshot starts a session against the mock (START observed); demand clear arms but does not immediately STOP; debounce expiry sends STOP; disable mid-stream sends STOP and persists; relaunch restores disabled and sends no START on demand; hold forces START with no demand and auto-expires; reconnect re-fires demand; `debounceFireCount` increments only on real fire; `lastActivationLatencyMs` set after first frame.

- [ ] **Step 2: Run and confirm they fail**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/DemandSettingsTests`
Expected: FAIL — missing types. (Coordinator extensions fail on missing wiring.)

- [ ] **Step 3: Write the minimal implementation**

Create `DemandSettings.swift`; extend `ConnectionCoordinator` per above. Observer callbacks hop onto `queue`; all `SessionController.handle` calls stay on `queue`; state/month publish on main as today. Hold timer is a `DispatchSourceTimer` with 1 s remaining-publication granularity. DISABLED is restored before `startIfPaired` so launch lands correctly.

- [ ] **Step 4: Run and confirm it passes**

Run: `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/DemandSettingsTests -only-testing:SharedMicTests/ConnectionCoordinatorTests`
Expected: PASS — `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Session/DemandSettings.swift macos/SharedMic/Net/ConnectionCoordinator.swift macos/SharedMicTests/DemandSettingsTests.swift macos/SharedMicTests/ConnectionCoordinatorTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): wire demand observer to sessions with debounce and hold timers

Observer snapshots drive demandChanged with reconnect re-fire; coordinator
owns the stop-debounce and 30-minute hold timers, persists only DISABLED,
and records debounce-fire count plus START-to-first-frame latency for the
Phase 3 measurements. Manual requestStart/requestStop removed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Menu bar — delete Start/Stop, show Disabled/Held/demand/system-input

**Files:**
- Modify: `macos/SharedMic/App/AppModel.swift`, `macos/SharedMic/App/MenuBarView.swift`
- Test: `macos/SharedMicTests/AppModelTests.swift` (extend)

**Interfaces (`AppModel`, all `@MainActor` published):**
- Removed: `startSession()/stopSession()`, `canStart/canStop`.
- Added: `disable()/enable()`, `beginHold()/cancelHold()`, `stopDebounceMs` (display) + `setStopDebounceMs(_:)` (clamped passthrough), `demandProcesses: [DemandingProcess]`, `demandCount: Int`, `holdRemaining: TimeInterval?`, `holdDisplay: String?` (`"Held 23:11 remaining"`), `systemInputName: String?`, `systemInputIsBlackHole: Bool`, `debounceFireCount: Int`, `lastActivationLatencyMs: Double?`, `sessionCount: Int`.
- Status text: `disabled` → `"Disabled — remote microphone off"`; hold active → `"Held …"` prefix/suffix with remaining per §11; `stopPending` renders as `"Stopping…"`-adjacent transient (spec has no §11 name for it; never persist it as a displayed state).

**Menu contents:** status dot (disabled = gray with explicit off-state, held = purple/blue distinct from streaming green), kill-switch toggle, 30-min hold button + cancel + remaining, demand section (count + bundle ID per holder — a bare count is unattributable per §5.1), system-input row + §3.4 warning when BlackHole is the default, byte counter (unchanged), debounce row (`"Stop debounce 1000 ms (500–2000)"`), last-activation + debounce-fire diagnostics row, pairing/unpair/quit (unchanged).

- [ ] **Step 1: Write the failing tests**

Extend `AppModelTests`: no Start/Stop API exists; disable persists and suppresses demand-start (via coordinator fake); hold publishes remaining and cancels; demand list publishes bundle IDs; system-input flag publishes; debounce setter clamps.

- [ ] **Step 2: Run and confirm they fail**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/AppModelTests`
Expected: FAIL — references to removed/added API.

- [ ] **Step 3: Write the minimal implementation**

Rewrite the menu sections; keep pairing/quit/byte-counter paths untouched. No device writes. No Start/Stop strings remain in the UI (grep must return nothing).

- [ ] **Step 4: Run and confirm it passes**

Run: same line as Step 2, then `grep -rn "Start session\|Stop session\|canStart\|canStop\|requestStart\|requestStop" macos/SharedMic/App macos/SharedMic/Net || echo CLEAN`.
Expected: PASS + CLEAN.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/App/AppModel.swift macos/SharedMic/App/MenuBarView.swift macos/SharedMicTests/AppModelTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): automatic-demand menu with kill switch and force-on hold

Manual Start/Stop removed; menu gains persistent disable, 30-minute hold
with remaining-time display, per-process demand list with bundle IDs,
system-input row with BlackHole-as-default warning, and debounce/latency
diagnostics. No device selection is ever written.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Measurements and owner-gated acceptance (no code, or instrumentation-only)

Spec §9 rows this phase owes. Automation proves the plumbing; the verdicts need the owner's Mac, ears, and real applications.

**Instrumentation already in place (Tasks 3–4):** `debounceFireCount`, `lastActivationLatencyMs` (START→first frame), `sessionCount`, demand-appear/clear timestamps in the observer (for demand-detection latency = device-open → snapshot-emit, measured against a real app, not the synthetic 5 ms probe row).

- [ ] **Step 1: Record the automated baselines.** Full suite green (`xcodebuild test …`), harness `pytest -q` untouched (101 passed), `grep -rn "IsRunningInput" macos/SharedMic/Audio` shows only diagnostics-or-tests (never the gate), `grep -rn "Start session" macos/SharedMic` is empty.
- [ ] **Step 2: Owner matrix (one sitting per app, §3.4-configured default = real hardware mic).** Raycast 4+ activations incl. second-and-later without restart (START/STOP automatic, demand list shows Raycast, clear each release); System Settings → Sound open (zero STARTs); Safari open/idle/capture/stop (zero STARTs at idle, correct START while capturing, return to 0 after); Dictation, Chrome/Chromium, ChatGPT desktop, Zoom, Teams — first session each, or documented force-on fallback per app (§13 Q1). Log appear/clear latency per app (state, not timing, was all Phase 0 recorded).
- [ ] **Step 3: Debounce + first-word verdicts.** Debounce firing check (did `debounceFireCount` ever increment in normal use?); 95-of-100 first-word run with automated onset (not manual START as stand-in); demand-detection latency against a real app (replaces the synthetic 5 ms §6.3 row); 10-min idle byte counter = 0; kill-switch-with-demand byte counter = 0.
- [ ] **Step 4: File the results.** Update this plan's Measurements Appendix table with the figures and which run they came from; open follow-ups for any app that needs the force-on fallback. Do not change code to chase a single app's quirk without a spec discussion.

## Measurements Appendix (maps to spec §9–§10 and issue #12)

| Spec / issue row | Proved by | Status |
|---|---|---|
| Raycast auto START/STOP incl. repeat activations | Tasks 2+4 wiring, Task 6 owner matrix | Owner-gated |
| Sound-pane + Safari produce zero STARTs (§3.4-configured) | Tasks 1+2 predicate, Task 6 matrix | Owner-gated |
| 95-of-100 first-word, threshold frozen | Task 4 `lastActivationLatencyMs` + Task 6 run | Owner-gated |
| Demand-detection latency vs real app (replaces synthetic 5 ms) | Task 4 observer timestamps + Task 6 | Owner-gated |
| Debounce fires at all | Task 4 `debounceFireCount` + Task 6 | Owner-gated |
| Kill switch: zero bytes with demand | Tasks 3+4+5, Task 6 counter check | Automated + owner counter check |
| Hold expires at 30 min | Tasks 3+4 timers, Task 6 elapsed-vs-configured | Automated + owner check |
| 10-min idle → 0 PCM bytes | Unchanged Phase 2 counter, Task 6 | Owner-gated |
| Dictation / Chrome / ChatGPT / Zoom / Teams | Task 6 matrix (§13 Q1) | Owner-gated, fallback is documented force-on |
| WebKit-retains-BlackHole-as-default unknown | House note: requires BlackHole-as-default run, NOT the §3.4 run | Explicitly unmeasured, do not assume |

## Phase 3 completion checklist

- [ ] `ruby macos/project.rb` regenerates with no leftover diff
- [ ] `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64'` — `** TEST SUCCEEDED **`
- [ ] `grep -rn "Start session\|Stop session\|requestStart\|requestStop" macos/SharedMic` is empty (scaffolding gone)
- [ ] `grep -rn "IsRunningInput" macos/SharedMic/Audio` shows no gating use (diagnostic-only at most)
- [ ] `grep -rn "setDefault\|SetDefault\|DefaultInputDevice.*set\|DefaultOutputDevice.*set" macos/SharedMic` is empty (no device writes)
- [ ] Menu shows Disabled, Held-with-remaining, demand count + bundle IDs, system input + §3.4 warning, byte counter, debounce/latency rows
- [ ] DISABLED survives relaunch; hold does not; debounce clamps 500–2000
- [ ] This plan's Measurements Appendix has a status per row; owner-gated rows name their run

## Phase 4 handoff

- Observer emits change-only snapshots; sleep/wake (Phase 4) should force a re-resolve + rescan on wake rather than trusting cached IDs.
- `lastActivationLatencyMs` / `sessionCount` / `debounceFireCount` are coordinator-owned counters for the Phase 4 diagnostics view; the menu shows only the latest rows, not history.
- Known unmeasured: the five untested apps (§13 Q1), WebKit-retains-BlackHole-as-default, real-app appear/clear latencies, 95-of-100 verdict. All tracked above, none assumed.
- If any app reports unreliably, the fallback is documented force-on for that app — not a gate workaround.

## Scope coverage map

| Scope item (issue #12) | Task(s) |
|---|---|
| `AudioDemandObserver`, UID-only, PID-skipping, own-PID skip, contains-predicate | 1 (predicate), 2 (observer + fallback) |
| STARTING / ACTIVE / STOP_PENDING (1000 ms, 500–2000) / STOPPING / DEGRADED wired to observer | 3 (machine), 4 (timers + re-fire) |
| `Disabled` + `Held` (§11) | 3 (disabled node; held as UI indication over hold-active), 4 (persistence + remaining), 5 (display) |
| Kill switch: persistent DISABLED, immediate STOP, never auto-leaves | 3, 4, 5 |
| Force-on hold: 30-min auto-expire + remaining display | 3, 4, 5 |
| Notify on DEGRADED-with-demand only; silent at idle | 3 (gating), 4 (passthrough) |
| Demand count + bundle IDs, system input display (§11, §3.4) | 5 (menu), 2 (data) |
| Measurements: 95-of-100, debounce fire, demand latency, untested apps, house note | 4 (instrumentation), 6 (owner runs) |

