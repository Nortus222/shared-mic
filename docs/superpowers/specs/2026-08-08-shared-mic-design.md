# On-Demand Shared USB Microphone — Design

**Status:** Approved for planning
**Date:** August 8, 2026
**Supersedes:** `shared_microphone_system_design.docx` (draft, same date)

One USB microphone is physically attached to a Windows host. It must be usable from Windows and
macOS simultaneously, with no hardware switch and no manual device switching — and microphone audio
must cross the network only while macOS actually has an application asking for input.

---

## 1. What changed from the draft

The draft is largely sound and most of it survives. Five decisions changed, and they are the reason
this document supersedes it.

| Draft | Now | Why |
|---|---|---|
| §5.2: process-level demand detection false-positives are unavoidable in the MVP | Demand is scoped to the shared virtual device by UID | The target Mac runs macOS 26.6.1, where `kAudioProcessPropertyDevices` (14.4+) reports per-process devices with an input scope. The limitation was a version assumption, not a platform one. |
| §7.2: two TCP connections, TLS optional | One TLS connection carrying control and audio, multiplexed with a priority send queue | Hardening is in scope, and two channels means two handshakes, two auth paths, two reconnect state machines. It also puts a TLS handshake on the activation path, which is exactly where the first-word-clipping risk lives. |
| Phase 5: security hardening | Security is built in Phase 1, with the transport | Retrofitting TLS and auth onto a working plaintext channel means building the connection layer twice. Under a single multiplexed channel, the connection is the chokepoint for everything else. |
| Phase 6: custom "Shared Mic" Core Audio driver | Dropped | Its only substantive justification was an unambiguous demand signal. Device-scoped detection provides that without the signing, install, and real-time-debugging burden. |
| §6.4: optional Windows "warm capture" mode | Dropped | It keeps the Windows microphone-in-use indicator permanently lit, which is one of the things this project exists to avoid. |

Two ambiguities in the draft are resolved here: the stop debounce is **1000 ms** (§3 of the draft
said 750–1500 ms, §5.4 said 1000 ms), and the BlackHole writer opens on entry to `STARTING` and
closes after `STOPPING` drains — never held open at idle.

Three additions the draft did not cover: a **kill switch**, a **force-on hold**, and **clock-drift
correction**.

---

## 2. Goals

### 2.1 Functional

- One USB-A microphone attached to Windows is usable from Windows and macOS without a hardware switch.
- Both machines may use it at the same time.
- No manual switching during normal operation.
- Microphone audio is transmitted only while macOS has active input demand **on the shared virtual
  device**.
- Starting dictation on macOS activates the remote microphone automatically; stopping it deactivates
  after a short debounce.
- Both agents launch at login and recover from sleep, network changes, and process restarts.
- The user can hard-disable the remote microphone, and can force it on when detection misses an app.

### 2.2 Non-functional

| Metric | Target | Rationale |
|---|---|---|
| Idle microphone payload | 0 bytes/sec | The core requirement |
| Idle control traffic | < 1 KB/min | Heartbeat and state only |
| Activation latency | < 300 ms p95 on LAN | Avoid clipped first words |
| Steady-state end-to-end latency | < 150 ms p95 | Comfortable for dictation |
| Active payload bandwidth | 768 kbps | 48 kHz, mono, 16-bit PCM |
| CPU usage | < 2% average per machine while active | Background utility |
| Internet dependency | None | LAN-only |

### 2.3 Non-goals

- Studio-quality monitoring or musical performance.
- Multi-user conferencing or WAN traversal.
- Replacing the Windows microphone with a virtual device.
- More than one remote Mac.
- Echo cancellation, noise suppression, gain control, or transcription.
- A custom macOS audio driver.

### 2.4 Motivation, recorded

The zero-idle-bytes requirement is driven by three things, in this order: **privacy** (no hot mic
capturing and shipping audio unless something genuinely needs it), the **Windows microphone-in-use
indicator** (it should be off when the mic is off), and **bandwidth and CPU**.

Privacy being a driver is load-bearing. It is why the demand signal must be device-scoped rather
than process-scoped, why the force-on hold expires, and why a certificate mismatch is a hard stop.
An implementation that satisfies the letter of "zero idle bytes" while starting sessions for
unrelated applications has failed the actual requirement.

---

## 3. Architecture

```
Windows host                                          Mac
┌──────────────────────────┐                ┌────────────────────────────┐
│ USB mic → MicCapture     │                │ AudioDemandObserver        │
│   (WASAPI shared)        │                │  (per-process, UID-scoped) │
│        ↓ bounded channel │                │        ↓ demandCount       │
│ PcmNormalizer 48k/mono   │                │ SessionController          │
│        ↓                 │   ONE TLS      │        ↓                   │
│ SessionStateMachine ── ControlConnection ═══ ControlClient             │
│                          │  ctrl + audio  │        ↓ PCMRingBuffer     │
│ TrayApp                  │   multiplexed  │ AudioRenderer → BlackHole  │
└──────────────────────────┘                └────────────────────────────┘
```

Windows listens on **TCP 47800** (configurable), bound to private interfaces only. The Mac is the
client. The connection is established whenever both machines are awake and stays up; it carries
control messages and, when a session is active, audio.

### 3.1 Module boundaries

Three units hold the logic that is easy to get wrong. All three are pure — no I/O, no platform
APIs — and all three carry real unit tests:

- **`PcmNormalizer`** (Windows) — device mix format to 48 kHz / mono / s16le.
- **`SessionStateMachine`** (Windows) — session lifecycle as a pure transition function.
- **`PCMRingBuffer`** (macOS) — lock-free single-producer/single-consumer ring.

Everything touching WASAPI, Core Audio, or sockets is a thin shell around these. Network code never
runs on an audio callback, and audio code never performs network I/O.

### 3.2 Windows agent

C# on .NET 10 LTS, using NAudio's WASAPI capture API for shared-mode capture. Packaged as a tray
application with launch-at-login.

| Module | Responsibility | Knows nothing about |
|---|---|---|
| `DeviceManager` | Resolve and persist the MMDevice endpoint ID; watch arrival/removal | Network, sessions |
| `MicCaptureService` | Own the WASAPI shared-mode client; emit frames to a bounded channel | Network, protocol |
| `PcmNormalizer` | Format conversion (pure) | Everything else |
| `SessionStateMachine` | Session lifecycle (pure) | I/O |
| `ControlConnection` | TLS, framing, priority send queue, heartbeat, auth | Audio semantics |
| `TrayApp` | Status UI, device picker, level meter, pairing display | Protocol details |

### 3.3 macOS agent

Swift with Core Audio, packaged as a menu-bar application with launch-at-login.

| Module | Responsibility | Knows nothing about |
|---|---|---|
| `AudioDemandObserver` | Device-scoped per-process input observation; publishes `demandCount` | Network, sessions |
| `BlackHoleDevice` | Resolve the virtual device by UID; presence checks | Network |
| `SessionController` | State machine including `DISABLED` and force-on hold | Socket details |
| `ControlClient` | TLS, framing, reconnect, heartbeat, auth | Audio semantics |
| `PCMRingBuffer` | Lock-free SPSC ring (pure) | Everything else |
| `AudioRenderer` | AUHAL output to BlackHole; real-time-safe render callback | Network |
| `MenuBarController` | Status UI, kill switch, force-on, diagnostics, pairing | Protocol details |

---

## 4. Transport

### 4.1 Framing

After the TLS 1.3 handshake, every message on the wire is:

```
uint8   type        // 1 = CONTROL, 2 = AUDIO
uint32  length      // payload byte count, network byte order
bytes   payload
```

`CONTROL` payload is UTF-8 JSON. `AUDIO` payload is:

```
uint32  sequence
uint64  captureTimestampUs
bytes   pcm                 // 1920 bytes for a 20 ms frame
```

The draft's separate inner `payloadLength` field is removed — the envelope already carries the
length, and two length fields that can disagree is a defect waiting to be written.

### 4.2 Priority send queue

This is what makes a single multiplexed channel safe. The Windows writer drains two queues:

- **Control** — unbounded (messages are tiny and rare), always drained first.
- **Audio** — a bounded ring of **25 frames (500 ms)** that **drops the oldest frame on overflow,
  never blocks**.

A stalled network can therefore delay audio, but can never delay a `STOP_ACK` or a `STATUS`. The
WASAPI capture callback hands frames to a bounded channel and returns; it never touches a socket.

Dropped frames are counted and surfaced in diagnostics. Silent dropping that looks like healthy
operation is worse than the drop itself.

### 4.3 Heartbeat and reconnect

The Mac sends `PING` every **15 s**; the connection is declared dead after **45 s** without a
`PONG` (three missed). Windows applies the same dead-peer rule to absent `PING`s.

A slow heartbeat is deliberate. The heartbeat exists to keep UI status honest and NAT state fresh —
it is not the hot path. When demand actually arrives, liveness is established by `START`'s own 2 s
timeout, which detects a dead peer far faster than any practical heartbeat interval. At 15 s the
idle control traffic is roughly 500 B/min of TCP payload (~820 B/min including IP framing),
comfortably inside the < 1 KB/min budget; a 10 s interval would have pushed the IP-framed figure
past it for no benefit.

The Mac reconnects with exponential backoff from **0.5 s to a 30 s cap**, jittered.

### 4.4 Control messages

| Message | Direction | Purpose |
|---|---|---|
| `GREETING` | Win → Mac | Server identity, auth nonce |
| `HELLO` | Mac → Win | Protocol version, client identity, auth proof |
| `HELLO_ACK` | Win → Mac | Server identity, microphone status |
| `START` | Mac → Win | Request an active session |
| `START_ACK` | Win → Mac | Session ID, negotiated format |
| `START_NACK` | Win → Mac | Reason (e.g. `MIC_UNAVAILABLE`) |
| `STOP` | Mac → Win | End the active session |
| `STOP_ACK` | Win → Mac | Session ended |
| `STATUS` | Win → Mac | Mic presence, active state, device label, errors |
| `PING` / `PONG` | Both | Connection health |

`START` and `STOP` are idempotent. A duplicate `START` while active returns the current session
info; a duplicate `STOP` while idle returns success. This makes reconnect and retry safe.

The full wire contract lives in `protocol/protocol-v1.md`, written in Phase 0.

---

## 5. Demand detection

### 5.1 Algorithm

At startup, resolve BlackHole by UID and cache its `AudioObjectID`. Then count processes where:

- `kAudioProcessPropertyDevices` with scope `kAudioObjectPropertyScopeInput` contains BlackHole's
  object ID.

Our own PID is always skipped. Register listeners on `kAudioHardwarePropertyProcessObjectList`, and
per process on `Devices`, adding and removing per-process listeners as the list changes. Where
listener registration fails for a property, look up that specific process with
`kAudioHardwarePropertyTranslatePIDToProcessObject` and poll only that one process at 100 ms. A
targeted, single-process lookup is roughly an order of magnitude cheaper than enumerating the full
process list (§6.3), so the fallback must target the specific process rather than sweep everything.

**`kAudioProcessPropertyIsRunningInput` is not part of the gate, and must not become one.** An
earlier version of this section (and the draft before it) required `IsRunningInput` as a second,
mandatory conjunct alongside `Devices`. Task 10's macOS probe
(`docs/superpowers/probes/2026-08-08-macos-demand-findings.md`), run on the actual target Mac
(macOS 26.6.1), found that `IsRunningInput` does **not** reliably re-trigger past a process's
*first* input activation: on a process's second and later activations, it read `false` at the exact
instant `Devices` membership was independently confirmed `true` — self-introspectively, for a
genuinely separate helper process, and via both the full-sweep and targeted-lookup paths — and in
the observed case it stayed `false` through 1188 ms of 10 ms-interval polling, far too long to be
propagation lag. `Devices` membership and the general, non-input-scoped `kAudioProcessPropertyIsRunning`
both re-triggered correctly on every activation tested. Since real applications (Dictation, a
browser tab, Chrome, anything on `AVAudioEngine`) are not restarted between recording sessions,
gating on `IsRunningInput AND Devices` as originally specified would detect an application's first
use of the microphone and then silently miss every subsequent one for that process's entire
lifetime — the user would be talking into a dead microphone with no error surfaced anywhere. Demand
is therefore gated on `Devices` membership alone. `IsRunningInput` may still be read and shown as a
supplementary or diagnostic signal — it is logged alongside `Devices` membership in the probe for
exactly this reason — but it must never be a required conjunct for starting or stopping a session.

The root cause is unidentified, and the flag may still be salvageable as a secondary signal later.
Every activation in the probe constructed a **brand-new** `AudioComponentInstance` per cycle
(dispose the old unit, create and configure a new one), while a real client such as Dictation,
Chrome, or anything built on `AVAudioEngine` is far more likely to hold **one** engine/unit instance
for its whole session and call start/stop on that same instance repeatedly. The sticky-false
behavior may therefore be HAL-client re-registration scoped to a *new instance*, not a genuine
process-level "Nth activation" property — in which case real long-lived apps might re-trigger
`IsRunningInput` correctly every time, and it would be salvageable after all. This distinction was
not tested. **The first thing Phase 3 should check, before relying on or ruling out
`IsRunningInput` for anything, is the measurement the probe specifies but did not run: build one
`AudioUnit` instance, call `AudioOutputUnitStart`/`AudioOutputUnitStop` on that same instance twice
with no dispose-and-recreate in between, and observe whether `IsRunningInput` re-triggers `true` on
the second start.** Device-list membership works as the gate regardless of how that measurement
turns out.

The `Devices` predicate is the entire point. The target Mac has BlackHole, ManyCam, Microsoft Teams
Audio, Parallels Access Sound, and Squirrels Audio installed. Under process-level detection alone,
any of those going active would start the remote microphone. Device scoping is not an optimization
here; it is what makes the privacy claim true.

### 5.2 State machine

```
DISABLED ──user enables──────────────────→ IDLE

IDLE
  ├─ demandCount > 0 ──────────────────────→ STARTING
  ├─ user force-on ────────────────────────→ STARTING
  └─ user disables ────────────────────────→ DISABLED

STARTING                       (BlackHole writer opens on entry)
  ├─ START_ACK + first frame ──────────────→ ACTIVE
  ├─ demand gone and no hold ──────────────→ STOPPING
  ├─ START_NACK / error / 2 s timeout ─────→ DEGRADED
  └─ user disables ────────────────────────→ STOPPING → DISABLED

ACTIVE
  ├─ demandCount > 0 or hold active ───────→ ACTIVE
  ├─ demandCount == 0 and no hold ─────────→ STOP_PENDING
  ├─ transport lost ───────────────────────→ DEGRADED
  └─ user disables ────────────────────────→ STOPPING → DISABLED

STOP_PENDING                   (1000 ms debounce)
  ├─ demand returns or hold set ───────────→ ACTIVE
  └─ debounce expires ─────────────────────→ STOPPING

STOPPING                       (drain buffer, close writer; 1 s timeout)
  └─ STOP_ACK or timeout ──────────────────→ IDLE or DISABLED

DEGRADED                       (notification fires here, conditionally)
  ├─ reconnected and demand > 0 ───────────→ STARTING
  ├─ reconnected and no demand ────────────→ IDLE
  └─ user disables ────────────────────────→ DISABLED
```

`START` is immediate; only `STOP` is debounced. The debounce default is **1000 ms**, configurable
**500–2000 ms**. It exists because Dictation, browsers, and communication apps routinely tear down
and immediately recreate an input stream.

### 5.3 Kill switch

`DISABLED` persists across restarts. Entering it sends `STOP` immediately; while in it, no `START`
is ever sent regardless of demand. The control connection stays up so status remains accurate, and
the menu bar states plainly that the remote microphone is off.

### 5.4 Force-on hold

A manual hold forces a session for applications whose input Core Audio does not report. It
**auto-expires after 30 minutes** (configurable), with remaining time shown in the menu bar. An
override that can be left on indefinitely quietly becomes the always-on hot microphone this project
exists to eliminate.

### 5.5 Notification policy

The user-visible alert fires on entering `DEGRADED` **while demand is active** — the moment where
the user is dictating into nothing and needs to know immediately.

It deliberately does not fire when the connection drops at idle. Windows sleeping overnight is
normal, and an alert for it would train the user to ignore the alert that matters.

---

## 6. Audio path

### 6.1 Windows capture

`DeviceManager` persists the MMDevice endpoint ID rather than the friendly name. On `START` it
verifies presence; if the device is absent, Windows replies `START_NACK{reason: MIC_UNAVAILABLE}`
and the Mac enters `DEGRADED`.

Capture opens in **WASAPI shared mode**. Exclusive mode is prohibited — it would take the microphone
away from Windows applications, defeating the simultaneous-use goal.

`PcmNormalizer` converts the shared mix format to 48 kHz / mono / signed 16-bit little-endian:
float32 to int16, resampling only when the mix format is not already 48 kHz, and downmixing to
mono. Channel handling is configurable — **`mix` (default) | `left` | `right`**. A mono capsule
presented as dual-mono averages correctly, but a microphone that places signal only on the left
channel loses 6 dB under averaging. The tray shows an input level meter so this is caught in
seconds rather than diagnosed as a mysterious volume problem.

Capture lifecycle:

```
START received → verify device present → open shared-mode client → start capture
               → normalize → send START_ACK → stream frames

STOP received  → stop capture → dispose client → send STOP_ACK → idle
```

### 6.2 Frame format

| Property | Value |
|---|---|
| Sample rate | 48,000 Hz |
| Channels | 1 (mono) |
| Sample format | 16-bit signed little-endian PCM |
| Frame duration | 20 ms |
| Samples per frame | 960 |
| Audio bytes per frame | 1,920 |
| Frames per second | 50 |
| Payload rate | 96,000 B/s = 768 kbps |

No codec. Sub-1 Mbps is trivial on a LAN, and PCM avoids codec delay, resampling edge cases, native
library packaging, and an entire class of debugging.

### 6.3 Activation latency budget

| Stage | Typical | Source |
|---|---|---|
| Input demand appears → `Devices` membership confirmed | 4–6 ms | **Measured** — Task 10 macOS probe, targeted lookup via `kAudioHardwarePropertyTranslatePIDToProcessObject`, self-introspection on the target Mac (macOS 26.6.1) |
| Demand detected → `START` sent (warm TLS connection) | 1–5 ms | Estimate |
| LAN transit | 2–15 ms | Estimate |
| WASAPI shared open and start | 20–80 ms | Estimate — **unverified**, see below |
| First 20 ms frame captured | 20 ms | Fixed by frame duration |
| Transit to Mac | 2–10 ms | Estimate |
| Jitter buffer prefill | 60 ms | Estimate — set by measurement in Phase 2 |
| **Total** | **~109–196 ms** | |

The demand-detection figure is the targeted-lookup measurement from
`docs/superpowers/probes/2026-08-08-macos-demand-findings.md` (leg 1: 5 ms to detect appearance,
3 ms to detect clearing). Two other numbers from that probe are deliberately **not** used here: the
full-sweep figure (~40–60 ms, enumerating all ~40 process objects on the test machine) is roughly
90% enumeration overhead rather than Core Audio propagation, and the cross-process figures
(575–1188 ms) are dominated by helper-process spawn and `AudioUnit` setup, not steady-state
detection latency for an already-running application. Neither characterizes what a running demand
observer actually experiences once its listeners are registered.

The WASAPI shared-mode open figure (20–80 ms) is still the original, unmeasured planning estimate.
The Windows probe that would measure it
(`probes/windows-wasapi-latency/`, see
`docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`) has been written but **has never
been compiled or run** — no real figure exists yet. Treat this row, and therefore the total, as
provisional until the owner runs that probe on the actual Windows host.

This fits the 300 ms p95 target with headroom, provisionally. The single largest contributor to
that headroom is the warm TLS connection — under the draft's two-connection design, a handshake
would sit directly on this path.

**Accepted limitation, stated plainly:** because capture is closed at idle by design, there is no
pre-roll. Audio spoken before `START` is unrecoverable. No tuning removes this; it is the direct
cost of the zero-idle-bytes requirement. The defenses are minimizing activation latency and the
fact that applications normally open input before the user begins speaking. Acceptance is measured
empirically (§9), not assumed.

### 6.4 macOS render

`AudioRenderer` uses an AUHAL output unit targeting BlackHole **by UID**, set explicitly. The Mac's
default output device is never modified. Mono is duplicated to both BlackHole channels.

The render callback is real-time safe without exception: it reads the lock-free ring buffer and
zero-fills on underrun. No allocation, no locks, no logging, no network I/O.

The jitter buffer targets **60 ms** prefill (three frames), adapting within **40–120 ms**. The
prefill figure is a tuning knob to be set by measurement in Phase 2, not by guess — lowering it
trades activation latency against underrun risk, and only measurement on the real network settles
the trade.

### 6.5 Clock drift

The Windows capture clock and BlackHole's clock are both nominally 48 kHz and are not the same
clock. At a plausible 100 ppm they diverge about 60 ms over a ten-minute session — enough to drain
or overflow the buffer during a long dictation.

The adaptive buffer corrects it: depth above the **120 ms high watermark** for 5 consecutive
seconds drops one frame; depth below the **40 ms low watermark** for 5 consecutive seconds inserts
one frame of silence. The 5-second dwell requirement is what distinguishes real drift from ordinary
network jitter — correcting on instantaneous depth would fight the jitter buffer instead of
complementing it. A single 20 ms adjustment every few minutes is inaudible in speech, and it keeps
long sessions stable indefinitely.

---

## 7. Security

### 7.1 Pairing

Windows generates a self-signed P-256 device certificate on first run, with the private key
DPAPI-protected. The tray displays a pairing string encoding a random 256-bit token. The user
enters the host address and that string on the Mac once. At that moment the Mac pins the server
certificate fingerprint and stores the token and fingerprint in the Keychain.

### 7.2 Authentication

On each connection:

1. Windows sends `GREETING{serverId, nonce}`.
2. The Mac replies `HELLO{version, clientId, mac: HMAC-SHA256(token, nonce)}`.
3. Windows verifies and replies `HELLO_ACK`.

The token itself never crosses the wire, and the nonce makes the proof replay-resistant. Failed
authentication is rate-limited to 5 attempts followed by a 30 s lockout.

### 7.3 Rules

- The listener binds to private interfaces only, with a Windows Firewall rule scoped to the Private
  profile. The agent is never exposed to the public Internet.
- **A certificate fingerprint mismatch is a hard stop** — no auto-retry, no silent re-pair, a
  prominent warning, and re-pairing requires explicit user action. This is the one failure that can
  indicate an active attacker, and silently healing it would defeat the entire purpose of pinning.
- Audio payload is never logged or persisted. Logs contain lifecycle events and counters only.

---

## 8. Failure handling

| Failure | Behavior |
|---|---|
| Windows agent unreachable | Mac renders silence, enters `DEGRADED`, reconnects with backoff. Notification only if demand was active. |
| USB mic unplugged while idle | Windows sends `STATUS{micPresent: false}`. Mac stays connected; activation is blocked with a clear reason. |
| USB mic unplugged mid-session | Windows stops capture and sends `STATUS`. Mac enters `DEGRADED` and notifies. On replug, auto-restarts if demand is still active. |
| Network drops mid-session | Mac renders silence, reconnects, reissues `START` if demand persists. |
| Mac sleeps | Sockets closed cleanly where possible. On wake, reconnect and **recompute demand from scratch** — a stale count must never be trusted across a sleep. |
| Windows sleeps or reboots | Mac retries with backoff. No manual repair. |
| BlackHole missing or uninstalled while running | Activation blocked, distinct error state, setup guidance in the menu. |
| Certificate fingerprint mismatch | Hard stop with warning. No reconnect attempts until the user re-pairs explicitly. |
| Authentication failure | Connection refused, rate-limited, surfaced in both UIs. |
| Format negotiation failure | Windows normalizes before transport; the protocol rejects unsupported formats rather than sending something the Mac cannot render. |

---

## 9. Acceptance criteria

- [ ] Both machines running and idle for 10 minutes: microphone payload received by the Mac is
      exactly **zero bytes**.
- [ ] Starting macOS Dictation activates the remote stream automatically, with no button press.
- [ ] Stopping Dictation returns the system to idle automatically.
- [ ] Windows applications can use the physical USB microphone while the Mac is receiving it.
- [ ] Across 100 repeated Dictation activations, **at least 95 lose no complete first word**.
- [ ] `START`-to-first-playable-frame latency is **below 300 ms at p95** on the home LAN.
- [ ] Opening microphone input in ManyCam, Teams, or another non-BlackHole virtual device produces
      **zero** `START` messages.
- [ ] The kill switch guarantees zero bytes even with an application actively requesting input.
- [ ] The force-on hold expires automatically at its configured duration.
- [ ] A 30-minute continuous session completes with no drift-induced underruns.
- [ ] Mac and Windows sleep/wake recover without reconfiguration.
- [ ] USB microphone unplug and replug recovers without restarting either application.
- [ ] A tampered or mismatched certificate fingerprint blocks the connection and warns the user.
- [ ] No microphone PCM is written to disk or to any application log.

---

## 10. Test matrix

| Scenario | Expected | Measure | Priority |
|---|---|---|---|
| Mac Dictation start/stop | Automatic START/STOP | Activation and stop latency | P0 |
| ChatGPT / browser voice input | Automatic stream | Audio accepted | P0 |
| Windows + Mac simultaneous dictation | Both receive speech | No WASAPI conflict | P0 |
| 10-minute idle | No PCM transport | Byte counter = 0 | P0 |
| **ManyCam/Teams input opened** | **No START sent** | **False-start count = 0** | **P0** |
| **Kill switch engaged, app requests input** | **No START sent** | **Byte counter = 0** | **P0** |
| Mic unplug / replug | Recover | Time to healthy | P0 |
| Force-on hold expiry | Session ends at expiry | Elapsed vs configured | P1 |
| Mac sleep / wake | Reconnect, demand recomputed | Manual actions = 0 | P1 |
| Windows reboot | Reconnect | Manual actions = 0 | P1 |
| Wi-Fi packet loss | Graceful silence and recovery | Underruns, dropped frames | P1 |
| 30-minute continuous session | Stable buffer | Drift corrections, underruns | P1 |
| BlackHole unavailable | Clear error and guidance | UI state | P1 |
| Certificate mismatch | Hard stop with warning | No reconnect attempts | P1 |
| 8-hour idle soak | No PCM transport | Byte counter = 0 | P1 |

### 10.1 Unit tests

- **`PcmNormalizer`** — golden vectors covering float32 stereo 44.1 kHz → s16le mono 48 kHz, all
  three channel modes, and clipping behavior at full scale.
- **`SessionStateMachine`** — every transition, including debounce expiry and cancellation, hold
  expiry, kill-switch entry from each state, and idempotent duplicate `START`/`STOP`.
- **`PCMRingBuffer`** — SPSC correctness, wraparound, underrun zero-fill, and drift-correction
  insert/drop.

### 10.2 Protocol conformance harness

A test double that speaks the wire protocol on both sides, so the Windows and macOS agents can be
built and tested independently without the other machine present. Written in Phase 0, before either
implementation.

---

## 11. Observability

Windows tray and Mac menu bar both show: Disconnected, Idle, Starting, Streaming, Degraded,
Disabled, and Held (force-on, with time remaining).

Counters exposed in a diagnostics view:

- Activation latency histogram (`START` sent → first playable frame)
- Session count and duration
- **PCM bytes received today** — surfaced directly in the Mac menu, not buried in diagnostics
- Jitter buffer depth, underrun count, drift corrections applied
- Frames dropped at the send queue
- Reconnect count, authentication failures
- Current demand process count

Showing the daily byte total in the menu makes the central privacy guarantee something the user can
verify at a glance rather than take on trust.

---

## 12. Phased plan

**Phase 0 — Protocol and probes.** Write `protocol/protocol-v1.md` and the conformance harness.
Build two throwaway probes: (a) device-scoped demand detection on macOS 26.6.1, verifying that
`kAudioProcessPropertyDevices` correctly scopes demand to BlackHole for self-introspection, a
genuinely separate process, and repeat activations — done, and it also forced a correction to §5.1
(see §13 Q1); the per-application matrix for Dictation, Chrome, ChatGPT, and Zoom/Teams still needs
the owner; (b) measured WASAPI shared-mode open latency on the actual Windows host — the probe is
written but has never been compiled or run on Windows hardware (see §13 Q2). One of the two major
risks is retired before real code is written; the other awaits the owner running the Windows probe.

**Phase 1 — Transport and security.** Single TLS channel, certificate generation, pairing, HMAC
auth, framing, priority send queue, heartbeat, reconnect. Both ends. No audio yet.

**Phase 2 — Audio path.** Windows capture and normalization, Mac render to BlackHole, manual
START/STOP from the menu. Validate quality, measure latency, set the prefill figure, verify drift
correction.

**Phase 3 — Automatic demand.** Device-scoped observer, full state machine, kill switch, force-on
hold, notification policy.

**Phase 4 — Reliability and polish.** Launch-at-login on both machines, sleep/wake, USB replug,
mDNS/Bonjour discovery, diagnostics view, level meter.

---

## 13. Open questions

Resolved by Phase 0 probes:

1. **Does device-scoped demand detection work at all — can macOS reliably attribute "someone is
   recording" to the one specific device (BlackHole) rather than only a coarse "some process
   somewhere is using some microphone"?** Yes.
   `docs/superpowers/probes/2026-08-08-macos-demand-findings.md` verified
   `kAudioProcessPropertyDevices` (input scope) correctly reports which device a process has open —
   for self-introspection, for a genuinely separate helper process observed through the normal
   PID-skipping path (not the process's own view of itself), and across repeat activations by the
   same process — with a negative control that correctly did *not* report BlackHole. Corroborating
   detail worth keeping: the system default input device was BlackHole for the entire negative-control
   leg, so a coarse "system default" signal would have made that leg fail by reporting BlackHole
   anyway; it didn't, which is independent evidence the property is genuinely per-stream-scoped. The
   same probe found that `kAudioProcessPropertyIsRunningInput` must **not** be part of the gate —
   see §5.1 for the correction this forced in the design itself.

   **Still open, and not to be treated as settled:** whether the specific target applications —
   macOS Dictation, ChatGPT, Chrome, Zoom, Teams — go through Core Audio in a way that populates
   `Devices` the same way, including on a **second** recording session per app (now specifically
   important given the `IsRunningInput` finding), has not been measured. That per-application matrix
   needs the owner and has not been run; see "Requires the owner" in the findings document. If some
   application does not report reliably, the force-on hold is the fallback for that application, and
   the gap is documented rather than worked around.

2. **What is the real WASAPI shared-mode open latency on this Windows host, cold and warm?**
   **Still open.** The probe (`probes/windows-wasapi-latency/`) is written but has **never been
   compiled or run** — this environment has no Windows machine. No latency figure exists; the
   spec's 20–80 ms budget entry (§6.3) remains the original planning estimate, not a measurement.
   See `docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`, which is explicitly marked
   not-yet-filled-in. Whether WASAPI shared mode genuinely permits simultaneous Windows + Mac
   capture is also untested — that probe's concurrency check is the go/no-go for it, and it has not
   run either.

Resolved by Phase 2 measurement:

3. Does macOS Dictation open its input stream far enough ahead of speech to avoid first-syllable
   clipping at the measured activation latency?
4. Is TCP over the actual Wi-Fi network stable enough, or does retransmission stall latency badly
   enough to justify a DTLS/UDP audio path later?

Question 4's answer changes only the transport internals. The session lifecycle, demand detection,
and virtual-device strategy are unaffected either way, which is why it can safely be deferred.

---

## 14. Alternatives considered

| Option | Advantages | Disadvantages | Decision |
|---|---|---|---|
| USB sharing switch | Trivial, no software | Manual switching; one host at a time | Rejected |
| KVM | Switches full workstation | Still transfers ownership; overkill | Rejected |
| Always-on SonoBus + BlackHole | Already proven to work | Continuous session; no lifecycle control | Prototype only |
| Voice-activity detection as trigger | Stops sending silence | Models speech, not application need; clips words | Rejected |
| Two TCP connections | Closed audio socket is a structural guarantee | Two handshakes, two auth and reconnect paths; handshake on the activation path | Rejected in favor of one multiplexed TLS channel |
| DTLS/UDP audio | Best jitter behavior | Materially more code; unproven need | Deferred pending Phase 2 measurement |
| Custom "Shared Mic" driver | Exact device lifecycle | Signing, install, real-time debugging burden | Dropped — device-scoped detection provides the same signal |
| **One TLS channel + BlackHole + device-scoped demand** | Fast to build; no driver; no false positives; lowest activation latency | Idle guarantee is a code property, verified by counter rather than by a closed socket | **Selected** |

---

## 15. References

Verified while preparing this design; implementation anchors rather than strict dependencies.

- Apple — `AudioHardwareProcess`, `AudioHardwareSystem.processes`, Core Audio
- Microsoft — About WASAPI
- NAudio — WASAPI capture documentation
- BlackHole — https://github.com/ExistentialAudio/BlackHole

API availability and third-party library behavior change. Phase 0 verifies exact API availability
and the current NAudio capture type names against the deployment targets before Phase 1 begins.
