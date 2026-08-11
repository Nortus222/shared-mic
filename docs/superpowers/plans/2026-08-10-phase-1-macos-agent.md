# macOS Agent — Phase 1 (Transport and Security) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a macOS menu-bar agent that pairs with a Windows agent (or the Python `MockWindowsServer`), authenticates over pinned TLS 1.3, holds a healthy heartbeat-monitored session, and survives the connection dropping — with framing and control codecs that byte-match `protocol/vectors/*.json`.

**Architecture:** A pure protocol core (`Hex`, `FrameCodec`, `ControlCodec`, `AudioFrameCodec`, `PairingString`, `AuthProof`, `FrameBuffer`, `HeartbeatMonitor`, `ReconnectPolicy`, `SessionController`) with no I/O, tested exhaustively against the golden vectors; a thin `PinnedTLSTransport` shell over `Network.framework` that owns TLS and certificate-fingerprint pinning; a `ControlClient` that drives the `GREETING`/`HELLO`/`HELLO_ACK` handshake and the heartbeat; and a `ConnectionCoordinator` that wires those to a Keychain-backed `PairingStore` and a SwiftUI `MenuBarExtra` UI. Every network-facing task is developed and tested against the Phase 0 Python mock, so no Windows machine is required.

**Tech Stack:** Swift 5 language mode (Xcode 26.6 / Swift 6.3 toolchain), SwiftUI `MenuBarExtra`, `Network.framework` (`NWConnection` + `sec_protocol_options_set_verify_block`), CryptoKit (`SHA256`, `HMAC`), Security.framework (Keychain `kSecClassGenericPassword`), XCTest, an `.xcodeproj` generated deterministically by the `xcodeproj` Ruby gem, and the Phase 0 harness at `harness/.venv/bin/python`.

---

## Global Constraints

Every task implicitly includes all of these. Values are copied verbatim from `protocol/protocol-v1.md` and `docs/superpowers/specs/2026-08-08-shared-mic-design.md`.

**Scope of Phase 1 — transport and security only.**
No audio, no demand detection. There is no `PCMRingBuffer`, no `AudioRenderer`, no `AudioDemandObserver`, no `BlackHoleDevice`, and no Core Audio API is called anywhere in this phase. `AudioFrameCodec` (Task 4) is written because the golden vectors cover audio framing and Phase 2 needs the codec — but nothing in Phase 1 ever produces or consumes a real audio frame.

**Because demand detection does not exist yet, the menu bar carries manual Start/Stop commands.** These are temporary Phase 1 scaffolding whose only purpose is to drive a session by hand for testing. Phase 3 replaces them with `AudioDemandObserver`-driven automatic activation. Every place they appear must be commented as such.

**Explicitly out of scope, and must not be implemented in this phase:**
Core Audio / AUHAL / BlackHole rendering; demand detection; the kill switch; the force-on hold; launch-at-login; the diagnostics view; the level meter; mDNS/Bonjour discovery; sleep/wake handling; notification policy.

**Spec §3.4 must not be contradicted.** BlackHole is *not* to be the Mac's selected system input device, and the agent must never change the system input device. Phase 1 touches no audio device at all, so it satisfies this by construction — no task may add code that selects, sets, or prefers an input device.

**Transport (protocol-v1 §2):**
- One TCP connection carries control and audio, multiplexed. Default port **47800**.
- **TLS 1.3** wraps the connection immediately after the TCP handshake. Windows is the TLS server; macOS is the TLS client.
- Trust is a **pinned certificate fingerprint, not a certificate authority**. There is no CA anywhere in this design. The pinned value is the **lowercase hex SHA-256 of the server certificate's DER encoding**. **CA validation and hostname validation are deliberately disabled**; the pin is the only certificate check.
- **A fingerprint mismatch is a hard stop.** Close the connection immediately. No automatic retry, no silent re-pair, a prominent user-visible warning, and re-establishing trust requires an explicit user pairing action.
- The server certificate profile (protocol-v1 §11.3) is EC P-256, ECDSA-with-SHA-256, self-signed, one `dNSName` SAN byte-identical to the subject CN, 3,650-day validity, chain length 1.

**Envelope (protocol-v1 §3) — big-endian:**
```
uint8   type     // 1 = CONTROL, 2 = AUDIO
uint32  length   // payload byte count, BIG-ENDIAN
bytes   payload  // exactly `length` bytes
```
- Header is **5 bytes**. `length` counts only the payload.
- `type` MUST be `1` or `2`; any other value is a protocol violation and the receiver MUST **close the connection**, not resynchronize.
- **`length` MUST NOT exceed 1,048,576 bytes (1 MiB).** Above that is a protocol violation → close.
- Multiple envelopes are concatenated with no delimiter. A partial buffer yields "not yet", never a wrong answer.

**Audio payload (protocol-v1 §4) — big-endian header, little-endian PCM:**
```
uint32  sequence             // BIG-ENDIAN
uint64  captureTimestampUs   // BIG-ENDIAN
bytes   pcm                  // exactly 1,920 bytes of s16le PCM
```
- Audio header is **12 bytes**; an `AUDIO` envelope's `length` MUST be exactly **1,932**; total envelope **1,937 bytes**.
- **THE ENDIANNESS TRAP: the frame envelope and the audio header are big-endian; the 960 PCM samples inside are each little-endian (`s16le`).** Getting this wrong compiles, raises nothing, and produces byte-for-byte wrong output.
- A receiver MUST treat an `AUDIO` payload of any length other than 1,932 as a protocol violation and close — the reference Python decoder is deliberately more permissive here and this implementation must be stricter.
- Format, fixed, non-negotiable: 48,000 Hz, 1 channel, 16-bit signed, 20 ms frames, 960 samples, 1,920 PCM bytes, 50 fps.
- `sequence` starts at `0` per session and increments by 1. `captureTimestampUs` starts at `0` and increases by `20000` per frame.

**Control messages (protocol-v1 §5):** a `CONTROL` payload is a single UTF-8 JSON object with **no line breaks or padding — exactly the bytes `json.dumps(msg, sort_keys=True, separators=(",", ":"))` would produce**. Keys are sorted lexicographically, recursively. Every message carries `"v"` (integer, always `1`) and `"type"` (string). A message whose `"v"` is not `1` MUST cause the connection to close. The eleven types and their required fields:

| Type | Direction | Required fields beyond `v`/`type` |
|---|---|---|
| `GREETING` | Win → Mac | `serverId` (string), `nonce` (string, lowercase hex, 32 bytes / 64 chars) |
| `HELLO` | Mac → Win | `clientId` (string), `mac` (string, lowercase hex HMAC-SHA256, 64 chars) |
| `HELLO_ACK` | Win → Mac | `serverId` (string), `micPresent` (bool), `deviceLabel` (string) |
| `START` | Mac → Win | `requestId` (string), `preferredFormat` (object, always `{"sampleRate":48000,"channels":1,"sampleFormat":"s16le"}`) |
| `START_ACK` | Win → Mac | `requestId` (string), `sessionId` (string), `format` (object) |
| `START_NACK` | Win → Mac | `requestId` (string), `reason` (string), **and one OPTIONAL advisory field, `holderName` (string)** — the friendly name of the Mac that currently holds the session. Present only with `reason: "SESSION_IN_USE"`, and **may be absent even then**. |
| `STOP` | Mac → Win | `requestId` (string), `sessionId` (string) |
| `STOP_ACK` | Win → Mac | `requestId` (string), `sessionId` (string) |
| `STATUS` | Win → Mac | `micPresent` (bool), `active` (bool), `deviceLabel` (string) — **no `errors` field** |
| `PING` | Mac → Win | `seq` (integer) |
| `PONG` | Win → Mac | `seq` (integer) — MUST equal the `PING`'s `seq` |

`STATUS` is unsolicited. A receiver MUST NOT route it through the queue it uses to match replies to outstanding requests, or it will be silently lost when it lands mid-exchange.

**Handshake (protocol-v1 §6):** every new connection, immediately after the TLS handshake and before any `START`/`STOP`/`PING`/`STATUS`:
1. Windows sends `GREETING{serverId, nonce}`; `nonce` is freshly random per connection.
2. The Mac replies `HELLO{clientId, mac}` where **`mac = lowercase_hex(HMAC-SHA256(token, nonce))`**, `token` is the 256-bit pairing secret, and `nonce` is **the raw 32 bytes decoded from the hex** — the HMAC is over raw bytes, not over the hex string. **The token never crosses the wire.**
3. Windows verifies and replies `HELLO_ACK`, or closes without replying.
- Windows enforces a **5-second** deadline from TLS completion to a valid `HELLO`. The Mac mirrors it: if the handshake has not completed within 5 s, treat the connection as dead.

**Session lifecycle (protocol-v1 §7):** `START` and `STOP` are both idempotent. A duplicate `START` while active returns the **existing** `sessionId` and does not reset the sequence counter. A `STOP` while idle still returns `STOP_ACK`; its `sessionId` MAY be an empty string. `STOP` means "make sure no session is active on this connection", not "end specifically this session ID". **No `AUDIO` frame may exist outside an active session — an idle connection carries zero audio bytes.**

**This Mac is not the only client.** Several Macs may be paired with one Windows agent and connected at the same time; the Windows host has one microphone, so **at most one of them holds the session at a time**. Three consequences for this plan, and they are the whole of the multi-Mac work on this side:

1. **`START` can be refused because another Mac is using the microphone**, with `START_NACK{reason: "SESSION_IN_USE"}`. That is not an error and not a degraded connection: this Mac is still authenticated, still healthy, and still heartbeating. It just does not have the mic. It must be shown as "In use by ...", never as a generic failure.
2. **The advisory `holderName` name may be absent.** When it is, show `In use by another Mac` — never an empty name, a placeholder, or the raw reason string.
3. **Nothing tells this Mac when the mic frees up.** There is no queue and no push notification in version 1; Windows sends one `START_NACK` and that is the end of the exchange. The Mac stays in its "in use" state until the user tries Start again (which retries) or the connection changes. Phase 2's `STATUS` is where a proper "the mic is free" signal belongs; do not invent a message type for it here.

**Pairing does not change at all.** Each Mac gets its own 256-bit token from Windows and its own pairing string, in exactly the format §11.2 already specifies. Nothing in Tasks 6 or 7 needs to be different because the Windows side now holds a list instead of a single token — the Mac never sees the list.

**The Python mock cannot exercise any of point 1 or 2.** `MockWindowsServer` gives every connection its own `_session_id` and never sends `SESSION_IN_USE`, so an integration test against it will never reach the new state. Those paths are covered by the pure `SessionControllerTests` and `ControlCodecTests` (Tasks 3, 9) and by `AppModelTests` driving the controller directly (Task 14) — not by the mock.

**Timers (protocol-v1 §8) — all mandatory, none exercised by the harness:**

| Timer | Value | Effect on expiry |
|---|---|---|
| `START` response | **2 s** | Treat as a failed/dead peer; do not wait indefinitely |
| `STOP` response | **1 s** | Treat the session as ended locally regardless |
| `PING` interval | **15 s** | Mac sends `PING`; Windows replies `PONG` immediately |
| Peer dead | **45 s** without a `PONG` (three missed) | Declare the connection dead, close, begin reconnect |
| Pre-auth (`HELLO`) deadline | **5 s** | Close the connection |

**Reconnect (spec §4.3):** exponential backoff from **0.5 s** to a **30 s cap**, jittered. Reset on a successful authenticated connection. **Never** schedule a reconnect after a fingerprint mismatch.

**Pairing (protocol-v1 §11):**
- Token is **32 bytes / 256 bits** from a CSPRNG, generated by Windows.
- Pairing string: **base32, RFC 4648 alphabet (`A`–`Z` then `2`–`7`), uppercase, unpadded, hyphen-grouped in runs of 8**. 32 bytes → 52 characters + 6 hyphens = **58 characters**.
- Worked example: token `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f` → `AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ`.
- Decoding is tolerant: **uppercase first**, **delete every character not in `[A-Z2-7]`**, re-pad with `=` to a multiple of 8, base32-decode, then **the result MUST be exactly 32 bytes** or reject. **Do not add confusable-character mapping** (`0`→`O`, `1`→`I`/`L`) — that is a protocol version change.
- The Mac stores the token and the pinned fingerprint in the **Keychain**.

**Trust-on-first-use is confined to the pairing action.** The pairing string carries only the token. The fingerprint is captured on the single pairing connection and persisted **only after that connection's `HELLO_ACK` proves the token** — a certificate presented by a peer that cannot answer the HMAC challenge is never pinned. Every subsequent connection is strict-pinned.

**Never log or persist audio payload, private key material, the pairing token, or the pairing string.** Logs carry lifecycle events and counters only.

**Deployment target is macOS 14.4**, set now for consistency with the Phase 3 Core Audio requirement even though Phase 1 does not need it. Swift language version 5.

**Project regeneration.** `macos/SharedMic.xcodeproj` is generated from `macos/project.rb`, which globs `macos/SharedMic/**/*.swift` and `macos/SharedMicTests/**/*.swift` at generation time. **Any task that adds a `.swift` file must re-run `ruby macos/project.rb` before building, and commit the regenerated `project.pbxproj` with the sources.**

**Canonical commands** (run from the repository root):
```sh
ruby macos/project.rb
xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64'
xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/SomeTestCase
```
`xcodebuild` prints a large amount of unrelated `[Connection] Unable to get synchronousRemoteObjectProxy` noise from the SwiftUI test host; it is harmless. Append `2>&1 | grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)"` to read the result quickly.

**The Python mock is the peer.** Its interpreter is `harness/.venv/bin/python`; **there is no bare `python` on this machine** and the system `python3` has no `pytest`. The full server side of the protocol lives in `harness/sharedmic_protocol/server.py` (`MockWindowsServer`) with TLS from `harness/sharedmic_protocol/tls.py`.

**Networking stack decision: `Network.framework` (`NWConnection`), not `URLSession` or raw sockets.**
The deciding constraint is pinning with the CA path disabled. `sec_protocol_options_set_verify_block` **replaces** the default trust evaluation rather than running after it, so a self-signed certificate with no CA never has to pass a chain check that would reject it, and hostname validation never runs either — exactly what protocol-v1 §2 and §11.3 require. `URLSession` is HTTP-shaped and its `URLAuthenticationChallenge` hook still sits behind a `SecTrust` evaluation the caller has to override by constructing a `SecTrustResultType` by hand, and it has no clean bidirectional byte-stream mode for a persistent framed connection. Raw `Socket` + `SecureTransport` would mean hand-rolling TLS 1.3 lifecycle against a deprecated API. `NWConnection` additionally gives TLS 1.3 pinning via `sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)` in two lines.
**This has been verified, not assumed:** a Swift `NWConnection` client using the verify block above completed a TLS 1.3 handshake against `MockWindowsServer`'s certificate, pinned its SHA-256-of-DER fingerprint, and finished the `GREETING`/`HELLO`/`HELLO_ACK` exchange, on macOS 26.6.1 with Swift 6.3.3.

**One `Network.framework` trap this plan is built around:** on a rejected verify block, `NWConnection` does **not** enter `.failed`. It enters **`.waiting(-9808: bad certificate format)` and retries forever.** A hard stop therefore requires treating **any** `.waiting` as terminal — cancel the connection and report the error. The `-9808` code is also uninformative, so the transport must record *why* the verify block said no (out of band, in a lock-protected property) rather than trying to read it back out of the `NWError`.

---

## File Structure

**Created by this plan:**

| Path | Responsibility |
|---|---|
| `macos/project.rb` | Deterministic `.xcodeproj` generator (Ruby `xcodeproj` gem). Source of truth for the project; the `.xcodeproj` is a build artifact that is nonetheless committed. |
| `macos/.gitignore` | Ignores `xcuserdata/`, `DerivedData/`, `.DS_Store`. |
| `macos/SharedMic.xcodeproj/` | Generated. App target `SharedMic` + unit-test bundle `SharedMicTests` + shared scheme `SharedMic`. |
| `macos/SharedMic/Info.plist` | `LSUIElement = true` (menu-bar-only, no Dock icon), `LSMinimumSystemVersion = 14.4`. |
| `macos/SharedMic/Protocol/ProtocolConstants.swift` | `SharedMicProtocol` — every fixed value from protocol-v1 in one place. |
| `macos/SharedMic/Protocol/Hex.swift` | `Hex.encode`/`Hex.decode`, lowercase hex. |
| `macos/SharedMic/Protocol/ProtocolError.swift` | `ProtocolError` — every wire-level violation, all of which mean "close the connection". |
| `macos/SharedMic/Protocol/FrameCodec.swift` | `FrameType`, `DecodedFrame`, `FrameCodec` — the 5-byte big-endian envelope, incremental decode, 1 MiB ceiling. |
| `macos/SharedMic/Protocol/ControlMessage.swift` | `AudioFormat`, `ControlMessage` (11 cases) and its JSON-object mapping/validation. |
| `macos/SharedMic/Protocol/ControlCodec.swift` | Canonical sorted-key UTF-8 JSON encode/decode of `ControlMessage`. |
| `macos/SharedMic/Protocol/AudioFrameCodec.swift` | `AudioFrame`, big-endian 12-byte header, strict 1,932-byte payload, little-endian PCM sample accessors. **Written for the vectors and for Phase 2; unused at runtime in Phase 1.** |
| `macos/SharedMic/Protocol/FrameBuffer.swift` | Pure incremental byte accumulator that yields whole frames. |
| `macos/SharedMic/Security/Base32.swift` | RFC 4648 base32 encode (unpadded) / decode. |
| `macos/SharedMic/Security/PairingString.swift` | Pairing-string encode/decode, tolerant per §11.2. |
| `macos/SharedMic/Security/AuthProof.swift` | `HMAC-SHA256(token, nonce)` hex proof; SHA-256-of-DER fingerprint. |
| `macos/SharedMic/Security/PairingStore.swift` | `PairingRecord`, `PairingStore` protocol, `InMemoryPairingStore`, `KeychainPairingStore`. |
| `macos/SharedMic/Session/ReconnectPolicy.swift` | Pure jittered exponential backoff, 0.5 s → 30 s. |
| `macos/SharedMic/Session/HeartbeatMonitor.swift` | Pure `PING`/`PONG` sequencing and dead-peer detection against an injected clock. |
| `macos/SharedMic/Session/SessionController.swift` | Pure state machine: `AgentState`, `SessionEvent`, `SessionAction`. |
| `macos/SharedMic/Net/PinnedTLSTransport.swift` | `MessageTransport` protocol; `NWConnection` + TLS 1.3 + fingerprint pinning + hard stop. |
| `macos/SharedMic/Net/ControlClient.swift` | Handshake, framed send/receive, heartbeat driving, message dispatch. |
| `macos/SharedMic/Net/ConnectionCoordinator.swift` | Wires store + transport + client + controller + backoff; owns the timers. |
| `macos/SharedMic/App/AppModel.swift` | `@MainActor ObservableObject` bridging `ConnectionCoordinator` to SwiftUI. |
| `macos/SharedMic/App/MenuBarView.swift` | Menu contents: state, pairing field, **temporary** Start/Stop, quit. |
| `macos/SharedMic/App/SharedMicApp.swift` | `@main`, `MenuBarExtra` scene. |
| `macos/SharedMicTests/Support/mock_windows_server.py` | Test driver that stands up `MockWindowsServer` over TLS and speaks a one-line-JSON control channel on stdio. |
| `macos/SharedMicTests/Support/MockWindowsServerProcess.swift` | Swift wrapper that launches the driver, parses its handshake line, and can drive mic-unplug and connection-drop. |
| `macos/SharedMicTests/Support/RepositoryPaths.swift` | Locates the repository root from `#filePath`. |
| `macos/SharedMicTests/*Tests.swift` | One test file per component, named in each task. |

**Never modified by this plan:** `protocol/`, `harness/`, `docs/superpowers/specs/`, `probes/`, and `docs/superpowers/plans/2026-08-10-phase-1-windows-agent.md`.

---

### Task 1: Project skeleton, protocol constants, and hex

**Files:**
- Create: `macos/project.rb`, `macos/.gitignore`, `macos/SharedMic/Info.plist`, `macos/SharedMic/App/SharedMicApp.swift`, `macos/SharedMic/Protocol/ProtocolConstants.swift`, `macos/SharedMic/Protocol/Hex.swift`
- Test: `macos/SharedMicTests/ProtocolConstantsTests.swift`, `macos/SharedMicTests/HexTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SharedMicProtocol` with static constants (all `public`): `version: Int`, `defaultPort: UInt16`, `envelopeHeaderSize: Int`, `maxPayloadBytes: Int`, `audioHeaderSize: Int`, `audioPCMBytes: Int`, `audioPayloadSize: Int`, `audioEnvelopeSize: Int`, `sampleRate: Int`, `channels: Int`, `sampleFormat: String`, `samplesPerFrame: Int`, `frameDurationUs: UInt64`, `framesPerSecond: Int`, `startTimeout: TimeInterval`, `stopTimeout: TimeInterval`, `pingInterval: TimeInterval`, `peerDeadTimeout: TimeInterval`, `helloDeadline: TimeInterval`, `reconnectInitialDelay: TimeInterval`, `reconnectMaxDelay: TimeInterval`, `reconnectJitterFraction: Double`, `tokenBytes: Int`, `nonceBytes: Int`, `pairingGroupSize: Int`, `pairingStringLength: Int`
  - `enum Hex` with `static func encode(_ data: Data) -> String` and `static func decode(_ string: String) -> Data?`
  - A buildable, testable Xcode project and the two canonical commands.

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/ProtocolConstantsTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class ProtocolConstantsTests: XCTestCase {
    func testVersionAndPort() {
        XCTAssertEqual(SharedMicProtocol.version, 1)
        XCTAssertEqual(SharedMicProtocol.defaultPort, 47800)
    }

    func testEnvelopeConstants() {
        XCTAssertEqual(SharedMicProtocol.envelopeHeaderSize, 5)
        XCTAssertEqual(SharedMicProtocol.maxPayloadBytes, 1_048_576)
    }

    func testAudioFrameArithmeticMatchesTheSpecTable() {
        XCTAssertEqual(SharedMicProtocol.audioHeaderSize, 12)
        XCTAssertEqual(SharedMicProtocol.audioPCMBytes, 1_920)
        XCTAssertEqual(SharedMicProtocol.audioPayloadSize, 1_932)
        XCTAssertEqual(SharedMicProtocol.audioEnvelopeSize, 1_937)
        XCTAssertEqual(
            SharedMicProtocol.audioPayloadSize,
            SharedMicProtocol.audioHeaderSize + SharedMicProtocol.audioPCMBytes
        )
        XCTAssertEqual(
            SharedMicProtocol.audioEnvelopeSize,
            SharedMicProtocol.envelopeHeaderSize + SharedMicProtocol.audioPayloadSize
        )
    }

    func testAudioFormatConstants() {
        XCTAssertEqual(SharedMicProtocol.sampleRate, 48_000)
        XCTAssertEqual(SharedMicProtocol.channels, 1)
        XCTAssertEqual(SharedMicProtocol.sampleFormat, "s16le")
        XCTAssertEqual(SharedMicProtocol.samplesPerFrame, 960)
        XCTAssertEqual(SharedMicProtocol.framesPerSecond, 50)
        XCTAssertEqual(SharedMicProtocol.frameDurationUs, 20_000)
        XCTAssertEqual(SharedMicProtocol.samplesPerFrame * 2, SharedMicProtocol.audioPCMBytes)
        XCTAssertEqual(SharedMicProtocol.samplesPerFrame * SharedMicProtocol.framesPerSecond,
                       SharedMicProtocol.sampleRate)
    }

    func testTimerConstants() {
        XCTAssertEqual(SharedMicProtocol.startTimeout, 2.0)
        XCTAssertEqual(SharedMicProtocol.stopTimeout, 1.0)
        XCTAssertEqual(SharedMicProtocol.pingInterval, 15.0)
        XCTAssertEqual(SharedMicProtocol.peerDeadTimeout, 45.0)
        XCTAssertEqual(SharedMicProtocol.helloDeadline, 5.0)
    }

    func testReconnectAndPairingConstants() {
        XCTAssertEqual(SharedMicProtocol.reconnectInitialDelay, 0.5)
        XCTAssertEqual(SharedMicProtocol.reconnectMaxDelay, 30.0)
        XCTAssertEqual(SharedMicProtocol.tokenBytes, 32)
        XCTAssertEqual(SharedMicProtocol.nonceBytes, 32)
        XCTAssertEqual(SharedMicProtocol.pairingGroupSize, 8)
        XCTAssertEqual(SharedMicProtocol.pairingStringLength, 58)
    }
}
```

Create `macos/SharedMicTests/HexTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class HexTests: XCTestCase {
    func testEncodeIsLowercaseAndZeroPadded() {
        XCTAssertEqual(Hex.encode(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
        XCTAssertEqual(Hex.encode(Data()), "")
    }

    func testEncodeMatchesTheSpecWorkedExampleToken() {
        let token = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(
            Hex.encode(token),
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        )
    }

    func testDecodeRoundTrips() {
        let data = Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0x01])
        XCTAssertEqual(Hex.decode(Hex.encode(data)), data)
    }

    func testDecodeAcceptsUppercase() {
        XCTAssertEqual(Hex.decode("DEADBEEF"), Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testDecodeRejectsOddLengthAndNonHex() {
        XCTAssertNil(Hex.decode("abc"))
        XCTAssertNil(Hex.decode("zz"))
        XCTAssertNil(Hex.decode("00 11"))
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64'`
Expected: FAIL — `xcodebuild` errors with `does not exist` / `Unable to find a project`, because `macos/SharedMic.xcodeproj` has not been generated yet.

- [ ] **Step 3: Implement**

Create `macos/.gitignore`:

```gitignore
xcuserdata/
DerivedData/
build/
.DS_Store
```

Create `macos/SharedMic/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SharedMic</string>
  <key>CFBundleDisplayName</key><string>SharedMic</string>
  <key>CFBundleIdentifier</key><string>com.sharedmic.SharedMic</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>SharedMic</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string></string>
</dict>
</plist>
```

Create `macos/project.rb`:

```ruby
#!/usr/bin/env ruby
# Deterministic generator for macos/SharedMic.xcodeproj.
#
# The .xcodeproj is a build artifact that happens to be committed; THIS file is
# the source of truth. Re-run it after adding or removing any .swift file:
#
#   ruby macos/project.rb
#
# Requires the `xcodeproj` gem (already installed on this machine: 1.27.0).

require 'xcodeproj'
require 'fileutils'

ROOT = File.dirname(File.expand_path(__FILE__))
PROJECT_PATH = File.join(ROOT, 'SharedMic.xcodeproj')
DEPLOYMENT_TARGET = '14.4'
SWIFT_VERSION = '5.0'

FileUtils.rm_rf(PROJECT_PATH)
project = Xcodeproj::Project.new(PROJECT_PATH)

project.build_configurations.each do |config|
  config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  config.build_settings['SWIFT_VERSION'] = SWIFT_VERSION
  config.build_settings['ALWAYS_SEARCH_USER_PATHS'] = 'NO'
  config.build_settings['CLANG_ENABLE_OBJC_ARC'] = 'YES'
  config.build_settings['SDKROOT'] = 'macosx'
end

app = project.new_target(:application, 'SharedMic', :osx, DEPLOYMENT_TARGET)
tests = project.new_target(:unit_test_bundle, 'SharedMicTests', :osx, DEPLOYMENT_TARGET)

app_group = project.new_group('SharedMic', 'SharedMic')
test_group = project.new_group('SharedMicTests', 'SharedMicTests')

def add_swift_sources(group, target, directory)
  Dir.glob(File.join(directory, '**', '*.swift')).sort.each do |file|
    relative = file.sub(directory + '/', '')
    reference = group.new_reference(relative)
    target.add_file_references([reference])
  end
end

add_swift_sources(app_group, app, File.join(ROOT, 'SharedMic'))
add_swift_sources(test_group, tests, File.join(ROOT, 'SharedMicTests'))

app.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = 'SharedMic'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.sharedmic.SharedMic'
  settings['INFOPLIST_FILE'] = 'SharedMic/Info.plist'
  settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGN_IDENTITY'] = '-'
  settings['ENABLE_HARDENED_RUNTIME'] = 'YES'
  settings['COMBINE_HIDPI_IMAGES'] = 'YES'
  settings['SWIFT_VERSION'] = SWIFT_VERSION
  settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
end

tests.build_configurations.each do |config|
  settings = config.build_settings
  settings['PRODUCT_NAME'] = 'SharedMicTests'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.sharedmic.SharedMicTests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['CODE_SIGN_IDENTITY'] = '-'
  settings['SWIFT_VERSION'] = SWIFT_VERSION
  settings['MACOSX_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  settings['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/SharedMic.app/Contents/MacOS/SharedMic'
  settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
end

tests.add_dependency(app)
project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.add_test_target(tests)
scheme.set_launch_target(app)
scheme.save_as(PROJECT_PATH, 'SharedMic', true)

puts "generated #{PROJECT_PATH}"
```

Create `macos/SharedMic/Protocol/ProtocolConstants.swift`:

```swift
import Foundation

/// Every fixed value in protocol-v1.md, in one place.
///
/// Changing anything here is a protocol version change (protocol-v1 §1), not an
/// implementation decision.
public enum SharedMicProtocol {
    // §1 / §2
    public static let version: Int = 1
    public static let defaultPort: UInt16 = 47_800

    // §3 — envelope, big-endian
    public static let envelopeHeaderSize: Int = 5
    public static let maxPayloadBytes: Int = 1_048_576

    // §4 — audio payload. Header is big-endian; the PCM inside is little-endian.
    public static let audioHeaderSize: Int = 12
    public static let audioPCMBytes: Int = 1_920
    public static let audioPayloadSize: Int = 1_932
    public static let audioEnvelopeSize: Int = 1_937

    public static let sampleRate: Int = 48_000
    public static let channels: Int = 1
    public static let sampleFormat: String = "s16le"
    public static let samplesPerFrame: Int = 960
    public static let frameDurationUs: UInt64 = 20_000
    public static let framesPerSecond: Int = 50

    // §8 — timers
    public static let startTimeout: TimeInterval = 2.0
    public static let stopTimeout: TimeInterval = 1.0
    public static let pingInterval: TimeInterval = 15.0
    public static let peerDeadTimeout: TimeInterval = 45.0
    public static let helloDeadline: TimeInterval = 5.0

    // design spec §4.3 — reconnect
    public static let reconnectInitialDelay: TimeInterval = 0.5
    public static let reconnectMaxDelay: TimeInterval = 30.0
    public static let reconnectJitterFraction: Double = 0.2

    // §11 — pairing
    public static let tokenBytes: Int = 32
    public static let nonceBytes: Int = 32
    public static let pairingGroupSize: Int = 8
    public static let pairingStringLength: Int = 58
}
```

Create `macos/SharedMic/Protocol/Hex.swift`:

```swift
import Foundation

/// Lowercase hex, the only hex representation this protocol uses:
/// the `GREETING` nonce, the `HELLO` mac, and the pinned certificate
/// fingerprint are all lowercase hex (protocol-v1 §2, §5, §6).
public enum Hex {
    private static let digits: [Character] = Array("0123456789abcdef")

    public static func encode(_ data: Data) -> String {
        var output = String()
        output.reserveCapacity(data.count * 2)
        for byte in data {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return output
    }

    /// Returns nil for odd-length input or any character outside `[0-9a-fA-F]`.
    public static func decode(_ string: String) -> Data? {
        let characters = Array(string)
        guard characters.count % 2 == 0 else { return nil }
        var output = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = characters[index].hexDigitValue,
                  let low = characters[index + 1].hexDigitValue,
                  high < 16, low < 16 else { return nil }
            output.append(UInt8(high << 4 | low))
            index += 2
        }
        return output
    }
}
```

Create `macos/SharedMic/App/SharedMicApp.swift`:

```swift
import SwiftUI

@main
struct SharedMicApp: App {
    var body: some Scene {
        MenuBarExtra("SharedMic", systemImage: "mic") {
            Button("Quit SharedMic") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
```

Then generate the project:

```sh
ruby macos/project.rb
```

- [ ] **Step 4: Run and confirm it passes**

Run: `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/ProtocolConstantsTests -only-testing:SharedMicTests/HexTests`
Expected: PASS — `** TEST SUCCEEDED **`, 11 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/.gitignore macos/project.rb macos/SharedMic.xcodeproj macos/SharedMic macos/SharedMicTests
git commit -m "$(cat <<'EOF'
feat(macos): scaffold SharedMic menu-bar project with protocol constants

Generated .xcodeproj (macos/project.rb is the source of truth), macOS 14.4
deployment target, LSUIElement menu-bar app, and the protocol-v1 constant
table plus lowercase-hex helpers with tests.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Frame envelope codec

**Files:**
- Create: `macos/SharedMic/Protocol/ProtocolError.swift`, `macos/SharedMic/Protocol/FrameCodec.swift`
- Test: `macos/SharedMicTests/FrameCodecTests.swift`

**Interfaces:**
- Consumes: `SharedMicProtocol.envelopeHeaderSize`, `SharedMicProtocol.maxPayloadBytes` (Task 1).
- Produces:
  - `public enum ProtocolError: Error, Equatable` with cases `unknownFrameType(UInt8)`, `payloadTooLarge(Int)`, `malformedJSON(String)`, `notAnObject`, `unknownControlType(String)`, `unsupportedVersion(Int?)`, `missingField(type: String, field: String)`, `wrongFieldType(type: String, field: String)`, `badAudioPayloadLength(Int)`
  - `public enum FrameType: UInt8 { case control = 1; case audio = 2 }`
  - `public struct DecodedFrame: Equatable { public let type: FrameType; public let payload: Data; public let bytesConsumed: Int }`
  - `public enum FrameCodec` with `static func encode(type: FrameType, payload: Data) throws -> Data` and `static func decode(_ buffer: Data) throws -> DecodedFrame?`

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/FrameCodecTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class FrameCodecTests: XCTestCase {
    func testEncodesTheWorkedExampleFromTheSpec() throws {
        // protocol-v1 §3 worked example: CONTROL frame carrying {"type":"PING"}
        let payload = Data(#"{"type":"PING"}"#.utf8)
        XCTAssertEqual(payload.count, 15)
        let frame = try FrameCodec.encode(type: .control, payload: payload)
        XCTAssertEqual(
            Hex.encode(frame),
            "010000000f7b2274797065223a2250494e47227d"
        )
    }

    func testLengthIsBigEndian() throws {
        let payload = Data(repeating: 0x41, count: 258) // 0x0102
        let frame = try FrameCodec.encode(type: .audio, payload: payload)
        XCTAssertEqual(Array(frame.prefix(5)), [0x02, 0x00, 0x00, 0x01, 0x02])
    }

    func testRoundTrip() throws {
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let frame = try FrameCodec.encode(type: .audio, payload: payload)
        let decoded = try XCTUnwrap(FrameCodec.decode(frame))
        XCTAssertEqual(decoded.type, .audio)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.bytesConsumed, 9)
    }

    func testDecodeReturnsNilWhenHeaderIncomplete() throws {
        XCTAssertNil(try FrameCodec.decode(Data()))
        XCTAssertNil(try FrameCodec.decode(Data([0x01, 0x00, 0x00, 0x00])))
    }

    func testDecodeReturnsNilWhenPayloadIncomplete() throws {
        var partial = try FrameCodec.encode(type: .control, payload: Data([0x7b, 0x7d]))
        partial.removeLast()
        XCTAssertNil(try FrameCodec.decode(partial))
    }

    func testDecodeReportsConsumedSoStreamCanHoldTwoFrames() throws {
        var stream = try FrameCodec.encode(type: .control, payload: Data([0x61]))
        stream.append(try FrameCodec.encode(type: .audio, payload: Data([0x62, 0x63])))

        let first = try XCTUnwrap(FrameCodec.decode(stream))
        XCTAssertEqual(first.type, .control)
        XCTAssertEqual(first.payload, Data([0x61]))
        XCTAssertEqual(first.bytesConsumed, 6)

        let rest = stream.dropFirst(first.bytesConsumed)
        let second = try XCTUnwrap(FrameCodec.decode(Data(rest)))
        XCTAssertEqual(second.type, .audio)
        XCTAssertEqual(second.payload, Data([0x62, 0x63]))
        XCTAssertEqual(second.bytesConsumed, 7)
    }

    func testDecodeRejectsUnknownFrameType() {
        let bytes = Data([0x03, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownFrameType(3))
        }
    }

    func testDecodeRejectsOversizedPayloadWithoutAllocating() {
        // 1 MiB + 1, big-endian: 00 10 00 01
        let bytes = Data([0x01, 0x00, 0x10, 0x00, 0x01])
        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .payloadTooLarge(1_048_577))
        }
    }

    func testEncodeRefusesOversizedPayload() {
        let payload = Data(repeating: 0, count: SharedMicProtocol.maxPayloadBytes + 1)
        XCTAssertThrowsError(try FrameCodec.encode(type: .audio, payload: payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .payloadTooLarge(1_048_577))
        }
    }

    func testDecodeWorksOnASliceWithNonZeroStartIndex() throws {
        var stream = Data([0xff, 0xff, 0xff])
        stream.append(try FrameCodec.encode(type: .control, payload: Data([0x7a])))
        let slice = stream.dropFirst(3)
        let decoded = try XCTUnwrap(FrameCodec.decode(slice))
        XCTAssertEqual(decoded.payload, Data([0x7a]))
        XCTAssertEqual(decoded.bytesConsumed, 6)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/FrameCodecTests`
Expected: FAIL — compile error, `cannot find 'FrameCodec' in scope` and `cannot find type 'ProtocolError' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Protocol/ProtocolError.swift`:

```swift
import Foundation

/// Every wire-level violation defined by protocol-v1.
///
/// All of these mean the same thing at the connection level: **close the
/// connection**. protocol-v1 §3 is explicit that a receiver must not attempt to
/// resynchronize past a bad frame, and §1 is explicit that a version mismatch is
/// a hard protocol violation rather than something to downgrade or retry.
public enum ProtocolError: Error, Equatable {
    case unknownFrameType(UInt8)
    case payloadTooLarge(Int)
    case malformedJSON(String)
    case notAnObject
    case unknownControlType(String)
    case unsupportedVersion(Int?)
    case missingField(type: String, field: String)
    case wrongFieldType(type: String, field: String)
    case badAudioPayloadLength(Int)
}

extension ProtocolError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknownFrameType(let value):
            return "unknown frame type \(value)"
        case .payloadTooLarge(let count):
            return "payload of \(count) bytes exceeds the 1 MiB ceiling"
        case .malformedJSON(let detail):
            return "malformed JSON control payload: \(detail)"
        case .notAnObject:
            return "control message must be a JSON object"
        case .unknownControlType(let value):
            return "unknown control type '\(value)'"
        case .unsupportedVersion(let value):
            return "unsupported protocol version \(value.map(String.init) ?? "<missing>")"
        case .missingField(let type, let field):
            return "\(type) missing required field '\(field)'"
        case .wrongFieldType(let type, let field):
            return "\(type) field '\(field)' has the wrong type"
        case .badAudioPayloadLength(let count):
            return "audio payload is \(count) bytes, must be exactly 1932"
        }
    }
}
```

Create `macos/SharedMic/Protocol/FrameCodec.swift`:

```swift
import Foundation

/// protocol-v1 §3: `uint8 type` + `uint32 length` (BIG-ENDIAN) + payload.
public enum FrameType: UInt8 {
    case control = 1
    case audio = 2
}

public struct DecodedFrame: Equatable {
    public let type: FrameType
    public let payload: Data
    /// Total bytes the frame occupied, i.e. 5 + length. The caller drops this
    /// many bytes off the front of its buffer and tries again.
    public let bytesConsumed: Int

    public init(type: FrameType, payload: Data, bytesConsumed: Int) {
        self.type = type
        self.payload = payload
        self.bytesConsumed = bytesConsumed
    }
}

public enum FrameCodec {
    public static func encode(type: FrameType, payload: Data) throws -> Data {
        guard payload.count <= SharedMicProtocol.maxPayloadBytes else {
            throw ProtocolError.payloadTooLarge(payload.count)
        }
        var output = Data(capacity: SharedMicProtocol.envelopeHeaderSize + payload.count)
        output.append(type.rawValue)
        var lengthBigEndian = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lengthBigEndian) { output.append(contentsOf: $0) }
        output.append(payload)
        return output
    }

    /// Decodes one frame from the front of `buffer`.
    ///
    /// Returns nil when `buffer` does not yet hold a complete frame — "not yet",
    /// never a wrong answer. Throws on a protocol violation, which the caller
    /// must treat as "close the connection".
    ///
    /// Written against `buffer.startIndex` rather than 0 so it is correct on a
    /// `Data` slice, which keeps the parent's indices.
    public static func decode(_ buffer: Data) throws -> DecodedFrame? {
        let start = buffer.startIndex
        guard buffer.count >= SharedMicProtocol.envelopeHeaderSize else { return nil }

        let rawType = buffer[start]
        guard let type = FrameType(rawValue: rawType) else {
            throw ProtocolError.unknownFrameType(rawType)
        }

        let length = Int(buffer[start + 1]) << 24
            | Int(buffer[start + 2]) << 16
            | Int(buffer[start + 3]) << 8
            | Int(buffer[start + 4])
        guard length <= SharedMicProtocol.maxPayloadBytes else {
            throw ProtocolError.payloadTooLarge(length)
        }

        let total = SharedMicProtocol.envelopeHeaderSize + length
        guard buffer.count >= total else { return nil }

        let payloadStart = start + SharedMicProtocol.envelopeHeaderSize
        let payload = Data(buffer[payloadStart ..< (start + total)])
        return DecodedFrame(type: type, payload: payload, bytesConsumed: total)
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/FrameCodecTests`
Expected: PASS — `** TEST SUCCEEDED **`, 10 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Protocol/ProtocolError.swift macos/SharedMic/Protocol/FrameCodec.swift macos/SharedMicTests/FrameCodecTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): big-endian frame envelope codec

5-byte envelope, big-endian length, 1 MiB ceiling, incremental decode that
returns nil rather than guessing, and hard rejection of unknown frame types.
Matches the protocol-v1 §3 worked example byte for byte.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Control message model and canonical JSON codec

**Files:**
- Create: `macos/SharedMic/Protocol/ControlMessage.swift`, `macos/SharedMic/Protocol/ControlCodec.swift`
- Test: `macos/SharedMicTests/ControlCodecTests.swift`

**Interfaces:**
- Consumes: `ProtocolError` and `FrameCodec.encode(type:payload:)` (Task 2), `SharedMicProtocol.version` / `.sampleRate` / `.channels` / `.sampleFormat` (Task 1).
- Produces:
  - `public struct AudioFormat: Equatable` — `init(sampleRate: Int, channels: Int, sampleFormat: String)`, `static let v1: AudioFormat`, `var jsonObject: [String: Any]`
  - `public enum ControlMessage: Equatable` with the eleven cases `greeting(serverId:nonce:)`, `hello(clientId:mac:)`, `helloAck(serverId:micPresent:deviceLabel:)`, `start(requestId:preferredFormat:)`, `startAck(requestId:sessionId:format:)`, `startNack(requestId:reason:holderName:)`, `stop(requestId:sessionId:)`, `stopAck(requestId:sessionId:)`, `status(micPresent:active:deviceLabel:)`, `ping(seq:)`, `pong(seq:)`; plus `var typeName: String`, `var jsonObject: [String: Any]`, `init(jsonObject: Any) throws`
  - `startNack`'s `holderName` is `String?` — the protocol's only optional field. It decodes to `nil` when absent and, when `nil`, is **omitted from `jsonObject` entirely** rather than encoded as `null`. That omission is what keeps the committed `START_NACK` golden vector (which has no `holderName`) byte-identical through a decode/encode round trip in Task 5.
  - `public enum ControlCodec` — `static func encode(_ message: ControlMessage) throws -> Data` (payload bytes), `static func decode(_ payload: Data) throws -> ControlMessage`, `static func encodeFrame(_ message: ControlMessage) throws -> Data` (complete envelope)

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/ControlCodecTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class ControlCodecTests: XCTestCase {
    func testEncodesWithSortedKeysAndNoWhitespace() throws {
        let message = ControlMessage.ping(seq: 1)
        let payload = try ControlCodec.encode(message)
        XCTAssertEqual(String(data: payload, encoding: .utf8), #"{"seq":1,"type":"PING","v":1}"#)
    }

    func testNestedObjectKeysAreAlsoSorted() throws {
        let message = ControlMessage.start(requestId: "req-0001", preferredFormat: .v1)
        let payload = try ControlCodec.encode(message)
        XCTAssertEqual(
            String(data: payload, encoding: .utf8),
            #"{"preferredFormat":{"channels":1,"sampleFormat":"s16le","sampleRate":48000},"requestId":"req-0001","type":"START","v":1}"#
        )
    }

    func testCanonicalAudioFormatMatchesSpec() {
        XCTAssertEqual(AudioFormat.v1.sampleRate, 48_000)
        XCTAssertEqual(AudioFormat.v1.channels, 1)
        XCTAssertEqual(AudioFormat.v1.sampleFormat, "s16le")
    }

    func testEncodeFrameProducesACompleteControlEnvelope() throws {
        let frame = try ControlCodec.encodeFrame(.pong(seq: 7))
        let decoded = try XCTUnwrap(FrameCodec.decode(frame))
        XCTAssertEqual(decoded.type, .control)
        XCTAssertEqual(try ControlCodec.decode(decoded.payload), .pong(seq: 7))
    }

    func testRoundTripsEveryMessageType() throws {
        let messages: [ControlMessage] = [
            .greeting(serverId: "win-desktop", nonce: String(repeating: "0", count: 64)),
            .hello(clientId: "mac-studio", mac: String(repeating: "ab", count: 32)),
            .helloAck(serverId: "win-desktop", micPresent: true, deviceLabel: "USB Microphone"),
            .start(requestId: "req-0001", preferredFormat: .v1),
            .startAck(requestId: "req-0001", sessionId: "sess-0001", format: .v1),
            .startNack(requestId: "req-0002", reason: "MIC_UNAVAILABLE", holderName: nil),
            .stop(requestId: "req-0003", sessionId: "sess-0001"),
            .stopAck(requestId: "req-0003", sessionId: "sess-0001"),
            .status(micPresent: false, active: false, deviceLabel: "USB Microphone"),
            .ping(seq: 1),
            .pong(seq: 1)
        ]
        XCTAssertEqual(messages.count, 11)
        for message in messages {
            let payload = try ControlCodec.encode(message)
            XCTAssertEqual(try ControlCodec.decode(payload), message, "round trip failed for \(message.typeName)")
        }
    }

    func testRejectsWrongProtocolVersion() {
        let payload = Data(#"{"seq":1,"type":"PING","v":2}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .unsupportedVersion(2))
        }
    }

    func testRejectsMissingRequiredField() {
        let payload = Data(#"{"type":"HELLO","v":1,"clientId":"mac"}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .missingField(type: "HELLO", field: "mac"))
        }
    }

    func testRejectsWrongFieldType() {
        let payload = Data(#"{"seq":"one","type":"PING","v":1}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .wrongFieldType(type: "PING", field: "seq"))
        }
    }

    func testRejectsUnknownMessageType() {
        let payload = Data(#"{"type":"BOOM","v":1}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownControlType("BOOM"))
        }
    }

    func testRejectsNonObjectJSON() {
        let payload = Data("[1,2,3]".utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .notAnObject)
        }
    }

    func testRejectsMalformedJSON() {
        let payload = Data("{not json".utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            guard case .malformedJSON = (error as? ProtocolError) else {
                return XCTFail("expected .malformedJSON, got \(error)")
            }
        }
    }

    /// protocol-v1 §5: `holderName` is advisory and OPTIONAL. A START_NACK without
    /// it is completely valid — that is what every MIC_UNAVAILABLE refusal looks
    /// like — so decoding must yield nil rather than throwing.
    func testStartNackDecodesWithoutTheOptionalHolder() throws {
        let payload = Data(#"{"reason":"MIC_UNAVAILABLE","requestId":"req-0002","type":"START_NACK","v":1}"#.utf8)
        XCTAssertEqual(
            try ControlCodec.decode(payload),
            .startNack(requestId: "req-0002", reason: "MIC_UNAVAILABLE", holderName: nil)
        )
    }

    func testStartNackCarriesTheHolderWhenTheSessionIsInUse() throws {
        let payload = Data(
            #"{"holderName":"Mac Studio","reason":"SESSION_IN_USE","requestId":"req-0002","type":"START_NACK","v":1}"#.utf8
        )
        XCTAssertEqual(
            try ControlCodec.decode(payload),
            .startNack(requestId: "req-0002", reason: "SESSION_IN_USE", holderName: "Mac Studio")
        )
    }

    /// A nil holder must vanish from the object, not appear as `"holderName":null`.
    /// The committed START_NACK vector has no holder, so anything else would
    /// break the golden-vector round trip in Task 5.
    func testANilHolderIsOmittedFromTheEncodedObject() throws {
        let payload = try ControlCodec.encode(
            .startNack(requestId: "req-0002", reason: "MIC_UNAVAILABLE", holderName: nil)
        )
        XCTAssertEqual(
            String(data: payload, encoding: .utf8),
            #"{"reason":"MIC_UNAVAILABLE","requestId":"req-0002","type":"START_NACK","v":1}"#
        )

        let withHolder = try ControlCodec.encode(
            .startNack(requestId: "req-0002", reason: "SESSION_IN_USE", holderName: "Mac Studio")
        )
        XCTAssertEqual(
            String(data: withHolder, encoding: .utf8),
            #"{"holderName":"Mac Studio","reason":"SESSION_IN_USE","requestId":"req-0002","type":"START_NACK","v":1}"#
        )
    }

    /// protocol-v1 §5: a START_NACK MUST NOT be rejected for carrying
    /// `holderName`, and the field is display-only. An unusable value is
    /// therefore ignored — the refusal still has to reach the user.
    func testAnUnusableHolderNameIsIgnoredRatherThanRejected() throws {
        let wrongType = Data(
            #"{"holderName":7,"reason":"SESSION_IN_USE","requestId":"r","type":"START_NACK","v":1}"#.utf8
        )
        XCTAssertEqual(
            try ControlCodec.decode(wrongType),
            .startNack(requestId: "r", reason: "SESSION_IN_USE", holderName: nil)
        )

        // ...and carrying it alongside some other reason is also well-formed;
        // §5 says the field is simply ignored where it is not meaningful.
        let otherReason = Data(
            #"{"holderName":"Mac Studio","reason":"MIC_UNAVAILABLE","requestId":"r","type":"START_NACK","v":1}"#.utf8
        )
        XCTAssertEqual(
            try ControlCodec.decode(otherReason),
            .startNack(requestId: "r", reason: "MIC_UNAVAILABLE", holderName: "Mac Studio")
        )
    }

    func testStatusHasExactlyThreeFieldsBeyondVersionAndType() throws {
        let payload = try ControlCodec.encode(.status(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "type", "micPresent", "active", "deviceLabel"])
        XCTAssertNil(object["errors"])
    }

    func testEncodesAsUTF8WithoutASCIIEscaping() throws {
        let payload = try ControlCodec.encode(.helloAck(serverId: "win", micPresent: true, deviceLabel: "Mikrofón ✓"))
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertTrue(text.contains("Mikrofón ✓"))
        XCTAssertFalse(text.contains("\\u"))
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/ControlCodecTests`
Expected: FAIL — compile error, `cannot find 'ControlCodec' in scope` and `cannot find type 'ControlMessage' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Protocol/ControlMessage.swift`:

```swift
import Foundation

/// protocol-v1 §4: fixed for version 1, no negotiation is possible.
public struct AudioFormat: Equatable {
    public let sampleRate: Int
    public let channels: Int
    public let sampleFormat: String

    public init(sampleRate: Int, channels: Int, sampleFormat: String) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleFormat = sampleFormat
    }

    public static let v1 = AudioFormat(
        sampleRate: SharedMicProtocol.sampleRate,
        channels: SharedMicProtocol.channels,
        sampleFormat: SharedMicProtocol.sampleFormat
    )

    public var jsonObject: [String: Any] {
        ["sampleRate": sampleRate, "channels": channels, "sampleFormat": sampleFormat]
    }
}

/// The eleven control message types of protocol-v1 §5.
public enum ControlMessage: Equatable {
    case greeting(serverId: String, nonce: String)
    case hello(clientId: String, mac: String)
    case helloAck(serverId: String, micPresent: Bool, deviceLabel: String)
    case start(requestId: String, preferredFormat: AudioFormat)
    case startAck(requestId: String, sessionId: String, format: AudioFormat)
    /// `holderName` is the protocol's only optional field: the friendly name of the
    /// Mac that currently holds the session, sent only with
    /// `reason == "SESSION_IN_USE"` and permitted to be absent even then. It is
    /// advisory — every path that uses it must work when it is nil.
    case startNack(requestId: String, reason: String, holderName: String?)
    case stop(requestId: String, sessionId: String)
    case stopAck(requestId: String, sessionId: String)
    case status(micPresent: Bool, active: Bool, deviceLabel: String)
    case ping(seq: Int)
    case pong(seq: Int)

    public var typeName: String {
        switch self {
        case .greeting: return "GREETING"
        case .hello: return "HELLO"
        case .helloAck: return "HELLO_ACK"
        case .start: return "START"
        case .startAck: return "START_ACK"
        case .startNack: return "START_NACK"
        case .stop: return "STOP"
        case .stopAck: return "STOP_ACK"
        case .status: return "STATUS"
        case .ping: return "PING"
        case .pong: return "PONG"
        }
    }

    public static let allTypeNames: Set<String> = [
        "GREETING", "HELLO", "HELLO_ACK", "START", "START_ACK", "START_NACK",
        "STOP", "STOP_ACK", "STATUS", "PING", "PONG"
    ]

    public var jsonObject: [String: Any] {
        var object: [String: Any] = ["v": SharedMicProtocol.version, "type": typeName]
        switch self {
        case .greeting(let serverId, let nonce):
            object["serverId"] = serverId
            object["nonce"] = nonce
        case .hello(let clientId, let mac):
            object["clientId"] = clientId
            object["mac"] = mac
        case .helloAck(let serverId, let micPresent, let deviceLabel):
            object["serverId"] = serverId
            object["micPresent"] = micPresent
            object["deviceLabel"] = deviceLabel
        case .start(let requestId, let preferredFormat):
            object["requestId"] = requestId
            object["preferredFormat"] = preferredFormat.jsonObject
        case .startAck(let requestId, let sessionId, let format):
            object["requestId"] = requestId
            object["sessionId"] = sessionId
            object["format"] = format.jsonObject
        case .startNack(let requestId, let reason, let holderName):
            object["requestId"] = requestId
            object["reason"] = reason
            // Omitted, not encoded as null: the committed START_NACK vector has
            // no `holderName` key and must round-trip byte-identically.
            if let holderName {
                object["holderName"] = holderName
            }
        case .stop(let requestId, let sessionId):
            object["requestId"] = requestId
            object["sessionId"] = sessionId
        case .stopAck(let requestId, let sessionId):
            object["requestId"] = requestId
            object["sessionId"] = sessionId
        case .status(let micPresent, let active, let deviceLabel):
            object["micPresent"] = micPresent
            object["active"] = active
            object["deviceLabel"] = deviceLabel
        case .ping(let seq):
            object["seq"] = seq
        case .pong(let seq):
            object["seq"] = seq
        }
        return object
    }

    public init(jsonObject: Any) throws {
        guard let dictionary = jsonObject as? [String: Any] else {
            throw ProtocolError.notAnObject
        }
        guard let typeName = dictionary["type"] as? String,
              ControlMessage.allTypeNames.contains(typeName) else {
            throw ProtocolError.unknownControlType((dictionary["type"] as? String) ?? "<missing>")
        }
        // protocol-v1 §1: a "v" other than 1 is a hard protocol violation.
        let rawVersion = dictionary["v"] as? Int
        guard rawVersion == SharedMicProtocol.version else {
            throw ProtocolError.unsupportedVersion(rawVersion)
        }

        func string(_ key: String) throws -> String {
            guard let raw = dictionary[key] else {
                throw ProtocolError.missingField(type: typeName, field: key)
            }
            guard let value = raw as? String else {
                throw ProtocolError.wrongFieldType(type: typeName, field: key)
            }
            return value
        }
        func bool(_ key: String) throws -> Bool {
            guard let raw = dictionary[key] else {
                throw ProtocolError.missingField(type: typeName, field: key)
            }
            guard let value = raw as? Bool else {
                throw ProtocolError.wrongFieldType(type: typeName, field: key)
            }
            return value
        }
        func integer(_ key: String) throws -> Int {
            guard let raw = dictionary[key] else {
                throw ProtocolError.missingField(type: typeName, field: key)
            }
            // JSONSerialization hands back NSNumber for every JSON number. It also
            // hands back NSNumber for `true`/`false`, which this deliberately does
            // not try to separate — the reference Python decoder does not type-check
            // these fields at all, and inventing a stricter rule here would reject
            // messages the far end considers valid.
            guard let number = raw as? NSNumber else {
                throw ProtocolError.wrongFieldType(type: typeName, field: key)
            }
            return number.intValue
        }
        /// An OPTIONAL ADVISORY field. protocol-v1 §5 is explicit that a
        /// START_NACK must never be rejected for carrying `holderName`, and that
        /// the field is display-only, so anything unusable — absent, null, or
        /// not a string — decodes to nil rather than throwing. This is
        /// deliberately more forgiving than `string(_:)`, which guards required
        /// fields and must stay strict.
        func advisoryString(_ key: String) -> String? {
            dictionary[key] as? String
        }
        func format(_ key: String) throws -> AudioFormat {
            guard let raw = dictionary[key] else {
                throw ProtocolError.missingField(type: typeName, field: key)
            }
            guard let nested = raw as? [String: Any],
                  let sampleRate = (nested["sampleRate"] as? NSNumber)?.intValue,
                  let channels = (nested["channels"] as? NSNumber)?.intValue,
                  let sampleFormat = nested["sampleFormat"] as? String else {
                throw ProtocolError.wrongFieldType(type: typeName, field: key)
            }
            return AudioFormat(sampleRate: sampleRate, channels: channels, sampleFormat: sampleFormat)
        }

        switch typeName {
        case "GREETING":
            self = .greeting(serverId: try string("serverId"), nonce: try string("nonce"))
        case "HELLO":
            self = .hello(clientId: try string("clientId"), mac: try string("mac"))
        case "HELLO_ACK":
            self = .helloAck(serverId: try string("serverId"),
                             micPresent: try bool("micPresent"),
                             deviceLabel: try string("deviceLabel"))
        case "START":
            self = .start(requestId: try string("requestId"),
                          preferredFormat: try format("preferredFormat"))
        case "START_ACK":
            self = .startAck(requestId: try string("requestId"),
                             sessionId: try string("sessionId"),
                             format: try format("format"))
        case "START_NACK":
            self = .startNack(requestId: try string("requestId"),
                              reason: try string("reason"),
                              holderName: advisoryString("holderName"))
        case "STOP":
            self = .stop(requestId: try string("requestId"), sessionId: try string("sessionId"))
        case "STOP_ACK":
            self = .stopAck(requestId: try string("requestId"), sessionId: try string("sessionId"))
        case "STATUS":
            self = .status(micPresent: try bool("micPresent"),
                           active: try bool("active"),
                           deviceLabel: try string("deviceLabel"))
        case "PING":
            self = .ping(seq: try integer("seq"))
        case "PONG":
            self = .pong(seq: try integer("seq"))
        default:
            throw ProtocolError.unknownControlType(typeName)
        }
    }
}
```

Create `macos/SharedMic/Protocol/ControlCodec.swift`:

```swift
import Foundation

/// protocol-v1 §5 / §10: a CONTROL payload is one UTF-8 JSON object with no line
/// breaks or padding — exactly the bytes
/// `json.dumps(msg, sort_keys=True, separators=(",", ":"))` would produce.
///
/// `JSONSerialization` with `.sortedKeys` produces separator-free output with
/// lexicographically sorted keys, recursively, and emits UTF-8 without \u
/// escaping — byte-identical to the reference encoder. `.withoutEscapingSlashes`
/// is included so a `/` inside a device label cannot diverge from Python, which
/// never escapes it.
public enum ControlCodec {
    public static func encode(_ message: ControlMessage) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: message.jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public static func decode(_ payload: Data) throws -> ControlMessage {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
            throw ProtocolError.malformedJSON(error.localizedDescription)
        }
        return try ControlMessage(jsonObject: object)
    }

    /// A complete CONTROL envelope (protocol-v1 §3) ready to write to the wire.
    public static func encodeFrame(_ message: ControlMessage) throws -> Data {
        try FrameCodec.encode(type: .control, payload: try encode(message))
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/ControlCodecTests`
Expected: PASS — `** TEST SUCCEEDED **`, 17 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Protocol/ControlMessage.swift macos/SharedMic/Protocol/ControlCodec.swift macos/SharedMicTests/ControlCodecTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): control message model and canonical sorted-key JSON codec

All eleven protocol-v1 §5 types with per-type required-field validation on both
encode and decode, version-1 enforcement, and canonical UTF-8 output with
lexicographically sorted keys including nested format objects. START_NACK
carries the optional advisory `holderName` name, omitted rather than encoded as null
when absent so the committed vector still round-trips byte for byte.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Audio payload codec (big-endian header, little-endian PCM)

**Files:**
- Create: `macos/SharedMic/Protocol/AudioFrameCodec.swift`
- Test: `macos/SharedMicTests/AudioFrameCodecTests.swift`

**Interfaces:**
- Consumes: `ProtocolError`, `FrameCodec.encode(type:payload:)` (Task 2); `SharedMicProtocol.audioHeaderSize` / `.audioPCMBytes` / `.audioPayloadSize` (Task 1).
- Produces:
  - `public struct AudioFrame: Equatable { public let sequence: UInt32; public let captureTimestampUs: UInt64; public let pcm: Data }`
  - `public enum AudioFrameCodec` — `static func encodePayload(sequence: UInt32, captureTimestampUs: UInt64, pcm: Data) throws -> Data`, `static func decodePayload(_ payload: Data) throws -> AudioFrame`, `static func encodeFrame(sequence: UInt32, captureTimestampUs: UInt64, pcm: Data) throws -> Data`, `static func samples(from pcm: Data) -> [Int16]`, `static func pcmBytes(from samples: [Int16]) -> Data`

**Phase note:** nothing in Phase 1 produces or consumes a real audio frame. This codec exists because the golden vectors cover audio framing and Phase 2's renderer will use exactly this code. Do not wire it into any runtime path in this phase.

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/AudioFrameCodecTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class AudioFrameCodecTests: XCTestCase {
    private func silentPCM() -> Data {
        Data(repeating: 0, count: SharedMicProtocol.audioPCMBytes)
    }

    func testHeaderIsTwelveBigEndianBytes() throws {
        let payload = try AudioFrameCodec.encodePayload(
            sequence: 0x0102_0304,
            captureTimestampUs: 0x0102_0304_0506_0708,
            pcm: silentPCM()
        )
        XCTAssertEqual(payload.count, SharedMicProtocol.audioPayloadSize)
        XCTAssertEqual(
            Array(payload.prefix(12)),
            [0x01, 0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        )
    }

    func testEnvelopeIs1937Bytes() throws {
        let frame = try AudioFrameCodec.encodeFrame(sequence: 0, captureTimestampUs: 0, pcm: silentPCM())
        XCTAssertEqual(frame.count, SharedMicProtocol.audioEnvelopeSize)
        XCTAssertEqual(Array(frame.prefix(5)), [0x02, 0x00, 0x00, 0x07, 0x8c]) // 1932 = 0x078c
    }

    func testRoundTrip() throws {
        var pcm = silentPCM()
        pcm[0] = 0x11
        pcm[SharedMicProtocol.audioPCMBytes - 1] = 0x22
        let payload = try AudioFrameCodec.encodePayload(sequence: 49, captureTimestampUs: 980_000, pcm: pcm)
        let frame = try AudioFrameCodec.decodePayload(payload)
        XCTAssertEqual(frame.sequence, 49)
        XCTAssertEqual(frame.captureTimestampUs, 980_000)
        XCTAssertEqual(frame.pcm, pcm)
    }

    func testEncodeRejectsShortPCM() {
        let pcm = Data(repeating: 0, count: 1_918)
        XCTAssertThrowsError(try AudioFrameCodec.encodePayload(sequence: 0, captureTimestampUs: 0, pcm: pcm)) { error in
            XCTAssertEqual(error as? ProtocolError, .badAudioPayloadLength(1_930))
        }
    }

    func testDecodeRejectsAnythingOtherThanExactly1932Bytes() {
        // protocol-v1 §4: "Short audio payloads are not legal. There is no partial
        // frame in this protocol." The reference Python decoder is deliberately more
        // permissive; this receiver must not be.
        for count in [0, 11, 12, 1_931, 1_933] {
            let payload = Data(repeating: 0, count: count)
            XCTAssertThrowsError(try AudioFrameCodec.decodePayload(payload)) { error in
                XCTAssertEqual(error as? ProtocolError, .badAudioPayloadLength(count))
            }
        }
    }

    func testPCMSamplesAreLittleEndian() {
        // The envelope and the audio header are big-endian; the s16 samples are not.
        let bytes = AudioFrameCodec.pcmBytes(from: [1, -2, 256, Int16.min, Int16.max])
        XCTAssertEqual(
            Array(bytes),
            [0x01, 0x00, 0xfe, 0xff, 0x00, 0x01, 0x00, 0x80, 0xff, 0x7f]
        )
        XCTAssertEqual(AudioFrameCodec.samples(from: bytes), [1, -2, 256, Int16.min, Int16.max])
    }

    func testSampleCountForAFullFrame() {
        XCTAssertEqual(AudioFrameCodec.samples(from: silentPCM()).count, SharedMicProtocol.samplesPerFrame)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/AudioFrameCodecTests`
Expected: FAIL — compile error, `cannot find 'AudioFrameCodec' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Protocol/AudioFrameCodec.swift`:

```swift
import Foundation

/// protocol-v1 §4.
///
/// ```
/// uint32  sequence             // BIG-ENDIAN
/// uint64  captureTimestampUs   // BIG-ENDIAN
/// bytes   pcm                  // exactly 1920 bytes of s16 LITTLE-ENDIAN PCM
/// ```
///
/// **The single most likely implementation mistake** (protocol-v1 §4): the
/// envelope and this header are big-endian, and the PCM samples inside are
/// little-endian. Applying the header's byte order to the PCM compiles, raises
/// nothing, and produces heavy static rather than a crash.
///
/// Phase 1 never carries PCM. This codec exists so the golden audio vectors can
/// be byte-matched now and so Phase 2's renderer inherits a tested codec.
public struct AudioFrame: Equatable {
    public let sequence: UInt32
    public let captureTimestampUs: UInt64
    public let pcm: Data

    public init(sequence: UInt32, captureTimestampUs: UInt64, pcm: Data) {
        self.sequence = sequence
        self.captureTimestampUs = captureTimestampUs
        self.pcm = pcm
    }
}

public enum AudioFrameCodec {
    public static func encodePayload(sequence: UInt32,
                                     captureTimestampUs: UInt64,
                                     pcm: Data) throws -> Data {
        guard pcm.count == SharedMicProtocol.audioPCMBytes else {
            throw ProtocolError.badAudioPayloadLength(SharedMicProtocol.audioHeaderSize + pcm.count)
        }
        var output = Data(capacity: SharedMicProtocol.audioPayloadSize)
        var sequenceBigEndian = sequence.bigEndian
        withUnsafeBytes(of: &sequenceBigEndian) { output.append(contentsOf: $0) }
        var timestampBigEndian = captureTimestampUs.bigEndian
        withUnsafeBytes(of: &timestampBigEndian) { output.append(contentsOf: $0) }
        output.append(pcm)
        return output
    }

    /// Strict on purpose: protocol-v1 §4 requires a receiver to treat any length
    /// other than 1932 as a protocol violation and close the connection.
    public static func decodePayload(_ payload: Data) throws -> AudioFrame {
        guard payload.count == SharedMicProtocol.audioPayloadSize else {
            throw ProtocolError.badAudioPayloadLength(payload.count)
        }
        let start = payload.startIndex
        var sequence: UInt32 = 0
        for offset in 0..<4 {
            sequence = (sequence << 8) | UInt32(payload[start + offset])
        }
        var timestamp: UInt64 = 0
        for offset in 4..<12 {
            timestamp = (timestamp << 8) | UInt64(payload[start + offset])
        }
        let pcm = Data(payload[(start + SharedMicProtocol.audioHeaderSize)...])
        return AudioFrame(sequence: sequence, captureTimestampUs: timestamp, pcm: pcm)
    }

    public static func encodeFrame(sequence: UInt32,
                                   captureTimestampUs: UInt64,
                                   pcm: Data) throws -> Data {
        let payload = try encodePayload(sequence: sequence,
                                        captureTimestampUs: captureTimestampUs,
                                        pcm: pcm)
        return try FrameCodec.encode(type: .audio, payload: payload)
    }

    /// s16 **little-endian** — low byte first.
    public static func samples(from pcm: Data) -> [Int16] {
        var output: [Int16] = []
        output.reserveCapacity(pcm.count / 2)
        var index = pcm.startIndex
        while index + 1 < pcm.endIndex {
            let low = UInt16(pcm[index])
            let high = UInt16(pcm[index + 1])
            output.append(Int16(bitPattern: low | (high << 8)))
            index += 2
        }
        return output
    }

    /// s16 **little-endian** — low byte first.
    public static func pcmBytes(from samples: [Int16]) -> Data {
        var output = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            output.append(UInt8(bits & 0x00ff))
            output.append(UInt8((bits >> 8) & 0x00ff))
        }
        return output
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/AudioFrameCodecTests`
Expected: PASS — `** TEST SUCCEEDED **`, 7 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Protocol/AudioFrameCodec.swift macos/SharedMicTests/AudioFrameCodecTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): audio payload codec with strict 1932-byte receiver

Big-endian 12-byte header, little-endian s16 PCM accessors, and a decoder that
rejects any payload length other than 1932 — stricter than the reference Python
decoder, as protocol-v1 §4 requires. Unused at runtime in Phase 1; written for
the golden vectors and for Phase 2.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Golden vector conformance suite

This is the backbone of the phase. It loads `protocol/vectors/*.json` and iterates every case; it does not hand-copy any of them. It is what proves interoperability before either machine has ever talked to the other.

**Files:**
- Create: `macos/SharedMicTests/Support/RepositoryPaths.swift`
- Test: `macos/SharedMicTests/VectorConformanceTests.swift`

**Interfaces:**
- Consumes: `Hex` (Task 1), `FrameCodec`/`FrameType`/`DecodedFrame` (Task 2), `ControlMessage`/`ControlCodec` (Task 3), `AudioFrameCodec` (Task 4).
- Produces: `enum RepositoryPaths` (test-target only) with `static var root: URL`, `static var vectorsDirectory: URL`, `static var harnessDirectory: URL`, `static var pythonExecutable: URL`.

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/Support/RepositoryPaths.swift`:

```swift
import Foundation

/// Locates repository files from the test bundle.
///
/// `#filePath` is the absolute path of THIS source file at compile time:
/// `<repo>/macos/SharedMicTests/Support/RepositoryPaths.swift`. Four
/// `deletingLastPathComponent()` calls walk Support -> SharedMicTests -> macos ->
/// repository root. Using the source tree rather than a copied resource bundle
/// means the tests read the same committed vector files the Python harness does,
/// so the two can never silently drift apart.
enum RepositoryPaths {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // SharedMicTests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repository root
    }

    static var vectorsDirectory: URL {
        root.appendingPathComponent("protocol/vectors", isDirectory: true)
    }

    static var harnessDirectory: URL {
        root.appendingPathComponent("harness", isDirectory: true)
    }

    /// There is no bare `python` on this machine and the system `python3` has no
    /// pytest — the harness virtualenv interpreter is the only usable one.
    static var pythonExecutable: URL {
        harnessDirectory.appendingPathComponent(".venv/bin/python")
    }
}
```

Create `macos/SharedMicTests/VectorConformanceTests.swift`:

```swift
import XCTest
@testable import SharedMic

/// protocol-v1 §10: an implementation is conformant only if it produces and
/// accepts the exact bytes in `protocol/vectors/*.json`.
final class VectorConformanceTests: XCTestCase {

    // MARK: - Loading

    private struct ControlVector {
        let name: String
        let message: [String: Any]
        let hex: String
    }

    private struct AudioVector {
        let name: String
        let sequence: UInt32
        let timestampUs: UInt64
        let pcmHex: String
        let hex: String
    }

    private func loadControlVectors() throws -> [ControlVector] {
        let url = RepositoryPaths.vectorsDirectory.appendingPathComponent("control-messages.json")
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try raw.map { entry in
            ControlVector(
                name: try XCTUnwrap(entry["name"] as? String),
                message: try XCTUnwrap(entry["message"] as? [String: Any]),
                hex: try XCTUnwrap(entry["hex"] as? String)
            )
        }
    }

    private func loadAudioVectors() throws -> [AudioVector] {
        let url = RepositoryPaths.vectorsDirectory.appendingPathComponent("audio-frames.json")
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try raw.map { entry in
            AudioVector(
                name: try XCTUnwrap(entry["name"] as? String),
                sequence: try XCTUnwrap((entry["sequence"] as? NSNumber)?.uint32Value),
                timestampUs: try XCTUnwrap((entry["timestampUs"] as? NSNumber)?.uint64Value),
                pcmHex: try XCTUnwrap(entry["pcmHex"] as? String),
                hex: try XCTUnwrap(entry["hex"] as? String)
            )
        }
    }

    // MARK: - Existence

    func testVectorFilesExist() {
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(
            atPath: RepositoryPaths.vectorsDirectory.appendingPathComponent("control-messages.json").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: RepositoryPaths.vectorsDirectory.appendingPathComponent("audio-frames.json").path))
    }

    // MARK: - Control conformance

    func testControlVectorsCoverEveryMessageType() throws {
        let vectors = try loadControlVectors()
        XCTAssertEqual(vectors.count, 11)
        XCTAssertEqual(Set(vectors.map(\.name)), ControlMessage.allTypeNames)
    }

    /// protocol-v1 §10 encode conformance: encoding a vector's `message` with the
    /// canonical (sorted-key) encoder MUST produce bytes identical to its `hex`.
    func testControlVectorsEncodeToExpectedBytes() throws {
        for vector in try loadControlVectors() {
            let message = try ControlMessage(jsonObject: vector.message)
            let frame = try ControlCodec.encodeFrame(message)
            XCTAssertEqual(Hex.encode(frame), vector.hex, "encode mismatch for \(vector.name)")
        }
    }

    /// protocol-v1 §10 decode conformance: parsing a vector's `hex` MUST yield an
    /// object equal field-for-field (ignoring key order and whitespace) to its
    /// `message`.
    func testControlVectorsDecodeToExpectedMessage() throws {
        for vector in try loadControlVectors() {
            let bytes = try XCTUnwrap(Hex.decode(vector.hex), "bad hex in vector \(vector.name)")
            let frame = try XCTUnwrap(FrameCodec.decode(bytes), "incomplete frame in vector \(vector.name)")
            XCTAssertEqual(frame.type, .control, "wrong envelope type for \(vector.name)")
            XCTAssertEqual(frame.bytesConsumed, bytes.count, "trailing bytes in vector \(vector.name)")

            let message = try ControlCodec.decode(frame.payload)
            XCTAssertEqual(message.typeName, vector.name, "wrong decoded type for \(vector.name)")
            XCTAssertEqual(
                NSDictionary(dictionary: message.jsonObject),
                NSDictionary(dictionary: vector.message),
                "decoded fields differ for \(vector.name)"
            )
        }
    }

    /// Re-encoding what we decoded must return to the same bytes. This is what
    /// catches a decoder that silently drops a field the vector carried.
    func testControlVectorsSurviveDecodeThenEncode() throws {
        for vector in try loadControlVectors() {
            let bytes = try XCTUnwrap(Hex.decode(vector.hex))
            let frame = try XCTUnwrap(FrameCodec.decode(bytes))
            let message = try ControlCodec.decode(frame.payload)
            XCTAssertEqual(Hex.encode(try ControlCodec.encodeFrame(message)), vector.hex,
                           "decode/encode is not the identity for \(vector.name)")
        }
    }

    // MARK: - Audio conformance

    /// protocol-v1 §10 audio conformance: compare bytes.
    func testAudioVectorsEncodeToExpectedBytes() throws {
        let vectors = try loadAudioVectors()
        XCTAssertEqual(vectors.count, 3)
        for vector in vectors {
            let pcm = try XCTUnwrap(Hex.decode(vector.pcmHex), "bad pcmHex in vector \(vector.name)")
            XCTAssertEqual(pcm.count, SharedMicProtocol.audioPCMBytes, "wrong PCM size in \(vector.name)")
            let frame = try AudioFrameCodec.encodeFrame(
                sequence: vector.sequence,
                captureTimestampUs: vector.timestampUs,
                pcm: pcm
            )
            XCTAssertEqual(frame.count, SharedMicProtocol.audioEnvelopeSize)
            XCTAssertEqual(Hex.encode(frame), vector.hex, "encode mismatch for \(vector.name)")
        }
    }

    func testAudioVectorsDecodeToExpectedFrame() throws {
        for vector in try loadAudioVectors() {
            let bytes = try XCTUnwrap(Hex.decode(vector.hex))
            let envelope = try XCTUnwrap(FrameCodec.decode(bytes))
            XCTAssertEqual(envelope.type, .audio, "wrong envelope type for \(vector.name)")
            XCTAssertEqual(envelope.bytesConsumed, SharedMicProtocol.audioEnvelopeSize)

            let frame = try AudioFrameCodec.decodePayload(envelope.payload)
            XCTAssertEqual(frame.sequence, vector.sequence, "sequence mismatch for \(vector.name)")
            XCTAssertEqual(frame.captureTimestampUs, vector.timestampUs, "timestamp mismatch for \(vector.name)")
            XCTAssertEqual(Hex.encode(frame.pcm), vector.pcmHex, "PCM mismatch for \(vector.name)")
        }
    }

    /// The endianness trap, asserted against real vector data rather than a
    /// hand-written example: frame-0 of the synthetic session is a rising sine, so
    /// its first samples increase monotonically when read little-endian and jump
    /// wildly when read big-endian.
    func testAudioVectorPCMIsLittleEndian() throws {
        let vectors = try loadAudioVectors()
        let frameZero = try XCTUnwrap(vectors.first { $0.name == "frame-0" })
        let pcm = try XCTUnwrap(Hex.decode(frameZero.pcmHex))
        let samples = AudioFrameCodec.samples(from: pcm)
        XCTAssertEqual(samples.count, SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(Array(samples.prefix(4)), [0, 943, 1883, 2816])
    }

    /// Timestamps advance by exactly one frame duration per sequence step
    /// (protocol-v1 §4), which is what the 0/1/49 vector selection exists to pin.
    func testAudioVectorTimestampsMatchSequenceTimes20ms() throws {
        for vector in try loadAudioVectors() {
            XCTAssertEqual(vector.timestampUs,
                           UInt64(vector.sequence) * SharedMicProtocol.frameDurationUs,
                           "timestamp/sequence relationship broken in \(vector.name)")
        }
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/VectorConformanceTests`
Expected: FAIL — compile error, `cannot find 'RepositoryPaths' in scope` before the file below is created; once it compiles, any codec deviation fails with a named-vector message such as `encode mismatch for START_ACK`.

- [ ] **Step 3: Implement**

Both files above are the deliverable — this task's "implementation" is the loader and the assertions, and the code under test already exists from Tasks 1–4. If any assertion fails, fix the codec, not the vector: `protocol/vectors/*.json` is the contract and must not be edited or regenerated by this task.

To cross-check the same fixtures against the reference implementation while debugging:

```sh
cd harness && .venv/bin/python -m pytest tests/test_vectors.py -v
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/VectorConformanceTests`
Expected: PASS — `** TEST SUCCEEDED **`, 9 test cases, covering all 14 committed vectors (11 control encoded, 11 control decoded, 11 round-tripped, 3 audio encoded, 3 audio decoded).

Also confirm the whole suite is still green:

Run: `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMicTests/Support/RepositoryPaths.swift macos/SharedMicTests/VectorConformanceTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
test(macos): golden vector conformance against protocol/vectors

Iterates every committed vector rather than hand-copying cases: 11 control
messages encoded and decoded, 3 audio frames encoded and decoded, plus a
little-endian PCM assertion driven by real vector data. This is the
interoperability proof that precedes any contact with a Windows agent.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Pairing string codec and HMAC auth proof

**Files:**
- Create: `macos/SharedMic/Security/Base32.swift`, `macos/SharedMic/Security/PairingString.swift`, `macos/SharedMic/Security/AuthProof.swift`
- Test: `macos/SharedMicTests/PairingStringTests.swift`, `macos/SharedMicTests/AuthProofTests.swift`

**Interfaces:**
- Consumes: `Hex` (Task 1), `SharedMicProtocol.tokenBytes` / `.pairingGroupSize` / `.pairingStringLength` (Task 1).
- Produces:
  - `public enum Base32` — `static func encode(_ data: Data) -> String` (unpadded, uppercase), `static func decode(_ text: String) -> Data?`
  - `public enum PairingStringError: Error, Equatable { case invalidBase32; case wrongDecodedLength(Int) }`
  - `public enum PairingString` — `static func encode(token: Data) -> String`, `static func decode(_ text: String) throws -> Data`
  - `public enum AuthProof` — `static func proof(token: Data, nonce: Data) -> String`, `static func fingerprint(ofDER der: Data) -> String`

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/PairingStringTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class PairingStringTests: XCTestCase {
    private let specToken = Data((0..<32).map { UInt8($0) })
    private let specString = "AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ"

    func testEncodesTheSpecWorkedExample() {
        XCTAssertEqual(PairingString.encode(token: specToken), specString)
    }

    func testShapeIs58CharactersWithSixHyphens() {
        let encoded = PairingString.encode(token: specToken)
        XCTAssertEqual(encoded.count, SharedMicProtocol.pairingStringLength)
        XCTAssertEqual(encoded.filter { $0 == "-" }.count, 6)
        let groups = encoded.split(separator: "-").map(String.init)
        XCTAssertEqual(groups.map(\.count), [8, 8, 8, 8, 8, 8, 4])
    }

    func testEncodingIsUppercaseUnpaddedRFC4648() {
        let encoded = PairingString.encode(token: specToken)
        XCTAssertFalse(encoded.contains("="))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567-")
        XCTAssertTrue(encoded.allSatisfy { allowed.contains($0) })
    }

    func testRoundTripsARandomToken() throws {
        var token = Data(count: 32)
        for index in 0..<32 { token[index] = UInt8.random(in: 0...255) }
        XCTAssertEqual(try PairingString.decode(PairingString.encode(token: token)), token)
    }

    func testDecodesTheSpecWorkedExample() throws {
        XCTAssertEqual(try PairingString.decode(specString), specToken)
    }

    func testToleratesHumanTranscription() throws {
        XCTAssertEqual(try PairingString.decode(specString.lowercased()), specToken)
        XCTAssertEqual(try PairingString.decode(specString.replacingOccurrences(of: "-", with: " ")), specToken)
        XCTAssertEqual(try PairingString.decode(specString.replacingOccurrences(of: "-", with: "")), specToken)
        XCTAssertEqual(try PairingString.decode("  \(specString)\n\t"), specToken)
        XCTAssertEqual(try PairingString.decode("AAAQ EAYE-aud aocaj/BIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPQ"), specToken)
    }

    func testRejectsWrongLength() {
        XCTAssertThrowsError(try PairingString.decode("AAAQEAYE")) { error in
            XCTAssertEqual(error as? PairingStringError, .wrongDecodedLength(5))
        }
        XCTAssertThrowsError(try PairingString.decode(specString + "AAAAAAAA")) { error in
            XCTAssertEqual(error as? PairingStringError, .wrongDecodedLength(37))
        }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try PairingString.decode("!!!!"))
        XCTAssertThrowsError(try PairingString.decode(""))
    }

    func testDoesNotMapConfusableCharacters() {
        // protocol-v1 §11.2: a typed `0` or `1` is DELETED, not corrected to O/I/L.
        // Deleting four characters from a valid string must therefore fail the
        // 32-byte length check rather than silently decode to a different token.
        let withConfusables = specString.replacingOccurrences(of: "A", with: "0")
        XCTAssertThrowsError(try PairingString.decode(withConfusables))
    }
}
```

Create `macos/SharedMicTests/AuthProofTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class AuthProofTests: XCTestCase {
    /// Known answers computed with the reference implementation:
    ///   harness/.venv/bin/python -c \
    ///     "import hmac,hashlib; print(hmac.new(bytes(range(32)), bytes(range(32)), hashlib.sha256).hexdigest())"
    func testProofMatchesReferenceHMACSHA256() {
        let sequentialToken = Data((0..<32).map { UInt8($0) })
        let sequentialNonce = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(
            AuthProof.proof(token: sequentialToken, nonce: sequentialNonce),
            "e8499be4f1980d68f13222a418df5cbd97d53fddf590c2108e22d40005b70713"
        )

        let zeros = Data(repeating: 0, count: 32)
        XCTAssertEqual(
            AuthProof.proof(token: zeros, nonce: zeros),
            "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"
        )

        let abNonce = Data(repeating: 0xab, count: 32)
        XCTAssertEqual(
            AuthProof.proof(token: sequentialToken, nonce: abNonce),
            "de295e728712be63b6352907b1f77cbb4437e815c00c17a7fcf86670b2141af1"
        )
    }

    func testProofIsLowercaseHex64Characters() {
        let proof = AuthProof.proof(token: Data(repeating: 7, count: 32), nonce: Data(repeating: 9, count: 32))
        XCTAssertEqual(proof.count, 64)
        XCTAssertEqual(proof, proof.lowercased())
        XCTAssertNotNil(Hex.decode(proof))
    }

    /// protocol-v1 §6: the HMAC is over the raw 32 nonce bytes, not over the
    /// 64-character hex string. Getting this wrong authenticates against nothing.
    func testProofIsOverRawNonceBytesNotTheHexString() {
        let token = Data(repeating: 0x5a, count: 32)
        let nonce = Data(repeating: 0xab, count: 32)
        let overRawBytes = AuthProof.proof(token: token, nonce: nonce)
        let overHexString = AuthProof.proof(token: token, nonce: Data(Hex.encode(nonce).utf8))
        XCTAssertNotEqual(overRawBytes, overHexString)
    }

    func testFingerprintIsLowercaseHexSHA256OfTheGivenBytes() {
        // SHA-256 of the empty input, the standard known answer.
        XCTAssertEqual(
            AuthProof.fingerprint(ofDER: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        let fingerprint = AuthProof.fingerprint(ofDER: Data([0x30, 0x82, 0x01]))
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertEqual(fingerprint, fingerprint.lowercased())
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/PairingStringTests -only-testing:SharedMicTests/AuthProofTests`
Expected: FAIL — compile error, `cannot find 'PairingString' in scope` and `cannot find 'AuthProof' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Security/Base32.swift`:

```swift
import Foundation

/// RFC 4648 base32 with the standard alphabet (`A`-`Z` then `2`-`7`).
///
/// Written by hand because Foundation has no base32. `encode` emits unpadded
/// uppercase output, which is what protocol-v1 §11.2 specifies for display;
/// `decode` expects input already filtered to the alphabet and tolerates the
/// missing padding, so 52 characters decode to 32 bytes with the 4 trailing bits
/// discarded exactly as `base64.b32decode` does after re-padding.
public enum Base32 {
    private static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    private static func value(of character: Character) -> UInt64? {
        if let ascii = character.asciiValue {
            switch ascii {
            case 0x41...0x5a: return UInt64(ascii - 0x41)          // A-Z -> 0-25
            case 0x32...0x37: return UInt64(ascii - 0x32) + 26     // 2-7 -> 26-31
            default: return nil
            }
        }
        return nil
    }

    public static func encode(_ data: Data) -> String {
        var output = String()
        output.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt64 = 0
        var bitsInBuffer = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bitsInBuffer += 8
            while bitsInBuffer >= 5 {
                let index = Int((buffer >> UInt64(bitsInBuffer - 5)) & 0x1f)
                output.append(alphabet[index])
                bitsInBuffer -= 5
            }
        }
        if bitsInBuffer > 0 {
            let index = Int((buffer << UInt64(5 - bitsInBuffer)) & 0x1f)
            output.append(alphabet[index])
        }
        return output
    }

    /// Returns nil if any character is outside the alphabet.
    public static func decode(_ text: String) -> Data? {
        var output = Data(capacity: text.count * 5 / 8)
        var buffer: UInt64 = 0
        var bitsInBuffer = 0
        for character in text {
            guard let symbol = value(of: character) else { return nil }
            buffer = (buffer << 5) | symbol
            bitsInBuffer += 5
            if bitsInBuffer >= 8 {
                output.append(UInt8((buffer >> UInt64(bitsInBuffer - 8)) & 0xff))
                bitsInBuffer -= 8
            }
        }
        return output
    }
}
```

Create `macos/SharedMic/Security/PairingString.swift`:

```swift
import Foundation

public enum PairingStringError: Error, Equatable {
    case invalidBase32
    case wrongDecodedLength(Int)
}

extension PairingStringError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalidBase32:
            return "That pairing string could not be decoded. Check it against the Windows tray and retype it."
        case .wrongDecodedLength(let count):
            return "That pairing string decodes to \(count) bytes; a valid one decodes to 32. It looks truncated or over-long."
        }
    }
}

/// protocol-v1 §11.2.
///
/// Display: base32 (RFC 4648), uppercase, unpadded, hyphen-grouped in runs of 8.
/// 32 bytes -> 52 characters + 6 hyphens = 58 characters.
///
/// Input: uppercase first, delete every character outside `[A-Z2-7]`, decode,
/// then require exactly 32 bytes. **No confusable-character mapping** — a typed
/// `0` or `1` is deleted, and the length check then rejects the result. Adding a
/// mapping here would accept strings the Windows implementation rejects.
public enum PairingString {
    private static let alphabet: Set<Character> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(token: Data) -> String {
        let raw = Base32.encode(token)
        var groups: [String] = []
        var index = raw.startIndex
        while index < raw.endIndex {
            let end = raw.index(index, offsetBy: SharedMicProtocol.pairingGroupSize,
                                limitedBy: raw.endIndex) ?? raw.endIndex
            groups.append(String(raw[index..<end]))
            index = end
        }
        return groups.joined(separator: "-")
    }

    public static func decode(_ text: String) throws -> Data {
        let cleaned = String(text.uppercased().filter { alphabet.contains($0) })
        guard !cleaned.isEmpty, let token = Base32.decode(cleaned) else {
            throw PairingStringError.invalidBase32
        }
        guard token.count == SharedMicProtocol.tokenBytes else {
            throw PairingStringError.wrongDecodedLength(token.count)
        }
        return token
    }
}
```

Create `macos/SharedMic/Security/AuthProof.swift`:

```swift
import CryptoKit
import Foundation

/// protocol-v1 §6 step 2 and §2.
///
/// The token is the HMAC key and never crosses the wire; only the per-connection
/// proof does. The nonce passed here is the **raw 32 bytes** decoded from the
/// GREETING's hex `nonce` field — HMAC over the hex string authenticates against
/// nothing and fails on every connection with an opaque error.
public enum AuthProof {
    public static func proof(token: Data, nonce: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: token))
        return Hex.encode(Data(code))
    }

    /// The pinned value: lowercase hex SHA-256 over the certificate's DER encoding.
    public static func fingerprint(ofDER der: Data) -> String {
        Hex.encode(Data(SHA256.hash(data: der)))
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/PairingStringTests -only-testing:SharedMicTests/AuthProofTests`
Expected: PASS — `** TEST SUCCEEDED **`, 13 test cases.

Optionally cross-check the pairing string against the reference implementation:

```sh
harness/.venv/bin/python -c "import sys; sys.path.insert(0,'harness'); from sharedmic_protocol.auth import encode_pairing_string; print(encode_pairing_string(bytes(range(32))))"
```
Expected output: `AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ`

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Security macos/SharedMicTests/PairingStringTests.swift macos/SharedMicTests/AuthProofTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): pairing string codec and HMAC-SHA256 auth proof

RFC 4648 base32 (uppercase, unpadded, grouped in 8s), tolerant decoding that
deletes rather than remaps out-of-alphabet characters, a hard 32-byte length
check, and the HMAC proof computed over the raw nonce bytes. Verified against
the protocol-v1 §11.2 worked example and reference HMAC known answers.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: Keychain-backed pairing store

**Files:**
- Create: `macos/SharedMic/Security/PairingStore.swift`
- Test: `macos/SharedMicTests/PairingStoreTests.swift`

**Interfaces:**
- Consumes: `Hex` (Task 1), `SharedMicProtocol.defaultPort` / `.tokenBytes` (Task 1).
- Produces:
  - `public struct PairingRecord: Equatable { public let host: String; public let port: UInt16; public let token: Data; public let certificateFingerprint: String }` with `init(host:port:token:certificateFingerprint:)`
  - `public protocol PairingStore: AnyObject { func save(_ record: PairingRecord) throws; func load() throws -> PairingRecord?; func clear() throws }`
  - `public final class InMemoryPairingStore: PairingStore` with `init()`
  - `public enum KeychainError: Error, Equatable { case unexpectedStatus(OSStatus); case corruptRecord }`
  - `public final class KeychainPairingStore: PairingStore` with `init(service: String = "com.sharedmic.SharedMic.pairing", account: String = "default")`

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/PairingStoreTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class PairingStoreTests: XCTestCase {
    private func sampleRecord() -> PairingRecord {
        PairingRecord(
            host: "192.168.1.42",
            port: 47_800,
            token: Data((0..<32).map { UInt8($0) }),
            certificateFingerprint: String(repeating: "ab", count: 32)
        )
    }

    // MARK: - In-memory

    func testInMemoryStoreStartsEmpty() throws {
        let store = InMemoryPairingStore()
        XCTAssertNil(try store.load())
    }

    func testInMemoryStoreRoundTrips() throws {
        let store = InMemoryPairingStore()
        let record = sampleRecord()
        try store.save(record)
        XCTAssertEqual(try store.load(), record)
    }

    func testInMemoryStoreClears() throws {
        let store = InMemoryPairingStore()
        try store.save(sampleRecord())
        try store.clear()
        XCTAssertNil(try store.load())
    }

    // MARK: - Keychain

    private var keychainService: String!

    override func setUp() {
        super.setUp()
        keychainService = "com.sharedmic.tests.\(UUID().uuidString)"
    }

    override func tearDown() {
        if let service = keychainService {
            try? KeychainPairingStore(service: service, account: "default").clear()
        }
        super.tearDown()
    }

    func testKeychainStoreStartsEmpty() throws {
        let store = KeychainPairingStore(service: keychainService, account: "default")
        XCTAssertNil(try store.load())
    }

    func testKeychainStoreRoundTrips() throws {
        let store = KeychainPairingStore(service: keychainService, account: "default")
        let record = sampleRecord()
        try store.save(record)
        let loaded = try XCTUnwrap(try store.load())
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded.token.count, SharedMicProtocol.tokenBytes)
    }

    func testKeychainSaveOverwritesRatherThanDuplicating() throws {
        let store = KeychainPairingStore(service: keychainService, account: "default")
        try store.save(sampleRecord())
        let replacement = PairingRecord(
            host: "10.0.0.9",
            port: 47_801,
            token: Data(repeating: 0x7f, count: 32),
            certificateFingerprint: String(repeating: "cd", count: 32)
        )
        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)
    }

    func testKeychainClearRemovesTheItemAndIsIdempotent() throws {
        let store = KeychainPairingStore(service: keychainService, account: "default")
        try store.save(sampleRecord())
        try store.clear()
        XCTAssertNil(try store.load())
        XCTAssertNoThrow(try store.clear())
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/PairingStoreTests`
Expected: FAIL — compile error, `cannot find type 'PairingRecord' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Security/PairingStore.swift`:

```swift
import Foundation
import Security

/// Everything pairing established: where the Windows agent is, the shared token
/// (protocol-v1 §11.1), and the pinned certificate fingerprint (§2).
public struct PairingRecord: Equatable {
    public let host: String
    public let port: UInt16
    public let token: Data
    public let certificateFingerprint: String

    public init(host: String, port: UInt16, token: Data, certificateFingerprint: String) {
        self.host = host
        self.port = port
        self.token = token
        self.certificateFingerprint = certificateFingerprint.lowercased()
    }
}

public protocol PairingStore: AnyObject {
    func save(_ record: PairingRecord) throws
    func load() throws -> PairingRecord?
    func clear() throws
}

/// Test double. Never used by the shipping app.
public final class InMemoryPairingStore: PairingStore {
    private var record: PairingRecord?
    private let lock = NSLock()

    public init() {}

    public func save(_ record: PairingRecord) throws {
        lock.lock(); defer { lock.unlock() }
        self.record = record
    }

    public func load() throws -> PairingRecord? {
        lock.lock(); defer { lock.unlock() }
        return record
    }

    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        record = nil
    }
}

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case corruptRecord
}

/// Design spec §7.1: the Mac stores the token and the pinned fingerprint in the
/// Keychain.
///
/// Serialized as a small JSON object in a single `kSecClassGenericPassword` item
/// so the whole record is written and read atomically — a half-updated pairing
/// (new token, old fingerprint) would be indistinguishable from an attack.
/// The token is stored hex-encoded inside that blob and is never logged.
public final class KeychainPairingStore: PairingStore {
    private let service: String
    private let account: String

    public init(service: String = "com.sharedmic.SharedMic.pairing",
                account: String = "default") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func save(_ record: PairingRecord) throws {
        let payload: [String: Any] = [
            "host": record.host,
            "port": Int(record.port),
            "tokenHex": Hex.encode(record.token),
            "certificateFingerprint": record.certificateFingerprint
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])

        // Delete-then-add keeps save idempotent and avoids a partial update.
        SecItemDelete(baseQuery as CFDictionary)

        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrDescription as String] = "SharedMic pairing"

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public func load() throws -> PairingRecord? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = object["host"] as? String,
              let port = (object["port"] as? NSNumber)?.intValue,
              let tokenHex = object["tokenHex"] as? String,
              let token = Hex.decode(tokenHex),
              token.count == SharedMicProtocol.tokenBytes,
              let fingerprint = object["certificateFingerprint"] as? String else {
            throw KeychainError.corruptRecord
        }
        return PairingRecord(host: host,
                             port: UInt16(truncatingIfNeeded: port),
                             token: token,
                             certificateFingerprint: fingerprint)
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/PairingStoreTests`
Expected: PASS — `** TEST SUCCEEDED **`, 7 test cases. (The Keychain tests use a per-run random service name and delete it in `tearDown`, so repeated runs leave nothing behind. They require an unlocked login keychain; on a locked one they fail with `unexpectedStatus(-25308)` — unlock and rerun.)

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Security/PairingStore.swift macos/SharedMicTests/PairingStoreTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): Keychain-backed pairing store

Host, port, 256-bit token and pinned certificate fingerprint written atomically
as one generic-password item, with an in-memory double for tests. The token is
hex-encoded inside the blob and never logged.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Connection-health primitives — reconnect backoff and heartbeat monitor

Two small pure types with injected randomness and an injected clock, so the 15 s / 45 s / 30 s behaviour is tested in microseconds instead of minutes.

**Files:**
- Create: `macos/SharedMic/Session/ReconnectPolicy.swift`, `macos/SharedMic/Session/HeartbeatMonitor.swift`
- Test: `macos/SharedMicTests/ReconnectPolicyTests.swift`, `macos/SharedMicTests/HeartbeatMonitorTests.swift`

**Interfaces:**
- Consumes: `SharedMicProtocol.reconnectInitialDelay` / `.reconnectMaxDelay` / `.reconnectJitterFraction` / `.pingInterval` / `.peerDeadTimeout` (Task 1); `ControlMessage` (Task 3).
- Produces:
  - `public struct ReconnectPolicy` — `init(initialDelay:maxDelay:jitterFraction:)`, `var attemptCount: Int { get }`, `mutating func nextDelay(randomFraction: Double) -> TimeInterval`, `mutating func nextDelay() -> TimeInterval`, `mutating func reset()`
  - `public enum HeartbeatError: Error, Equatable { case unexpectedPongSequence(Int) }`
  - `public struct HeartbeatMonitor` — `init(now: TimeInterval)`, `var lastPongAt: TimeInterval { get }`, `var outstandingCount: Int { get }`, `mutating func makePing(now: TimeInterval) -> ControlMessage`, `mutating func handlePong(seq: Int, now: TimeInterval) throws`, `func shouldSendPing(now: TimeInterval, interval: TimeInterval) -> Bool`, `func isPeerDead(now: TimeInterval, timeout: TimeInterval) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/ReconnectPolicyTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class ReconnectPolicyTests: XCTestCase {
    func testDefaultsMatchTheSpec() {
        let policy = ReconnectPolicy()
        XCTAssertEqual(policy.initialDelay, 0.5)
        XCTAssertEqual(policy.maxDelay, 30.0)
        XCTAssertEqual(policy.attemptCount, 0)
    }

    /// randomFraction 0.5 is the centre of the jitter window, so the sequence is
    /// the undisturbed exponential curve: 0.5, 1, 2, 4, 8, 16, then the 30 s cap.
    func testDoublesFromHalfASecondAndCapsAtThirty() {
        var policy = ReconnectPolicy()
        var delays: [TimeInterval] = []
        for _ in 0..<9 {
            delays.append(policy.nextDelay(randomFraction: 0.5))
        }
        XCTAssertEqual(delays, [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0])
        XCTAssertEqual(policy.attemptCount, 9)
    }

    func testJitterStaysWithinTwentyPercentOfTheBase() {
        var low = ReconnectPolicy()
        XCTAssertEqual(low.nextDelay(randomFraction: 0.0), 0.4, accuracy: 1e-9)
        var high = ReconnectPolicy()
        XCTAssertEqual(high.nextDelay(randomFraction: 1.0), 0.6, accuracy: 1e-9)
    }

    func testJitteredDelaysAreNeverNegativeAndNeverExceedTheCapWindow() {
        var policy = ReconnectPolicy()
        for _ in 0..<40 {
            let delay = policy.nextDelay()
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 30.0 * 1.2)
        }
    }

    func testResetReturnsToTheInitialDelay() {
        var policy = ReconnectPolicy()
        _ = policy.nextDelay(randomFraction: 0.5)
        _ = policy.nextDelay(randomFraction: 0.5)
        policy.reset()
        XCTAssertEqual(policy.attemptCount, 0)
        XCTAssertEqual(policy.nextDelay(randomFraction: 0.5), 0.5)
    }

    func testLongRunOfFailuresDoesNotOverflow() {
        var policy = ReconnectPolicy()
        for _ in 0..<10_000 {
            _ = policy.nextDelay(randomFraction: 0.5)
        }
        XCTAssertEqual(policy.nextDelay(randomFraction: 0.5), 30.0)
    }
}
```

Create `macos/SharedMicTests/HeartbeatMonitorTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class HeartbeatMonitorTests: XCTestCase {
    func testPingSequenceStartsAtOneAndIncrements() {
        var monitor = HeartbeatMonitor(now: 0)
        XCTAssertEqual(monitor.makePing(now: 0), .ping(seq: 1))
        XCTAssertEqual(monitor.makePing(now: 15), .ping(seq: 2))
        XCTAssertEqual(monitor.makePing(now: 30), .ping(seq: 3))
    }

    func testMatchingPongClearsTheOutstandingPing() throws {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        XCTAssertEqual(monitor.outstandingCount, 1)
        try monitor.handlePong(seq: 1, now: 15.2)
        XCTAssertEqual(monitor.outstandingCount, 0)
        XCTAssertEqual(monitor.lastPongAt, 15.2)
    }

    /// protocol-v1 §5: a PONG's seq MUST equal the seq of the PING it answers.
    func testUnknownPongSequenceIsAProtocolViolation() {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        XCTAssertThrowsError(try monitor.handlePong(seq: 99, now: 15.1)) { error in
            XCTAssertEqual(error as? HeartbeatError, .unexpectedPongSequence(99))
        }
    }

    func testDuplicatePongIsAlsoRejected() throws {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        try monitor.handlePong(seq: 1, now: 15.1)
        XCTAssertThrowsError(try monitor.handlePong(seq: 1, now: 15.2)) { error in
            XCTAssertEqual(error as? HeartbeatError, .unexpectedPongSequence(1))
        }
    }

    func testALatePongClearsEveryOlderOutstandingPing() throws {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        _ = monitor.makePing(now: 30)
        _ = monitor.makePing(now: 45)
        XCTAssertEqual(monitor.outstandingCount, 3)
        try monitor.handlePong(seq: 3, now: 45.1)
        XCTAssertEqual(monitor.outstandingCount, 0)
    }

    func testShouldSendPingEveryFifteenSeconds() {
        var monitor = HeartbeatMonitor(now: 0)
        XCTAssertFalse(monitor.shouldSendPing(now: 14.9, interval: SharedMicProtocol.pingInterval))
        XCTAssertTrue(monitor.shouldSendPing(now: 15.0, interval: SharedMicProtocol.pingInterval))
        _ = monitor.makePing(now: 15.0)
        XCTAssertFalse(monitor.shouldSendPing(now: 29.9, interval: SharedMicProtocol.pingInterval))
        XCTAssertTrue(monitor.shouldSendPing(now: 30.0, interval: SharedMicProtocol.pingInterval))
    }

    func testPeerIsDeclaredDeadAfterFortyFiveSecondsWithoutAPong() throws {
        var monitor = HeartbeatMonitor(now: 0)
        XCTAssertFalse(monitor.isPeerDead(now: 44.9, timeout: SharedMicProtocol.peerDeadTimeout))
        XCTAssertTrue(monitor.isPeerDead(now: 45.0, timeout: SharedMicProtocol.peerDeadTimeout))

        _ = monitor.makePing(now: 15)
        try monitor.handlePong(seq: 1, now: 15.1)
        XCTAssertFalse(monitor.isPeerDead(now: 60.0, timeout: SharedMicProtocol.peerDeadTimeout))
        XCTAssertTrue(monitor.isPeerDead(now: 60.2, timeout: SharedMicProtocol.peerDeadTimeout))
    }

    func testThreeMissedHeartbeatsIsExactlyWhatFortyFiveSecondsMeans() {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        _ = monitor.makePing(now: 30)
        _ = monitor.makePing(now: 45)
        XCTAssertEqual(monitor.outstandingCount, 3)
        XCTAssertTrue(monitor.isPeerDead(now: 45.0, timeout: SharedMicProtocol.peerDeadTimeout))
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/ReconnectPolicyTests -only-testing:SharedMicTests/HeartbeatMonitorTests`
Expected: FAIL — compile error, `cannot find type 'ReconnectPolicy' in scope` and `cannot find type 'HeartbeatMonitor' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Session/ReconnectPolicy.swift`:

```swift
import Foundation

/// Design spec §4.3: the Mac reconnects with exponential backoff from 0.5 s to a
/// 30 s cap, jittered.
///
/// Randomness is injected rather than sampled internally so the curve is testable
/// exactly. `nextDelay()` is the convenience that samples for real callers.
public struct ReconnectPolicy {
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterFraction: Double

    private var attempt: Int = 0

    public init(initialDelay: TimeInterval = SharedMicProtocol.reconnectInitialDelay,
                maxDelay: TimeInterval = SharedMicProtocol.reconnectMaxDelay,
                jitterFraction: Double = SharedMicProtocol.reconnectJitterFraction) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
    }

    public var attemptCount: Int { attempt }

    /// - Parameter randomFraction: uniform in `0...1`. 0.5 yields the undisturbed
    ///   base delay; 0 and 1 yield the edges of the jitter window.
    public mutating func nextDelay(randomFraction: Double) -> TimeInterval {
        // Clamp the exponent before shifting: 2^62 already exceeds any cap, and
        // an unclamped exponent overflows after ~1000 failed attempts.
        let exponent = min(attempt, 32)
        let base = min(initialDelay * pow(2.0, Double(exponent)), maxDelay)
        attempt += 1
        let clamped = min(max(randomFraction, 0.0), 1.0)
        let multiplier = (1.0 - jitterFraction) + (2.0 * jitterFraction * clamped)
        return base * multiplier
    }

    public mutating func nextDelay() -> TimeInterval {
        nextDelay(randomFraction: Double.random(in: 0...1))
    }

    /// Called after a connection reaches HELLO_ACK, not merely after TCP connects —
    /// a peer that accepts the socket and then fails authentication is not a
    /// success and must not reset the curve.
    public mutating func reset() {
        attempt = 0
    }
}
```

Create `macos/SharedMic/Session/HeartbeatMonitor.swift`:

```swift
import Foundation

public enum HeartbeatError: Error, Equatable {
    case unexpectedPongSequence(Int)
}

/// protocol-v1 §8: the Mac sends PING every 15 s and declares the connection dead
/// after 45 s without a PONG (three missed heartbeats).
///
/// Pure, with an injected monotonic clock in seconds. The owning connection calls
/// `shouldSendPing`/`isPeerDead` on a timer tick and feeds PONGs back in.
public struct HeartbeatMonitor {
    private var nextSequence: Int = 1
    private var outstanding: [Int] = []
    private var lastPingSentAt: TimeInterval
    private(set) public var lastPongAt: TimeInterval

    public init(now: TimeInterval) {
        lastPingSentAt = now
        lastPongAt = now
    }

    public var outstandingCount: Int { outstanding.count }

    public mutating func makePing(now: TimeInterval) -> ControlMessage {
        let sequence = nextSequence
        nextSequence += 1
        outstanding.append(sequence)
        lastPingSentAt = now
        return .ping(seq: sequence)
    }

    /// A PONG whose `seq` matches no outstanding PING is a protocol violation
    /// (protocol-v1 §5) — including a repeat of one already answered.
    public mutating func handlePong(seq: Int, now: TimeInterval) throws {
        guard outstanding.contains(seq) else {
            throw HeartbeatError.unexpectedPongSequence(seq)
        }
        // A PONG implicitly acknowledges every earlier PING: the peer answered a
        // later one, so the earlier ones can never usefully arrive.
        outstanding.removeAll { $0 <= seq }
        lastPongAt = now
    }

    public func shouldSendPing(now: TimeInterval,
                               interval: TimeInterval = SharedMicProtocol.pingInterval) -> Bool {
        now - lastPingSentAt >= interval
    }

    public func isPeerDead(now: TimeInterval,
                           timeout: TimeInterval = SharedMicProtocol.peerDeadTimeout) -> Bool {
        now - lastPongAt >= timeout
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/ReconnectPolicyTests -only-testing:SharedMicTests/HeartbeatMonitorTests`
Expected: PASS — `** TEST SUCCEEDED **`, 14 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Session/ReconnectPolicy.swift macos/SharedMic/Session/HeartbeatMonitor.swift macos/SharedMicTests/ReconnectPolicyTests.swift macos/SharedMicTests/HeartbeatMonitorTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): jittered reconnect backoff and heartbeat monitor

Pure units with injected randomness and an injected clock: 0.5s->30s capped
exponential backoff with +/-20% jitter, and 15s PING scheduling with strict
PONG sequence matching and 45s dead-peer detection.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Session state machine (pure)

The one place the phase's lifecycle rules live: `START`/`STOP` idempotency, the 2 s / 1 s timeouts, `STATUS` handling, the "another Mac is using the mic" state, and — most importantly — that a fingerprint mismatch produces a terminal state with **no** reconnect action.

**The Python mock never produces a `SESSION_IN_USE`.** It gives every connection its own session, so the `sessionInUse` paths below are reachable only from these pure unit tests and from `AppModelTests` (Task 14) driving the controller directly. Do not expect the Task 13 integration tests to cover them; they cannot.

**Files:**
- Create: `macos/SharedMic/Session/SessionController.swift`
- Test: `macos/SharedMicTests/SessionControllerTests.swift`

**Interfaces:**
- Consumes: `SharedMicProtocol.startTimeout` / `.stopTimeout` (Task 1).
- Produces:
  - `public enum AgentState: Equatable` — `unpaired`, `disconnected`, `connecting`, `idle`, `starting(requestId: String)`, `streaming(sessionId: String)`, `stopping(requestId: String, sessionId: String)`, `sessionInUse(holderName: String?)`, `degraded(reason: String)`, `hardStop(reason: String)`; plus `var displayName: String`
  - `public enum SessionEvent: Equatable` — `paired`, `connectAttemptStarted`, `authenticated(micPresent: Bool, deviceLabel: String)`, `userRequestedStart(requestId: String)`, `startAcked(requestId: String, sessionId: String)`, `startNacked(requestId: String, reason: String, holderName: String?)`, `startTimedOut(requestId: String)`, `userRequestedStop(requestId: String)`, `stopAcked(requestId: String)`, `stopTimedOut(requestId: String)`, `statusReceived(micPresent: Bool, active: Bool, deviceLabel: String)`, `connectionLost(reason: String)`, `fingerprintMismatch(expected: String, presented: String)`, `unpairedByUser`

`sessionInUse` is **not an error state**. The connection is authenticated, healthy and heartbeating; this Mac simply does not have the microphone. It is distinct from `degraded` (which means something is wrong) and from `idle` (which means "Start would probably work"), and its `displayName` is what the menu bar shows: `In use by Mac Studio`, or `In use by another Mac` when the advisory `holderName` is absent.

Leaving `sessionInUse` has exactly three routes, because version 1 has no "the mic is free now" message: the user tries Start again (which retries and may now succeed), a `STATUS` arrives saying nothing is active, or the connection changes state. Nothing polls.
  - `public enum SessionAction: Equatable` — `sendStart(requestId: String)`, `sendStop(requestId: String, sessionId: String)`, `armStartTimeout(requestId: String, seconds: TimeInterval)`, `armStopTimeout(requestId: String, seconds: TimeInterval)`, `scheduleReconnect`, `closeConnection`, `warnFingerprintMismatch(expected: String, presented: String)`, `notify(String)`
  - `public struct SessionController` — `init(state: AgentState = .unpaired)`, `var state: AgentState { get }`, `var micPresent: Bool { get }`, `var deviceLabel: String { get }`, `var activeSessionId: String? { get }`, `mutating func handle(_ event: SessionEvent) -> [SessionAction]`

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/SessionControllerTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class SessionControllerTests: XCTestCase {

    /// Drives a controller to an authenticated, mic-present idle state.
    private func authenticatedController() -> SessionController {
        var controller = SessionController()
        _ = controller.handle(.paired)
        _ = controller.handle(.connectAttemptStarted)
        _ = controller.handle(.authenticated(micPresent: true, deviceLabel: "USB Microphone"))
        return controller
    }

    func testStartsUnpaired() {
        let controller = SessionController()
        XCTAssertEqual(controller.state, .unpaired)
        XCTAssertNil(controller.activeSessionId)
    }

    func testPairingMovesToDisconnected() {
        var controller = SessionController()
        XCTAssertEqual(controller.handle(.paired), [])
        XCTAssertEqual(controller.state, .disconnected)
    }

    func testAuthenticationMovesToIdleAndRecordsMicState() {
        var controller = authenticatedController()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.micPresent)
        XCTAssertEqual(controller.deviceLabel, "USB Microphone")
        _ = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        XCTAssertFalse(controller.micPresent)
    }

    func testStartSendsStartAndArmsTheTwoSecondTimeout() {
        var controller = authenticatedController()
        let actions = controller.handle(.userRequestedStart(requestId: "req-1"))
        XCTAssertEqual(actions, [
            .sendStart(requestId: "req-1"),
            .armStartTimeout(requestId: "req-1", seconds: 2.0)
        ])
        XCTAssertEqual(controller.state, .starting(requestId: "req-1"))
    }

    func testStartAckMovesToStreamingAndExposesTheSessionId() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        XCTAssertEqual(controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1")), [])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
        XCTAssertEqual(controller.activeSessionId, "sess-1")
    }

    func testDuplicateStartWhileStreamingIsANoOp() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        XCTAssertEqual(controller.handle(.userRequestedStart(requestId: "req-2")), [])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
    }

    func testStartWhileMicAbsentIsRefusedLocally() {
        var controller = authenticatedController()
        _ = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        let actions = controller.handle(.userRequestedStart(requestId: "req-1"))
        XCTAssertEqual(actions, [.notify("The Windows microphone is unavailable.")])
        XCTAssertEqual(controller.state, .idle)
    }

    func testStartNackReturnsToIdleWithTheReason() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        let actions = controller.handle(.startNacked(requestId: "req-1", reason: "MIC_UNAVAILABLE", holderName: nil))
        XCTAssertEqual(actions, [.notify("Start refused: MIC_UNAVAILABLE")])
        XCTAssertEqual(controller.state, .idle)
    }

    /// Several Macs share one Windows microphone. Being refused because another
    /// one has it is an ordinary, expected outcome — a distinct state with the
    /// holder's name in it, not a generic failure notice.
    func testSessionInUseIsItsOwnStateNamingTheHolder() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        let actions = controller.handle(
            .startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "Mac Studio")
        )
        XCTAssertEqual(actions, [.notify("The microphone is in use by Mac Studio.")])
        XCTAssertEqual(controller.state, .sessionInUse(holderName: "Mac Studio"))
        XCTAssertEqual(controller.state.displayName, "In use by Mac Studio")
        XCTAssertNil(controller.activeSessionId)
    }

    /// protocol-v1 §5: `holderName` is advisory and may be absent. The UI must not
    /// render "In use by " with nothing after it.
    func testSessionInUseWithoutAHolderNameSaysAnotherMac() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        let actions = controller.handle(
            .startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: nil)
        )
        XCTAssertEqual(actions, [.notify("The microphone is in use by another Mac.")])
        XCTAssertEqual(controller.state, .sessionInUse(holderName: nil))
        XCTAssertEqual(controller.state.displayName, "In use by another Mac")
    }

    /// A blank name is as useless as a missing one and must be treated the same.
    func testABlankHolderNameIsTreatedAsAbsent() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "   "))
        XCTAssertEqual(controller.state, .sessionInUse(holderName: nil))
        XCTAssertEqual(controller.state.displayName, "In use by another Mac")
    }

    /// There is no "the mic is free now" message in version 1, so retrying is
    /// how this Mac finds out. Start must therefore be allowed from this state.
    func testStartCanBeRetriedFromSessionInUse() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "Mac Studio"))

        let actions = controller.handle(.userRequestedStart(requestId: "req-2"))

        XCTAssertEqual(actions, [
            .sendStart(requestId: "req-2"),
            .armStartTimeout(requestId: "req-2", seconds: 2.0)
        ])
        XCTAssertEqual(controller.state, .starting(requestId: "req-2"))

        _ = controller.handle(.startAcked(requestId: "req-2", sessionId: "sess-9"))
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-9"))
    }

    /// A refusal is not a broken connection. Nothing is closed and nothing is
    /// reconnected — this Mac stays authenticated and keeps heartbeating.
    func testSessionInUseEmitsNoTeardownOrReconnectAction() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        let actions = controller.handle(
            .startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "Mac Studio")
        )
        XCTAssertFalse(actions.contains(.closeConnection))
        XCTAssertFalse(actions.contains(.scheduleReconnect))
    }

    /// If Windows ever does report an idle microphone while this Mac is waiting,
    /// stop claiming someone else has it.
    func testAnIdleStatusClearsSessionInUse() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "Mac Studio"))

        let actions = controller.handle(
            .statusReceived(micPresent: true, active: false, deviceLabel: "USB Microphone")
        )

        XCTAssertEqual(actions, [])
        XCTAssertEqual(controller.state, .idle)
    }

    /// ...but a STATUS that says the mic is still busy must not.
    func testAnActiveStatusLeavesSessionInUseAlone() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "Mac Studio"))

        _ = controller.handle(.statusReceived(micPresent: true, active: true, deviceLabel: "USB Microphone"))

        XCTAssertEqual(controller.state, .sessionInUse(holderName: "Mac Studio"))
    }

    func testLosingTheConnectionClearsSessionInUse() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "Mac Studio"))

        let actions = controller.handle(.connectionLost(reason: "peer dead"))

        XCTAssertEqual(actions, [.scheduleReconnect])
        XCTAssertEqual(controller.state, .disconnected)
    }

    /// A NACK for a request this Mac is no longer waiting on changes nothing.
    func testAStaleSessionInUseNackIsIgnored() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))

        let actions = controller.handle(
            .startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "Mac Studio")
        )

        XCTAssertEqual(actions, [])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
    }

    /// protocol-v1 §8: a START that goes unanswered for 2 s means a failed or dead
    /// peer — not something to keep waiting on.
    func testStartTimeoutTearsDownAndReconnects() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        let actions = controller.handle(.startTimedOut(requestId: "req-1"))
        XCTAssertEqual(actions, [.closeConnection, .scheduleReconnect])
        XCTAssertEqual(controller.state, .degraded(reason: "The Windows agent did not answer START within 2 s."))
    }

    func testStaleStartTimeoutIsIgnored() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        XCTAssertEqual(controller.handle(.startTimedOut(requestId: "req-1")), [])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
    }

    func testStopSendsStopWithTheActiveSessionIdAndArmsTheOneSecondTimeout() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        let actions = controller.handle(.userRequestedStop(requestId: "req-2"))
        XCTAssertEqual(actions, [
            .sendStop(requestId: "req-2", sessionId: "sess-1"),
            .armStopTimeout(requestId: "req-2", seconds: 1.0)
        ])
        XCTAssertEqual(controller.state, .stopping(requestId: "req-2", sessionId: "sess-1"))
    }

    /// protocol-v1 §7: a STOP with no session active still succeeds, and its
    /// sessionId MAY be an empty string.
    func testStopWhileIdleSendsStopWithAnEmptySessionId() {
        var controller = authenticatedController()
        let actions = controller.handle(.userRequestedStop(requestId: "req-9"))
        XCTAssertEqual(actions, [
            .sendStop(requestId: "req-9", sessionId: ""),
            .armStopTimeout(requestId: "req-9", seconds: 1.0)
        ])
        XCTAssertEqual(controller.state, .stopping(requestId: "req-9", sessionId: ""))
    }

    func testStopAckReturnsToIdleAndClearsTheSession() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        _ = controller.handle(.userRequestedStop(requestId: "req-2"))
        XCTAssertEqual(controller.handle(.stopAcked(requestId: "req-2")), [])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeSessionId)
    }

    /// protocol-v1 §8: treat the session as ended locally regardless; do not block
    /// on a STOP_ACK that may never arrive.
    func testStopTimeoutEndsTheSessionLocallyWithoutTearingDownTheConnection() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        _ = controller.handle(.userRequestedStop(requestId: "req-2"))
        let actions = controller.handle(.stopTimedOut(requestId: "req-2"))
        XCTAssertEqual(actions, [.notify("STOP went unanswered; the session is treated as ended.")])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeSessionId)
    }

    func testMicUnplugMidSessionEntersDegradedAndNotifies() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        let actions = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        XCTAssertEqual(actions, [.notify("The Windows microphone was disconnected.")])
        XCTAssertEqual(controller.state, .degraded(reason: "The Windows microphone was disconnected."))
        XCTAssertNil(controller.activeSessionId)
    }

    func testMicUnplugWhileIdleStaysConnectedAndSilent() {
        var controller = authenticatedController()
        let actions = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.micPresent)
    }

    func testMicReplugRecoversFromDegraded() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        _ = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        let actions = controller.handle(.statusReceived(micPresent: true, active: false, deviceLabel: "USB Microphone"))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.micPresent)
    }

    func testConnectionLossSchedulesAReconnectAndDropsTheSession() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        let actions = controller.handle(.connectionLost(reason: "peer dead"))
        XCTAssertEqual(actions, [.scheduleReconnect])
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.activeSessionId)
    }

    /// The load-bearing test of this whole phase: protocol-v1 §2 and design spec
    /// §7.3 forbid any automatic recovery from a pinned-fingerprint mismatch.
    func testFingerprintMismatchIsATerminalHardStopWithNoReconnect() {
        var controller = authenticatedController()
        let actions = controller.handle(.fingerprintMismatch(expected: "aa", presented: "bb"))
        XCTAssertEqual(actions, [
            .closeConnection,
            .warnFingerprintMismatch(expected: "aa", presented: "bb")
        ])
        XCTAssertFalse(actions.contains(.scheduleReconnect))
        XCTAssertEqual(controller.state, .hardStop(reason: "The Windows agent presented a different certificate than the one paired. Re-pair explicitly to continue."))
    }

    func testHardStopSwallowsEveryEventExceptAnExplicitRePair() {
        var controller = authenticatedController()
        _ = controller.handle(.fingerprintMismatch(expected: "aa", presented: "bb"))
        let hardStop = controller.state

        for event: SessionEvent in [
            .connectAttemptStarted,
            .connectionLost(reason: "whatever"),
            .userRequestedStart(requestId: "req-1"),
            .userRequestedStop(requestId: "req-2"),
            .statusReceived(micPresent: true, active: false, deviceLabel: "USB Microphone"),
            .authenticated(micPresent: true, deviceLabel: "USB Microphone")
        ] {
            XCTAssertEqual(controller.handle(event), [], "hard stop leaked an action for \(event)")
            XCTAssertEqual(controller.state, hardStop, "hard stop left the terminal state for \(event)")
        }

        XCTAssertEqual(controller.handle(.paired), [])
        XCTAssertEqual(controller.state, .disconnected)
    }

    func testUnpairingClosesTheConnection() {
        var controller = authenticatedController()
        XCTAssertEqual(controller.handle(.unpairedByUser), [.closeConnection])
        XCTAssertEqual(controller.state, .unpaired)
    }

    func testDisplayNamesCoverTheObservabilityStates() {
        XCTAssertEqual(AgentState.disconnected.displayName, "Disconnected")
        XCTAssertEqual(AgentState.idle.displayName, "Idle")
        XCTAssertEqual(AgentState.starting(requestId: "r").displayName, "Starting")
        XCTAssertEqual(AgentState.streaming(sessionId: "s").displayName, "Streaming")
        XCTAssertEqual(AgentState.sessionInUse(holderName: "Mac Studio").displayName, "In use by Mac Studio")
        XCTAssertEqual(AgentState.sessionInUse(holderName: nil).displayName, "In use by another Mac")
        XCTAssertEqual(AgentState.degraded(reason: "x").displayName, "Degraded")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/SessionControllerTests`
Expected: FAIL — compile error, `cannot find type 'SessionController' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Session/SessionController.swift`:

```swift
import Foundation

/// Observability spec §11 names the states the UI must show. Phase 1 implements
/// every one except `Disabled` and `Held`, which are the Phase 3 kill switch and
/// force-on hold.
public enum AgentState: Equatable {
    case unpaired
    case disconnected
    case connecting
    case idle
    case starting(requestId: String)
    case streaming(sessionId: String)
    case stopping(requestId: String, sessionId: String)
    /// Another paired Mac holds the Windows microphone. NOT an error: this Mac
    /// is authenticated, healthy and heartbeating; it just does not have the
    /// mic. `holderName` is the advisory name from START_NACK and may be nil.
    case sessionInUse(holderName: String?)
    case degraded(reason: String)
    /// Terminal until the user re-pairs. Reached only by a pinned-fingerprint
    /// mismatch, which protocol-v1 §2 forbids recovering from automatically.
    case hardStop(reason: String)

    public var displayName: String {
        switch self {
        case .unpaired: return "Not paired"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .streaming: return "Streaming"
        case .stopping: return "Stopping"
        case .sessionInUse(let holderName):
            // The advisory name may be absent or empty; "In use by " with
            // nothing after it is not an acceptable thing to put in a menu bar.
            guard let holderName, !holderName.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "In use by another Mac"
            }
            return "In use by \(holderName)"
        case .degraded: return "Degraded"
        case .hardStop: return "Certificate mismatch"
        }
    }
}

public enum SessionEvent: Equatable {
    case paired
    case connectAttemptStarted
    case authenticated(micPresent: Bool, deviceLabel: String)
    case userRequestedStart(requestId: String)
    case startAcked(requestId: String, sessionId: String)
    case startNacked(requestId: String, reason: String, holderName: String?)
    case startTimedOut(requestId: String)
    case userRequestedStop(requestId: String)
    case stopAcked(requestId: String)
    case stopTimedOut(requestId: String)
    case statusReceived(micPresent: Bool, active: Bool, deviceLabel: String)
    case connectionLost(reason: String)
    case fingerprintMismatch(expected: String, presented: String)
    case unpairedByUser
}

public enum SessionAction: Equatable {
    case sendStart(requestId: String)
    case sendStop(requestId: String, sessionId: String)
    case armStartTimeout(requestId: String, seconds: TimeInterval)
    case armStopTimeout(requestId: String, seconds: TimeInterval)
    case scheduleReconnect
    case closeConnection
    case warnFingerprintMismatch(expected: String, presented: String)
    case notify(String)
}

/// Pure transition function. No sockets, no timers, no UI — the coordinator
/// performs the returned actions and feeds the results back in as events.
public struct SessionController {
    public private(set) var state: AgentState
    public private(set) var micPresent: Bool = false
    public private(set) var deviceLabel: String = ""

    /// protocol-v1 §5: the START_NACK reason meaning another paired Mac holds
    /// the one microphone.
    public static let sessionInUseReason = "SESSION_IN_USE"

    private static let micUnavailableMessage = "The Windows microphone is unavailable."
    private static let micDisconnectedMessage = "The Windows microphone was disconnected."
    private static let startTimeoutMessage = "The Windows agent did not answer START within 2 s."
    private static let stopTimeoutMessage = "STOP went unanswered; the session is treated as ended."
    private static let hardStopMessage = "The Windows agent presented a different certificate than the one paired. Re-pair explicitly to continue."

    public init(state: AgentState = .unpaired) {
        self.state = state
    }

    public var activeSessionId: String? {
        switch state {
        case .streaming(let sessionId):
            return sessionId
        case .stopping(_, let sessionId):
            return sessionId.isEmpty ? nil : sessionId
        default:
            return nil
        }
    }

    public mutating func handle(_ event: SessionEvent) -> [SessionAction] {
        // A hard stop is terminal. Only an explicit re-pair (or an explicit
        // unpair) leaves it — nothing automatic, by design.
        if case .hardStop = state {
            switch event {
            case .paired:
                state = .disconnected
                return []
            case .unpairedByUser:
                state = .unpaired
                return [.closeConnection]
            default:
                return []
            }
        }

        switch event {
        case .paired:
            state = .disconnected
            return []

        case .unpairedByUser:
            state = .unpaired
            return [.closeConnection]

        case .fingerprintMismatch(let expected, let presented):
            state = .hardStop(reason: Self.hardStopMessage)
            return [.closeConnection, .warnFingerprintMismatch(expected: expected, presented: presented)]

        case .connectAttemptStarted:
            state = .connecting
            return []

        case .authenticated(let mic, let label):
            micPresent = mic
            deviceLabel = label
            state = .idle
            return []

        case .connectionLost:
            state = .disconnected
            return [.scheduleReconnect]

        case .userRequestedStart(let requestId):
            switch state {
            case .idle, .sessionInUse:
                // Retrying from .sessionInUse is deliberate: version 1 has no
                // "the mic is free now" message, so asking again is the only way
                // this Mac finds out that the holder let go.
                guard micPresent else {
                    return [.notify(Self.micUnavailableMessage)]
                }
                state = .starting(requestId: requestId)
                return [
                    .sendStart(requestId: requestId),
                    .armStartTimeout(requestId: requestId, seconds: SharedMicProtocol.startTimeout)
                ]
            default:
                // Already starting, already streaming, stopping, disconnected, or
                // degraded: a user Start is a no-op rather than a second session.
                return []
            }

        case .startAcked(let requestId, let sessionId):
            guard case .starting(let pending) = state, pending == requestId else { return [] }
            state = .streaming(sessionId: sessionId)
            return []

        case .startNacked(let requestId, let reason, let holderName):
            guard case .starting(let pending) = state, pending == requestId else { return [] }

            // SESSION_IN_USE is not a failure. Another paired Mac has the one
            // microphone; this connection is untouched and the user is told who
            // has it, by name when Windows offered one.
            //
            // protocol-v1 §5: holderName is advisory and display-only. It is
            // carried here so the UI can render it, and it drives no decision —
            // not the retry policy, not the transition, not the notification's
            // severity. Only the wording changes.
            if reason == Self.sessionInUseReason {
                let named = holderName?.trimmingCharacters(in: .whitespaces)
                let usable = (named?.isEmpty == false) ? named : nil
                state = .sessionInUse(holderName: usable)
                return [.notify("The microphone is in use by \(usable ?? "another Mac").")]
            }

            state = .idle
            return [.notify("Start refused: \(reason)")]

        case .startTimedOut(let requestId):
            guard case .starting(let pending) = state, pending == requestId else { return [] }
            state = .degraded(reason: Self.startTimeoutMessage)
            return [.closeConnection, .scheduleReconnect]

        case .userRequestedStop(let requestId):
            switch state {
            case .streaming(let sessionId):
                state = .stopping(requestId: requestId, sessionId: sessionId)
                return [
                    .sendStop(requestId: requestId, sessionId: sessionId),
                    .armStopTimeout(requestId: requestId, seconds: SharedMicProtocol.stopTimeout)
                ]
            case .starting, .idle:
                // protocol-v1 §7: STOP always means "make sure no session is
                // active"; an empty sessionId is explicitly allowed.
                state = .stopping(requestId: requestId, sessionId: "")
                return [
                    .sendStop(requestId: requestId, sessionId: ""),
                    .armStopTimeout(requestId: requestId, seconds: SharedMicProtocol.stopTimeout)
                ]
            default:
                return []
            }

        case .stopAcked(let requestId):
            guard case .stopping(let pending, _) = state, pending == requestId else { return [] }
            state = .idle
            return []

        case .stopTimedOut(let requestId):
            guard case .stopping(let pending, _) = state, pending == requestId else { return [] }
            state = .idle
            return [.notify(Self.stopTimeoutMessage)]

        case .statusReceived(let mic, let active, let label):
            micPresent = mic
            deviceLabel = label
            if !mic {
                switch state {
                case .starting, .streaming, .stopping:
                    state = .degraded(reason: Self.micDisconnectedMessage)
                    return [.notify(Self.micDisconnectedMessage)]
                default:
                    return []
                }
            }
            if case .degraded = state {
                state = .idle
            }
            // Phase 1's Windows agent never sends STATUS, but if a later one
            // reports an idle microphone while this Mac is waiting on another
            // Mac, stop claiming someone else has it. `active: true` means the
            // holder still does, so leave the state alone.
            if case .sessionInUse = state, !active {
                state = .idle
            }
            return []
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/SessionControllerTests`
Expected: PASS — `** TEST SUCCEEDED **`, 30 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Session/SessionController.swift macos/SharedMicTests/SessionControllerTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): pure session state machine

START/STOP idempotency, the 2s and 1s response timeouts, STATUS-driven DEGRADED
and recovery, a distinct sessionInUse state for when another paired Mac holds
the one Windows microphone (naming the holder when the advisory field is there
and saying "another Mac" when it is not), and a terminal hard-stop on
certificate fingerprint mismatch that emits no reconnect action and swallows
every subsequent event until an explicit re-pair.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Mock Windows server test harness

Everything network-facing from here on is developed against the Phase 0 Python mock. **This is what makes the entire Phase 1 macOS agent buildable with no Windows machine at all.** This task's deliverable is a mock that an XCTest can start, interrogate, and steer.

**Files:**
- Create: `macos/SharedMicTests/Support/mock_windows_server.py`, `macos/SharedMicTests/Support/MockWindowsServerProcess.swift`
- Test: `macos/SharedMicTests/MockWindowsServerProcessTests.swift`

**Interfaces:**
- Consumes: `RepositoryPaths` (Task 5), `PairingString.decode(_:)` (Task 6).
- Produces (test target only):
  - `final class MockWindowsServerProcess` — `init(micPresent: Bool = true) throws`, `let port: UInt16`, `let fingerprint: String`, `let pairingString: String`, `let token: Data`, `func setMicPresent(_ present: Bool)`, `func dropConnections()`, `func terminate()`. The mock always uses `deviceLabel = "Mock USB Mic"` and `serverId = "mock-win"`; both are baked into the Python driver rather than parameterised, because no test needs to vary them.

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/MockWindowsServerProcessTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class MockWindowsServerProcessTests: XCTestCase {
    func testHarnessInterpreterAndModulesArePresent() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: RepositoryPaths.pythonExecutable.path),
                      "harness/.venv/bin/python is missing — see harness/README.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: RepositoryPaths.harnessDirectory.appendingPathComponent("sharedmic_protocol/server.py").path))
    }

    func testStartsAndPublishesItsPortFingerprintAndPairingString() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }

        XCTAssertGreaterThan(server.port, 0)
        XCTAssertEqual(server.fingerprint.count, 64)
        XCTAssertEqual(server.fingerprint, server.fingerprint.lowercased())
        XCTAssertNotNil(Hex.decode(server.fingerprint))
        XCTAssertEqual(server.pairingString.count, SharedMicProtocol.pairingStringLength)
        XCTAssertEqual(server.token.count, SharedMicProtocol.tokenBytes)
    }

    /// The pairing string the mock prints is the one a user would type, and it
    /// must decode to the token the mock actually authenticates against.
    func testPairingStringDecodesToTheServersToken() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        XCTAssertEqual(try PairingString.decode(server.pairingString), server.token)
    }

    func testEachInstanceGetsAFreshCertificateAndPort() throws {
        let first = try MockWindowsServerProcess()
        defer { first.terminate() }
        let second = try MockWindowsServerProcess()
        defer { second.terminate() }
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(first.port, second.port)
    }

    func testAcceptsATCPConnectionOnItsPort() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }

        let connected = expectation(description: "tcp connect")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: server.port),
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "test.tcp"))
        wait(for: [connected], timeout: 5.0)
        connection.cancel()
    }

    func testControlCommandsDoNotKillTheServer() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        server.setMicPresent(false)
        server.setMicPresent(true)
        server.dropConnections()

        // Still listening after all three commands.
        let connected = expectation(description: "tcp connect after commands")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: server.port),
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "test.tcp.after"))
        wait(for: [connected], timeout: 5.0)
        connection.cancel()
    }
}
```

The file's imports are `import XCTest`, `import Network`, and `@testable import SharedMic`.

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/MockWindowsServerProcessTests`
Expected: FAIL — compile error, `cannot find 'MockWindowsServerProcess' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMicTests/Support/mock_windows_server.py`:

```python
"""Stand up harness/sharedmic_protocol's MockWindowsServer over TLS for XCTest.

Run with the harness virtualenv interpreter; there is no bare `python` on this
machine and the system python3 has no dependencies installed:

    harness/.venv/bin/python macos/SharedMicTests/Support/mock_windows_server.py <harness-dir> [port]

On startup it prints exactly one JSON line to stdout describing the server, then
reads one command per line from stdin until EOF or `quit`:

    micoff | micon | drop | quit

`drop` closes every live connection without stopping the listener, which is how
the reconnect tests simulate the Windows host going away and coming back.
"""

import json
import socket
import sys
import time

harness_directory = sys.argv[1]
requested_port = int(sys.argv[2]) if len(sys.argv) > 2 else 0
sys.path.insert(0, harness_directory)

from sharedmic_protocol.auth import encode_pairing_string  # noqa: E402
from sharedmic_protocol.server import MockWindowsServer  # noqa: E402
from sharedmic_protocol.tls import (  # noqa: E402
    certificate_fingerprint,
    generate_self_signed_cert,
    server_context,
)

TOKEN = bytes(range(32))

cert_pem, key_pem = generate_self_signed_cert()
server = MockWindowsServer(
    TOKEN,
    host="127.0.0.1",
    port=requested_port,
    mic_present=True,
    device_label="Mock USB Mic",
    server_id="mock-win",
    ssl_context=server_context(cert_pem, key_pem),
)
server.start()

print(
    json.dumps(
        {
            "port": server.port,
            "fingerprint": certificate_fingerprint(cert_pem),
            "pairing": encode_pairing_string(TOKEN),
            "tokenHex": TOKEN.hex(),
        }
    ),
    flush=True,
)


def drop_connections():
    # Reaches into MockWindowsServer._connections on purpose: the mock has no
    # public "hang up on everyone" API, and simulating a mid-session network drop
    # is exactly what a reconnect test needs. This is test-harness code, not
    # agent code.
    for connection in list(server._connections):
        try:
            connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            connection.close()
        except OSError:
            pass


try:
    for line in sys.stdin:
        command = line.strip()
        if command == "micoff":
            server.set_mic_present(False)
        elif command == "micon":
            server.set_mic_present(True)
        elif command == "drop":
            drop_connections()
        elif command == "quit":
            break
        elif command:
            print(json.dumps({"error": f"unknown command {command!r}"}), flush=True)
        print(json.dumps({"ack": command}), flush=True)
finally:
    server.stop()
    time.sleep(0.05)
```

Create `macos/SharedMicTests/Support/MockWindowsServerProcess.swift`:

```swift
import Foundation
@testable import SharedMic

/// Launches the Phase 0 Python mock as a child process and exposes the values a
/// Swift client needs: the ephemeral port, the certificate fingerprint to pin,
/// and the pairing string a user would type.
///
/// `@testable import` is required rather than a plain import: `SharedMic` is an
/// application target, and the test bundle links against it as its BUNDLE_LOADER.
///
/// Every network test in this phase runs against this, which is why no Windows
/// machine is required to build the macOS agent.
final class MockWindowsServerProcess {
    enum LaunchError: Error, CustomStringConvertible {
        case interpreterMissing(String)
        case noHandshakeLine
        case malformedHandshakeLine(String)

        var description: String {
            switch self {
            case .interpreterMissing(let path):
                return "harness interpreter not found at \(path); see harness/README.md"
            case .noHandshakeLine:
                return "mock server exited before printing its handshake line"
            case .malformedHandshakeLine(let line):
                return "mock server printed an unreadable handshake line: \(line)"
            }
        }
    }

    let port: UInt16
    let fingerprint: String
    let pairingString: String
    let token: Data

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private var terminated = false

    init(micPresent: Bool = true) throws {
        let interpreter = RepositoryPaths.pythonExecutable
        guard FileManager.default.isExecutableFile(atPath: interpreter.path) else {
            throw LaunchError.interpreterMissing(interpreter.path)
        }
        let script = RepositoryPaths.root
            .appendingPathComponent("macos/SharedMicTests/Support/mock_windows_server.py")

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        process = Process()
        process.executableURL = interpreter
        process.arguments = [script.path, RepositoryPaths.harnessDirectory.path, "0"]
        process.currentDirectoryURL = RepositoryPaths.root
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        try process.run()

        // Read the single JSON handshake line, byte by byte so no bytes belonging
        // to later command acknowledgements are swallowed.
        let handle = stdoutPipe.fileHandleForReading
        var lineBytes = Data()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                continue
            }
            lineBytes.append(chunk)
            if lineBytes.contains(0x0a) { break }
        }
        guard let newlineIndex = lineBytes.firstIndex(of: 0x0a) else {
            process.terminate()
            throw LaunchError.noHandshakeLine
        }
        let line = String(decoding: lineBytes[lineBytes.startIndex..<newlineIndex], as: UTF8.self)
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let portNumber = (object["port"] as? NSNumber)?.intValue,
              let fingerprint = object["fingerprint"] as? String,
              let pairing = object["pairing"] as? String,
              let tokenHex = object["tokenHex"] as? String,
              let token = Hex.decode(tokenHex) else {
            process.terminate()
            throw LaunchError.malformedHandshakeLine(line)
        }

        self.port = UInt16(truncatingIfNeeded: portNumber)
        self.fingerprint = fingerprint
        self.pairingString = pairing
        self.token = token

        if !micPresent {
            setMicPresent(false)
        }
    }

    func setMicPresent(_ present: Bool) {
        write(present ? "micon" : "micoff")
        // The mock notifies connected peers synchronously on the command thread;
        // a short settle keeps the assertion that follows from racing the STATUS.
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Closes every live connection without stopping the listener — a simulated
    /// network drop that the agent must recover from with backoff.
    func dropConnections() {
        write("drop")
        Thread.sleep(forTimeInterval: 0.1)
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        write("quit")
        stdinPipe.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    private func write(_ command: String) {
        guard process.isRunning else { return }
        stdinPipe.fileHandleForWriting.write(Data("\(command)\n".utf8))
    }

    deinit {
        terminate()
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/MockWindowsServerProcessTests`
Expected: PASS — `** TEST SUCCEEDED **`, 6 test cases.

Sanity-check the same mock by hand, which is also how it is driven for manual smoke testing on the real default port. From the repository root:

```sh
harness/.venv/bin/python macos/SharedMicTests/Support/mock_windows_server.py "$PWD/harness" 47800
```
Expected first line of output, with different random values:
```
{"port": 47800, "fingerprint": "65940ce4...", "pairing": "AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ", "tokenHex": "000102...1f"}
```
Paste the `pairing` value into the menu bar's pairing field and the agent will pin the `fingerprint` value on its own. Type `quit` and press return to shut it down.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMicTests/Support/mock_windows_server.py macos/SharedMicTests/Support/MockWindowsServerProcess.swift macos/SharedMicTests/MockWindowsServerProcessTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
test(macos): launchable Python mock Windows server for XCTest

Wraps the Phase 0 MockWindowsServer in a child process that publishes its port,
certificate fingerprint and pairing string on stdout and accepts micoff/micon/
drop commands on stdin. Every network test in Phase 1 runs against this, so the
macOS agent is developable with no Windows machine present.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Pinned TLS 1.3 transport

**Files:**
- Create: `macos/SharedMic/Net/PinnedTLSTransport.swift`
- Test: `macos/SharedMicTests/PinnedTLSTransportTests.swift`

**Interfaces:**
- Consumes: `Hex` (Task 1), `AuthProof.fingerprint(ofDER:)` (Task 6), `MockWindowsServerProcess` (Task 10).
- Produces:
  - `public enum TransportError: Error, Equatable` — `fingerprintMismatch(expected: String, presented: String)`, `noCertificatePresented`, `connectionFailed(String)`, `timedOut`, `closed`
  - `public enum PinningMode: Equatable { case pinned(fingerprint: String); case trustOnFirstUse }`
  - `public protocol MessageTransport: AnyObject { var onReceive: ((Data) -> Void)? { get set }; var onClose: ((Error?) -> Void)? { get set }; func send(_ data: Data, completion: @escaping (Error?) -> Void); func close() }`
  - `public final class PinnedTLSTransport: MessageTransport` — `init()`, `func connect(host: String, port: UInt16, mode: PinningMode, timeout: TimeInterval = 10.0, completion: @escaping (Result<String, Error>) -> Void)`; `connect`'s success value is the **presented fingerprint**, which is what trust-on-first-use pairing pins.

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/PinnedTLSTransportTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class PinnedTLSTransportTests: XCTestCase {

    private func connect(_ transport: PinnedTLSTransport,
                         to server: MockWindowsServerProcess,
                         mode: PinningMode,
                         timeout: TimeInterval = 10.0) -> Result<String, Error> {
        let finished = expectation(description: "connect completed")
        var outcome: Result<String, Error>!
        transport.connect(host: "127.0.0.1", port: server.port, mode: mode, timeout: timeout) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: timeout + 10.0)
        return outcome
    }

    /// protocol-v1 §2 and §11.3: a self-signed EC P-256 certificate with no CA
    /// anywhere must complete a TLS 1.3 handshake when its fingerprint matches.
    func testConnectsWhenTheFingerprintMatches() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let result = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint))
        switch result {
        case .success(let presented):
            XCTAssertEqual(presented, server.fingerprint)
        case .failure(let error):
            XCTFail("expected a successful pinned handshake, got \(error)")
        }
    }

    func testTrustOnFirstUseReportsThePresentedFingerprint() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let result = connect(transport, to: server, mode: .trustOnFirstUse)
        switch result {
        case .success(let presented):
            XCTAssertEqual(presented, server.fingerprint)
            XCTAssertEqual(presented.count, 64)
        case .failure(let error):
            XCTFail("trust-on-first-use should not fail, got \(error)")
        }
    }

    /// The single most important test in this phase. A mismatch must surface as a
    /// mismatch — quickly, and without Network.framework quietly retrying.
    func testFingerprintMismatchIsAHardStop() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let wrong = String(repeating: "00", count: 32)
        let started = Date()
        let result = connect(transport, to: server, mode: .pinned(fingerprint: wrong), timeout: 10.0)

        switch result {
        case .success:
            XCTFail("a mismatched pin must never produce a usable connection")
        case .failure(let error):
            XCTAssertEqual(
                error as? TransportError,
                .fingerprintMismatch(expected: wrong, presented: server.fingerprint)
            )
        }
        // Must fail fast rather than sit in NWConnection's `.waiting` retry loop.
        XCTAssertLessThan(Date().timeIntervalSince(started), 9.0)
    }

    func testMismatchDoesNotRetryOnItsOwn() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        var closeCallbacks = 0
        transport.onClose = { _ in closeCallbacks += 1 }
        _ = connect(transport, to: server, mode: .pinned(fingerprint: String(repeating: "11", count: 32)))

        // Give NWConnection ample time to attempt a retry of its own accord.
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        // The transport reported the failure exactly once, through `connect`'s
        // completion, and never re-entered the handshake.
        XCTAssertEqual(closeCallbacks, 0)
    }

    func testFingerprintComparisonIsCaseInsensitiveOnTheStoredValue() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let result = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint.uppercased()))
        guard case .success = result else {
            return XCTFail("an uppercased pin of the same certificate must still match")
        }
    }

    func testReceivesTheGreetingBytesTheServerSendsImmediately() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let received = expectation(description: "greeting bytes")
        var bytes = Data()
        transport.onReceive = { chunk in
            bytes.append(chunk)
            if bytes.count >= 5 { received.fulfill() }
        }
        guard case .success = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint)) else {
            return XCTFail("handshake failed")
        }
        wait(for: [received], timeout: 10.0)

        // protocol-v1 §6 step 1: the server greets immediately after the handshake.
        XCTAssertEqual(bytes.first, FrameType.control.rawValue)
        let frame = try XCTUnwrap(FrameCodec.decode(bytes))
        let message = try ControlCodec.decode(frame.payload)
        guard case .greeting(let serverId, let nonce) = message else {
            return XCTFail("expected GREETING, got \(message.typeName)")
        }
        XCTAssertEqual(serverId, "mock-win")
        XCTAssertEqual(nonce.count, 64)
    }

    func testConnectingToAClosedPortFailsRatherThanHanging() {
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let finished = expectation(description: "failed")
        var outcome: Result<String, Error>!
        // Port 1 is reserved and nothing listens on it.
        transport.connect(host: "127.0.0.1", port: 1, mode: .trustOnFirstUse, timeout: 5.0) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 15.0)
        guard case .failure = outcome! else {
            return XCTFail("connecting to a closed port must fail")
        }
    }

    func testCloseReportsNilToOnClose() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()

        guard case .success = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint)) else {
            return XCTFail("handshake failed")
        }
        let closed = expectation(description: "closed")
        transport.onClose = { error in
            XCTAssertNil(error, "an intentional close is not an error")
            closed.fulfill()
        }
        transport.close()
        wait(for: [closed], timeout: 5.0)
    }

    func testPeerHangUpReportsAnErrorToOnClose() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        guard case .success = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint)) else {
            return XCTFail("handshake failed")
        }
        let closed = expectation(description: "peer hung up")
        transport.onClose = { error in
            XCTAssertNotNil(error, "an unexpected drop must be reported as an error")
            closed.fulfill()
        }
        server.dropConnections()
        wait(for: [closed], timeout: 10.0)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/PinnedTLSTransportTests`
Expected: FAIL — compile error, `cannot find 'PinnedTLSTransport' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Net/PinnedTLSTransport.swift`:

```swift
import CryptoKit
import Foundation
import Network

public enum TransportError: Error, Equatable {
    case fingerprintMismatch(expected: String, presented: String)
    case noCertificatePresented
    case connectionFailed(String)
    case timedOut
    case closed
}

extension TransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .fingerprintMismatch(let expected, let presented):
            return "certificate fingerprint mismatch — pinned \(expected), presented \(presented)"
        case .noCertificatePresented:
            return "the peer presented no certificate"
        case .connectionFailed(let detail):
            return "connection failed: \(detail)"
        case .timedOut:
            return "connection timed out"
        case .closed:
            return "connection closed"
        }
    }
}

public enum PinningMode: Equatable {
    /// Every connection after pairing. The pin is the only certificate check.
    case pinned(fingerprint: String)
    /// **Pairing only.** Accepts whatever certificate is presented and reports its
    /// fingerprint so the caller can pin it — but only after the HMAC handshake on
    /// that same connection proves the peer holds the pairing token. A certificate
    /// from a peer that cannot answer the challenge is never persisted.
    case trustOnFirstUse
}

/// A framed byte-stream transport, deliberately narrow so the protocol layer can
/// be tested against a double.
public protocol MessageTransport: AnyObject {
    var onReceive: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
    func send(_ data: Data, completion: @escaping (Error?) -> Void)
    func close()
}

/// TLS 1.3 over `NWConnection` with SHA-256-of-DER certificate pinning.
///
/// protocol-v1 §2 and §11.3: there is no CA anywhere in this design, and the
/// client must explicitly opt out of both CA and hostname validation.
/// `sec_protocol_options_set_verify_block` **replaces** the default trust
/// evaluation rather than running after it, so neither check ever executes —
/// which is precisely why `Network.framework` was chosen over `URLSession`.
///
/// Two traps this class exists to contain:
///
/// 1. On a rejected verify block `NWConnection` enters `.waiting`, not `.failed`,
///    and retries **forever**. protocol-v1 §2 forbids any automatic retry after a
///    fingerprint mismatch, so any `.waiting` is treated as terminal here.
/// 2. The `NWError` that surfaces is `-9808 bad certificate format`, which says
///    nothing about pinning. The verify block therefore records *why* it refused
///    in `pinFailure` and that recorded reason wins over the opaque network error.
public final class PinnedTLSTransport: MessageTransport {
    public var onReceive: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let queue = DispatchQueue(label: "com.sharedmic.transport")
    private let lock = NSLock()

    private var connection: NWConnection?
    private var presentedFingerprint: String?
    private var pinFailure: TransportError?
    private var connectCompletion: ((Result<String, Error>) -> Void)?
    private var didCompleteConnect = false
    private var didReportClose = false
    private var closingIntentionally = false

    public init() {}

    public func connect(host: String,
                        port: UInt16,
                        mode: PinningMode,
                        timeout: TimeInterval = 10.0,
                        completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        connectCompletion = completion
        didCompleteConnect = false
        didReportClose = false
        closingIntentionally = false
        presentedFingerprint = nil
        pinFailure = nil
        lock.unlock()

        let tlsOptions = NWProtocolTLS.Options()
        let security = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(security, { [weak self] _, trustRef, verifyComplete in
            guard let self else { verifyComplete(false); return }
            let trust = sec_trust_copy_ref(trustRef).takeRetainedValue()
            guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                  let leaf = chain.first else {
                self.record(pinFailure: .noCertificatePresented)
                verifyComplete(false)
                return
            }
            // NOTE: SecTrustEvaluate is never called. There is no CA and no
            // hostname to match — the pin below is the entire trust decision.
            let der = SecCertificateCopyData(leaf) as Data
            let fingerprint = AuthProof.fingerprint(ofDER: der)
            self.record(fingerprint: fingerprint)

            switch mode {
            case .trustOnFirstUse:
                verifyComplete(true)
            case .pinned(let expected):
                let normalized = expected.lowercased()
                if fingerprint == normalized {
                    verifyComplete(true)
                } else {
                    self.record(pinFailure: .fingerprintMismatch(expected: normalized,
                                                                 presented: fingerprint))
                    verifyComplete(false)
                }
            }
        }, queue)

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let connection = NWConnection(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(integerLiteral: port),
                                      using: parameters)
        lock.lock(); self.connection = connection; lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.finishConnect(.success(self.currentFingerprint() ?? ""))
                self.receiveLoop()
            case .waiting(let error):
                // See the class comment: `.waiting` is where a rejected pin lands,
                // and NWConnection would otherwise retry it indefinitely.
                self.fail(with: self.recordedFailure(or: .connectionFailed("\(error)")))
            case .failed(let error):
                self.fail(with: self.recordedFailure(or: .connectionFailed("\(error)")))
            case .cancelled:
                self.reportClose(self.wasClosingIntentionally() ? nil : TransportError.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.connectIsPending() else { return }
            self.fail(with: TransportError.timedOut)
        }
    }

    public func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        lock.lock(); let connection = self.connection; lock.unlock()
        guard let connection else {
            completion(TransportError.closed)
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            completion(error)
        })
    }

    public func close() {
        lock.lock()
        closingIntentionally = true
        let connection = self.connection
        lock.unlock()
        connection?.cancel()
    }

    // MARK: - Receive

    private func receiveLoop() {
        lock.lock(); let connection = self.connection; lock.unlock()
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onReceive?(data)
            }
            if let error {
                self.fail(with: TransportError.connectionFailed("\(error)"))
                return
            }
            if isComplete {
                self.fail(with: TransportError.closed)
                return
            }
            self.receiveLoop()
        }
    }

    // MARK: - State bookkeeping

    private func record(fingerprint: String) {
        lock.lock(); presentedFingerprint = fingerprint; lock.unlock()
    }

    private func record(pinFailure: TransportError) {
        lock.lock(); self.pinFailure = pinFailure; lock.unlock()
    }

    private func currentFingerprint() -> String? {
        lock.lock(); defer { lock.unlock() }
        return presentedFingerprint
    }

    private func recordedFailure(or fallback: TransportError) -> TransportError {
        lock.lock(); defer { lock.unlock() }
        return pinFailure ?? fallback
    }

    private func wasClosingIntentionally() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return closingIntentionally
    }

    private func connectIsPending() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !didCompleteConnect && connectCompletion != nil
    }

    private func finishConnect(_ result: Result<String, Error>) {
        lock.lock()
        guard !didCompleteConnect, let completion = connectCompletion else {
            lock.unlock()
            return
        }
        didCompleteConnect = true
        connectCompletion = nil
        lock.unlock()
        completion(result)
    }

    /// A failure before `connect` completes is reported through `connect`'s
    /// completion and nowhere else. A failure afterwards is reported through
    /// `onClose`. Either way it happens exactly once, and the connection is
    /// cancelled so nothing retries.
    private func fail(with error: Error) {
        let pending = connectIsPending()
        lock.lock()
        closingIntentionally = true
        if pending { didReportClose = true }
        let connection = self.connection
        lock.unlock()

        if pending {
            finishConnect(.failure(error))
            connection?.cancel()
            return
        }
        reportClose(error)
        connection?.cancel()
    }

    private func reportClose(_ error: Error?) {
        lock.lock()
        guard !didReportClose else { lock.unlock(); return }
        didReportClose = true
        lock.unlock()
        onClose?(error)
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/PinnedTLSTransportTests`
Expected: PASS — `** TEST SUCCEEDED **`, 9 test cases. In particular `testFingerprintMismatchIsAHardStop` must fail with `.fingerprintMismatch` in well under 9 seconds; if it instead times out, the `.waiting` branch is missing and `NWConnection` is retrying.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Net/PinnedTLSTransport.swift macos/SharedMicTests/PinnedTLSTransportTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): TLS 1.3 transport with certificate fingerprint pinning

NWConnection with a verify block that replaces trust evaluation entirely — no CA
check, no hostname check, only SHA-256 of the presented DER compared against the
pin. A mismatch is a hard stop: NWConnection's `.waiting` retry state is treated
as terminal, and the refusal reason is recorded out of band because the surfaced
NWError (-9808) says nothing about pinning.

Verified end to end against the Phase 0 Python mock over real TLS 1.3.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: Frame buffer and control client (handshake, dispatch, heartbeat)

**Files:**
- Create: `macos/SharedMic/Protocol/FrameBuffer.swift`, `macos/SharedMic/Net/ControlClient.swift`
- Test: `macos/SharedMicTests/FrameBufferTests.swift`, `macos/SharedMicTests/ControlClientTests.swift`

**Interfaces:**
- Consumes: `FrameCodec`/`DecodedFrame`/`FrameType`/`ProtocolError` (Task 2), `ControlMessage`/`ControlCodec` (Task 3), `AudioFrameCodec` (Task 4), `AuthProof`/`Hex` (Tasks 1, 6), `HeartbeatMonitor`/`HeartbeatError` (Task 8), `MessageTransport`/`TransportError` (Task 11), `MockWindowsServerProcess` (Task 10).
- Produces:
  - `public struct FrameBuffer` — `init()`, `var byteCount: Int { get }`, `mutating func append(_ data: Data)`, `mutating func nextFrame() throws -> DecodedFrame?`
  - `public enum ControlClientError: Error, Equatable` — `unexpectedMessageBeforeAuthentication(String)`, `unexpectedAudioFrame`, `handshakeTimedOut`, `peerDead`, `protocolViolation(String)`
  - `public protocol ControlClientDelegate: AnyObject` — `func controlClientDidAuthenticate(_ client: ControlClient, micPresent: Bool, deviceLabel: String)`, `func controlClient(_ client: ControlClient, didReceive message: ControlMessage)`, `func controlClient(_ client: ControlClient, didCloseWith error: Error?)`
  - `public final class ControlClient` — `init(transport: MessageTransport, token: Data, clientId: String, pingInterval: TimeInterval = SharedMicProtocol.pingInterval, peerDeadTimeout: TimeInterval = SharedMicProtocol.peerDeadTimeout, handshakeDeadline: TimeInterval = SharedMicProtocol.helloDeadline)`, `weak var delegate: ControlClientDelegate?`, `func begin()`, `func send(_ message: ControlMessage)`, `func stop()`, `var isAuthenticated: Bool { get }`, `var audioFramesReceived: Int { get }`, `var audioBytesReceived: Int { get }`, `var sequenceGaps: Int { get }`

**Phase 1 note on `AUDIO` frames:** the mock streams synthetic audio while a session is active, so a Phase 1 client does receive `AUDIO` envelopes. It validates them strictly (exactly 1,932 bytes), counts frames, bytes and sequence gaps, and **discards the PCM immediately** — Phase 1 has no renderer and the project rule is that audio payload is never logged or persisted. Those counters are what make the "an idle connection carries zero audio bytes" invariant assertable on the Mac side now rather than in Phase 2.

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/FrameBufferTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class FrameBufferTests: XCTestCase {
    func testEmptyBufferYieldsNothing() throws {
        var buffer = FrameBuffer()
        XCTAssertNil(try buffer.nextFrame())
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testFrameSplitAcrossManyChunksIsReassembled() throws {
        let frame = try ControlCodec.encodeFrame(.ping(seq: 5))
        var buffer = FrameBuffer()
        for byte in frame.dropLast() {
            buffer.append(Data([byte]))
            XCTAssertNil(try buffer.nextFrame(), "a partial frame must never decode")
        }
        buffer.append(Data([frame.last!]))
        let decoded = try XCTUnwrap(buffer.nextFrame())
        XCTAssertEqual(try ControlCodec.decode(decoded.payload), .ping(seq: 5))
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testTwoConcatenatedFramesInOneChunk() throws {
        var chunk = try ControlCodec.encodeFrame(.ping(seq: 1))
        chunk.append(try ControlCodec.encodeFrame(.pong(seq: 1)))
        var buffer = FrameBuffer()
        buffer.append(chunk)

        let first = try XCTUnwrap(buffer.nextFrame())
        XCTAssertEqual(try ControlCodec.decode(first.payload), .ping(seq: 1))
        let second = try XCTUnwrap(buffer.nextFrame())
        XCTAssertEqual(try ControlCodec.decode(second.payload), .pong(seq: 1))
        XCTAssertNil(try buffer.nextFrame())
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testTrailingPartialFrameIsRetained() throws {
        var chunk = try ControlCodec.encodeFrame(.ping(seq: 1))
        chunk.append(try ControlCodec.encodeFrame(.pong(seq: 1)).prefix(4))
        var buffer = FrameBuffer()
        buffer.append(chunk)
        _ = try buffer.nextFrame()
        XCTAssertNil(try buffer.nextFrame())
        XCTAssertEqual(buffer.byteCount, 4)
    }

    func testBadFrameTypeThrows() {
        var buffer = FrameBuffer()
        buffer.append(Data([0x09, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try buffer.nextFrame()) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownFrameType(9))
        }
    }

    func testOversizedLengthThrowsBeforeWaitingForTheBytes() {
        var buffer = FrameBuffer()
        buffer.append(Data([0x01, 0xff, 0xff, 0xff, 0xff]))
        XCTAssertThrowsError(try buffer.nextFrame()) { error in
            XCTAssertEqual(error as? ProtocolError, .payloadTooLarge(4_294_967_295))
        }
    }

    func testCarriesAFullAudioEnvelope() throws {
        let pcm = Data(repeating: 0x11, count: SharedMicProtocol.audioPCMBytes)
        let frame = try AudioFrameCodec.encodeFrame(sequence: 7, captureTimestampUs: 140_000, pcm: pcm)
        var buffer = FrameBuffer()
        buffer.append(frame.prefix(1_000))
        XCTAssertNil(try buffer.nextFrame())
        buffer.append(frame.dropFirst(1_000))
        let decoded = try XCTUnwrap(buffer.nextFrame())
        XCTAssertEqual(decoded.type, .audio)
        let audio = try AudioFrameCodec.decodePayload(decoded.payload)
        XCTAssertEqual(audio.sequence, 7)
        XCTAssertEqual(audio.captureTimestampUs, 140_000)
    }
}
```

Create `macos/SharedMicTests/ControlClientTests.swift`:

```swift
import XCTest
@testable import SharedMic

private final class RecordingDelegate: ControlClientDelegate {
    var authenticated: (micPresent: Bool, deviceLabel: String)?
    var messages: [ControlMessage] = []
    var didClose = false
    var closeError: Error?
    var onAuthenticate: (() -> Void)?
    var onMessage: ((ControlMessage) -> Void)?
    var onClose: ((Error?) -> Void)?

    func controlClientDidAuthenticate(_ client: ControlClient, micPresent: Bool, deviceLabel: String) {
        authenticated = (micPresent, deviceLabel)
        onAuthenticate?()
    }

    func controlClient(_ client: ControlClient, didReceive message: ControlMessage) {
        messages.append(message)
        onMessage?(message)
    }

    func controlClient(_ client: ControlClient, didCloseWith error: Error?) {
        didClose = true
        closeError = error
        onClose?(error)
    }
}

final class ControlClientTests: XCTestCase {

    /// Connects a pinned transport to the mock and returns the wired-up client.
    private func makeAuthenticatedClient(
        _ server: MockWindowsServerProcess,
        delegate: RecordingDelegate,
        pingInterval: TimeInterval = SharedMicProtocol.pingInterval,
        peerDeadTimeout: TimeInterval = SharedMicProtocol.peerDeadTimeout
    ) throws -> (ControlClient, PinnedTLSTransport) {
        let transport = PinnedTLSTransport()
        let connected = expectation(description: "tls connected")
        transport.connect(host: "127.0.0.1", port: server.port,
                          mode: .pinned(fingerprint: server.fingerprint)) { result in
            if case .failure(let error) = result { XCTFail("handshake failed: \(error)") }
            connected.fulfill()
        }
        wait(for: [connected], timeout: 15.0)

        let client = ControlClient(transport: transport,
                                   token: server.token,
                                   clientId: "mac-tests",
                                   pingInterval: pingInterval,
                                   peerDeadTimeout: peerDeadTimeout)
        client.delegate = delegate
        let authenticated = expectation(description: "authenticated")
        delegate.onAuthenticate = { authenticated.fulfill() }
        client.begin()
        wait(for: [authenticated], timeout: 15.0)
        return (client, transport)
    }

    /// protocol-v1 §6: GREETING -> HELLO -> HELLO_ACK over a real TLS connection.
    func testCompletesTheHandshakeAgainstTheMock() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(delegate.authenticated?.micPresent, true)
        XCTAssertEqual(delegate.authenticated?.deviceLabel, "Mock USB Mic")
    }

    func testWrongTokenFailsToAuthenticate() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }

        let transport = PinnedTLSTransport()
        defer { transport.close() }
        let connected = expectation(description: "tls connected")
        transport.connect(host: "127.0.0.1", port: server.port,
                          mode: .pinned(fingerprint: server.fingerprint)) { _ in connected.fulfill() }
        wait(for: [connected], timeout: 15.0)

        let delegate = RecordingDelegate()
        let closed = expectation(description: "closed")
        delegate.onClose = { _ in closed.fulfill() }
        delegate.onAuthenticate = { XCTFail("a wrong token must never authenticate") }

        let client = ControlClient(transport: transport,
                                   token: Data(repeating: 0xee, count: 32),
                                   clientId: "mac-tests")
        client.delegate = delegate
        client.begin()
        wait(for: [closed], timeout: 15.0)
        XCTAssertFalse(client.isAuthenticated)
    }

    func testPingGetsAMatchingPong() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        // 0.3 s heartbeat so the loop is observable inside a test.
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate,
                                                              pingInterval: 0.3, peerDeadTimeout: 30.0)
        defer { client.stop(); transport.close() }

        let stillAlive = expectation(description: "heartbeat kept running")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { stillAlive.fulfill() }
        wait(for: [stillAlive], timeout: 5.0)

        // A mismatched PONG would have been a protocol violation that closed the
        // connection, so surviving several heartbeat rounds is the assertion.
        XCTAssertFalse(delegate.didClose, "the heartbeat closed the connection: \(String(describing: delegate.closeError))")
        XCTAssertTrue(client.isAuthenticated)
    }

    func testDeadPeerIsDetected() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate,
                                                              pingInterval: 30.0, peerDeadTimeout: 1.0)
        defer { client.stop(); transport.close() }

        let closed = expectation(description: "peer declared dead")
        delegate.onClose = { error in
            XCTAssertEqual(error as? ControlClientError, .peerDead)
            closed.fulfill()
        }
        wait(for: [closed], timeout: 10.0)
    }

    /// protocol-v1 §5: STATUS is unsolicited and must not be swallowed by the
    /// reply path.
    func testUnsolicitedStatusIsDelivered() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        let gotStatus = expectation(description: "status delivered")
        delegate.onMessage = { message in
            if case .status(let micPresent, _, _) = message, micPresent == false {
                gotStatus.fulfill()
            }
        }
        server.setMicPresent(false)
        wait(for: [gotStatus], timeout: 10.0)
    }

    func testStartAndStopExchange() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        var sessionId: String?
        let started = expectation(description: "START_ACK")
        delegate.onMessage = { message in
            if case .startAck(_, let id, let format) = message {
                sessionId = id
                XCTAssertEqual(format, .v1)
                started.fulfill()
            }
        }
        client.send(.start(requestId: "req-1", preferredFormat: .v1))
        wait(for: [started], timeout: 10.0)

        let stopped = expectation(description: "STOP_ACK")
        delegate.onMessage = { message in
            if case .stopAck(let requestId, _) = message, requestId == "req-2" {
                stopped.fulfill()
            }
        }
        client.send(.stop(requestId: "req-2", sessionId: try XCTUnwrap(sessionId)))
        wait(for: [stopped], timeout: 10.0)
    }

    /// protocol-v1 §7, the project's core privacy guarantee, asserted from the
    /// Mac side: an idle authenticated connection carries zero audio bytes.
    func testIdleConnectionCarriesZeroAudioBytes() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        let settled = expectation(description: "idle period elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        XCTAssertEqual(client.audioFramesReceived, 0)
        XCTAssertEqual(client.audioBytesReceived, 0)
    }

    func testAudioFlowsOnlyBetweenStartAndStop() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        var sessionId = ""
        let started = expectation(description: "START_ACK")
        delegate.onMessage = { message in
            if case .startAck(_, let id, _) = message {
                sessionId = id
                started.fulfill()
            }
        }
        client.send(.start(requestId: "req-1", preferredFormat: .v1))
        wait(for: [started], timeout: 10.0)

        let streaming = expectation(description: "audio arrived")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { streaming.fulfill() }
        wait(for: [streaming], timeout: 5.0)
        XCTAssertGreaterThan(client.audioFramesReceived, 10, "expected ~50 frames/second")
        XCTAssertEqual(client.audioBytesReceived,
                       client.audioFramesReceived * SharedMicProtocol.audioPCMBytes)
        XCTAssertEqual(client.sequenceGaps, 0)

        let stopped = expectation(description: "STOP_ACK")
        delegate.onMessage = { message in
            if case .stopAck = message { stopped.fulfill() }
        }
        client.send(.stop(requestId: "req-2", sessionId: sessionId))
        wait(for: [stopped], timeout: 10.0)

        // Let the socket settle, then assert the count stops moving. protocol-v1 §7
        // tolerates at most one frame already inside sendall() at STOP_ACK time.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 5.0)
        let afterStop = client.audioFramesReceived

        let quiet = expectation(description: "quiet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { quiet.fulfill() }
        wait(for: [quiet], timeout: 5.0)
        XCTAssertEqual(client.audioFramesReceived, afterStop, "audio continued after STOP_ACK")
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/FrameBufferTests -only-testing:SharedMicTests/ControlClientTests`
Expected: FAIL — compile error, `cannot find type 'FrameBuffer' in scope` and `cannot find type 'ControlClient' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Protocol/FrameBuffer.swift`:

```swift
import Foundation

/// Accumulates bytes off the wire and yields whole envelopes.
///
/// protocol-v1 §3: a receiver reads bytes into a buffer and repeatedly attempts
/// to decode one envelope from the front; a short buffer means "wait", never a
/// wrong answer. A throw here is a protocol violation and the caller must close
/// the connection rather than resynchronize.
public struct FrameBuffer {
    private var storage = Data()

    public init() {}

    public var byteCount: Int { storage.count }

    public mutating func append(_ data: Data) {
        storage.append(data)
    }

    public mutating func nextFrame() throws -> DecodedFrame? {
        guard let frame = try FrameCodec.decode(storage) else { return nil }
        let end = storage.index(storage.startIndex, offsetBy: frame.bytesConsumed)
        storage.removeSubrange(storage.startIndex..<end)
        return frame
    }
}
```

Create `macos/SharedMic/Net/ControlClient.swift`:

```swift
import Foundation

public enum ControlClientError: Error, Equatable {
    case unexpectedMessageBeforeAuthentication(String)
    case unexpectedAudioFrame
    case handshakeTimedOut
    case peerDead
    case protocolViolation(String)
}

extension ControlClientError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unexpectedMessageBeforeAuthentication(let type):
            return "received \(type) before authentication completed"
        case .unexpectedAudioFrame:
            return "received an AUDIO frame outside an active session"
        case .handshakeTimedOut:
            return "the handshake did not complete within 5 s"
        case .peerDead:
            return "no PONG for 45 s — the peer is dead"
        case .protocolViolation(let detail):
            return "protocol violation: \(detail)"
        }
    }
}

public protocol ControlClientDelegate: AnyObject {
    func controlClientDidAuthenticate(_ client: ControlClient, micPresent: Bool, deviceLabel: String)
    func controlClient(_ client: ControlClient, didReceive message: ControlMessage)
    func controlClient(_ client: ControlClient, didCloseWith error: Error?)
}

/// Owns one authenticated connection: the protocol-v1 §6 handshake, the §8
/// heartbeat, and dispatch of every other control message to the delegate.
///
/// It does **not** decide what to do about those messages — that is
/// `SessionController`'s job. This class only guarantees that what reaches the
/// delegate is a valid, authenticated, protocol-conformant message.
public final class ControlClient {
    public weak var delegate: ControlClientDelegate?

    private enum Phase {
        case awaitingGreeting
        case awaitingHelloAck
        case authenticated
        case finished
    }

    private let transport: MessageTransport
    private let token: Data
    private let clientId: String
    private let pingInterval: TimeInterval
    private let peerDeadTimeout: TimeInterval
    private let handshakeDeadline: TimeInterval
    private let queue = DispatchQueue(label: "com.sharedmic.control")

    private var phase: Phase = .awaitingGreeting
    private var buffer = FrameBuffer()
    private var heartbeat = HeartbeatMonitor(now: ProcessInfo.processInfo.systemUptime)
    private var heartbeatTimer: DispatchSourceTimer?
    private var handshakeTimer: DispatchSourceTimer?

    private var frameCount = 0
    private var byteCount = 0
    private var gapCount = 0
    private var lastSequence: UInt32?

    public init(transport: MessageTransport,
                token: Data,
                clientId: String,
                pingInterval: TimeInterval = SharedMicProtocol.pingInterval,
                peerDeadTimeout: TimeInterval = SharedMicProtocol.peerDeadTimeout,
                handshakeDeadline: TimeInterval = SharedMicProtocol.helloDeadline) {
        self.transport = transport
        self.token = token
        self.clientId = clientId
        self.pingInterval = pingInterval
        self.peerDeadTimeout = peerDeadTimeout
        self.handshakeDeadline = handshakeDeadline
    }

    public var isAuthenticated: Bool {
        queue.sync { phase == .authenticated }
    }

    /// Counters only — the PCM itself is discarded the moment it is validated.
    /// Phase 1 has no renderer, and audio payload is never logged or persisted.
    public var audioFramesReceived: Int { queue.sync { frameCount } }
    public var audioBytesReceived: Int { queue.sync { byteCount } }
    public var sequenceGaps: Int { queue.sync { gapCount } }

    public func begin() {
        transport.onReceive = { [weak self] data in
            self?.queue.async { self?.ingest(data) }
        }
        transport.onClose = { [weak self] error in
            self?.queue.async { self?.finish(with: error) }
        }
        queue.async { [weak self] in
            self?.startHandshakeDeadline()
        }
    }

    public func send(_ message: ControlMessage) {
        queue.async { [weak self] in
            self?.write(message)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelTimers()
            self.phase = .finished
        }
        transport.close()
    }

    // MARK: - Receive path (always on `queue`)

    private func ingest(_ data: Data) {
        guard phase != .finished else { return }
        buffer.append(data)
        while true {
            let frame: DecodedFrame?
            do {
                frame = try buffer.nextFrame()
            } catch {
                abort(with: ControlClientError.protocolViolation(String(describing: error)))
                return
            }
            guard let frame else { return }
            switch frame.type {
            case .control:
                do {
                    try handle(try ControlCodec.decode(frame.payload))
                } catch let error as ControlClientError {
                    abort(with: error)
                    return
                } catch {
                    abort(with: ControlClientError.protocolViolation(String(describing: error)))
                    return
                }
            case .audio:
                do {
                    try handleAudio(frame.payload)
                } catch {
                    abort(with: ControlClientError.protocolViolation(String(describing: error)))
                    return
                }
            }
            if phase == .finished { return }
        }
    }

    private func handle(_ message: ControlMessage) throws {
        switch phase {
        case .awaitingGreeting:
            guard case .greeting(_, let nonceHex) = message else {
                throw ControlClientError.unexpectedMessageBeforeAuthentication(message.typeName)
            }
            // protocol-v1 §6 step 2: HMAC over the RAW nonce bytes, not the hex.
            guard let nonce = Hex.decode(nonceHex), nonce.count == SharedMicProtocol.nonceBytes else {
                throw ControlClientError.protocolViolation("GREETING nonce is not 32 hex-encoded bytes")
            }
            phase = .awaitingHelloAck
            write(.hello(clientId: clientId, mac: AuthProof.proof(token: token, nonce: nonce)))

        case .awaitingHelloAck:
            guard case .helloAck(_, let micPresent, let deviceLabel) = message else {
                throw ControlClientError.unexpectedMessageBeforeAuthentication(message.typeName)
            }
            phase = .authenticated
            cancelHandshakeDeadline()
            startHeartbeat()
            let client = self
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.controlClientDidAuthenticate(client,
                                                            micPresent: micPresent,
                                                            deviceLabel: deviceLabel)
            }

        case .authenticated:
            if case .pong(let seq) = message {
                do {
                    try heartbeat.handlePong(seq: seq, now: ProcessInfo.processInfo.systemUptime)
                } catch {
                    throw ControlClientError.protocolViolation("PONG seq \(seq) matches no outstanding PING")
                }
                return
            }
            let client = self
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.controlClient(client, didReceive: message)
            }

        case .finished:
            break
        }
    }

    private func handleAudio(_ payload: Data) throws {
        guard phase == .authenticated else {
            throw ControlClientError.unexpectedAudioFrame
        }
        // Strict: protocol-v1 §4 requires exactly 1932 bytes. decodePayload throws
        // otherwise, which closes the connection.
        let frame = try AudioFrameCodec.decodePayload(payload)
        if let previous = lastSequence, frame.sequence != previous &+ 1 {
            gapCount += 1
        }
        lastSequence = frame.sequence
        frameCount += 1
        byteCount += frame.pcm.count
        // The PCM goes no further. Phase 2 hands it to PCMRingBuffer here.
    }

    // MARK: - Send path

    private func write(_ message: ControlMessage) {
        guard phase != .finished else { return }
        let bytes: Data
        do {
            bytes = try ControlCodec.encodeFrame(message)
        } catch {
            abort(with: ControlClientError.protocolViolation("could not encode \(message.typeName)"))
            return
        }
        transport.send(bytes) { [weak self] error in
            guard let error else { return }
            self?.queue.async {
                self?.abort(with: ControlClientError.protocolViolation("send failed: \(error)"))
            }
        }
    }

    // MARK: - Timers

    private func startHandshakeDeadline() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + handshakeDeadline)
        timer.setEventHandler { [weak self] in
            guard let self, self.phase != .authenticated, self.phase != .finished else { return }
            self.abort(with: ControlClientError.handshakeTimedOut)
        }
        timer.resume()
        handshakeTimer = timer
    }

    private func cancelHandshakeDeadline() {
        handshakeTimer?.cancel()
        handshakeTimer = nil
    }

    private func startHeartbeat() {
        heartbeat = HeartbeatMonitor(now: ProcessInfo.processInfo.systemUptime)
        // Tick at a tenth of the ping interval so both the send schedule and the
        // dead-peer deadline are checked with useful resolution without a timer
        // per deadline.
        let tick = max(pingInterval / 10.0, 0.05)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self, self.phase == .authenticated else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.heartbeat.isPeerDead(now: now, timeout: self.peerDeadTimeout) {
                self.abort(with: ControlClientError.peerDead)
                return
            }
            if self.heartbeat.shouldSendPing(now: now, interval: self.pingInterval) {
                self.write(self.heartbeat.makePing(now: now))
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func cancelTimers() {
        cancelHandshakeDeadline()
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    // MARK: - Teardown

    /// Every protocol violation in this protocol has the same consequence:
    /// close the connection (protocol-v1 §1, §3, §4, §6).
    private func abort(with error: Error) {
        guard phase != .finished else { return }
        finish(with: error)
        transport.close()
    }

    private func finish(with error: Error?) {
        guard phase != .finished else { return }
        phase = .finished
        cancelTimers()
        let client = self
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.controlClient(client, didCloseWith: error)
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/FrameBufferTests -only-testing:SharedMicTests/ControlClientTests`
Expected: PASS — `** TEST SUCCEEDED **`, 15 test cases.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Protocol/FrameBuffer.swift macos/SharedMic/Net/ControlClient.swift macos/SharedMicTests/FrameBufferTests.swift macos/SharedMicTests/ControlClientTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): control client with handshake, heartbeat and strict framing

Incremental frame buffer, the GREETING/HELLO/HELLO_ACK exchange with HMAC over
the raw nonce bytes, a 5s handshake deadline, the 15s/45s heartbeat with strict
PONG sequence matching, and unsolicited STATUS delivered outside any reply path.
AUDIO frames are validated at exactly 1932 bytes and counted, never retained —
which makes the zero-idle-bytes invariant assertable from the Mac side today.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Connection coordinator — pairing, sessions, reconnect

**Files:**
- Create: `macos/SharedMic/Net/ConnectionCoordinator.swift`
- Test: `macos/SharedMicTests/ConnectionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `PairingRecord`/`PairingStore`/`InMemoryPairingStore` (Task 7), `PairingString` (Task 6), `SessionController`/`AgentState`/`SessionEvent`/`SessionAction` (Task 9), `ReconnectPolicy` (Task 8), `PinnedTLSTransport`/`PinningMode`/`TransportError` (Task 11), `ControlClient`/`ControlClientDelegate` (Task 12), `MockWindowsServerProcess` (Task 10).
- Produces:
  - `public enum PairingError: Error, Equatable { case alreadyPairing; case authenticationFailed(String); case transport(String) }`
  - `public final class ConnectionCoordinator: ControlClientDelegate` — `init(store: PairingStore, clientId: String = Host.current().localizedName ?? "mac")`, `var onStateChange: ((AgentState) -> Void)?`, `var onNotice: ((String) -> Void)?`, `var onFingerprintWarning: ((_ expected: String, _ presented: String) -> Void)?`, `var state: AgentState { get }`, `var deviceLabel: String { get }`, `var micPresent: Bool { get }`, `var pairedHost: String? { get }`, `var audioBytesReceived: Int { get }`, `func startIfPaired()`, `func pair(host: String, port: UInt16, pairingString: String, completion: @escaping (Result<PairingRecord, Error>) -> Void)`, `func unpair()`, `func requestStart()`, `func requestStop()`, `func shutdown()`

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/ConnectionCoordinatorTests.swift`:

```swift
import XCTest
@testable import SharedMic

final class ConnectionCoordinatorTests: XCTestCase {

    private func waitForState(_ coordinator: ConnectionCoordinator,
                              timeout: TimeInterval = 20.0,
                              description: String,
                              _ matches: @escaping (AgentState) -> Bool) {
        let reached = expectation(description: description)
        var fulfilled = false
        coordinator.onStateChange = { state in
            if !fulfilled && matches(state) {
                fulfilled = true
                reached.fulfill()
            }
        }
        if !fulfilled && matches(coordinator.state) {
            fulfilled = true
            reached.fulfill()
        }
        wait(for: [reached], timeout: timeout)
    }

    private func pair(_ coordinator: ConnectionCoordinator,
                      with server: MockWindowsServerProcess) throws -> PairingRecord {
        let paired = expectation(description: "paired")
        var outcome: Result<PairingRecord, Error>!
        coordinator.pair(host: "127.0.0.1", port: server.port, pairingString: server.pairingString) { result in
            outcome = result
            paired.fulfill()
        }
        wait(for: [paired], timeout: 30.0)
        switch outcome! {
        case .success(let record):
            return record
        case .failure(let error):
            throw error
        }
    }

    /// Design spec §7.1: pairing pins the fingerprint and stores token +
    /// fingerprint in the store. The fingerprint is captured trust-on-first-use
    /// and persisted only after the token proves out on that same connection.
    func testPairingPinsTheFingerprintAndStoresTheToken() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let record = try pair(coordinator, with: server)
        XCTAssertEqual(record.certificateFingerprint, server.fingerprint)
        XCTAssertEqual(record.token, server.token)
        XCTAssertEqual(record.host, "127.0.0.1")
        XCTAssertEqual(record.port, server.port)
        XCTAssertEqual(try store.load(), record)
    }

    func testPairingReachesIdle() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle after pairing") { $0 == .idle }
        XCTAssertEqual(coordinator.deviceLabel, "Mock USB Mic")
        XCTAssertTrue(coordinator.micPresent)
    }

    /// A wrong token must not leave a pinned certificate behind — otherwise a
    /// mistyped pairing string would silently pin whatever answered the port.
    func testFailedPairingStoresNothing() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let finished = expectation(description: "pairing finished")
        var outcome: Result<PairingRecord, Error>!
        // A syntactically valid pairing string for a different 32-byte token.
        let wrongString = PairingString.encode(token: Data(repeating: 0x5a, count: 32))
        coordinator.pair(host: "127.0.0.1", port: server.port, pairingString: wrongString) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30.0)

        guard case .failure = outcome! else {
            return XCTFail("pairing with the wrong token must fail")
        }
        XCTAssertNil(try store.load(), "a failed pairing must not persist anything")
    }

    func testMalformedPairingStringIsRejectedBeforeAnyConnection() throws {
        let store = InMemoryPairingStore()
        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let finished = expectation(description: "rejected")
        var outcome: Result<PairingRecord, Error>!
        coordinator.pair(host: "127.0.0.1", port: 47_800, pairingString: "TOOSHORT") { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10.0)
        guard case .failure(let error) = outcome! else {
            return XCTFail("a short pairing string must be rejected")
        }
        XCTAssertEqual(error as? PairingStringError, .wrongDecodedLength(5))
        XCTAssertNil(try store.load())
    }

    func testStartIfPairedReconnectsFromAStoredRecord() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: server.fingerprint))

        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }
        coordinator.startIfPaired()
        waitForState(coordinator, description: "idle from stored pairing") { $0 == .idle }
    }

    /// Temporary Phase 1 scaffolding: the manual Start/Stop that Phase 3's demand
    /// detection replaces.
    func testManualStartAndStopDriveASession() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        coordinator.requestStart()
        waitForState(coordinator, description: "streaming") { state in
            if case .streaming = state { return true }
            return false
        }
        XCTAssertGreaterThan(coordinator.audioBytesReceived, 0)

        coordinator.requestStop()
        waitForState(coordinator, description: "idle again") { $0 == .idle }
    }

    /// Design spec §8: network drops mid-session — the Mac reconnects with backoff.
    func testReconnectsAfterTheConnectionDrops() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        let disconnected = expectation(description: "disconnected")
        var sawDisconnected = false
        coordinator.onStateChange = { state in
            if !sawDisconnected && state == .disconnected {
                sawDisconnected = true
                disconnected.fulfill()
            }
        }
        server.dropConnections()
        wait(for: [disconnected], timeout: 20.0)

        // First backoff step is 0.5 s +/- 20%, so this must recover quickly.
        waitForState(coordinator, timeout: 30.0, description: "idle again after reconnect") { $0 == .idle }
    }

    /// The hard stop, end to end: a stored pin that does not match the presented
    /// certificate must stop dead, warn, and never retry.
    func testFingerprintMismatchStopsDeadAndDoesNotRetry() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: String(repeating: "00", count: 32)))

        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let warned = expectation(description: "user warned")
        var warning: (expected: String, presented: String)?
        coordinator.onFingerprintWarning = { expected, presented in
            warning = (expected, presented)
            warned.fulfill()
        }
        coordinator.startIfPaired()
        wait(for: [warned], timeout: 30.0)

        XCTAssertEqual(warning?.expected, String(repeating: "00", count: 32))
        XCTAssertEqual(warning?.presented, server.fingerprint)
        guard case .hardStop = coordinator.state else {
            return XCTFail("expected .hardStop, got \(coordinator.state)")
        }

        // No automatic retry, ever: the state must still be .hardStop after long
        // enough for several backoff steps to have fired.
        let settled = expectation(description: "no retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { settled.fulfill() }
        wait(for: [settled], timeout: 10.0)
        guard case .hardStop = coordinator.state else {
            return XCTFail("the agent recovered from a fingerprint mismatch on its own")
        }
    }

    func testUnpairClearsTheStoreAndReturnsToUnpaired() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        coordinator.unpair()
        waitForState(coordinator, description: "unpaired") { $0 == .unpaired }
        XCTAssertNil(try store.load())
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/ConnectionCoordinatorTests`
Expected: FAIL — compile error, `cannot find type 'ConnectionCoordinator' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/Net/ConnectionCoordinator.swift`:

```swift
import Foundation

public enum PairingError: Error, Equatable {
    case alreadyPairing
    case authenticationFailed(String)
    case transport(String)
}

extension PairingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyPairing:
            return "A pairing attempt is already in progress."
        case .authenticationFailed(let detail):
            return "The Windows agent rejected that pairing string (\(detail)). Check it and try again."
        case .transport(let detail):
            return "Could not reach the Windows agent: \(detail)"
        }
    }
}

/// Wires the pure units to the network: loads the pairing record, opens a pinned
/// TLS connection, runs the handshake, performs whatever `SessionController`
/// asks for, and reconnects with backoff — except after a fingerprint mismatch,
/// which is terminal.
///
/// All mutable state is confined to `queue`; every callback out is delivered on
/// the main queue so the SwiftUI layer can consume it directly.
public final class ConnectionCoordinator: ControlClientDelegate {
    public var onStateChange: ((AgentState) -> Void)?
    public var onNotice: ((String) -> Void)?
    public var onFingerprintWarning: ((_ expected: String, _ presented: String) -> Void)?

    private let store: PairingStore
    private let clientId: String
    private let queue = DispatchQueue(label: "com.sharedmic.coordinator")

    private var controller = SessionController()
    private var backoff = ReconnectPolicy()
    private var transport: PinnedTLSTransport?
    private var client: ControlClient?
    private var record: PairingRecord?
    private var reconnectTimer: DispatchSourceTimer?
    private var startTimeoutTimer: DispatchSourceTimer?
    private var stopTimeoutTimer: DispatchSourceTimer?
    private var pairingInProgress = false
    private var pendingPairing: (record: PairingRecord, completion: (Result<PairingRecord, Error>) -> Void)?
    private var shuttingDown = false
    private var requestCounter = 0
    private var totalAudioBytes = 0

    public init(store: PairingStore, clientId: String = Host.current().localizedName ?? "mac") {
        self.store = store
        self.clientId = clientId
        if let loaded = try? store.load() {
            self.record = loaded
            self.controller = SessionController(state: .disconnected)
        }
    }

    // MARK: - Observable state

    public var state: AgentState { queue.sync { controller.state } }
    public var deviceLabel: String { queue.sync { controller.deviceLabel } }
    public var micPresent: Bool { queue.sync { controller.micPresent } }
    public var pairedHost: String? { queue.sync { record?.host } }
    public var audioBytesReceived: Int { queue.sync { totalAudioBytes + (client?.audioBytesReceived ?? 0) } }

    // MARK: - Lifecycle

    public func startIfPaired() {
        queue.async { [weak self] in
            guard let self, self.record != nil else { return }
            self.openConnection()
        }
    }

    public func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shuttingDown = true
            self.cancelReconnect()
            self.cancelSessionTimers()
            self.teardownConnection()
        }
    }

    // MARK: - Pairing

    /// protocol-v1 §11: the pairing string carries only the token. The certificate
    /// fingerprint is taken trust-on-first-use from this one connection and is
    /// persisted **only after HELLO_ACK proves the token** — a peer that cannot
    /// answer the challenge never gets pinned.
    public func pair(host: String,
                     port: UInt16,
                     pairingString: String,
                     completion: @escaping (Result<PairingRecord, Error>) -> Void) {
        let token: Data
        do {
            token = try PairingString.decode(pairingString)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard !self.pairingInProgress else {
                DispatchQueue.main.async { completion(.failure(PairingError.alreadyPairing)) }
                return
            }
            self.pairingInProgress = true
            self.cancelReconnect()
            self.teardownConnection()

            let transport = PinnedTLSTransport()
            self.transport = transport
            transport.connect(host: host, port: port, mode: .trustOnFirstUse) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .failure(let error):
                        self.pairingInProgress = false
                        self.teardownConnection()
                        DispatchQueue.main.async {
                            completion(.failure(PairingError.transport(String(describing: error))))
                        }
                    case .success(let presentedFingerprint):
                        let candidate = PairingRecord(host: host,
                                                      port: port,
                                                      token: token,
                                                      certificateFingerprint: presentedFingerprint)
                        self.beginPairingHandshake(transport: transport,
                                                   candidate: candidate,
                                                   completion: completion)
                    }
                }
            }
        }
    }

    private func beginPairingHandshake(transport: PinnedTLSTransport,
                                       candidate: PairingRecord,
                                       completion: @escaping (Result<PairingRecord, Error>) -> Void) {
        let client = ControlClient(transport: transport, token: candidate.token, clientId: clientId)
        self.client = client
        self.pendingPairing = (candidate, completion)
        client.delegate = self
        client.begin()
    }

    public func unpair() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelReconnect()
            self.cancelSessionTimers()
            try? self.store.clear()
            self.record = nil
            self.apply(self.controller.handle(.unpairedByUser))
            self.publishState()
        }
    }

    // MARK: - Manual session control
    //
    // TEMPORARY PHASE 1 SCAFFOLDING. Phase 3 replaces both of these with
    // AudioDemandObserver-driven activation; nothing else should ever call them.

    public func requestStart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.userRequestedStart(requestId: self.nextRequestId())))
            self.publishState()
        }
    }

    public func requestStop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.userRequestedStop(requestId: self.nextRequestId())))
            self.publishState()
        }
    }

    // MARK: - Connection

    private func openConnection() {
        guard !shuttingDown, let record else { return }
        if case .hardStop = controller.state { return }
        teardownConnection()

        apply(controller.handle(.connectAttemptStarted))
        publishState()

        let transport = PinnedTLSTransport()
        self.transport = transport
        transport.connect(host: record.host,
                          port: record.port,
                          mode: .pinned(fingerprint: record.certificateFingerprint)) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                switch result {
                case .success:
                    let client = ControlClient(transport: transport,
                                               token: record.token,
                                               clientId: self.clientId)
                    self.client = client
                    client.delegate = self
                    client.begin()
                case .failure(let error):
                    if case .fingerprintMismatch(let expected, let presented) = (error as? TransportError) {
                        self.apply(self.controller.handle(
                            .fingerprintMismatch(expected: expected, presented: presented)))
                    } else {
                        self.apply(self.controller.handle(
                            .connectionLost(reason: String(describing: error))))
                    }
                    self.publishState()
                }
            }
        }
    }

    private func teardownConnection() {
        if let client { totalAudioBytes += client.audioBytesReceived }
        client?.stop()
        client = nil
        transport?.close()
        transport = nil
    }

    // MARK: - Actions

    private func apply(_ actions: [SessionAction]) {
        for action in actions {
            switch action {
            case .sendStart(let requestId):
                client?.send(.start(requestId: requestId, preferredFormat: .v1))
            case .sendStop(let requestId, let sessionId):
                client?.send(.stop(requestId: requestId, sessionId: sessionId))
            case .armStartTimeout(let requestId, let seconds):
                armStartTimeout(requestId: requestId, seconds: seconds)
            case .armStopTimeout(let requestId, let seconds):
                armStopTimeout(requestId: requestId, seconds: seconds)
            case .scheduleReconnect:
                scheduleReconnect()
            case .closeConnection:
                teardownConnection()
            case .warnFingerprintMismatch(let expected, let presented):
                DispatchQueue.main.async { [weak self] in
                    self?.onFingerprintWarning?(expected, presented)
                }
            case .notify(let message):
                DispatchQueue.main.async { [weak self] in
                    self?.onNotice?(message)
                }
            }
        }
    }

    private func nextRequestId() -> String {
        requestCounter += 1
        return "req-\(requestCounter)-\(UUID().uuidString.prefix(8))"
    }

    private func armStartTimeout(requestId: String, seconds: TimeInterval) {
        startTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.startTimedOut(requestId: requestId)))
            self.publishState()
        }
        timer.resume()
        startTimeoutTimer = timer
    }

    private func armStopTimeout(requestId: String, seconds: TimeInterval) {
        stopTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.stopTimedOut(requestId: requestId)))
            self.publishState()
        }
        timer.resume()
        stopTimeoutTimer = timer
    }

    private func cancelSessionTimers() {
        startTimeoutTimer?.cancel(); startTimeoutTimer = nil
        stopTimeoutTimer?.cancel(); stopTimeoutTimer = nil
    }

    private func scheduleReconnect() {
        guard !shuttingDown, record != nil else { return }
        if case .hardStop = controller.state { return }
        cancelReconnect()
        let delay = backoff.nextDelay()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.openConnection()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    private func publishState() {
        let current = controller.state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(current)
        }
    }

    // MARK: - ControlClientDelegate

    public func controlClientDidAuthenticate(_ client: ControlClient,
                                             micPresent: Bool,
                                             deviceLabel: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if let pending = self.pendingPairing {
                // The token proved out on this connection, so the certificate it
                // presented is now trustworthy enough to pin.
                self.pendingPairing = nil
                self.pairingInProgress = false
                do {
                    try self.store.save(pending.record)
                } catch {
                    DispatchQueue.main.async { pending.completion(.failure(error)) }
                    return
                }
                self.record = pending.record
                self.apply(self.controller.handle(.paired))
                DispatchQueue.main.async { pending.completion(.success(pending.record)) }
            }
            self.backoff.reset()
            self.apply(self.controller.handle(.authenticated(micPresent: micPresent,
                                                             deviceLabel: deviceLabel)))
            self.publishState()
        }
    }

    public func controlClient(_ client: ControlClient, didReceive message: ControlMessage) {
        queue.async { [weak self] in
            guard let self else { return }
            switch message {
            case .startAck(let requestId, let sessionId, _):
                self.startTimeoutTimer?.cancel(); self.startTimeoutTimer = nil
                self.apply(self.controller.handle(.startAcked(requestId: requestId, sessionId: sessionId)))
            case .startNack(let requestId, let reason, let holderName):
                self.startTimeoutTimer?.cancel(); self.startTimeoutTimer = nil
                // The advisory holder name is passed straight through; the
                // controller decides what to do when it is nil or blank.
                self.apply(self.controller.handle(
                    .startNacked(requestId: requestId, reason: reason, holderName: holderName)))
            case .stopAck(let requestId, _):
                self.stopTimeoutTimer?.cancel(); self.stopTimeoutTimer = nil
                self.apply(self.controller.handle(.stopAcked(requestId: requestId)))
            case .status(let micPresent, let active, let deviceLabel):
                self.apply(self.controller.handle(.statusReceived(micPresent: micPresent,
                                                                  active: active,
                                                                  deviceLabel: deviceLabel)))
            default:
                // GREETING/HELLO/HELLO_ACK are consumed by ControlClient; PING/PONG
                // never reach here. Anything else is a server-side message this
                // phase has no use for.
                break
            }
            self.publishState()
        }
    }

    public func controlClient(_ client: ControlClient, didCloseWith error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelSessionTimers()
            if let pending = self.pendingPairing {
                // Closed before HELLO_ACK: the token was wrong, or the peer hung up.
                self.pendingPairing = nil
                self.pairingInProgress = false
                self.teardownConnection()
                DispatchQueue.main.async {
                    pending.completion(.failure(
                        PairingError.authenticationFailed(error.map { String(describing: $0) } ?? "connection closed")))
                }
                return
            }
            self.teardownConnection()
            self.apply(self.controller.handle(
                .connectionLost(reason: error.map { String(describing: $0) } ?? "connection closed")))
            self.publishState()
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/ConnectionCoordinatorTests`
Expected: PASS — `** TEST SUCCEEDED **`, 9 test cases.

The `switch` in `apply(_:)` is exhaustive over exactly the eight `SessionAction` cases Task 9 defines: `sendStart`, `sendStop`, `armStartTimeout`, `armStopTimeout`, `scheduleReconnect`, `closeConnection`, `warnFingerprintMismatch`, `notify`. There is deliberately no `default:` — adding a ninth action in a later phase should break this build rather than be silently ignored.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/Net/ConnectionCoordinator.swift macos/SharedMicTests/ConnectionCoordinatorTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): connection coordinator for pairing, sessions and reconnect

Trust-on-first-use pairing that persists the pin only after HELLO_ACK proves the
token, pinned reconnects with 0.5s-to-30s jittered backoff, START/STOP response
timeouts, and a fingerprint mismatch that warns the user and never retries.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Menu-bar UI

**Files:**
- Create: `macos/SharedMic/App/AppModel.swift`, `macos/SharedMic/App/MenuBarView.swift`
- Modify: `macos/SharedMic/App/SharedMicApp.swift` (created in Task 1)
- Test: `macos/SharedMicTests/AppModelTests.swift`

**Interfaces:**
- Consumes: `ConnectionCoordinator`/`PairingError` (Task 13), `KeychainPairingStore`/`InMemoryPairingStore`/`PairingStore` (Task 7), `AgentState` (Task 9), `SharedMicProtocol.defaultPort` (Task 1), `MockWindowsServerProcess` (Task 10).
- Produces:
  - `@MainActor public final class AppModel: ObservableObject` — `init(store: PairingStore = KeychainPairingStore(), clientId: String = Host.current().localizedName ?? "mac", autoStart: Bool = true)`; `@Published private(set) var state: AgentState`, `@Published private(set) var deviceLabel: String`, `@Published private(set) var micPresent: Bool`, `@Published private(set) var pairedHost: String?`, `@Published private(set) var lastNotice: String?`, `@Published private(set) var fingerprintWarning: String?`, `@Published private(set) var audioBytesReceived: Int`, `@Published var hostField: String`, `@Published var portField: String`, `@Published var pairingField: String`, `@Published private(set) var isPairing: Bool`; `func pair()`, `func unpair()`, `func startSession()`, `func stopSession()`, `func quit()`; `var statusText: String { get }`, `var canStart: Bool { get }`, `var canStop: Bool { get }`
  - `struct MenuBarView: View`
  - `SharedMicApp` updated to host `MenuBarView` in a `.window`-style `MenuBarExtra`

**The Start and Stop commands in this menu are temporary Phase 1 scaffolding.** They exist only so a session can be driven by hand while there is no demand detection. Phase 3 replaces them with `AudioDemandObserver`; the menu items and `AppModel.startSession()`/`stopSession()` go away with them.

- [ ] **Step 1: Write the failing test**

Create `macos/SharedMicTests/AppModelTests.swift`:

```swift
import XCTest
@testable import SharedMic

@MainActor
final class AppModelTests: XCTestCase {

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 30.0,
                           _ condition: @escaping () -> Bool) {
        let met = expectation(description: description)
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if condition() {
                timer?.invalidate()
                met.fulfill()
            }
        }
        wait(for: [met], timeout: timeout)
        timer?.invalidate()
    }

    func testStartsUnpairedWithSensibleDefaults() {
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false)
        XCTAssertEqual(model.state, .unpaired)
        XCTAssertEqual(model.statusText, "Not paired")
        XCTAssertEqual(model.portField, String(SharedMicProtocol.defaultPort))
        XCTAssertNil(model.pairedHost)
        XCTAssertFalse(model.canStart)
        XCTAssertFalse(model.canStop)
    }

    func testPairingFromTheFormReachesIdle() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false)

        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()

        waitUntil("idle after pairing") { model.state == .idle }
        XCTAssertEqual(model.statusText, "Idle")
        XCTAssertEqual(model.deviceLabel, "Mock USB Mic")
        XCTAssertEqual(model.pairedHost, "127.0.0.1")
        XCTAssertTrue(model.canStart)
        XCTAssertFalse(model.canStop)
        XCTAssertFalse(model.isPairing)
        // The pairing string is cleared from the UI once it has been consumed.
        XCTAssertEqual(model.pairingField, "")
    }

    func testAMistypedPairingStringSurfacesANotice() {
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false)
        model.hostField = "127.0.0.1"
        model.portField = String(SharedMicProtocol.defaultPort)
        model.pairingField = "NOPE"
        model.pair()

        waitUntil("notice shown") { model.lastNotice != nil }
        XCTAssertEqual(model.state, .unpaired)
        XCTAssertFalse(model.isPairing)
    }

    /// Temporary Phase 1 scaffolding, exercised here so the manual path is known
    /// to work before it is used for hand testing.
    func testManualStartAndStopFlipTheAffordances() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false)
        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()
        waitUntil("idle") { model.state == .idle }

        model.startSession()
        waitUntil("streaming") {
            if case .streaming = model.state { return true }
            return false
        }
        XCTAssertEqual(model.statusText, "Streaming")
        XCTAssertFalse(model.canStart)
        XCTAssertTrue(model.canStop)

        model.stopSession()
        waitUntil("idle again") { model.state == .idle }
        XCTAssertTrue(model.canStart)
    }

    /// Another paired Mac holding the microphone must read as "In use by Mac
    /// Studio" in the menu bar, not as a generic failure — and as "In use by
    /// another Mac" when Windows sent no advisory name.
    ///
    /// This is checked against the state mapping rather than against the mock,
    /// because `MockWindowsServer` gives every connection its own session and
    /// never sends SESSION_IN_USE. `AppModel.statusText` IS `state.displayName`,
    /// so these are the exact strings the menu bar renders.
    func testMenuBarTextWhenAnotherMacHoldsTheMicrophone() {
        var controller = SessionController()
        _ = controller.handle(.paired)
        _ = controller.handle(.connectAttemptStarted)
        _ = controller.handle(.authenticated(micPresent: true, deviceLabel: "USB Microphone"))
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startNacked(requestId: "req-1", reason: "SESSION_IN_USE", holderName: "Mac Studio"))

        XCTAssertEqual(controller.state.displayName, "In use by Mac Studio")

        var anonymous = controller
        _ = anonymous.handle(.userRequestedStart(requestId: "req-2"))
        _ = anonymous.handle(.startNacked(requestId: "req-2", reason: "SESSION_IN_USE", holderName: nil))

        XCTAssertEqual(anonymous.state.displayName, "In use by another Mac")
    }

    func testFingerprintMismatchSurfacesAProminentWarning() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: String(repeating: "00", count: 32)))
        let model = AppModel(store: store, clientId: "mac-tests", autoStart: true)

        waitUntil("warning surfaced") { model.fingerprintWarning != nil }
        let warning = try XCTUnwrap(model.fingerprintWarning)
        XCTAssertTrue(warning.contains(server.fingerprint), "the presented fingerprint must be shown")
        XCTAssertTrue(warning.contains("re-pair") || warning.contains("Re-pair"))
        XCTAssertEqual(model.statusText, "Certificate mismatch")
        XCTAssertFalse(model.canStart, "a hard stop must not offer to start a session")
    }

    func testUnpairReturnsToTheUnpairedForm() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let model = AppModel(store: store, clientId: "mac-tests", autoStart: false)
        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()
        waitUntil("idle") { model.state == .idle }

        model.unpair()
        waitUntil("unpaired") { model.state == .unpaired }
        XCTAssertNil(model.pairedHost)
        XCTAssertNil(try store.load())
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/AppModelTests`
Expected: FAIL — compile error, `cannot find type 'AppModel' in scope`.

- [ ] **Step 3: Implement**

Create `macos/SharedMic/App/AppModel.swift`:

```swift
import Foundation
import SwiftUI

/// The SwiftUI-facing view of `ConnectionCoordinator`. Holds no protocol logic of
/// its own — every value here is published straight from the coordinator's
/// callbacks, which already arrive on the main queue.
@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var state: AgentState = .unpaired
    @Published public private(set) var deviceLabel: String = ""
    @Published public private(set) var micPresent: Bool = false
    @Published public private(set) var pairedHost: String?
    @Published public private(set) var lastNotice: String?
    @Published public private(set) var fingerprintWarning: String?
    @Published public private(set) var audioBytesReceived: Int = 0
    @Published public private(set) var isPairing: Bool = false

    @Published public var hostField: String = ""
    @Published public var portField: String = String(SharedMicProtocol.defaultPort)
    @Published public var pairingField: String = ""

    private let coordinator: ConnectionCoordinator
    private var refreshTimer: Timer?

    public init(store: PairingStore = KeychainPairingStore(),
                clientId: String = Host.current().localizedName ?? "mac",
                autoStart: Bool = true) {
        coordinator = ConnectionCoordinator(store: store, clientId: clientId)
        pairedHost = coordinator.pairedHost
        hostField = coordinator.pairedHost ?? ""
        state = coordinator.state

        coordinator.onStateChange = { [weak self] newState in
            guard let self else { return }
            Task { @MainActor in
                self.state = newState
                self.deviceLabel = self.coordinator.deviceLabel
                self.micPresent = self.coordinator.micPresent
                self.pairedHost = self.coordinator.pairedHost
                self.audioBytesReceived = self.coordinator.audioBytesReceived
            }
        }
        coordinator.onNotice = { [weak self] message in
            Task { @MainActor in self?.lastNotice = message }
        }
        coordinator.onFingerprintWarning = { [weak self] expected, presented in
            Task { @MainActor in
                self?.fingerprintWarning = """
                    The Windows agent presented a different certificate than the one you paired with.
                    Pinned:    \(expected)
                    Presented: \(presented)
                    SharedMic has stopped and will not reconnect. If you did not just reinstall or \
                    re-pair the Windows agent, treat this as a possible attack. Re-pair explicitly to continue.
                    """
            }
        }

        if autoStart {
            coordinator.startIfPaired()
        }
    }

    public var statusText: String { state.displayName }

    public var canStart: Bool {
        guard micPresent else { return false }
        // Start stays offered while another Mac holds the microphone: there is
        // no "the mic is free now" message in protocol version 1, so retrying is
        // how this Mac finds out. It must NOT be offered from .hardStop,
        // .streaming, .starting, .stopping, .disconnected or .unpaired.
        if case .sessionInUse = state { return true }
        return state == .idle
    }

    public var canStop: Bool {
        if case .streaming = state { return true }
        return false
    }

    public func pair() {
        guard !isPairing else { return }
        let port = UInt16(portField) ?? SharedMicProtocol.defaultPort
        let host = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairingString = pairingField
        isPairing = true
        lastNotice = nil
        fingerprintWarning = nil

        coordinator.pair(host: host, port: port, pairingString: pairingString) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isPairing = false
                switch result {
                case .success(let record):
                    // Never keep the pairing string in memory or on screen once it
                    // has served its purpose.
                    self.pairingField = ""
                    self.pairedHost = record.host
                    self.lastNotice = "Paired with \(record.host)."
                case .failure(let error):
                    self.lastNotice = String(describing: error)
                }
            }
        }
    }

    public func unpair() {
        coordinator.unpair()
        pairedHost = nil
        fingerprintWarning = nil
        lastNotice = "Unpaired."
    }

    // TEMPORARY PHASE 1 SCAFFOLDING — replaced by AudioDemandObserver in Phase 3.
    public func startSession() { coordinator.requestStart() }

    // TEMPORARY PHASE 1 SCAFFOLDING — replaced by AudioDemandObserver in Phase 3.
    public func stopSession() { coordinator.requestStop() }

    public func quit() {
        coordinator.shutdown()
        NSApplication.shared.terminate(nil)
    }
}
```

Create `macos/SharedMic/App/MenuBarView.swift`:

```swift
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)
                Text(model.statusText)
                    .font(.headline)
            }

            if let warning = model.fingerprintWarning {
                Text(warning)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let host = model.pairedHost {
                Text("Windows host: \(host)")
                    .font(.caption)
                Text("Microphone: \(model.deviceLabel.isEmpty ? "unknown" : model.deviceLabel)\(model.micPresent ? "" : " (unavailable)")")
                    .font(.caption)
                Text("Audio received: \(byteCountText)")
                    .font(.caption)
            } else {
                pairingForm
            }

            if let notice = model.lastNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // TEMPORARY PHASE 1 SCAFFOLDING. There is no demand detection yet, so a
            // session has to be driven by hand for testing. Phase 3 removes both of
            // these and starts sessions automatically from AudioDemandObserver.
            HStack {
                Button("Start session") { model.startSession() }
                    .disabled(!model.canStart)
                Button("Stop session") { model.stopSession() }
                    .disabled(!model.canStop)
            }
            Text("Start/Stop are temporary: automatic activation arrives in Phase 3.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                if model.pairedHost != nil {
                    Button("Unpair…") { model.unpair() }
                }
                Spacer()
                Button("Quit SharedMic") { model.quit() }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var pairingForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pair with the Windows agent")
                .font(.subheadline)
            TextField("Host or IP address", text: $model.hostField)
            TextField("Port", text: $model.portField)
            TextField("Pairing string", text: $model.pairingField)
                .font(.system(.body, design: .monospaced))
            Button(model.isPairing ? "Pairing…" : "Pair") { model.pair() }
                .disabled(model.isPairing || model.hostField.isEmpty || model.pairingField.isEmpty)
            Text("The Windows tray shows a 58-character pairing string. Hyphens, spaces and lowercase are all fine.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .streaming: return .green
        case .idle: return .blue
        case .connecting, .starting, .stopping: return .yellow
        case .degraded: return .orange
        case .hardStop: return .red
        case .disconnected, .unpaired: return .gray
        }
    }

    private var byteCountText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(model.audioBytesReceived))
    }
}
```

Replace `macos/SharedMic/App/SharedMicApp.swift` entirely with:

```swift
import SwiftUI

@main
struct SharedMicApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: labelSymbol)
        }
        // `.window` rather than the default `.menu`: the pairing form contains
        // TextFields, which a menu-style MenuBarExtra cannot host.
        .menuBarExtraStyle(.window)
    }

    private var labelSymbol: String {
        switch model.state {
        case .streaming: return "mic.fill"
        case .hardStop: return "mic.slash.fill"
        default: return "mic"
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run: `ruby macos/project.rb && xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -only-testing:SharedMicTests/AppModelTests`
Expected: PASS — `** TEST SUCCEEDED **`, 7 test cases.

Then run the whole suite:

Run: `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64'`
Expected: PASS — `** TEST SUCCEEDED **`.

Then a manual smoke test, which is the first time a human sees the agent work. In one terminal, from the repository root:

```sh
harness/.venv/bin/python macos/SharedMicTests/Support/mock_windows_server.py "$PWD/harness" 47800
```

In another:

```sh
xcodebuild build -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/SharedMicBuild
open /tmp/SharedMicBuild/Build/Products/Debug/SharedMic.app
```

Expected: a microphone icon appears in the menu bar with no Dock icon. Click it, enter `127.0.0.1`, port `47800`, paste the `pairing` value the Python process printed, and press Pair. The status goes Connecting → Idle and shows `Mock USB Mic`. Press **Start session** and the status goes Streaming with "Audio received" climbing at roughly 96 KB/s; press **Stop session** and it stops climbing. Type `quit` in the Python terminal and the status goes Disconnected, then cycles back through Connecting as the backoff retries.

- [ ] **Step 5: Commit**

```bash
git add macos/SharedMic/App macos/SharedMicTests/AppModelTests.swift macos/SharedMic.xcodeproj
git commit -m "$(cat <<'EOF'
feat(macos): menu-bar UI with pairing, status and temporary Start/Stop

MenuBarExtra in window style so the pairing form can host text fields; connection
state, Windows host, microphone label and received-byte total; a prominent,
selectable warning on certificate mismatch. Start/Stop are labelled temporary
Phase 1 scaffolding and are removed when Phase 3 adds demand detection.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 1 completion checklist

Run once, at the end, before opening the PR.

- [ ] `ruby macos/project.rb` regenerates the project with no uncommitted diff left behind
- [ ] `xcodebuild test -project macos/SharedMic.xcodeproj -scheme SharedMic -destination 'platform=macOS,arch=arm64'` — `** TEST SUCCEEDED **`
- [ ] `cd harness && .venv/bin/python -m pytest -v` still passes (101 tests); nothing in this phase modifies `harness/` or `protocol/`
- [ ] `git status` shows no changes under `protocol/`, `harness/`, `docs/superpowers/specs/`, `probes/`, or `docs/superpowers/plans/2026-08-10-phase-1-windows-agent.md`
- [ ] `grep -rn "AudioUnit\|CoreAudio\|AudioToolbox\|BlackHole\|kAudioProcess" macos/SharedMic` returns nothing — Phase 1 touches no audio device and never changes the system input device (spec §3.4)
- [ ] The manual smoke test in Task 14 has been run against the Python mock on port 47800
- [ ] The `SESSION_IN_USE` paths have been verified by `SessionControllerTests` and `AppModelTests`, **not** by the mock — `MockWindowsServer` gives every connection its own session and never sends that reason, so a green mock run says nothing about them. Confirm by eye that the menu bar reads `In use by <name>` and `In use by another Mac`, per those tests' expectations
- [ ] `CLAUDE.md`'s **Commands** section is updated with the two verified macOS commands (`ruby macos/project.rb`, the `xcodebuild test` line) — that file says to add real, verified commands as each project lands

## Phase 2 handoff

- `AudioFrameCodec` is written and vector-tested but has no runtime caller; Phase 2 wires it to `PCMRingBuffer`.
- `ControlClient.handleAudio` is the single insertion point: it currently validates, counts, and discards. Phase 2 replaces the discard with a hand-off to the ring buffer, and must keep the strict 1,932-byte check.
- `FrameBuffer` drops consumed bytes with `removeSubrange` from the front, which is O(n) per frame. Harmless for control traffic at 50 fps of 1,937-byte frames on a modern machine, but it is the first thing to profile if Phase 2 sees CPU in the network path.
- `ConnectionCoordinator.requestStart()`/`requestStop()` and the menu's Start/Stop buttons are the temporary manual drivers. Phase 3 deletes them and drives the same `SessionEvent.userRequestedStart`/`userRequestedStop` from `AudioDemandObserver`.
- Nothing in this phase selects, sets, or prefers an audio device, so spec §3.4's "BlackHole should not be the system input" recommendation is not contradicted. Phase 2 must resolve BlackHole explicitly by UID and must not change the system input or output device.

---

## Scope coverage map

Every Phase 1 scope item, and the task that implements it.

| Scope item | Task(s) |
|---|---|
| TLS 1.3 client connecting on TCP 47800 | 1 (`defaultPort`), 11 (`PinnedTLSTransport`, TLS 1.3 min *and* max), 14 (manual smoke on 47800) |
| Certificate fingerprint pinning, lowercase hex SHA-256 of DER | 6 (`AuthProof.fingerprint(ofDER:)`), 11 (verify block) |
| CA and hostname validation deliberately disabled | 11 (`sec_protocol_options_set_verify_block` replaces trust evaluation; `SecTrustEvaluate` is never called) |
| Mismatch is a hard stop — raise, close, no retry, no silent re-pair, prominent warning | 11 (`.waiting` treated as terminal, `fingerprintMismatch` recorded), 9 (`.hardStop` emits no `scheduleReconnect` and swallows later events), 13 (coordinator refuses to reconnect or open in `.hardStop`), 14 (prominent selectable warning) |
| Pairing: accept the string, decode it, store token + pinned fingerprint in the Keychain | 6 (`PairingString`), 7 (`KeychainPairingStore`), 13 (`pair`, TOFU-then-prove), 14 (pairing form) |
| `GREETING` → `HELLO` → `HELLO_ACK` with HMAC-SHA256 challenge-response | 6 (`AuthProof.proof`), 12 (`ControlClient` handshake, HMAC over raw nonce bytes) |
| Frame envelope codec byte-matching the vectors | 2, 5 |
| Control-message codec byte-matching the vectors | 3, 5 |
| Heartbeat: `PING` on the specified interval, `PONG` sequence verified, dead peer detected | 8 (`HeartbeatMonitor`), 12 (timer loop and violation handling) |
| Reconnect with exponential backoff 0.5 s → 30 s cap, jittered | 8 (`ReconnectPolicy`), 13 (`scheduleReconnect`, reset on `HELLO_ACK`) |
| Session lifecycle `START`/`STOP`, idempotent, with the specified timeouts | 9 (`SessionController`), 13 (2 s / 1 s timers, reply routing) |
| Another paired Mac holding the microphone: `SESSION_IN_USE` shown as "In use by \<name\>", and "In use by another Mac" when the advisory `holderName` is absent | 3 (optional `holderName` field), 9 (`.sessionInUse` state and its transitions), 13 (dispatch passes `holderName` through), 14 (menu-bar text and retryable Start) |
| Minimal menu-bar UI: state, pairing field, temporary Start/Stop, quit | 14 |
| Golden-vector conformance as a real iterating test | 5 |
| Endianness trap: big-endian envelope/header, little-endian PCM | 4 (codec and its tests), 5 (`testAudioVectorPCMIsLittleEndian` against real vector data) |
| Developable against the Python mock with no Windows machine | 10 (launchable mock), 11, 12, 13, 14 (all network tests run against it) |

**Explicitly out of scope and absent from every task:** Core Audio in any form, BlackHole, `PCMRingBuffer`, `AudioRenderer`, `AudioDemandObserver`, demand detection, the kill switch, the force-on hold, launch-at-login, the diagnostics view, the level meter, and mDNS. The completion checklist greps for the audio frameworks to keep it that way.

## Notes for the implementer

- **Task order matters for compilation, not for reading.** Tasks 1–9 are pure and have no dependency on a running mock; 10–14 need `harness/.venv/bin/python` to exist. If the virtualenv is missing, rebuild it per `harness/README.md` before starting Task 10.
- **Re-run `ruby macos/project.rb` whenever a `.swift` file is added or removed**, and commit the regenerated `project.pbxproj` alongside the sources. Forgetting this produces a confusing "cannot find X in scope" for a file that plainly exists.
- **Every network test starts a real Python child process and a real TLS connection.** They are slower than the pure tests (roughly 1–3 s each) and they bind ephemeral ports, so they are safe to run in parallel with anything except another copy of themselves on a fixed port. The mock always binds port 0 in tests; only the manual smoke test uses 47800.
- **If `testFingerprintMismatchIsAHardStop` hangs instead of failing fast**, the `.waiting` branch in `PinnedTLSTransport` is missing or wrong. That is the single most important behaviour in the phase and the one Network.framework makes easiest to get wrong.
- **A green mock run does not mean the multi-Mac paths work.** `MockWindowsServer` accepts any connection that proves its single token and gives each one its own `_session_id`, so it never sends `START_NACK{SESSION_IN_USE}` and never refuses a second client. Everything about another Mac holding the microphone is proved by `SessionControllerTests` and `ControlCodecTests`, which are pure and fast — treat a change there as a change to a contract, not to a detail. The Windows plan covers the other side of the same blind spot.

