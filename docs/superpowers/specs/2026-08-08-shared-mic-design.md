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
| §5.2: process-level demand detection false-positives are unavoidable in the MVP | Demand is scoped to the shared virtual device by UID | The target Mac runs macOS 26.6.1, where `kAudioProcessPropertyDevices` (14.4+) reports per-process devices with an input scope. The limitation was a version assumption, not a platform one. Two residual false-positive shapes were later *measured* rather than guessed at, and both are avoided by the device configuration in §3.4 — see §5.1, "False positives, measured". |
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
- **More than one Mac may be paired with the Windows host, and all of them may be connected at
  once — but at most one holds an active microphone session at any moment.** A `START` from a
  second Mac while another holds the session is refused with a clear reason naming the holder; it
  does not disconnect anyone and does not interrupt the session in progress. See §7.1 for pairing
  and `protocol/protocol-v1.md` §7 for the session rule.
- No manual switching during normal operation.
- Microphone audio is transmitted only while macOS has active input demand **on the shared virtual
  device**.
- Starting voice input in the primary application activates the remote microphone automatically;
  stopping it deactivates after a short debounce. **The primary application is Raycast**, which the
  Phase 0 probe pass confirmed opens BlackHole explicitly (§3.4). macOS Dictation is a secondary
  case and has **not** been tested against this mechanism.
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
- **Streaming the microphone to several Macs simultaneously.** Multiple Macs may be *paired* and
  *connected* (§2.1), and they take turns: exactly one session is active at a time, and a second
  Mac's request is refused while another holds it. Fan-out — one capture feeding two or more remote
  Macs at once — is out of scope. It is not a protocol change but an audio-path change: the capture
  path would need reference counting (who still wants the microphone, and when does capture
  actually stop), a send queue and drop accounting per subscriber, and a demand model where "idle"
  is the absence of demand from *every* Mac rather than from the one. That is a materially different
  design against the zero-idle-bytes guarantee, and nothing in this project needs it.
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

The diagram shows one Mac because that is the common case, not because it is the limit. Windows
serves **every paired Mac that is connected, concurrently** — each with its own connection, its own
control and audio queues, and its own view of status. What the extra Macs do not each get is a
session: the single `MicCaptureService` and `SessionStateMachine` on the left of the diagram are
per host, so one Mac streams at a time and the others are told the microphone is busy (§7.1,
`protocol/protocol-v1.md` §7).

### 3.1 Module boundaries

Three units hold the logic that is easy to get wrong. All three are pure — no I/O, no platform
APIs — and all three carry real unit tests:

- **`PcmNormalizer`** (Windows) — device mix format to 48 kHz / mono / s16le.
- **`SessionStateMachine`** (Windows) — session lifecycle as a pure transition function, including
  which connection holds the single session and therefore which `START`s are granted and which are
  refused as busy.
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
| `SessionStateMachine` | Session lifecycle and single-holder arbitration (pure); one instance per host | I/O |
| `PairedDeviceStore` | The paired-device list: per-device token, friendly name, paired-at; add, revoke, and verify a `HELLO` proof against every stored token | Sockets, sessions |
| `ControlConnection` | TLS, framing, priority send queue, heartbeat, auth — **one instance per connected Mac** | Audio semantics |
| `TrayApp` | Status UI, device picker, level meter, pairing display, paired-device list and session holder | Protocol details |

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

### 3.4 Mac audio-device configuration

**BlackHole does not need to be the Mac's selected system input device, and the recommended
configuration is that it is not.** Leave the system input on the real hardware microphone; let the
application that wants the remote microphone target BlackHole itself.

This is possible because the owner's primary application, Raycast, was observed targeting BlackHole
**explicitly, independent of the system default input** — it held `[BlackHole 2ch]` in its
input-device list while the system default was the OWC Thunderbolt 3 Audio Device
(`docs/superpowers/probes/2026-08-08-macos-demand-findings.md`, "Real applications, measured by the
owner"). An application that selects BlackHole by itself does not care what the system default is.

Three things follow, and they are the reason this is the recommendation rather than a footnote:

- **It removes both false-positive shapes that were actually observed.** Both attach to the *system
  default input*: `com.apple.Sound-Settings.extension` holds the default while the Sound pane is
  open, and `com.apple.WebKit.GPU` retains the default in its device list even while idle. With the
  default on real hardware, neither lands on BlackHole. See §5.1.
- **Applications that simply follow the system default get the real microphone** and never touch
  BlackHole at all, so they cannot start a session.
- **It shrinks the blast radius of a Windows outage.** With BlackHole permanently selected as the
  system input — the configuration this spec originally assumed — a sleeping or unreachable Windows
  host meant *every* macOS application that opened input got silence. Under this configuration only
  the applications that explicitly target BlackHole are affected; everything else keeps using the
  real microphone normally. This is what §5.5's notification policy is calibrated against.

Stated precisely: this is a **recommended configuration, not a guarantee**. It does not make false
positives impossible. An application that explicitly targets BlackHole will still register as
demand — that is the detection mechanism working as designed, not a defect. What the configuration
does is keep applications that merely follow the system default out of the picture entirely.

The agent must not change the system input device to achieve this, any more than it changes the
system output device (§6.4). The configuration is the user's, set once during setup; the menu bar
should surface the current system input device so a misconfiguration is visible rather than
mysterious.

Whether this configuration is *required* — i.e. whether BlackHole-as-default is actually unusable —
is **not established**. It was not measured with BlackHole as the default beyond what §5.1 records,
and the specific unknown there (does WebKit retain BlackHole when BlackHole is the default?) is
listed as open in §13 Q1.

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
| `START_NACK` | Win → Mac | Reason (`MIC_UNAVAILABLE`, or `SESSION_IN_USE` with the holder's friendly name in `holderName`) |
| `STOP` | Mac → Win | End the active session |
| `STOP_ACK` | Win → Mac | Session ended |
| `STATUS` | Win → Mac | Mic presence, active state, device label |
| `PING` / `PONG` | Both | Connection health |

`START` and `STOP` are idempotent **for the connection that holds the session**. A duplicate `START`
on that connection returns the current session info; a duplicate `STOP` while idle returns success.
This makes reconnect and retry safe.

Idempotency does not cross connections, and with several Macs paired that distinction carries the
whole multi-device design:

- A `START` from a Mac while a **different** Mac holds the session is not a duplicate. It is
  refused with `START_NACK{reason: SESSION_IN_USE, holderName}` — immediately, with no queueing and
  no preemption of the holder.
- A `STOP` from a Mac that does not hold the session ends nothing. It is answered with `STOP_ACK`
  and leaves the holder's audio uninterrupted. A session ID is not a capability.
- **A session ends when its control connection closes, not only on `STOP`.** A Mac that crashes,
  sleeps, or drops off the network releases the microphone the moment Windows sees the socket
  close — otherwise it would hold every other paired Mac off until the 45 s dead-peer timer
  (§4.3) expired. Dead-peer expiry releases it too; it is the backstop for a peer that vanished
  without a visible close, not the normal path.

The full wire contract lives in `protocol/protocol-v1.md`, written in Phase 0 — §5 for
`START_NACK`'s reasons and the `holderName` field, §6 for concurrent authenticated connections, §7
for the one-session rule and the release-on-close requirement.

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
mandatory conjunct alongside `Devices`. It was removed for a positive reason, not a negative one:

> `Devices` membership was correct in **every case observed** — the automated self-test's
> self-introspective, negative-control, cross-process and repeat-activation legs, and the owner's
> manual pass over three real processes (Raycast across 4+ activations of one long-lived process,
> `com.apple.Sound-Settings.extension`, and `com.apple.WebKit.GPU`, the last of these reporting a
> two-device list that the `contains BlackHole` predicate handled correctly). It is also correct
> **regardless of whether `IsRunningInput` is reliable**. A gate that needs only the property with
> an unblemished record, and that is unaffected by however the other property turns out to behave,
> is the safe gate. Adding `IsRunningInput` as a required conjunct buys nothing and imports a risk.

That is the whole justification, and it does not rest on any claim about how `IsRunningInput`
behaves in general. **Do not restate it as "the flag is broken past first activation."** That claim
is not supported, and one real application contradicts it.

What was actually observed about the flag, precisely:

- **In the probe's synthetic cycles**, which dispose the `AudioComponentInstance` and construct a
  brand-new one for every activation, `IsRunningInput` read `false` at the exact instant `Devices`
  membership was independently confirmed `true`, in both repeat-activation cases the committed
  self-test checks — self-introspectively re-opening BlackHole (leg 1's targeted cycle) and a
  genuinely separate helper process re-opening BlackHole after closing it (leg 4's cycle 2). That is
  a single sampled instant per case, not a claim about the duration of the disagreement; a stronger
  observation was made during investigation with throwaway scripts that are not committed, and the
  findings document treats it as investigation notes. Do **not** cite §6.3's cross-process cycle
  timings (543–1166 ms) as the duration of the disagreement either — those figures are dominated by
  helper fork/exec and `AudioUnit` setup, a window in which the flag is `false` trivially.
- **In Raycast**, a real, long-lived application (PID 759, confirmed by `ps` never to have restarted
  across any of the owner's runs), `IsRunningInput` read `yes` on **every** activation the owner
  observed, including the second, third and fourth activation of that same process.

So the synthetic result **does not generalise to Raycast**, and no general rule about the flag is
established by what was measured. What the Raycast result does support is the instance-reuse
hypothesis the findings document already records: that the sticky-`false` behaviour is scoped to
freshly created `AudioComponentInstance`s rather than to a process's activation history. It is
evidence for that hypothesis, not confirmation of it — one application, whose internal audio-client
shape was not inspected. **The controlled measurement that would settle it should still be Phase 3's
first check before relying on or ruling out `IsRunningInput` for anything: build one `AudioUnit`
instance, call `AudioOutputUnitStart`/`AudioOutputUnitStop` on that same instance twice with no
dispose-and-recreate in between, and observe whether `IsRunningInput` re-triggers `true` on the
second start.**

None of this changes the design. `IsRunningInput` may be read, logged and shown as a diagnostic —
the probe prints it alongside `Devices` membership for exactly that reason — but it must never be a
required conjunct for starting or stopping a session, because the gate does not need it and is
strictly safer without it.

The `Devices` predicate is the entire point. The target Mac has BlackHole, ManyCam, Microsoft Teams
Audio, Parallels Access Sound, and Squirrels Audio installed. Under process-level detection alone,
any of those going active would start the remote microphone. Device scoping is not an optimization
here; it is what makes the privacy claim true.

#### False positives, measured

The draft assumed process-level false positives were unavoidable (§1). Device scoping removes the
whole class of "an unrelated application opened *a* microphone." What it does not remove is a
process that carries **BlackHole specifically** in its input-device list without recording anything
the user would call recording. Two such shapes were observed on the target Mac — these are
measurements, not speculation, and they replace the guesswork this section previously contained:

| Process | Shape | When it is a false positive | Behaviour |
|---|---|---|---|
| `com.apple.Sound-Settings.extension` | Holds whatever device is the **system default input**, for as long as the System Settings Sound pane is open | BlackHole is the system default **and** the Sound pane is open | Persistent `demandCount = 1`. It showed `[BlackHole 2ch]` / `onTarget=YES` while BlackHole was the default and `[OWC Thunderbolt 3 Audio Device]` / `onTarget=-` after the default was changed. The process leaves the process list entirely when System Settings is closed. |
| `com.apple.WebKit.GPU` (Safari) | **Retains the system default device in its input-device list while idle** — `no / - / [OWC Thunderbolt 3 Audio Device]` with nothing recording | Unknown; see below | While capturing it showed `yes / YES / [OWC Thunderbolt 3 Audio Device, BlackHole 2ch]`, counted correctly. After the capture stopped, the process dropped off the list entirely — **BlackHole did not linger** and `demandCount` returned to 0. |

Both shapes attach to the **system default input**. That is why §3.4 recommends leaving the system
default on the real hardware microphone: with the default off BlackHole, neither process lands on
BlackHole at all. Raycast is unaffected by that configuration because it targets BlackHole
explicitly.

Three consequences for the implementation:

- **The Sound Settings case is not a debounce problem.** While the pane is open the condition does
  not clear on its own, so `demandCount` sits at 1 indefinitely. No amount of debouncing helps; only
  the §3.4 configuration (or closing the pane) does. This is worth surfacing in diagnostics — the
  menu bar already shows the current demand process count (§11), which makes a stuck count
  attributable rather than mysterious.
- **Multi-device lists are normal and must be handled as such.** WebKit reported two devices at
  once. The predicate is `contains(BlackHole)`, not `== [BlackHole]`, and that is load-bearing
  rather than incidental.
- **An idle process may still carry a device.** Raycast shows `[]` when idle; WebKit shows the
  default. Both are legitimate. The observer must not assume that presence in the process list
  implies recording, nor that a non-empty device list implies recording — only that BlackHole's
  presence in the input-scope list is what the design has chosen to treat as demand.

**Not tested, and design-relevant:** whether `com.apple.WebKit.GPU` would retain **BlackHole** in
that idle device list if BlackHole were the system default input. The device it was observed
retaining was the default at the time (OWC Thunderbolt 3 Audio Device), so the observation says
nothing about the BlackHole-as-default case — which is exactly the configuration this spec
originally assumed. If it does retain it, Safari merely being open would hold the demand predicate
on. This is unmeasured and must not be assumed either way; it is tracked in §13 Q1 and in the
findings document's "Requires the owner."

Also untested against this mechanism, in any configuration: macOS Dictation, Chrome/Chromium, the
ChatGPT desktop app, Zoom and Teams (§13 Q1).

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
**500–2000 ms**. It exists because applications that tear down and immediately recreate an input
stream would otherwise produce a stop/start pair on every such cycle. That teardown-and-recreate
pattern is an assumption inherited from the draft and has **not** been measured here: in the Phase 0
pass, each Raycast release cleared cleanly with no observed re-appearance, and nothing lingered. The
debounce is retained as cheap insurance, and Phase 3 should measure whether it fires at all. Note
that it is no defence against the Sound Settings false positive described in §5.1, which is
persistent rather than transient.

**`START_NACK{SESSION_IN_USE}` takes the same `STARTING → DEGRADED` edge as any other `START_NACK`,
but it is not the same event to the user.** The transition is deliberately unchanged — the Mac has
demand it cannot satisfy, it is rendering silence, and §5.5's notification policy (alert on
`DEGRADED` while demand is active) is exactly right for it. What differs is the message: this is
"another Mac is using the microphone", named with `holderName` when the refusal carried one and
worded generically when it did not, rather than a fault the user is expected to fix on this machine.
Recovery is also ordinary rather than special: nothing pushes "the microphone is free now", so the
Mac leaves `DEGRADED` the way it does after any other refusal — the next time demand is present and
it retries `START`. Do not build a waiting queue, a polling loop faster than the demand signal, or
any form of automatic preemption of the other Mac.

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
the user is speaking into nothing and needs to know immediately.

It deliberately does not fire when the connection drops at idle. Windows sleeping overnight is
normal, and an alert for it would train the user to ignore the alert that matters.

**The recommended device configuration (§3.4) makes this policy less risky than it was.** This
policy was written against the assumption that BlackHole was permanently selected as the Mac's
system input device, under which an unreachable Windows host meant every macOS application that
opened input got silence — a large blast radius for a failure the user is not told about until they
happen to be recording. With the system input left on the real hardware microphone, only the
applications that explicitly target BlackHole are affected by a Windows outage; everything else
keeps using the real microphone normally and is not degraded at all.

So the silent-at-idle rule now costs less: the failure it stays quiet about is scoped to the remote
path, not to microphone input on the Mac as a whole. The policy itself is unchanged — alert on
`DEGRADED` with demand active, stay quiet at idle — but the reason it is acceptable is now the
narrower blast radius rather than a judgement that the user will tolerate the broader one. Two
consequences:

- **Do not add an idle-time alert to compensate for the broad failure mode.** It no longer exists in
  the recommended configuration.
- **If the user does select BlackHole as the system input**, the broad failure mode returns. The
  menu bar shows the current system input device (§3.4) precisely so that state is visible; whether
  that configuration warrants a louder notification policy is a Phase 3 decision, and it is not
  specified here because it has not been measured.

---

## 6. Audio path

### 6.1 Windows capture

`DeviceManager` persists the MMDevice endpoint ID rather than the friendly name. On `START` it
verifies presence; if the device is absent, Windows replies `START_NACK{reason: MIC_UNAVAILABLE}`
and the Mac enters `DEGRADED`. Measured on the owner's Windows host, the target device is the
**Samson Meteorite Mic**, friendly name `Microphone (Samson Meteorite Mic)`, endpoint ID
`{0.0.1.00000000}.{dcea823c-c06f-40bf-8f35-9de9fb96acfd}` — see
`docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`.

Capture opens in **WASAPI shared mode**. Exclusive mode is prohibited — it would take the microphone
away from Windows applications, defeating the simultaneous-use goal.

`PcmNormalizer` converts the shared mix format to 48 kHz / mono / signed 16-bit little-endian:
float32 to int16, resampling only when the mix format is not already 48 kHz, and downmixing to
mono. Measured on this device (same source), the shared mix format is **48,000 Hz, 32-bit,
2 channels, encoding=Extensible**: the rate already matches the wire format (§6.2), so the resample
step does not fire on this hardware — this device's common path carries no rate conversion and no
resampling dependency, though the conditional stays in the design because a different microphone
could present a different rate. The float-to-int16 conversion is confirmed rather than assumed.
Channel handling is configurable — **`mix` (default) | `left` | `right`**. A mono capsule presented
as dual-mono averages correctly, but a microphone that places signal only on the left channel loses
6 dB under averaging. This is not a hypothetical for this project: the Meteorite is a mono condenser
microphone, but its shared mix format is 2 channels, so the downmix path executes on every frame
from day one — and which mode is correct is not yet known, because nothing measured so far
distinguishes dual-mono signal from signal placed on only one channel. Phase 2 must determine the
Meteorite's actual channel layout before choosing the default mode (§12); the tray input level meter
above is the mechanism for catching a wrong default, and the symptom of getting it wrong is "the Mac
sounds quiet" with no error anywhere, which is why it is worth settling deliberately rather than
discovering.

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
| Input demand appears → `Devices` membership confirmed | ~5 ms | **Measured** — Task 10 macOS probe, targeted lookup via `kAudioHardwarePropertyTranslatePIDToProcessObject`, self-introspection on the target Mac (macOS 26.6.1) |
| Demand detected → `START` sent (warm TLS connection) | 1–5 ms | Estimate |
| LAN transit | 2–15 ms | Estimate |
| WASAPI shared open and start | **78.5–93.4 ms** (p50–p95); **114.1 ms cold** | **Measured** — Windows probe, 20 cycles, **Samson Meteorite Mic** on the owner's Windows host, `net10.0-windows` / NAudio 2.2.1. See `docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md` |
| First 20 ms frame captured | 20 ms | Fixed by frame duration |
| Transit to Mac | 2–10 ms | Estimate |
| Jitter buffer prefill | 60 ms | Estimate — set by measurement in Phase 2 |
| **Total, typical** | **~168–208 ms** | p50 open at the low corner, p95 open at the high corner |
| **Total, cold start** | **~204–229 ms** | 114.1 ms cold open at both corners |

The totals are recomputed from the rows above, not carried over from the previous revision:

- **Typical, low corner** (every stage at its low end, p50 open):
  5 + 1 + 2 + 78.5 + 20 + 2 + 60 = **168.5 ms**
- **Typical, high corner** (every stage at its high end, p95 open):
  5 + 5 + 15 + 93.4 + 20 + 10 + 60 = **208.4 ms**
- **Cold start, low corner:** 5 + 1 + 2 + 114.1 + 20 + 2 + 60 = **204.1 ms**
- **Cold start, high corner:** 5 + 5 + 15 + 114.1 + 20 + 10 + 60 = **229.1 ms**

(The demand-detection row is quoted as ~5 ms; an earlier revision's totals treated it as a 4–6 ms
band, which is why those totals ended in 9 and 6. The ±1 ms is measurement noise and does not
change any conclusion below.)

**Against the 300 ms p95 target: it still holds.** The realistic worst case in this table is the
cold-start high corner at **229.1 ms**, leaving **~71 ms of headroom** (24% of the budget). The
typical high corner is **208.4 ms**, leaving **~92 ms** (31%). Neither figure breaches the target.
But the margin is materially thinner than the previous, unmeasured budget implied: the old total
topped out at ~196 ms, and the cold case is now **33 ms worse** than that. The jitter-buffer
prefill (60 ms, still an estimate) and LAN transit are now the only remaining knobs of comparable
size, and the prefill figure is set by measurement in Phase 2 — if that measurement pushes prefill
toward the 120 ms top of its adaptive range, the cold-start case would reach ~289 ms and the
headroom would be effectively gone. That interaction is a Phase 2 watch item, not a Phase 0 one.

**The cold-start case is not an edge case here; it is the design's normal case.** Capture is closed
whenever macOS has no input demand, so the first activation after any idle period pays the cold
open. The probe measured cold at 114.1 ms and, notably, that was also the *maximum* of its twenty
baseline cycles — no warm cycle was slower than the cold one.

The demand-detection figure is the targeted-lookup measurement from
`docs/superpowers/probes/2026-08-08-macos-demand-findings.md` (leg 1: **5 ms** to detect appearance,
**3 ms** to detect clearing). Two other numbers from that probe are deliberately **not** used here:
the full-sweep figure (**58 ms** to detect appearance and 58 ms to detect clearing, enumerating all
40 process objects present on the test machine during that run — the owner's later pass saw 40–42
depending on what was running) is roughly 90% enumeration overhead rather than Core Audio
propagation, and the cross-process figures (leg 4: **543 ms** and **1166 ms**) are dominated by
helper-process spawn and `AudioUnit` setup, not steady-state detection latency for an
already-running application. Neither characterizes what a running demand observer actually
experiences once its listeners are registered.

All of these are synthetic-probe figures. The owner's real-application pass recorded **state, not
timing** — no appear or clear latency was measured for Raycast, the Sound Settings extension, or
WebKit — so there is still no measurement of how quickly a real application's demand becomes
visible. The first row of the table remains a synthetic self-introspection figure, and should be
re-measured against a real application in Phase 3.

Every figure in this paragraph is quoted from the run committed in that findings document. These
are wall-clock measurements on a live machine and they vary run to run — earlier drafts of this
section quoted 4–6 ms, ~40–60 ms and 575–1188 ms from a different run, which is the same result to
within measurement noise but does not match anything a reader can find in the repository. Quote the
committed run; if you re-measure, replace the figures and say which run they come from.

The WASAPI shared-mode open figure is now **measured**, replacing the original 20–80 ms planning
estimate. The owner built and ran `probes/windows-wasapi-latency/` on the real Windows host: 20
cycles against a **Samson Meteorite Mic**, built with `dotnet build --no-incremental` (0 warnings,
0 errors) targeting `net10.0-windows` with **NAudio 2.2.1**. Baseline, with nothing else holding
the microphone: 20/20 succeeded, 0 conflicts, cold 114.1 ms, min 76.8 ms, p50 78.5 ms, p95 93.4 ms,
max 114.1 ms. Full detail, including what remains unrecorded, is in
`docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`.

**The assumption was optimistic.** p50 (78.5 ms) landed at the very top of the assumed 20–80 ms
band; p95 (93.4 ms) and cold (114.1 ms) fell outside it by 13.4 ms and 34.1 ms. Even the fastest of
twenty opens (76.8 ms) was above the assumed midpoint. The assumed band's lower half never occurred.

**Scope of that measurement, stated at its real width:** one microphone, one driver, one Windows
machine, 20 cycles. It does not characterize other USB controllers, drivers, microphone models, or
Windows builds, and 20 samples cannot say anything about a rare long tail. Phase 2 measures the real
end-to-end figure with the actual agent; this row is the open stage only.

The same probe run answered the co-access question, which was a functional go/no-go for the whole
design: with **Windows Voice Typing (Win+H)** actively using the same microphone, the probe still
opened it 20/20 times with **0 conflicts**, and Voice Typing kept working throughout. §6.1's
shared-mode requirement is therefore evidenced rather than assumed, on this one combination.

Worth knowing, and slightly counterintuitive: the concurrent run was **faster** than the baseline on
every statistic (p50 62.6 vs 78.5 ms, p95 77.7 vs 93.4 ms, cold 89.0 vs 114.1 ms). When another
client already holds the endpoint in shared mode, the Windows audio engine is already running, so
opening an additional shared stream joins a live engine instead of spinning one up cold. **The
practical consequence is the one that matters for this budget: the worst case for activation
latency is an idle machine with nothing else using the microphone — which is exactly the state this
product creates by design.** The table above is therefore built on the baseline figures, not the
friendlier concurrent ones.

The single largest contributor to the remaining headroom is the warm TLS connection — under the
draft's two-connection design, a handshake would sit directly on this path.

**Accepted limitation, stated plainly:** because capture is closed at idle by design, there is no
pre-roll. Audio spoken before `START` is unrecoverable. No tuning removes this; it is the direct
cost of the zero-idle-bytes requirement. The defenses are minimizing activation latency and the
fact that applications normally open input before the user begins speaking. Acceptance is measured
empirically (§9), not assumed.

**That limitation is now tighter than this spec previously implied, and the criterion is not being
softened to accommodate it.** The open stage costs 78.5–114.1 ms rather than the assumed 20–80 ms:
about **29 ms more at p50** than the assumed band's midpoint, **13 ms more at p95** and **34 ms more
cold** than its ceiling. That is that much additional unrecoverable audio at the front of every
activation, and there is no pre-roll to absorb it. The §9 criterion (at least 95 of 100 activations
losing no complete first word) stands exactly as written; it is simply harder to hit than the old
budget suggested, and the
probability of failing it is higher than it was when the budget was written. If Phase 2 measurement
shows the criterion failing, the response is a design change — a small pre-roll would contradict the
zero-idle-bytes requirement, so the realistic levers are reducing the jitter-buffer prefill or
accepting a documented limitation — not relaxing the number.

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
DPAPI-protected. **One certificate serves the host, for every paired Mac** — pairing another Mac
never regenerates it, because doing so would break the pins of the Macs already paired.

**Windows keeps a list of paired devices, one entry per Mac, and each entry has its own token.**
Pairing a Mac generates a fresh random 256-bit token for that device and records it alongside a
friendly name and the paired-at timestamp. The tray displays that device's pairing string; the user
enters the host address and that string on the Mac once. At that moment the Mac pins the server
certificate fingerprint and stores its own token and the fingerprint in the Keychain.

Three properties of that list are requirements, not implementation latitude:

- **Fresh token per device.** Two paired Macs never share a token, and one is never derived from
  another. Re-pairing a device issues it a new token and leaves the other entries alone.
- **Individually revocable.** Removing one device's entry must not disturb any other device: the
  rest keep connecting with no user action, no re-pairing, and no new pairing strings. Revoking a
  device must also drop its live connection and release its session if it held one, so revocation
  takes effect now rather than at that device's next reconnect.
- **Tokens are stored with the same protection as the certificate private key.** A list of 256-bit
  keys in the clear is the same mistake as one key in the clear.

The pairing string's exact encoding — unchanged by any of this; it is 32 bytes of secret and
carries no device identifier — and the certificate's required profile, both of which two
implementers would otherwise each invent differently, are specified in `protocol/protocol-v1.md`
§11. Implement against that section, not against this paragraph.

### 7.2 Authentication

On each connection:

1. Windows sends `GREETING{serverId, nonce}`.
2. The Mac replies `HELLO{version, clientId, mac: HMAC-SHA256(token, nonce)}`.
3. Windows verifies the proof **against each stored token in turn**; the entry that matches is the
   device, and Windows replies `HELLO_ACK`. No match is an authentication failure and the
   connection is closed.

The token itself never crosses the wire, and the nonce makes the proof replay-resistant.

**Trial verification is the whole identification mechanism, and there is no lookup by identifier.**
`HELLO` arrives before anything has been verified, so **`clientId` is a display label and is
explicitly untrusted**: it must never be used to choose which token to check, to grant or scope
anything, or to name the device anywhere a user might act on the name. Any name Windows shows for a
connected Mac comes from the paired-device list entry whose token verified the proof. This is
called out because `clientId` is precisely the field an implementer reaches for once several Macs
are paired and something has to tell them apart — and it is attacker-controlled. See
`protocol/protocol-v1.md` §5 (`HELLO`) and §6 step 3.

Failed authentication is rate-limited to 5 attempts followed by a 30 s lockout — see
`protocol/protocol-v1.md` §11.4 for what counts as an attempt (one connection is one attempt, no
matter how many stored tokens were tried against it) and why the limit is not optional.

### 7.3 Rules

- The listener binds to private interfaces only, with a Windows Firewall rule scoped to the Private
  profile. The agent is never exposed to the public Internet.
- **A certificate fingerprint mismatch is a hard stop** — no auto-retry, no silent re-pair, a
  prominent warning, and re-pairing requires explicit user action. This is the one failure that can
  indicate an active attacker, and silently healing it would defeat the entire purpose of pinning.
- **A device is whichever paired token verified its proof — nothing else.** No field a peer sends
  before authentication (`clientId` above all) may select a token, identify a device, or grant
  access. A device is authorised only for what any paired device may do; there are no per-device
  privileges to escalate to, and the session is taken first-come rather than by rank.
- Audio payload is never logged or persisted. Logs contain lifecycle events and counters only.

---

## 8. Failure handling

| Failure | Behavior |
|---|---|
| Windows agent unreachable | Mac renders silence into BlackHole, enters `DEGRADED`, reconnects with backoff. Notification only if demand was active (§5.5). Under the §3.4 configuration this affects only applications that explicitly target BlackHole; applications on the system default input are unaffected. |
| USB mic unplugged while idle | Windows sends `STATUS{micPresent: false}`. Mac stays connected; activation is blocked with a clear reason. |
| USB mic unplugged mid-session | Windows stops capture and sends `STATUS`. Mac enters `DEGRADED` and notifies. On replug, auto-restarts if demand is still active. |
| Network drops mid-session | Mac renders silence, reconnects, reissues `START` if demand persists. On the Windows side the closed connection ends its session immediately — capture stops and the microphone is available to another paired Mac at once, not after the 45 s dead-peer timer. |
| Session holder crashes, sleeps, or is force-quit mid-session | Same as above from Windows' side: **the session ends when its control connection closes**, so capture stops and the microphone is released the moment the socket goes. No `STOP` is needed or expected. If the peer vanishes without a visible close, the 45 s dead-peer timer (§4.3) releases it as a backstop. |
| A second Mac requests the microphone while another holds it | Windows answers `START_NACK{SESSION_IN_USE, holderName}`. Nobody is disconnected, the holder's session is untouched, and the requesting Mac enters `DEGRADED` with a message naming the holder (§5.2). It retries only when its own demand next asks. |
| A paired device is revoked while connected | Windows drops that device's connection and releases its session if it held one. Every other paired Mac is unaffected — no re-pairing, no new pairing string, no interruption. |
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
- [ ] Starting voice input in **Raycast** (the primary application) activates the remote stream
      automatically, with no button press.
- [ ] Stopping Raycast voice input returns the system to idle automatically.
- [ ] The two above hold on Raycast's **second and later** activations without restarting Raycast.
- [ ] With the Mac's system input device set to the **real hardware microphone** and BlackHole not
      selected as the system input (§3.4): opening System Settings → Sound, and separately opening
      Safari, produce **zero** `START` messages.
- [ ] Windows applications can use the physical USB microphone while the Mac is receiving it.
      *Strongly evidenced already, not yet closed:* the Phase 0 Windows probe opened the microphone
      20/20 times with **0 conflicts** while **Windows Voice Typing** was actively using it, and
      Voice Typing kept working throughout — on one microphone (Samson Meteorite), one driver, one
      machine, one concurrent application. This criterion still has to be met end to end in Phase 2
      by the real agent, and against applications other than Voice Typing.
- [ ] Across 100 repeated activations of the primary application, **at least 95 lose no complete
      first word**. **This got harder, and the number is not being relaxed.** The measured WASAPI
      open (78.5 ms p50 / 114.1 ms cold, §6.3) is ~29 ms slower at p50 than the midpoint of the
      estimate this criterion was written against, and 34 ms slower cold than its ceiling — with no
      pre-roll by design, that is all lost audio. Budget extra Phase 2 time for it, and
      treat a failure here as a design question, not as grounds to move the threshold.
- [ ] `START`-to-first-playable-frame latency is **below 300 ms at p95** on the home LAN. The §6.3
      budget now predicts ~208 ms typical and ~229 ms cold from measured and estimated stages, so
      the expected headroom is ~70–92 ms rather than the ~100+ ms the pre-measurement budget implied.
- [ ] Opening microphone input in ManyCam, Teams, or another non-BlackHole virtual device produces
      **zero** `START` messages.
- [ ] *Secondary, untested as of Phase 0:* macOS Dictation, Chrome/Chromium, the ChatGPT desktop
      app, Zoom and Teams each activate and release correctly, or are documented as needing the
      force-on hold (§5.4). None of these has been observed against this mechanism.
- [ ] The kill switch guarantees zero bytes even with an application actively requesting input.
- [ ] The force-on hold expires automatically at its configured duration.
- [ ] A 30-minute continuous session completes with no drift-induced underruns.
- [ ] Mac and Windows sleep/wake recover without reconfiguration.
- [ ] USB microphone unplug and replug recovers without restarting either application.
- [ ] A tampered or mismatched certificate fingerprint blocks the connection and warns the user.
- [ ] **Two Macs paired to one Windows host, each with its own pairing string, are connected at the
      same time and both show as connected.** Neither disconnects the other, and each authenticates
      with only its own token.
- [ ] **With one Mac streaming, the other's `START` is refused with `SESSION_IN_USE` naming the
      holder,** the streaming Mac's audio is uninterrupted, and the refused Mac receives zero audio
      bytes.
- [ ] **Killing the streaming Mac's agent without a `STOP` frees the microphone immediately** — the
      second Mac's next `START` succeeds in well under the 45 s dead-peer window, and Windows'
      microphone-in-use indicator goes out.
- [ ] **Revoking one paired device leaves the other working** with no re-pairing, and the revoked
      device can no longer authenticate.
- [ ] No microphone PCM is written to disk or to any application log.

---

## 10. Test matrix

| Scenario | Expected | Measure | Priority |
|---|---|---|---|
| **Raycast voice input start/stop (primary application)** | Automatic START/STOP | Activation and stop latency | **P0** |
| **Raycast repeat activations, same process** | Every activation detected | Missed activations = 0 | **P0** |
| **System Settings Sound pane open, real mic as system input** | No START sent | False-start count = 0 | **P0** |
| **Safari open and idle, real mic as system input** | No START sent | False-start count = 0 | **P0** |
| Safari/WebKit idle **with BlackHole as system input** | Unknown — measure before assuming (§13 Q1) | Does BlackHole appear in its idle device list? | P1 |
| Mac Dictation start/stop (secondary, untested) | Automatic START/STOP, or documented force-on fallback | Activation and stop latency | P1 |
| ChatGPT / browser voice input (untested) | Automatic stream | Audio accepted | P1 |
| Windows + Mac simultaneous capture | Both receive speech | No WASAPI conflict | P0 |
| Windows + Mac simultaneous capture, **applications other than Voice Typing** (Teams, Zoom, browser `getUserMedia`, OBS) | Both receive speech | No WASAPI conflict | P0 — the Phase 0 probe covered Voice Typing only (§13 Q2) |
| 10-minute idle | No PCM transport | Byte counter = 0 | P0 |
| **ManyCam/Teams input opened** | **No START sent** | **False-start count = 0** | **P0** |
| **Kill switch engaged, app requests input** | **No START sent** | **Byte counter = 0** | **P0** |
| **Two paired Macs connected simultaneously** | Both authenticated, neither disconnects the other | Unexpected disconnects = 0 | **P0** |
| **Second Mac requests while first is streaming** | `START_NACK{SESSION_IN_USE}` with holder name; first Mac's audio uninterrupted | Bytes received by second Mac = 0; gaps in first Mac's stream = 0 | **P0** |
| **Streaming Mac killed without `STOP`** | Windows releases the session on socket close; second Mac's `START` then succeeds | Time to microphone available (must be ≪ 45 s) | **P0** |
| Paired device revoked while connected | Connection dropped, session released; other device unaffected | Other device's interruptions = 0 | P1 |
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
  expiry, kill-switch entry from each state, and idempotent duplicate `START`/`STOP`. On the
  Windows side this unit also owns single-holder arbitration, so its tests must cover: `START` from
  a second connection while a session is active (refused, holder untouched), `STOP` from a
  non-holder (no effect), the holder's connection closing without a `STOP` (session released), and
  a subsequent `START` from another connection being granted a fresh session.
- **`PCMRingBuffer`** — SPSC correctness, wraparound, underrun zero-fill, and drift-correction
  insert/drop.

### 10.2 Protocol conformance harness

A test double that speaks the wire protocol on both sides, so the Windows and macOS agents can be
built and tested independently without the other machine present. Written in Phase 0, before either
implementation.

**It does not cover any of the multi-device behavior above, and a green run is no evidence about
it.** The mock Windows server holds exactly one token, never reads `clientId`, and gives every
connection its own independent session with its own audio loop — so an implementation that supports
one paired device, trusts `clientId` as an identity, streams to two Macs at once, and leaks sessions
past their connections passes the entire suite. Those behaviors need local tests on each platform;
`protocol/protocol-v1.md` §7 lists the specific ones to write.

---

## 11. Observability

Windows tray and Mac menu bar both show: Disconnected, Idle, Starting, Streaming, Degraded,
Disabled, and Held (force-on, with time remaining).

**The Windows tray additionally shows the paired-device list and who holds the microphone**, since
with several Macs paired "Streaming" alone no longer says enough:

- **Every paired device**, by friendly name, with its paired-at date and whether it is currently
  connected — and a way to revoke one. A device the user does not recognise in that list is the
  signal that matters most, and it is invisible if the list is not shown.
- **Which device holds the active session**, by friendly name, and for how long. "The microphone is
  in use" without a name is unactionable when the answer could be either of two machines.
- **Which devices are connected but idle.** These carry zero audio by design (§4.4), and showing
  them idle rather than not showing them at all is what makes that verifiable.

The Mac menu bar shows the reason it is not streaming when that reason is another device: the
holder's name from `START_NACK{SESSION_IN_USE}`, or generic wording when the refusal carried no
name.

Counters exposed in a diagnostics view:

- Activation latency histogram (`START` sent → first playable frame)
- Session count and duration
- **PCM bytes received today** — surfaced directly in the Mac menu, not buried in diagnostics
- Jitter buffer depth, underrun count, drift corrections applied
- Frames dropped at the send queue
- Reconnect count, authentication failures
- **Sessions refused as `SESSION_IN_USE`, and by which device** — a count that climbs steadily means
  two Macs are contending for the microphone often enough that the user should know
- **Current demand process count, and the bundle identifier of each process holding BlackHole** —
  not just the count. The Phase 0 pass found processes that legitimately carry BlackHole without the
  user thinking of themselves as recording (§5.1), and a bare count of 1 is unattributable while a
  named `com.apple.Sound-Settings.extension` explains itself.
- **The Mac's current system input device** — §3.4 recommends it *not* be BlackHole, and a
  configuration that drifts should be visible rather than inferred from symptoms.

Showing the daily byte total in the menu makes the central privacy guarantee something the user can
verify at a glance rather than take on trust.

---

## 12. Phased plan

**Phase 0 — Protocol and probes.** Write `protocol/protocol-v1.md` and the conformance harness.
Build two throwaway probes: (a) device-scoped demand detection on macOS 26.6.1, verifying that
`kAudioProcessPropertyDevices` correctly scopes demand to BlackHole for self-introspection, a
genuinely separate process, and repeat activations — done, and it also forced a correction to §5.1
(see §13 Q1). The owner has since run part of the per-application matrix by hand, covering Raycast
(the primary application), the System Settings Sound extension and Safari/WebKit; that pass produced
§3.4's device configuration, §5.1's measured false-positive analysis, and the requalification of the
`IsRunningInput` finding. Dictation, Chrome/Chromium, ChatGPT desktop and Zoom/Teams remain
untested. (b) measured WASAPI shared-mode open latency on the actual Windows host — **done**: the
owner built and ran the probe against a Samson Meteorite Mic (`net10.0-windows`, NAudio 2.2.1), and
it both produced a real open-latency figure (78.5 ms p50, 93.4 ms p95, 114.1 ms cold, forcing the
§6.3 revision) and confirmed shared-mode co-access with Windows Voice Typing at 20/20 opens and 0
conflicts (see §13 Q2). **Both major risks are retired before real code is written.** What the
Windows probe initially left behind was bookkeeping rather than risk: the exact MMDevice endpoint ID
string and the device's shared mix format were not captured from the probe's first output. Both have
since been supplied by the owner and are recorded in §6.1 and the findings document, along with the
design consequences the mix format carries (§6.1, §12 Phase 2).

**Phase 1 — Transport and security.** Single TLS channel, certificate generation, pairing, HMAC
auth, framing, priority send queue, heartbeat, reconnect. Both ends. No audio yet. Phase 1 also
carries the multi-device work, because it is all in the connection layer: the **paired-device list**
(per-device token, friendly name, paired-at, add and revoke), **trial verification** of a `HELLO`
proof against every stored token, **concurrent authenticated connections**, and the **single-holder
session arbiter** — `START_NACK{SESSION_IN_USE, holderName}`, `STOP` scoped to the holder, and
release of the session when its connection closes. The conformance harness covers none of it
(§10.2), so these need real tests on each platform rather than a green harness run.

**Phase 2 — Audio path.** Windows capture and normalization, Mac render to BlackHole, manual
START/STOP from the menu. Validate quality, measure latency, set the prefill figure, verify drift
correction. Three items are heavier here than the original plan assumed. Two are because of the
measured WASAPI open (§6.3): the **first-word-clipping criterion** (§9, 95 of 100) now has 15–35 ms
less slack than when it was written and needs real measurement time budgeted rather than a quick
check, and **setting the prefill figure** is no longer only a jitter/underrun trade — it is also the
main remaining lever on cold-start activation latency, so measure both effects before fixing it. The
third is because of the measured shared mix format (§6.1): the Samson Meteorite is a mono
microphone presented as 2 channels, so the stereo-to-mono downmix path runs on every frame, and
**which channel mode is correct for it — `mix` or one of the single-channel modes — is not yet known
and must be determined before the default is chosen**, using the tray input level meter. Getting it
wrong is silent — a quieter Mac-side signal with no error anywhere — which is why it is worth
settling deliberately rather than discovering.

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
   see §5.1 for the correction this forced in the design itself, and for the requalification the
   owner's later real-application pass forced on the *explanation* of that correction.

   **Answered for the primary application.** The owner has since observed three real processes with
   `--watch`. **Raycast** — the owner's primary use case — was detected on each of 4+ activations of
   one long-lived process, cleared on every release with no lingering, and was seen targeting
   BlackHole explicitly while the system default input was a different device, which is what §3.4
   rests on. `com.apple.Sound-Settings.extension` and `com.apple.WebKit.GPU` were also observed, and
   produced §5.1's measured false-positive analysis. In every row observed, the `Devices` predicate
   was correct.

   **Still open, and not to be treated as settled:**
   - **macOS Dictation, Chrome/Chromium, the ChatGPT desktop app, Zoom and Teams have not been
     tested at all**, on a first session or a repeat one. Dictation in particular is a *secondary*
     case for this project, not the marquee one, and nothing measured says how it behaves.
   - Whether `com.apple.WebKit.GPU` retains **BlackHole** in its idle input-device list when
     BlackHole is the system default input. It was observed retaining the default (OWC) in that
     state, but not with BlackHole as the default — the configuration this spec originally assumed.
   - Appear and clear latencies for any real application; the owner's pass recorded state, not
     timing.
   - Everything above is a single machine, one sitting per application, with no reboot.

   If some application does not report reliably, the force-on hold is the fallback for that
   application, and the gap is documented rather than worked around. See "Requires the owner" in the
   findings document for the exact steps and the remaining matrix.

2. **What is the real WASAPI shared-mode open latency on this Windows host, cold and warm?**
   **Answered.** The owner built and ran `probes/windows-wasapi-latency/` on the real Windows host
   against a **Samson Meteorite Mic** (`net10.0-windows`, NAudio 2.2.1, `dotnet build
   --no-incremental`, 0 warnings / 0 errors). Baseline, 20 cycles, nothing else holding the
   microphone: 20/20 succeeded, 0 conflicts, **cold 114.1 ms, min 76.8 ms, p50 78.5 ms, p95
   93.4 ms, max 114.1 ms**. The spec's 20–80 ms assumption was optimistic: p50 landed at the top of
   that band and p95 and cold fell outside it. §6.3 now carries the measured figure and totals
   recomputed from it (~208 ms typical, ~229 ms cold), which still fits the 300 ms p95 target with
   ~70–92 ms of headroom. See
   `docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`.

   **The co-access go/no-go passed.** With **Windows Voice Typing (Win+H)** actively using the same
   microphone, the probe still opened it **20/20 times with 0 conflicts, 0 timeouts, 0 failures**,
   and Voice Typing remained operational throughout. Simultaneous Windows + Mac use of the one
   physical microphone — the premise of the whole design — is now evidenced rather than assumed. The
   concurrent run was also *faster* than the baseline on every statistic (p50 62.6 ms, p95 77.7 ms,
   cold 89.0 ms), because a shared-mode client that joins a running audio engine avoids engine
   start-up cost; see §6.3.

   **Scope this at its real width, and note what is still missing:**
   - One microphone (Samson Meteorite), one driver, one Windows machine, one concurrent application
     (Voice Typing), 20 cycles per run. This is **not** a general "WASAPI shared mode works" result.
     An application that opens the endpoint in *exclusive* mode would still lock the agent out, and
     nothing here tests that.
   - 20 samples give a usable p50 and a rough p95; they say nothing about a rare long tail.
   - The **exact MMDevice endpoint ID string**
     (`{0.0.1.00000000}.{dcea823c-c06f-40bf-8f35-9de9fb96acfd}`) and the **device's shared mix
     format** (48,000 Hz, 32-bit, 2 channels, encoding=Extensible) have since been supplied by the
     owner and are recorded in §6.1 and the findings document. The mix format means no resampling is
     needed for this device — its rate already matches the wire format — and confirms the
     float-to-int16 conversion; it also confirms the microphone presents as 2 channels despite being
     physically mono, so the stereo-to-mono downmix path is live on every frame. Which channel mode
     (`mix`/`left`/`right`) is actually correct for this hardware is not known and is now a Phase 2
     task (§12).
   - The Windows version and SDK version were not recorded either.

Resolved by Phase 2 measurement:

3. Does the primary application (Raycast) open its input stream far enough ahead of speech to avoid
   first-syllable clipping at the measured activation latency? The same question applies to macOS
   Dictation as a secondary case, and neither has been measured — the Phase 0 pass recorded demand
   state, not timing.
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
| **One TLS channel + BlackHole + device-scoped demand** | Fast to build; no driver; false positives scoped to processes that carry BlackHole specifically, and the two observed shapes are avoided by the §3.4 configuration; lowest activation latency | Idle guarantee is a code property, verified by counter rather than by a closed socket; false positives are reduced, not eliminated (§5.1) | **Selected** |

---

## 15. References

Verified while preparing this design; implementation anchors rather than strict dependencies.

- Apple — `AudioHardwareProcess`, `AudioHardwareSystem.processes`, Core Audio
- Microsoft — About WASAPI
- NAudio — WASAPI capture documentation
- BlackHole — https://github.com/ExistentialAudio/BlackHole

API availability and third-party library behavior change. Phase 0 verifies exact API availability
and the current NAudio capture type names against the deployment targets before Phase 1 begins.
