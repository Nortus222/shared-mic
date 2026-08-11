# Windows Agent Phase 1 — Transport and Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Windows tray agent that **several** macOS clients (or the Python `MockMacClient`) can connect to over TLS 1.3, pair with individually, authenticate against by HMAC challenge-response, and hold healthy, heartbeat-monitored connections with — while **at most one of them holds the microphone session at a time** — producing wire bytes that byte-match `protocol/vectors/*.json`, and capturing no audio at all.

**Architecture:** A single `SharedMic.Agent` project holds four layers: a pure `Protocol/` codec layer (envelope framing, audio-payload framing, canonical control-message JSON) that is the only thing the golden-vector tests touch; a `Security/` layer (pairing token, base32 pairing string, HMAC proof, rate limiter, P-256 device certificate, DPAPI-protected identity store, DPAPI-protected paired-device list); a `Net/` layer (TLS listener bound to private interfaces, incremental frame reader, priority send queue, and the `ControlConnection` state machine that runs the handshake, session lifecycle and heartbeat); and a thin `Ui/` tray shell. `Session/SessionStateMachine` is a pure transition function with no I/O, exactly as spec §3.1 requires; `Session/SessionArbiter` is the thread-safe shell around it that grants the one session to one connection at a time. Every network-facing task is verified twice: by a C# test over a loopback socket, and by pointing the Python `MockMacClient` at the running agent.

**Tech Stack:** C# 13 on .NET 10 (`net10.0-windows`), WinForms `NotifyIcon` tray, `SslStream`/Schannel for TLS 1.3, `System.Text.Json` (`Utf8JsonWriter` with an explicit ordinal-sorted-key canonical writer), `System.Security.Cryptography` (ECDsa P-256, HMACSHA256, `ProtectedData`/DPAPI), xUnit for tests, and the Phase 0 Python harness (`harness/sharedmic_protocol`) as the interoperability peer.

## Global Constraints

Every task implicitly includes all of these. Values are copied verbatim from `protocol/protocol-v1.md` and `docs/superpowers/specs/2026-08-08-shared-mic-design.md`.

**Where work happens.** Feature work happens in a worktree at `.claude/worktrees/phase-1-windows-agent` on branch `feat/phase-1-windows-agent`. **PR target branch is `main`** (repo `CLAUDE.md`). Never commit in the main checkout.

**Which machine runs which step.**

- Every `dotnet` command in this plan runs **on the Windows host**, which has the .NET 10 SDK (confirmed by the Phase 0 WASAPI probe building `net10.0-windows`). The project targets `net10.0-windows` for WinForms and DPAPI, so the tests are not runnable on the Mac. The Mac in this repo has only .NET SDK 6.0.x installed — do not attempt `dotnet build` there.
- Every `harness/.venv/bin/python` command runs **on the Mac** (or on any machine with the harness virtualenv). On Windows the equivalent interpreter path is `harness\.venv\Scripts\python.exe` after creating a venv there.
- Writing code, reading vectors, and reviewing diffs can happen anywhere.
- **There is no bare `python` on the Mac dev machine and the system `python3` has no `pytest`.** Always use the explicit interpreter path `harness/.venv/bin/python`. Note the leading dot: the directory is `harness/.venv`, not `harness/venv` (a stale, incomplete `harness/venv` also exists on the Mac and does not have `cryptography` installed — do not use it).

**`.csproj` XML rule.** **A `--` sequence must never appear inside an XML comment in a `.csproj`.** `<!-- 20-ms -- frames -->` is illegal XML and fails the build with `MSB4025`. Two such comments slipped through Phase 0 review because nobody on the Mac could compile the file. Write comments without doubled hyphens, or leave the comment out.

**Protocol version.** `PROTOCOL_VERSION = 1`. Every control message carries `"v": 1`. A control message whose `"v"` is not `1` MUST cause the connection to close (protocol §1).

**Transport (protocol §2).** One TCP connection carries control and audio, multiplexed. Default port **47800**. The listener binds to **private interfaces only** and is never exposed to the public Internet. **TLS 1.3** wraps the connection immediately after the TCP handshake; Windows is the TLS server. Trust is a pinned SHA-256 fingerprint of the certificate's DER encoding, lowercase hex — there is no CA anywhere in this design.

**Envelope (protocol §3).** 5-byte header:

```
uint8   type     // 1 = CONTROL, 2 = AUDIO
uint32  length   // payload byte count, BIG-ENDIAN
bytes   payload  // exactly `length` bytes
```

`length` is big-endian and counts only the payload. `type` MUST be `1` or `2`; any other value is a protocol violation and the receiver MUST **close the connection** rather than resynchronize. `length` MUST NOT exceed **1,048,576 bytes (1 MiB)**; above that the receiver MUST close. Partial buffers decode to "not yet", never to a wrong answer. Multiple envelopes are simply concatenated — no delimiter.

**Audio payload (protocol §4)** — built now, never emitted in Phase 1:

```
uint32  sequence            // BIG-ENDIAN, starts at 0 per session, +1 per frame
uint64  captureTimestampUs  // BIG-ENDIAN, microseconds since session START, +20000 per frame
bytes   pcm                 // exactly 1,920 bytes of s16le PCM
```

Audio header is **12 bytes**; audio payload length MUST be exactly **1,932** bytes; total audio envelope is **1,937** bytes. **The PCM samples are little-endian (`s16le`) even though the envelope and the audio header are big-endian.** Format is fixed and non-negotiable: 48,000 Hz, 1 channel, 16-bit signed, 20 ms frames, 960 samples per frame, 1,920 PCM bytes per frame, 50 frames per second.

**Control messages (protocol §5).** UTF-8 JSON object, no line breaks or padding, exactly the bytes `json.dumps(msg, sort_keys=True, separators=(",", ":"))` produces — **keys sorted lexicographically, recursively, and no ASCII escaping of non-ASCII characters**. Eleven types with required fields:

| Type | Required fields beyond `v` and `type` |
|---|---|
| `GREETING` | `serverId` (string), `nonce` (lowercase hex, 32 bytes / 64 chars) |
| `HELLO` | `clientId` (string), `mac` (lowercase hex HMAC-SHA256, 64 chars) |
| `HELLO_ACK` | `serverId` (string), `micPresent` (bool), `deviceLabel` (string) |
| `START` | `requestId` (string), `preferredFormat` (object) |
| `START_ACK` | `requestId`, `sessionId` (string), `format` (object) |
| `START_NACK` | `requestId`, `reason` (string). **Plus one optional advisory field, `holder` (string)** — the friendly name of the paired device that currently holds the session. It is emitted only when `reason` is `"SESSION_IN_USE"`, it is advisory (a receiver must work without it), and it is omitted entirely rather than sent as `null` or `""` when the holder has no usable name. |
| `STOP` | `requestId`, `sessionId` |
| `STOP_ACK` | `requestId`, `sessionId` |
| `STATUS` | `micPresent` (bool), `active` (bool), `deviceLabel` (string) — these three fields are the whole message, there is no `errors` field |
| `PING` | `seq` (integer) |
| `PONG` | `seq` (integer), which MUST equal the `PING`'s `seq` |

`preferredFormat`/`format` are always exactly `{"sampleRate":48000,"channels":1,"sampleFormat":"s16le"}`.

**Handshake (protocol §6).** Windows sends `GREETING{serverId, nonce}` immediately after the TLS handshake; `nonce` is 32 fresh random bytes, lowercase hex, **never reused across connections**. The Mac replies `HELLO{clientId, mac}` where `mac = lowercase_hex(HMAC-SHA256(token, nonce))` computed over the **raw 32 nonce bytes, not the hex string**. Windows verifies with a **constant-time** comparison **against every stored paired-device token in turn** and replies `HELLO_ACK`, or closes without replying. **The proof is the only thing that identifies the device.** `clientId` is a display label and is **explicitly untrusted**: it arrives unauthenticated, so it must never be used to look up which token to check, must never grant anything, and must never overwrite a device's owner-assigned friendly name. **The token never crosses the wire.** **5-second pre-auth deadline**: from TLS handshake completion, Windows gives the Mac 5 seconds to deliver a valid `HELLO` — no message, an unparseable message, a non-`HELLO` message, or a failing `mac` all mean close. No `START`/`STOP`/`PING`/`STATUS`/`AUDIO` is valid before authentication. **Any frame whose envelope `type` is not `CONTROL` is rejected unconditionally at any point in the connection's lifetime** — the Mac never sends `AUDIO`.

**Session lifecycle (protocol §7).** `START` and `STOP` are idempotent. A duplicate `START` **from the connection that already holds the session** returns `START_ACK` carrying the **existing** `sessionId` and format, does not create a second session, and does not reset the audio `sequence` counter. A `STOP` while idle still returns `STOP_ACK`; Windows does not reject `STOP` on `sessionId` mismatch — `STOP` means "make sure no session is active **on this connection**". A `STOP` sent with no session active MAY carry an empty string or a stale `sessionId`. `sequence` resets to `0` at each `START_ACK` (implement the reset; the harness does not prove it). **No `AUDIO` frame may be sent outside an active session, and an idle connection MUST carry zero audio bytes.** In Phase 1 a session carries zero audio bytes at all times, active or not.

**Several paired Macs, one session at a time.** This is the load-bearing change from the first draft of this plan, and it touches the identity store, the auth path, the session state, the connection and the tray:

- Windows keeps a **list of paired devices**. Each has its own fresh 256-bit token, an owner-assigned friendly name, and a paired-at timestamp. Devices are **individually revocable**; revoking one must not disturb any other.
- **Several paired Macs may be connected and authenticated at the same time.** There is no supersession: a newly authenticated connection never displaces an older one. (An earlier draft of the contract said the opposite. It is wrong and must not be implemented.)
- **At most one session exists across all connections.** The connection that received the `START_ACK` owns it.
- A `START` from any other connection while the session is held is answered `START_NACK{requestId, reason: "SESSION_IN_USE", holder}` — refused, but the connection stays up and healthy.
- **A session ends when its owning control connection closes, not only on `STOP`.** This is load-bearing: without it, a Mac that crashes or has its cable pulled locks every other Mac out until the 45-second dead-peer timer fires. **Dead-peer detection must end that peer's session too**, by the same path.
- A `STOP` from a connection that does not hold the session ends nothing and still returns `STOP_ACK`. Anything else would let any paired Mac cancel another's session by sending one message.

**What the Python mock cannot catch, and what to do about it.** `MockWindowsServer` is a per-connection test double: it accepts any connection that proves a single shared token, keeps no device list, and gives **each connection its own independent `_session_id` and its own audio loop**. Two mock clients both get `START_ACK`. An implementation that gets every one of the multi-device rules above wrong therefore still passes `harness/tests` and still passes `drive_windows_agent.py --mode session`. **Every rule in the block above is proved by a local C# test over loopback (Tasks 9, 13, 14 and 15) and by nothing else.** The Python driver is still run, but as evidence of wire compatibility, not of arbitration.

**Timers (protocol §8).**

| Timer | Value | Who runs it | Effect on expiry |
|---|---|---|---|
| `START` response | 2 s | Mac | (Mac-side; not implemented here) |
| `STOP` response | 1 s | Mac | (Mac-side; not implemented here) |
| `PING` interval | 15 s | Mac sends; **Windows replies `PONG` immediately** and applies the same 15 s interval and dead-peer rule to *absent* `PING`s | — |
| Peer dead | **45 s** without peer traffic (three missed heartbeats) | Both sides | Windows closes the connection and accepts a new one |
| Pre-auth (`HELLO`) deadline | **5 s** | Windows, per new connection | Close the connection |

**Send priority (protocol §9).** Control messages are queued **unboundedly** and are **always drained before any audio frame**. Audio is a **bounded ring of 25 frames (500 ms at 50 fps) that drops the oldest frame on overflow and never blocks**. Two drop counters, kept separate: **evicted on overflow** (network could not keep up — alarm-worthy) and **discarded at session teardown** (intended). The identity `offered = received + evicted + discarded` must close, to within one frame in flight.

**Pairing token and string (protocol §11.1, §11.2).** A token is **32 bytes (256 bits) from a cryptographically secure random source**, minted **once per paired device**, never regenerated except by explicitly re-pairing that device, and never on the wire. **The pairing-string format is unchanged by the multi-device work** — same base32 alphabet, same 58 characters, same tolerant decode — so the macOS pairing path needs no change at all. Displayed as: **RFC 4648 base32** (`A`–`Z` then `2`–`7`), **uppercase**, **unpadded** (strip the four `=`), **hyphen-grouped in runs of 8** with a single `-` (U+002D). 32 bytes → 52 base32 characters → six groups of 8 plus a final group of 4 → **always 58 characters**. Worked example:

```
token (hex): 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
pairing string: AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ
```

Decoding is deliberately tolerant: uppercase first, delete every character not in `[A-Z2-7]`, re-pad to a multiple of 8, base32-decode, and **reject unless the result is exactly 32 bytes**. **Do not add confusable-character mapping** (`0`→`O`, `1`→`I`/`L`) — that would be a protocol version change.

**Device certificate (protocol §11.3).**

| Property | Value |
|---|---|
| Key type | EC P-256 (`secp256r1` / `prime256v1`) |
| Signature | ECDSA with SHA-256, self-signed (issuer == subject) |
| Subject | `CN = shared-mic` |
| Subject Alternative Name | **Required.** One `dNSName` entry, byte-identical to the subject CN |
| Validity | 3,650 days (10 years), starting 5 minutes in the past |
| Chain | None — one certificate long |

The SAN is not decorative: some Swift TLS stacks reject a SAN-less certificate *before* the pinning callback runs. Private key is **DPAPI-protected** at rest (spec §7.1).

**Authentication rate limiting (protocol §11.4), and how multiple devices resolve it.** After **5 consecutive failed attempts**, refuse further attempts for **30 seconds**. A failed attempt is any connection that reaches §6 without producing a verified `HELLO` — wrong `mac`, malformed or non-`HELLO` message, or the 5-second deadline expiring. Surface it in the UI.

With one token there was one obvious scope for that counter. With a list of paired devices there are three candidates, and they are not equivalent:

- **Per device — impossible, and not merely hard.** A device is identified *by* the proof, so before a proof verifies there is no device to count against. The only pre-identification hint is `clientId`, which is unauthenticated; keying the counter on it would hand an attacker a targeted weapon — claim to be `"Mac Studio"`, fail five times, and lock out that Mac specifically while every other device stays reachable. That is strictly worse than the problem it tries to solve.
- **Per connection — no throttle at all.** A failed `HELLO` closes the connection, so a per-connection counter never reaches 2, let alone 5. The attacker just reconnects.
- **Globally, one counter for the whole listener — a one-attacker denial of service on every paired Mac.** Anything that can reach TCP 47800 can fail five `HELLO`s every 30 seconds forever and no legitimate Mac ever authenticates again. With one Mac this was a self-inflicted annoyance; with several it is an outage of the whole fleet caused by one host.

**Decision: the lockout is keyed on the peer's source IP address, with the source port deliberately excluded, and the agent-wide counters are kept but made advisory.** Concretely:

- `AuthRateLimiter` holds one 5-failure/30-second counter **per remote `IPAddress`**. Five consecutive failures from `192.168.1.66` refuse further attempts *from `192.168.1.66`* for 30 seconds; every other address, including every other paired Mac, is untouched.
- **The port is excluded from the key on purpose.** §11.4's stated reason for rejecting a per-source scope was that an attacker must not be able to reset the counter by picking a new source port. Keying on the address alone satisfies that concern exactly, without the fleet-wide outage a single global counter causes.
- A successful authentication clears **only that address's** counter.
- The agent-wide totals (`TotalFailures`, `LockoutCount`) are still kept, still surfaced in the tray and in the final counters line, and still logged — as an **alarm**, since a burst of failures across many addresses is the signal worth seeing. They refuse nothing.
- The table is bounded (`MaxTrackedPeers`, 1,024) and evicts expired entries first, so an attacker spraying source addresses cannot grow it without bound.

Every non-loopback address is a distinct key, which is what makes this testable: the `--mode lockout` Python run still works unchanged, because all five of its attempts come from the same Mac.

**Privacy and logging (spec §7.3).** Audio payload is never logged or persisted. Logs carry lifecycle events and counters only. Never log any paired device's token, the private key, or the raw `mac` proof. A pairing string is the same secret in base32 — it may be shown to the user on the console banner and in the tray, and it must never reach the log.

**Phase 1 is transport and security only.** No WASAPI, no `MicCaptureService`, no `PcmNormalizer`, no `DeviceManager`, no device enumeration, no audio capture of any kind. A `START` establishes a session and returns `START_ACK`; it does not open a microphone and streams nothing.

**Known platform risk to watch.** TLS 1.3 server support in Schannel requires Windows 11 / Windows Server 2022 or later. Task 15 logs `SslStream.SslProtocol` after every handshake; if it is not `Tls13`, the Windows host's OS version is the cause and the finding must be reported rather than worked around by lowering `EnabledSslProtocols`.

---

## File Structure

```
windows/
  .gitignore                                  bin/ obj/ ignore rules for the C# tree
  SharedMic.Windows.sln                       solution containing both projects
  SharedMic.Agent/
    SharedMic.Agent.csproj                    net10.0-windows, WinForms, DPAPI package
    Program.cs                                entry point, CLI parsing, console banner, tray or headless host
    AgentOptions.cs                           port, mic presence, device label, data dir, injectable timers
    AgentStatus.cs                            Disconnected / Idle / Error
    Protocol/
      ProtocolConstants.cs                    every fixed number in protocol-v1.md, in one place
      ProtocolException.cs                    thrown on any wire-contract violation
      FrameType.cs                            enum FrameType : byte { Control = 1, Audio = 2 }
      FrameCodec.cs                           5-byte envelope encode + incremental decode
      AudioPayloadCodec.cs                    12-byte big-endian header + 1,920 little-endian PCM bytes
      ControlCodec.cs                         canonical sorted-key UTF-8 JSON codec + validation + deep-equality
      ControlMessages.cs                      typed factories for all eleven message types
    Security/
      PairingToken.cs                         256-bit token generation, base32 pairing-string encode/decode
      AuthProof.cs                            nonce generation, HMAC-SHA256 proof, constant-time verify
      AuthRateLimiter.cs                      5 consecutive failures then a 30 s lockout, keyed per source address
      DeviceCertificate.cs                    self-signed P-256 certificate with SAN, DER SHA-256 fingerprint
      IdentityStore.cs                        DPAPI-protected persistence of certificate and serverId
      PairedDeviceStore.cs                    DPAPI-protected list of paired devices; pair, revoke, identify-by-proof
    Net/
      FrameReader.cs                          incremental envelope reader over any Stream
      PrioritySendQueue.cs                    unbounded control queue, bounded 25-frame drop-oldest audio ring
      ControlConnection.cs                    handshake, pre-auth deadline, session lifecycle, heartbeat, writer loop
      PrivateAddress.cs                       RFC1918 / loopback / link-local classification and enumeration
      TlsListener.cs                          TCP 47800 bind per private interface, TLS 1.3, concurrent connections
    Session/
      SessionStateMachine.cs                  pure START/STOP transition function, idempotent
      SessionArbiter.cs                       the single session, its owner, and SESSION_IN_USE; shared by all connections
    Diagnostics/
      AgentLog.cs                             timestamped console log; never payload
      AgentMetrics.cs                         spec §11 counters plus a snapshot record
    Ui/
      TrayApp.cs                              NotifyIcon: status, pairing string, quit
  SharedMic.Agent.Tests/
    SharedMic.Agent.Tests.csproj              xUnit, project reference, copies protocol/vectors/*.json
    VectorFixtures.cs                         loads and exposes the committed golden vectors
    ProjectSetupTests.cs                      constants and vector-file presence
    FrameCodecTests.cs
    AudioPayloadCodecTests.cs
    ControlCodecTests.cs
    GoldenVectorTests.cs                      data-driven conformance over every committed vector
    PairingAndAuthTests.cs
    AuthRateLimiterTests.cs
    SessionStateMachineTests.cs
    SessionArbiterTests.cs                    one session across many owners, release on owner loss
    PrioritySendQueueTests.cs
    FrameReaderTests.cs
    IdentityTests.cs                          certificate profile, fingerprint, DPAPI round-trip
    PairedDeviceStoreTests.cs                 pair, revoke, identify-by-proof, DPAPI round-trip
    LoopbackPeer.cs                           test harness: connected socket pair + client-side protocol helpers
    ControlConnectionTests.cs
    PrivateAddressTests.cs
    TlsListenerTests.cs
    TrayAppTests.cs
harness/
  tools/drive_windows_agent.py                Python interop driver built on MockMacClient
```

Nothing under `protocol/`, `harness/sharedmic_protocol/`, `harness/tests/`, or `probes/` is modified by this plan. The one new harness file is `harness/tools/drive_windows_agent.py`.

---

### Task 1: Solution skeleton, protocol constants, and golden-vector fixtures

**Files:**
- Create: `windows/.gitignore`
- Create: `windows/SharedMic.Windows.sln`
- Create: `windows/SharedMic.Agent/SharedMic.Agent.csproj`
- Create: `windows/SharedMic.Agent/Protocol/ProtocolConstants.cs`
- Create: `windows/SharedMic.Agent/Protocol/ProtocolException.cs`
- Create: `windows/SharedMic.Agent.Tests/SharedMic.Agent.Tests.csproj`
- Test: `windows/SharedMic.Agent.Tests/VectorFixtures.cs`
- Test: `windows/SharedMic.Agent.Tests/ProjectSetupTests.cs`

**Interfaces:**
- Consumes: nothing.
- Produces: `SharedMic.Agent.Protocol.ProtocolConstants` (all `const`/`static readonly` values below); `SharedMic.Agent.Protocol.ProtocolException : Exception` with a `(string message)` constructor; test-side `VectorFixtures` with `IReadOnlyList<ControlVector> ControlVectors()`, `IReadOnlyList<AudioVector> AudioVectors()`, `ControlVector Control(string name)`, `AudioVector Audio(string name)`, `IEnumerable<object[]> ControlVectorNames()`, `IEnumerable<object[]> AudioVectorNames()`, and records `ControlVector(string Name, JsonElement Message, string Hex)` / `AudioVector(string Name, uint Sequence, ulong TimestampUs, string PcmHex, string Hex)`.

**This task runs on Windows.**

- [ ] **Step 1: Scaffold the projects and write the failing test**

Run, from the repo's `windows` directory (create it first):

```powershell
dotnet new sln -n SharedMic.Windows
mkdir SharedMic.Agent
mkdir SharedMic.Agent.Tests
dotnet sln add SharedMic.Agent\SharedMic.Agent.csproj
dotnet sln add SharedMic.Agent.Tests\SharedMic.Agent.Tests.csproj
```

(The two `dotnet sln add` calls will fail until the `.csproj` files below exist; create the files first, then run them.)

`windows/.gitignore`:

```gitignore
bin/
obj/
*.user
```

`windows/SharedMic.Agent/SharedMic.Agent.csproj` — **no `--` sequence may appear inside any XML comment in this file; `MSB4025` is the failure it causes:**

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <UseWindowsForms>true</UseWindowsForms>
    <EnableWindowsTargeting>true</EnableWindowsTargeting>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>latest</LangVersion>
    <AssemblyName>SharedMic.Agent</AssemblyName>
    <RootNamespace>SharedMic.Agent</RootNamespace>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="System.Security.Cryptography.ProtectedData" Version="10.0.0" />
  </ItemGroup>

</Project>
```

If NuGet cannot resolve `10.0.0` for `System.Security.Cryptography.ProtectedData`, run `dotnet add SharedMic.Agent\SharedMic.Agent.csproj package System.Security.Cryptography.ProtectedData` and let the SDK pick the version it ships with, then continue.

`windows/SharedMic.Agent.Tests/SharedMic.Agent.Tests.csproj` — same `--` rule applies:

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net10.0-windows</TargetFramework>
    <UseWindowsForms>true</UseWindowsForms>
    <EnableWindowsTargeting>true</EnableWindowsTargeting>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <LangVersion>latest</LangVersion>
    <IsPackable>false</IsPackable>
    <RootNamespace>SharedMic.Agent.Tests</RootNamespace>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.12.0" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\SharedMic.Agent\SharedMic.Agent.csproj" />
  </ItemGroup>

</Project>
```

`windows/SharedMic.Agent.Tests/VectorFixtures.cs`:

```csharp
using System.Text.Json;

namespace SharedMic.Agent.Tests;

public sealed record ControlVector(string Name, JsonElement Message, string Hex);

public sealed record AudioVector(string Name, uint Sequence, ulong TimestampUs, string PcmHex, string Hex);

/// <summary>
/// Loads the committed golden vectors from protocol/vectors/, which the test
/// project copies next to its own binary. These files are the conformance
/// contract: an implementation that produces different bytes for the same
/// message is wrong, so nothing here may transform or "fix up" what it reads.
/// </summary>
public static class VectorFixtures
{
    private static readonly Lazy<JsonDocument> ControlDocument = new(() => Load("control-messages.json"));
    private static readonly Lazy<JsonDocument> AudioDocument = new(() => Load("audio-frames.json"));

    private static JsonDocument Load(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "vectors", fileName);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"Golden vector file not found at '{path}'. The test project must copy " +
                "protocol/vectors/*.json into its output directory under 'vectors/'.", path);
        }

        return JsonDocument.Parse(File.ReadAllBytes(path));
    }

    public static IReadOnlyList<ControlVector> ControlVectors()
    {
        var vectors = new List<ControlVector>();
        foreach (var element in ControlDocument.Value.RootElement.EnumerateArray())
        {
            vectors.Add(new ControlVector(
                element.GetProperty("name").GetString()!,
                element.GetProperty("message"),
                element.GetProperty("hex").GetString()!));
        }

        return vectors;
    }

    public static IReadOnlyList<AudioVector> AudioVectors()
    {
        var vectors = new List<AudioVector>();
        foreach (var element in AudioDocument.Value.RootElement.EnumerateArray())
        {
            vectors.Add(new AudioVector(
                element.GetProperty("name").GetString()!,
                element.GetProperty("sequence").GetUInt32(),
                element.GetProperty("timestampUs").GetUInt64(),
                element.GetProperty("pcmHex").GetString()!,
                element.GetProperty("hex").GetString()!));
        }

        return vectors;
    }

    public static ControlVector Control(string name) => ControlVectors().Single(v => v.Name == name);

    public static AudioVector Audio(string name) => AudioVectors().Single(v => v.Name == name);

    public static IEnumerable<object[]> ControlVectorNames() =>
        ControlVectors().Select(v => new object[] { v.Name });

    public static IEnumerable<object[]> AudioVectorNames() =>
        AudioVectors().Select(v => new object[] { v.Name });
}
```

`windows/SharedMic.Agent.Tests/ProjectSetupTests.cs`:

```csharp
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class ProjectSetupTests
{
    [Fact]
    public void ConstantsMatchProtocolV1()
    {
        Assert.Equal(1, ProtocolConstants.ProtocolVersion);
        Assert.Equal(47800, ProtocolConstants.DefaultPort);
        Assert.Equal(5, ProtocolConstants.EnvelopeSize);
        Assert.Equal(1048576, ProtocolConstants.MaxPayloadBytes);
        Assert.Equal(12, ProtocolConstants.AudioHeaderSize);
        Assert.Equal(1920, ProtocolConstants.PcmBytesPerFrame);
        Assert.Equal(1932, ProtocolConstants.AudioPayloadSize);
        Assert.Equal(1937, ProtocolConstants.AudioEnvelopeSize);
        Assert.Equal(48000, ProtocolConstants.SampleRate);
        Assert.Equal(1, ProtocolConstants.Channels);
        Assert.Equal("s16le", ProtocolConstants.SampleFormat);
        Assert.Equal(960, ProtocolConstants.SamplesPerFrame);
        Assert.Equal(50, ProtocolConstants.FramesPerSecond);
        Assert.Equal(20, ProtocolConstants.FrameDurationMs);
        Assert.Equal(20000, ProtocolConstants.FrameDurationUs);
        Assert.Equal(25, ProtocolConstants.AudioQueueCapacity);
        Assert.Equal(32, ProtocolConstants.TokenBytes);
        Assert.Equal(32, ProtocolConstants.NonceBytes);
        Assert.Equal(5, ProtocolConstants.MaxAuthFailures);
        Assert.Equal(3650, ProtocolConstants.CertificateValidityDays);
        Assert.Equal("shared-mic", ProtocolConstants.CertificateCommonName);
        Assert.Equal(TimeSpan.FromSeconds(5), ProtocolConstants.HelloDeadline);
        Assert.Equal(TimeSpan.FromSeconds(15), ProtocolConstants.HeartbeatInterval);
        Assert.Equal(TimeSpan.FromSeconds(45), ProtocolConstants.PeerDeadTimeout);
        Assert.Equal(TimeSpan.FromSeconds(30), ProtocolConstants.AuthLockoutDuration);
    }

    [Fact]
    public void GoldenVectorFilesAreCopiedNextToTheTestBinary()
    {
        Assert.Equal(11, VectorFixtures.ControlVectors().Count);
        Assert.Equal(3, VectorFixtures.AudioVectors().Count);
        Assert.All(VectorFixtures.ControlVectors(), v => Assert.NotEmpty(v.Hex));
        Assert.All(VectorFixtures.AudioVectors(), v => Assert.NotEmpty(v.Hex));
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln
```

Expected: FAIL. The build fails with `CS0246: The type or namespace name 'ProtocolConstants' could not be found` (and `ProtocolException` is not yet referenced, so only `ProtocolConstants` reports). If the build is fixed by hand before running, `GoldenVectorFilesAreCopiedNextToTheTestBinary` fails with `FileNotFoundException: Golden vector file not found at '...\vectors\control-messages.json'`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Protocol/ProtocolConstants.cs`:

```csharp
namespace SharedMic.Agent.Protocol;

/// <summary>
/// Every fixed value in protocol/protocol-v1.md, in one place. Changing any of
/// these is a protocol version change (protocol-v1.md section 1), not an
/// implementation decision.
/// </summary>
public static class ProtocolConstants
{
    public const int ProtocolVersion = 1;

    public const int DefaultPort = 47800;

    public const int EnvelopeSize = 5;
    public const int MaxPayloadBytes = 1048576;

    public const int AudioHeaderSize = 12;
    public const int PcmBytesPerFrame = 1920;
    public const int AudioPayloadSize = AudioHeaderSize + PcmBytesPerFrame;
    public const int AudioEnvelopeSize = EnvelopeSize + AudioPayloadSize;

    public const int SampleRate = 48000;
    public const int Channels = 1;
    public const string SampleFormat = "s16le";
    public const int SamplesPerFrame = 960;
    public const int FramesPerSecond = 50;
    public const int FrameDurationMs = 20;
    public const long FrameDurationUs = 20000;

    public const int AudioQueueCapacity = 25;

    public const int TokenBytes = 32;
    public const int NonceBytes = 32;
    public const int MaxAuthFailures = 5;

    public const int CertificateValidityDays = 3650;
    public const string CertificateCommonName = "shared-mic";

    public static readonly TimeSpan HelloDeadline = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(15);
    public static readonly TimeSpan PeerDeadTimeout = TimeSpan.FromSeconds(45);
    public static readonly TimeSpan AuthLockoutDuration = TimeSpan.FromSeconds(30);
    public static readonly TimeSpan CertificateBackdate = TimeSpan.FromMinutes(5);
}
```

`windows/SharedMic.Agent/Protocol/ProtocolException.cs`:

```csharp
namespace SharedMic.Agent.Protocol;

/// <summary>
/// Thrown when bytes on the wire violate protocol/protocol-v1.md. Every catch
/// site for this exception must close the connection rather than skip the
/// offending frame and resynchronize (protocol-v1.md section 3).
/// </summary>
public sealed class ProtocolException : Exception
{
    public ProtocolException(string message)
        : base(message)
    {
    }
}
```

Add this `ItemGroup` to `windows/SharedMic.Agent.Tests/SharedMic.Agent.Tests.csproj`, immediately before the closing `</Project>`:

```xml
  <ItemGroup>
    <Content Include="..\..\protocol\vectors\control-messages.json"
             Link="vectors\control-messages.json"
             CopyToOutputDirectory="PreserveNewest" />
    <Content Include="..\..\protocol\vectors\audio-frames.json"
             Link="vectors\audio-frames.json"
             CopyToOutputDirectory="PreserveNewest" />
  </ItemGroup>
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln
```

Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/.gitignore windows/SharedMic.Windows.sln windows/SharedMic.Agent windows/SharedMic.Agent.Tests
git commit -m "Phase 1 Task 1: solution skeleton, protocol constants, golden-vector fixtures"
```

---

### Task 2: Envelope frame codec

**Files:**
- Create: `windows/SharedMic.Agent/Protocol/FrameType.cs`
- Create: `windows/SharedMic.Agent/Protocol/FrameCodec.cs`
- Test: `windows/SharedMic.Agent.Tests/FrameCodecTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.EnvelopeSize`, `ProtocolConstants.MaxPayloadBytes`, `ProtocolException(string)`.
- Produces: `enum FrameType : byte { Control = 1, Audio = 2 }`; `static class FrameCodec` with `byte[] EncodeFrame(FrameType type, ReadOnlySpan<byte> payload)` and `bool TryDecodeFrame(ReadOnlySpan<byte> buffer, out FrameType type, out byte[] payload, out int consumed)`.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/FrameCodecTests.cs`:

```csharp
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class FrameCodecTests
{
    [Fact]
    public void EncodesTheFiveByteBigEndianEnvelope()
    {
        var payload = "{\"type\":\"PING\"}"u8.ToArray();

        var frame = FrameCodec.EncodeFrame(FrameType.Control, payload);

        Assert.Equal(
            "010000000f7b2274797065223a2250494e47227d",
            Convert.ToHexString(frame).ToLowerInvariant());
    }

    [Fact]
    public void LengthIsBigEndianForMultiByteLengths()
    {
        var payload = new byte[300];

        var frame = FrameCodec.EncodeFrame(FrameType.Audio, payload);

        Assert.Equal(2, frame[0]);
        Assert.Equal(0x00, frame[1]);
        Assert.Equal(0x00, frame[2]);
        Assert.Equal(0x01, frame[3]);
        Assert.Equal(0x2c, frame[4]);
        Assert.Equal(305, frame.Length);
    }

    [Fact]
    public void RoundTripsAControlFrame()
    {
        var payload = new byte[] { 1, 2, 3, 4, 5 };
        var frame = FrameCodec.EncodeFrame(FrameType.Control, payload);

        Assert.True(FrameCodec.TryDecodeFrame(frame, out var type, out var decoded, out var consumed));
        Assert.Equal(FrameType.Control, type);
        Assert.Equal(payload, decoded);
        Assert.Equal(frame.Length, consumed);
    }

    [Fact]
    public void ReturnsFalseWhenHeaderIsIncomplete()
    {
        Assert.False(FrameCodec.TryDecodeFrame(new byte[] { 1, 0, 0 }, out _, out _, out var consumed));
        Assert.Equal(0, consumed);
    }

    [Fact]
    public void ReturnsFalseWhenPayloadIsIncomplete()
    {
        var frame = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 9, 9, 9, 9 });

        Assert.False(FrameCodec.TryDecodeFrame(frame.AsSpan(0, frame.Length - 1), out _, out _, out var consumed));
        Assert.Equal(0, consumed);
    }

    [Fact]
    public void ReportsConsumedSoAStreamCanHoldTwoFrames()
    {
        var first = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 1 });
        var second = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 2, 2 });
        var buffer = first.Concat(second).ToArray();

        Assert.True(FrameCodec.TryDecodeFrame(buffer, out _, out var firstPayload, out var firstConsumed));
        Assert.Equal(new byte[] { 1 }, firstPayload);
        Assert.Equal(6, firstConsumed);

        Assert.True(FrameCodec.TryDecodeFrame(buffer.AsSpan(firstConsumed), out _, out var secondPayload, out var secondConsumed));
        Assert.Equal(new byte[] { 2, 2 }, secondPayload);
        Assert.Equal(7, secondConsumed);
    }

    [Fact]
    public void DecodeRejectsUnknownFrameType()
    {
        var buffer = new byte[] { 3, 0, 0, 0, 0 };

        var error = Assert.Throws<ProtocolException>(() =>
            FrameCodec.TryDecodeFrame(buffer, out _, out _, out _));
        Assert.Contains("unknown frame type", error.Message);
    }

    [Fact]
    public void DecodeRejectsOversizedPayloadBeforeAllocatingForIt()
    {
        var buffer = new byte[] { 1, 0x00, 0x10, 0x00, 0x01 };

        var error = Assert.Throws<ProtocolException>(() =>
            FrameCodec.TryDecodeFrame(buffer, out _, out _, out _));
        Assert.Contains("payload too large", error.Message);
    }

    [Fact]
    public void EncodeRejectsAnOversizedPayload()
    {
        var payload = new byte[ProtocolConstants.MaxPayloadBytes + 1];

        Assert.Throws<ProtocolException>(() => FrameCodec.EncodeFrame(FrameType.Control, payload));
    }

    [Fact]
    public void EncodeRejectsAnUnknownFrameType()
    {
        Assert.Throws<ProtocolException>(() => FrameCodec.EncodeFrame((FrameType)7, new byte[] { 0 }));
    }

    [Fact]
    public void EncodesTheMaximumLegalPayload()
    {
        var payload = new byte[ProtocolConstants.MaxPayloadBytes];

        var frame = FrameCodec.EncodeFrame(FrameType.Audio, payload);

        Assert.Equal(ProtocolConstants.EnvelopeSize + ProtocolConstants.MaxPayloadBytes, frame.Length);
        Assert.True(FrameCodec.TryDecodeFrame(frame, out _, out var decoded, out _));
        Assert.Equal(ProtocolConstants.MaxPayloadBytes, decoded.Length);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~FrameCodecTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'FrameCodec' could not be found` and the same for `FrameType`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Protocol/FrameType.cs`:

```csharp
namespace SharedMic.Agent.Protocol;

/// <summary>Envelope type byte (protocol-v1.md section 3).</summary>
public enum FrameType : byte
{
    Control = 1,
    Audio = 2,
}
```

`windows/SharedMic.Agent/Protocol/FrameCodec.cs`:

```csharp
using System.Buffers.Binary;

namespace SharedMic.Agent.Protocol;

/// <summary>
/// The 5-byte envelope of protocol-v1.md section 3: one type byte and a
/// big-endian uint32 payload length. Pure: no sockets, no logging, no I/O.
/// Byte-matched against protocol/vectors by GoldenVectorTests.
/// </summary>
public static class FrameCodec
{
    public static byte[] EncodeFrame(FrameType type, ReadOnlySpan<byte> payload)
    {
        if (type != FrameType.Control && type != FrameType.Audio)
        {
            throw new ProtocolException($"unknown frame type {(byte)type}");
        }

        if (payload.Length > ProtocolConstants.MaxPayloadBytes)
        {
            throw new ProtocolException($"payload too large: {payload.Length} bytes");
        }

        var frame = new byte[ProtocolConstants.EnvelopeSize + payload.Length];
        frame[0] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(frame.AsSpan(1, 4), (uint)payload.Length);
        payload.CopyTo(frame.AsSpan(ProtocolConstants.EnvelopeSize));
        return frame;
    }

    /// <summary>
    /// Decode one envelope from the front of <paramref name="buffer"/>.
    /// Returns false when the buffer does not yet hold a complete envelope,
    /// which is "wait for more data", never a wrong answer. Throws
    /// <see cref="ProtocolException"/> on a violation; the caller must close
    /// the connection rather than resynchronize.
    /// </summary>
    public static bool TryDecodeFrame(
        ReadOnlySpan<byte> buffer,
        out FrameType type,
        out byte[] payload,
        out int consumed)
    {
        type = default;
        payload = Array.Empty<byte>();
        consumed = 0;

        if (buffer.Length < ProtocolConstants.EnvelopeSize)
        {
            return false;
        }

        var rawType = buffer[0];
        if (rawType != (byte)FrameType.Control && rawType != (byte)FrameType.Audio)
        {
            throw new ProtocolException($"unknown frame type {rawType}");
        }

        var length = BinaryPrimitives.ReadUInt32BigEndian(buffer.Slice(1, 4));
        if (length > (uint)ProtocolConstants.MaxPayloadBytes)
        {
            throw new ProtocolException($"payload too large: {length} bytes");
        }

        var total = ProtocolConstants.EnvelopeSize + (int)length;
        if (buffer.Length < total)
        {
            return false;
        }

        type = (FrameType)rawType;
        payload = buffer.Slice(ProtocolConstants.EnvelopeSize, (int)length).ToArray();
        consumed = total;
        return true;
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~FrameCodecTests"
```

Expected: PASS, 11 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Protocol windows/SharedMic.Agent.Tests/FrameCodecTests.cs
git commit -m "Phase 1 Task 2: envelope frame codec with close-on-violation semantics"
```

---

### Task 3: Audio payload codec

**Files:**
- Create: `windows/SharedMic.Agent/Protocol/AudioPayloadCodec.cs`
- Test: `windows/SharedMic.Agent.Tests/AudioPayloadCodecTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.AudioHeaderSize`, `ProtocolConstants.PcmBytesPerFrame`, `ProtocolConstants.AudioPayloadSize`, `ProtocolException(string)`.
- Produces: `readonly record struct AudioFrame(uint Sequence, ulong CaptureTimestampUs, byte[] Pcm)`; `static class AudioPayloadCodec` with `byte[] EncodeAudioPayload(uint sequence, ulong captureTimestampUs, ReadOnlySpan<byte> pcm)`, `AudioFrame DecodeAudioPayload(ReadOnlySpan<byte> payload)`, `short ReadPcmSample(ReadOnlySpan<byte> pcm, int index)`, `void WritePcmSample(Span<byte> pcm, int index, short sample)`.

Nothing in Phase 1 ever calls `EncodeAudioPayload` on a live connection. It exists so the golden vectors can hold the framing to account before Phase 2 writes a capture path against it.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/AudioPayloadCodecTests.cs`:

```csharp
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class AudioPayloadCodecTests
{
    private static byte[] Pcm(short fill)
    {
        var pcm = new byte[ProtocolConstants.PcmBytesPerFrame];
        for (var i = 0; i < ProtocolConstants.SamplesPerFrame; i++)
        {
            AudioPayloadCodec.WritePcmSample(pcm, i, fill);
        }

        return pcm;
    }

    [Fact]
    public void HeaderIsTwelveBytesAndBigEndian()
    {
        var payload = AudioPayloadCodec.EncodeAudioPayload(0x01020304u, 0x05060708090A0B0Cul, Pcm(0));

        Assert.Equal(ProtocolConstants.AudioPayloadSize, payload.Length);
        Assert.Equal(
            "0102030405060708090a0b0c",
            Convert.ToHexString(payload.AsSpan(0, ProtocolConstants.AudioHeaderSize)).ToLowerInvariant());
    }

    [Fact]
    public void PcmSamplesAreLittleEndianEvenThoughTheHeaderIsBigEndian()
    {
        var pcm = new byte[ProtocolConstants.PcmBytesPerFrame];
        AudioPayloadCodec.WritePcmSample(pcm, 0, unchecked((short)0xBEEF));

        Assert.Equal(0xEF, pcm[0]);
        Assert.Equal(0xBE, pcm[1]);
        Assert.Equal(unchecked((short)0xBEEF), AudioPayloadCodec.ReadPcmSample(pcm, 0));
    }

    [Fact]
    public void RoundTripsAFullFrame()
    {
        var pcm = Pcm(-1234);

        var decoded = AudioPayloadCodec.DecodeAudioPayload(
            AudioPayloadCodec.EncodeAudioPayload(49u, 980000ul, pcm));

        Assert.Equal(49u, decoded.Sequence);
        Assert.Equal(980000ul, decoded.CaptureTimestampUs);
        Assert.Equal(pcm, decoded.Pcm);
        Assert.Equal(-1234, AudioPayloadCodec.ReadPcmSample(decoded.Pcm, 500));
    }

    [Fact]
    public void EncodeRefusesAShortPcmBuffer()
    {
        var error = Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.EncodeAudioPayload(0u, 0ul, new byte[ProtocolConstants.PcmBytesPerFrame - 2]));

        Assert.Contains("1920", error.Message);
    }

    [Fact]
    public void EncodeRefusesAnOverlongPcmBuffer()
    {
        Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.EncodeAudioPayload(0u, 0ul, new byte[ProtocolConstants.PcmBytesPerFrame + 2]));
    }

    [Fact]
    public void DecodeRefusesAnythingOtherThanExactly1932Bytes()
    {
        Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.DecodeAudioPayload(new byte[ProtocolConstants.AudioPayloadSize - 1]));
        Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.DecodeAudioPayload(new byte[ProtocolConstants.AudioPayloadSize + 1]));
        Assert.Throws<ProtocolException>(() =>
            AudioPayloadCodec.DecodeAudioPayload(new byte[ProtocolConstants.AudioHeaderSize]));
    }

    [Fact]
    public void FullAudioEnvelopeIs1937Bytes()
    {
        var frame = FrameCodec.EncodeFrame(
            FrameType.Audio,
            AudioPayloadCodec.EncodeAudioPayload(0u, 0ul, Pcm(0)));

        Assert.Equal(ProtocolConstants.AudioEnvelopeSize, frame.Length);
        Assert.Equal(1937, frame.Length);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~AudioPayloadCodecTests"
```

Expected: FAIL with `CS0103: The name 'AudioPayloadCodec' does not exist in the current context`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Protocol/AudioPayloadCodec.cs`:

```csharp
using System.Buffers.Binary;

namespace SharedMic.Agent.Protocol;

/// <summary>One decoded AUDIO frame. Never logged, only counted.</summary>
public readonly record struct AudioFrame(uint Sequence, ulong CaptureTimestampUs, byte[] Pcm);

/// <summary>
/// The AUDIO payload of protocol-v1.md section 4: a 12-byte big-endian header
/// followed by exactly 1,920 bytes of PCM.
///
/// The single most likely implementation mistake in this protocol is applying
/// the header's byte order to the PCM. The header fields are BIG-endian; the
/// 960 16-bit samples that follow are each LITTLE-endian (s16le). Use
/// ReadPcmSample and WritePcmSample rather than hand-rolling the shift, so the
/// byte order lives in exactly one place.
///
/// Phase 1 never calls the encoder on a live connection: there is no capture
/// path yet, and an idle connection must carry zero audio bytes.
/// </summary>
public static class AudioPayloadCodec
{
    public static byte[] EncodeAudioPayload(uint sequence, ulong captureTimestampUs, ReadOnlySpan<byte> pcm)
    {
        if (pcm.Length != ProtocolConstants.PcmBytesPerFrame)
        {
            throw new ProtocolException(
                $"an audio frame must carry exactly {ProtocolConstants.PcmBytesPerFrame} PCM bytes, got {pcm.Length}; " +
                "there is no partial frame in this protocol");
        }

        var payload = new byte[ProtocolConstants.AudioPayloadSize];
        BinaryPrimitives.WriteUInt32BigEndian(payload.AsSpan(0, 4), sequence);
        BinaryPrimitives.WriteUInt64BigEndian(payload.AsSpan(4, 8), captureTimestampUs);
        pcm.CopyTo(payload.AsSpan(ProtocolConstants.AudioHeaderSize));
        return payload;
    }

    public static AudioFrame DecodeAudioPayload(ReadOnlySpan<byte> payload)
    {
        if (payload.Length != ProtocolConstants.AudioPayloadSize)
        {
            throw new ProtocolException(
                $"an AUDIO payload must be exactly {ProtocolConstants.AudioPayloadSize} bytes, got {payload.Length}");
        }

        var sequence = BinaryPrimitives.ReadUInt32BigEndian(payload.Slice(0, 4));
        var timestamp = BinaryPrimitives.ReadUInt64BigEndian(payload.Slice(4, 8));
        return new AudioFrame(sequence, timestamp, payload.Slice(ProtocolConstants.AudioHeaderSize).ToArray());
    }

    public static short ReadPcmSample(ReadOnlySpan<byte> pcm, int index) =>
        BinaryPrimitives.ReadInt16LittleEndian(pcm.Slice(index * 2, 2));

    public static void WritePcmSample(Span<byte> pcm, int index, short sample) =>
        BinaryPrimitives.WriteInt16LittleEndian(pcm.Slice(index * 2, 2), sample);
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~AudioPayloadCodecTests"
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Protocol/AudioPayloadCodec.cs windows/SharedMic.Agent.Tests/AudioPayloadCodecTests.cs
git commit -m "Phase 1 Task 3: audio payload codec, strict 1932-byte receiver, little-endian PCM"
```

---

### Task 4: Canonical control-message codec

**Files:**
- Create: `windows/SharedMic.Agent/Protocol/ControlCodec.cs`
- Create: `windows/SharedMic.Agent/Protocol/ControlMessages.cs`
- Test: `windows/SharedMic.Agent.Tests/ControlCodecTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.ProtocolVersion`, `ProtocolConstants.SampleRate`, `ProtocolConstants.Channels`, `ProtocolConstants.SampleFormat`, `ProtocolException(string)`.
- Produces: `static class ControlCodec` with `IReadOnlyDictionary<string, string[]> RequiredFields`, `byte[] Encode(IReadOnlyDictionary<string, object?> message)`, `Dictionary<string, object?> Decode(ReadOnlySpan<byte> payload)`, `Dictionary<string, object?> Normalize(IReadOnlyDictionary<string, object?> message)`, `void Validate(IReadOnlyDictionary<string, object?> message)`, `Dictionary<string, object?> FromJsonElement(JsonElement element)`, `bool DeepEquals(object? left, object? right)`; `static class ControlMessages` with `IReadOnlyDictionary<string, object?> AudioFormat` and factories `Greeting(string serverId, string nonceHex)`, `Hello(string clientId, string mac)`, `HelloAck(string serverId, bool micPresent, string deviceLabel)`, `Start(string requestId)`, `StartAck(string requestId, string sessionId)`, `StartNack(string requestId, string reason, string? holder = null)`, `Stop(string requestId, string sessionId)`, `StopAck(string requestId, string sessionId)`, `Status(bool micPresent, bool active, string deviceLabel)`, `Ping(long seq)`, `Pong(long seq)` — each returning `Dictionary<string, object?>`.

The message model is a dictionary rather than eleven record types on purpose: it lets the golden-vector test in Task 5 iterate the committed fixtures generically instead of hand-copying cases, and it makes the canonical sorted-key encoder a pure function of message content.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/ControlCodecTests.cs`:

```csharp
using System.Text;
using System.Text.Json;
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class ControlCodecTests
{
    [Fact]
    public void EncodesWithSortedKeysAndNoSeparatorWhitespace()
    {
        var message = new Dictionary<string, object?>
        {
            ["v"] = 1L,
            ["type"] = "PONG",
            ["seq"] = 7L,
        };

        Assert.Equal("{\"seq\":7,\"type\":\"PONG\",\"v\":1}", Encoding.UTF8.GetString(ControlCodec.Encode(message)));
    }

    [Fact]
    public void SortsNestedObjectKeysToo()
    {
        var json = Encoding.UTF8.GetString(ControlCodec.Encode(ControlMessages.Start("req-0001")));

        Assert.Equal(
            "{\"preferredFormat\":{\"channels\":1,\"sampleFormat\":\"s16le\",\"sampleRate\":48000}," +
            "\"requestId\":\"req-0001\",\"type\":\"START\",\"v\":1}",
            json);
    }

    [Fact]
    public void KeyOrderAtTheCallSiteDoesNotChangeTheBytes()
    {
        var a = new Dictionary<string, object?> { ["v"] = 1L, ["type"] = "STOP", ["requestId"] = "r", ["sessionId"] = "s" };
        var b = new Dictionary<string, object?> { ["sessionId"] = "s", ["requestId"] = "r", ["type"] = "STOP", ["v"] = 1L };

        Assert.Equal(ControlCodec.Encode(a), ControlCodec.Encode(b));
    }

    [Fact]
    public void EncodesAsUtf8WithoutAsciiEscaping()
    {
        var message = ControlMessages.HelloAck("win-desktop", true, "Mikrofón");

        var frame = FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message));

        Assert.Equal(
            "010000005f7b226465766963654c6162656c223a224d696b726f66c3b36e222c226d696350726573" +
            "656e74223a747275652c227365727665724964223a2277696e2d6465736b746f70222c2274797065" +
            "223a2248454c4c4f5f41434b222c2276223a317d",
            Convert.ToHexString(frame).ToLowerInvariant());
    }

    [Fact]
    public void IntegersEncodeWithoutADecimalPoint()
    {
        var message = new Dictionary<string, object?> { ["v"] = 1, ["type"] = "PING", ["seq"] = 42 };

        Assert.Equal("{\"seq\":42,\"type\":\"PING\",\"v\":1}", Encoding.UTF8.GetString(ControlCodec.Encode(message)));
    }

    [Fact]
    public void DecodesToTheSameLogicalMessage()
    {
        var message = ControlMessages.StartAck("req-0001", "sess-0001");

        var decoded = ControlCodec.Decode(ControlCodec.Encode(message));

        Assert.True(ControlCodec.DeepEquals(ControlCodec.Normalize(message), decoded));
        Assert.Equal("sess-0001", decoded["sessionId"]);
        Assert.Equal(1L, decoded["v"]);
    }

    [Fact]
    public void RejectsWrongProtocolVersionOnDecode()
    {
        var payload = Encoding.UTF8.GetBytes("{\"seq\":1,\"type\":\"PING\",\"v\":2}");

        var error = Assert.Throws<ProtocolException>(() => ControlCodec.Decode(payload));
        Assert.Contains("unsupported protocol version", error.Message);
    }

    [Fact]
    public void RejectsUnknownMessageType()
    {
        var payload = Encoding.UTF8.GetBytes("{\"type\":\"NOPE\",\"v\":1}");

        Assert.Throws<ProtocolException>(() => ControlCodec.Decode(payload));
    }

    [Fact]
    public void RejectsMissingRequiredField()
    {
        var payload = Encoding.UTF8.GetBytes("{\"requestId\":\"r\",\"type\":\"START_ACK\",\"v\":1}");

        var error = Assert.Throws<ProtocolException>(() => ControlCodec.Decode(payload));
        Assert.Contains("missing required field", error.Message);
    }

    [Fact]
    public void RejectsMalformedJson()
    {
        Assert.Throws<ProtocolException>(() => ControlCodec.Decode(Encoding.UTF8.GetBytes("{\"type\":")));
    }

    [Fact]
    public void RejectsNonObjectJson()
    {
        Assert.Throws<ProtocolException>(() => ControlCodec.Decode(Encoding.UTF8.GetBytes("[1,2,3]")));
    }

    [Fact]
    public void RejectsInvalidUtf8()
    {
        Assert.Throws<ProtocolException>(() => ControlCodec.Decode(new byte[] { 0x7b, 0xff, 0xfe, 0x7d }));
    }

    [Fact]
    public void ValidatesOnEncodeTooSoAHarnessBugIsLoud()
    {
        var message = new Dictionary<string, object?> { ["v"] = 1L, ["type"] = "PONG" };

        Assert.Throws<ProtocolException>(() => ControlCodec.Encode(message));
    }

    [Fact]
    public void RequiredFieldsTableCoversExactlyElevenTypes()
    {
        Assert.Equal(11, ControlCodec.RequiredFields.Count);
        Assert.Equal(
            new[]
            {
                "GREETING", "HELLO", "HELLO_ACK", "PING", "PONG", "START", "START_ACK",
                "START_NACK", "STATUS", "STOP", "STOP_ACK",
            },
            ControlCodec.RequiredFields.Keys.OrderBy(k => k, StringComparer.Ordinal).ToArray());
    }

    [Fact]
    public void EveryFactoryProducesAMessageTheCodecAccepts()
    {
        var messages = new[]
        {
            ControlMessages.Greeting("win-desktop", new string('0', 64)),
            ControlMessages.Hello("mac-studio", new string('a', 64)),
            ControlMessages.HelloAck("win-desktop", true, "USB Microphone"),
            ControlMessages.Start("req-0001"),
            ControlMessages.StartAck("req-0001", "sess-0001"),
            ControlMessages.StartNack("req-0002", "MIC_UNAVAILABLE"),
            ControlMessages.Stop("req-0003", "sess-0001"),
            ControlMessages.StopAck("req-0003", "sess-0001"),
            ControlMessages.Status(false, false, "USB Microphone"),
            ControlMessages.Ping(1L),
            ControlMessages.Pong(1L),
        };

        foreach (var message in messages)
        {
            var decoded = ControlCodec.Decode(ControlCodec.Encode(message));
            Assert.True(ControlCodec.DeepEquals(ControlCodec.Normalize(message), decoded));
        }
    }

    [Fact]
    public void StartNackOmitsTheAdvisoryHolderFieldUnlessOneIsGiven()
    {
        var plain = ControlMessages.StartNack("req-0002", "MIC_UNAVAILABLE");

        Assert.False(plain.ContainsKey("holder"));
        Assert.Equal(
            "{\"reason\":\"MIC_UNAVAILABLE\",\"requestId\":\"req-0002\",\"type\":\"START_NACK\",\"v\":1}",
            Encoding.UTF8.GetString(ControlCodec.Encode(plain)));
    }

    [Fact]
    public void StartNackCarriesTheHolderNameWhenTheSessionIsInUse()
    {
        var busy = ControlMessages.StartNack("req-0002", "SESSION_IN_USE", "Mac Studio");

        Assert.Equal("Mac Studio", busy["holder"]);
        Assert.Equal(
            "{\"holder\":\"Mac Studio\",\"reason\":\"SESSION_IN_USE\"," +
            "\"requestId\":\"req-0002\",\"type\":\"START_NACK\",\"v\":1}",
            Encoding.UTF8.GetString(ControlCodec.Encode(busy)));
    }

    [Fact]
    public void AnEmptyOrWhitespaceHolderIsOmittedRatherThanSentBlank()
    {
        // A blank advisory field is worse than no advisory field: the Mac would
        // render "In use by " with nothing after it. Omission is the contract.
        Assert.False(ControlMessages.StartNack("r", "SESSION_IN_USE", "").ContainsKey("holder"));
        Assert.False(ControlMessages.StartNack("r", "SESSION_IN_USE", "   ").ContainsKey("holder"));
        Assert.False(ControlMessages.StartNack("r", "SESSION_IN_USE", null).ContainsKey("holder"));
    }

    [Fact]
    public void AnAdvisoryFieldDoesNotBreakDecodeOrRoundTrip()
    {
        var busy = ControlMessages.StartNack("req-0002", "SESSION_IN_USE", "Mac Studio");

        var decoded = ControlCodec.Decode(ControlCodec.Encode(busy));

        Assert.True(ControlCodec.DeepEquals(ControlCodec.Normalize(busy), decoded));
        Assert.Equal("Mac Studio", decoded["holder"]);
    }

    [Fact]
    public void FromJsonElementBuildsTheSameModelTheDecoderDoes()
    {
        using var document = JsonDocument.Parse("{\"v\":1,\"type\":\"STATUS\",\"micPresent\":false,\"active\":false,\"deviceLabel\":\"x\"}");

        var fromElement = ControlCodec.FromJsonElement(document.RootElement);
        var fromBytes = ControlCodec.Decode(Encoding.UTF8.GetBytes(document.RootElement.GetRawText()));

        Assert.True(ControlCodec.DeepEquals(fromElement, fromBytes));
    }

    [Fact]
    public void DeepEqualsIgnoresKeyOrderAndComparesNestedObjects()
    {
        var a = ControlCodec.Normalize(ControlMessages.StartAck("r", "s"));
        var b = ControlCodec.Decode(ControlCodec.Encode(ControlMessages.StartAck("r", "s")));
        var c = ControlCodec.Decode(ControlCodec.Encode(ControlMessages.StartAck("r", "other")));

        Assert.True(ControlCodec.DeepEquals(a, b));
        Assert.False(ControlCodec.DeepEquals(a, c));
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~ControlCodecTests"
```

Expected: FAIL with `CS0103: The name 'ControlCodec' does not exist in the current context` and the same for `ControlMessages`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Protocol/ControlCodec.cs`:

```csharp
using System.Text.Encodings.Web;
using System.Text.Json;

namespace SharedMic.Agent.Protocol;

/// <summary>
/// The CONTROL payload of protocol-v1.md section 5: a single UTF-8 JSON object
/// with no line breaks or padding, keys sorted lexicographically (recursively),
/// and no ASCII escaping of non-ASCII characters. Those bytes must be identical
/// to what json.dumps(msg, sort_keys=True, separators=(",", ":")) produces in
/// the reference harness, which is what makes two implementations that build
/// the same logical message interoperable byte for byte.
///
/// Validation runs on both encode and decode, deliberately: a bug here should
/// surface as a loud local failure rather than as bytes the far end has to
/// guess about. Validation checks that every REQUIRED field is present; it does
/// not reject additional fields, which is what lets START_NACK carry the
/// optional advisory "holder" name without a protocol version change, and what
/// lets this decoder accept a future peer that adds one.
///
/// Messages are modelled as Dictionary&lt;string, object?&gt; with values
/// restricted to string, bool, long, double and nested dictionaries. That is
/// exactly the value space protocol version 1 uses, and it lets the conformance
/// test iterate the committed vectors generically.
/// </summary>
public static class ControlCodec
{
    public static readonly IReadOnlyDictionary<string, string[]> RequiredFields =
        new Dictionary<string, string[]>(StringComparer.Ordinal)
        {
            ["GREETING"] = new[] { "serverId", "nonce" },
            ["HELLO"] = new[] { "clientId", "mac" },
            ["HELLO_ACK"] = new[] { "serverId", "micPresent", "deviceLabel" },
            ["START"] = new[] { "requestId", "preferredFormat" },
            ["START_ACK"] = new[] { "requestId", "sessionId", "format" },
            ["START_NACK"] = new[] { "requestId", "reason" },
            ["STOP"] = new[] { "requestId", "sessionId" },
            ["STOP_ACK"] = new[] { "requestId", "sessionId" },
            ["STATUS"] = new[] { "micPresent", "active", "deviceLabel" },
            ["PING"] = new[] { "seq" },
            ["PONG"] = new[] { "seq" },
        };

    private static readonly JsonWriterOptions WriterOptions = new()
    {
        Indented = false,
        SkipValidation = false,

        // The default encoder escapes every non-ASCII character as \uXXXX and
        // also escapes characters such as '+' and '&'. The reference encoder
        // uses ensure_ascii=False and escapes only what JSON requires, so the
        // relaxed encoder is what produces matching bytes.
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static byte[] Encode(IReadOnlyDictionary<string, object?> message)
    {
        var normalized = Normalize(message);
        Validate(normalized);

        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream, WriterOptions))
        {
            WriteObject(writer, normalized);
        }

        return stream.ToArray();
    }

    public static Dictionary<string, object?> Decode(ReadOnlySpan<byte> payload)
    {
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(payload.ToArray());
        }
        catch (JsonException exception)
        {
            throw new ProtocolException($"malformed JSON control payload: {exception.Message}");
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new ProtocolException("control message must be a JSON object");
            }

            var message = FromJsonElement(document.RootElement);
            Validate(message);
            return message;
        }
    }

    /// <summary>
    /// Widen every integer to long and copy nested dictionaries, so that a
    /// message built with int literals compares and encodes identically to one
    /// decoded off the wire.
    /// </summary>
    public static Dictionary<string, object?> Normalize(IReadOnlyDictionary<string, object?> message)
    {
        var normalized = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var pair in message)
        {
            normalized[pair.Key] = NormalizeValue(pair.Value);
        }

        return normalized;
    }

    public static void Validate(IReadOnlyDictionary<string, object?> message)
    {
        if (!message.TryGetValue("type", out var typeValue) || typeValue is not string type ||
            !RequiredFields.ContainsKey(type))
        {
            throw new ProtocolException($"unknown control type '{typeValue ?? "(missing)"}'");
        }

        if (!message.TryGetValue("v", out var versionValue) || versionValue is not long version ||
            version != ProtocolConstants.ProtocolVersion)
        {
            throw new ProtocolException($"unsupported protocol version '{versionValue ?? "(missing)"}'");
        }

        foreach (var field in RequiredFields[type])
        {
            if (!message.ContainsKey(field))
            {
                throw new ProtocolException($"{type} missing required field '{field}'");
            }
        }
    }

    public static Dictionary<string, object?> FromJsonElement(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new ProtocolException("control message must be a JSON object");
        }

        var message = new Dictionary<string, object?>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            message[property.Name] = ValueFromJsonElement(property.Value);
        }

        return message;
    }

    /// <summary>
    /// Field-for-field equality ignoring key order, which is the decode-side
    /// conformance rule of protocol-v1.md section 10.
    /// </summary>
    public static bool DeepEquals(object? left, object? right)
    {
        if (left is IReadOnlyDictionary<string, object?> leftObject &&
            right is IReadOnlyDictionary<string, object?> rightObject)
        {
            if (leftObject.Count != rightObject.Count)
            {
                return false;
            }

            foreach (var pair in leftObject)
            {
                if (!rightObject.TryGetValue(pair.Key, out var other) || !DeepEquals(pair.Value, other))
                {
                    return false;
                }
            }

            return true;
        }

        return Equals(left, right);
    }

    private static object? NormalizeValue(object? value) => value switch
    {
        null => null,
        string text => text,
        bool flag => flag,
        int number => (long)number,
        uint number => (long)number,
        long number => number,
        double number => number,
        IReadOnlyDictionary<string, object?> nested => Normalize(nested),
        _ => throw new ProtocolException($"unsupported control value type {value.GetType().Name}"),
    };

    private static object? ValueFromJsonElement(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.Object => FromJsonElement(element),
        JsonValueKind.String => element.GetString(),
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        JsonValueKind.Null => null,
        JsonValueKind.Number => element.TryGetInt64(out var integer) ? integer : element.GetDouble(),
        _ => throw new ProtocolException($"unsupported JSON value kind {element.ValueKind} in a control message"),
    };

    private static void WriteObject(Utf8JsonWriter writer, IReadOnlyDictionary<string, object?> message)
    {
        writer.WriteStartObject();
        foreach (var key in message.Keys.OrderBy(key => key, StringComparer.Ordinal))
        {
            writer.WritePropertyName(key);
            WriteValue(writer, message[key]);
        }

        writer.WriteEndObject();
    }

    private static void WriteValue(Utf8JsonWriter writer, object? value)
    {
        switch (value)
        {
            case null:
                writer.WriteNullValue();
                break;
            case string text:
                writer.WriteStringValue(text);
                break;
            case bool flag:
                writer.WriteBooleanValue(flag);
                break;
            case long number:
                writer.WriteNumberValue(number);
                break;
            case double number:
                writer.WriteNumberValue(number);
                break;
            case IReadOnlyDictionary<string, object?> nested:
                WriteObject(writer, nested);
                break;
            default:
                throw new ProtocolException($"unsupported control value type {value.GetType().Name}");
        }
    }
}
```

`windows/SharedMic.Agent/Protocol/ControlMessages.cs`:

```csharp
namespace SharedMic.Agent.Protocol;

/// <summary>
/// Typed factories for all eleven control messages of protocol-v1.md section 5.
/// Windows only ever sends GREETING, HELLO_ACK, START_ACK, START_NACK,
/// STOP_ACK, STATUS and PONG; the client-side factories exist so tests can
/// drive the Mac half of the conversation. Phase 1 never sends STATUS, because
/// there is no device watcher to trigger it, but the factory is here so the
/// conformance test covers every type.
/// </summary>
public static class ControlMessages
{
    public static readonly IReadOnlyDictionary<string, object?> AudioFormat =
        new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["sampleRate"] = (long)ProtocolConstants.SampleRate,
            ["channels"] = (long)ProtocolConstants.Channels,
            ["sampleFormat"] = ProtocolConstants.SampleFormat,
        };

    public static Dictionary<string, object?> Greeting(string serverId, string nonceHex) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "GREETING",
            ["serverId"] = serverId,
            ["nonce"] = nonceHex,
        };

    public static Dictionary<string, object?> Hello(string clientId, string mac) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "HELLO",
            ["clientId"] = clientId,
            ["mac"] = mac,
        };

    public static Dictionary<string, object?> HelloAck(string serverId, bool micPresent, string deviceLabel) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "HELLO_ACK",
            ["serverId"] = serverId,
            ["micPresent"] = micPresent,
            ["deviceLabel"] = deviceLabel,
        };

    public static Dictionary<string, object?> Start(string requestId) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "START",
            ["requestId"] = requestId,
            ["preferredFormat"] = AudioFormat,
        };

    public static Dictionary<string, object?> StartAck(string requestId, string sessionId) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "START_ACK",
            ["requestId"] = requestId,
            ["sessionId"] = sessionId,
            ["format"] = AudioFormat,
        };

    /// <summary>
    /// `holder` is the ONE optional field in version 1: the friendly name of the
    /// paired device that currently holds the session, sent only alongside
    /// reason "SESSION_IN_USE". It is advisory — the Mac must render a sensible
    /// message without it — so a null, empty or whitespace name is omitted from
    /// the object entirely rather than encoded as null or "".
    /// </summary>
    public static Dictionary<string, object?> StartNack(string requestId, string reason, string? holder = null)
    {
        var message = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "START_NACK",
            ["requestId"] = requestId,
            ["reason"] = reason,
        };

        if (!string.IsNullOrWhiteSpace(holder))
        {
            message["holder"] = holder;
        }

        return message;
    }

    public static Dictionary<string, object?> Stop(string requestId, string sessionId) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "STOP",
            ["requestId"] = requestId,
            ["sessionId"] = sessionId,
        };

    public static Dictionary<string, object?> StopAck(string requestId, string sessionId) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "STOP_ACK",
            ["requestId"] = requestId,
            ["sessionId"] = sessionId,
        };

    public static Dictionary<string, object?> Status(bool micPresent, bool active, string deviceLabel) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "STATUS",
            ["micPresent"] = micPresent,
            ["active"] = active,
            ["deviceLabel"] = deviceLabel,
        };

    public static Dictionary<string, object?> Ping(long seq) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "PING",
            ["seq"] = seq,
        };

    public static Dictionary<string, object?> Pong(long seq) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "PONG",
            ["seq"] = seq,
        };
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~ControlCodecTests"
```

Expected: PASS, 21 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Protocol/ControlCodec.cs windows/SharedMic.Agent/Protocol/ControlMessages.cs windows/SharedMic.Agent.Tests/ControlCodecTests.cs
git commit -m "Phase 1 Task 4: canonical sorted-key control-message codec and message factories"
```

---

### Task 5: Golden-vector conformance

This is the backbone of the plan. It is the only evidence of interoperability that exists before the two machines have ever talked to each other, and it must be data-driven over the committed fixtures rather than a handful of hand-copied cases.

**Files:**
- Test: `windows/SharedMic.Agent.Tests/GoldenVectorTests.cs`
- Test (already created in Task 1, unchanged, repeated below so this task can be read alone): `windows/SharedMic.Agent.Tests/VectorFixtures.cs`

**Interfaces:**
- Consumes: `VectorFixtures.ControlVectors()`, `VectorFixtures.AudioVectors()`, `VectorFixtures.Control(string)`, `VectorFixtures.Audio(string)`, `VectorFixtures.ControlVectorNames()`, `VectorFixtures.AudioVectorNames()`; `FrameCodec.EncodeFrame(FrameType, ReadOnlySpan<byte>)`, `FrameCodec.TryDecodeFrame(...)`; `AudioPayloadCodec.EncodeAudioPayload(uint, ulong, ReadOnlySpan<byte>)`, `AudioPayloadCodec.DecodeAudioPayload(ReadOnlySpan<byte>)`; `ControlCodec.Encode`, `ControlCodec.Decode`, `ControlCodec.FromJsonElement`, `ControlCodec.DeepEquals`, `ControlCodec.RequiredFields`.
- Produces: no production types. Produces the conformance guarantee every later task depends on.

**This task runs on Windows.**

For reference, `VectorFixtures.cs` as created in Task 1:

```csharp
using System.Text.Json;

namespace SharedMic.Agent.Tests;

public sealed record ControlVector(string Name, JsonElement Message, string Hex);

public sealed record AudioVector(string Name, uint Sequence, ulong TimestampUs, string PcmHex, string Hex);

public static class VectorFixtures
{
    private static readonly Lazy<JsonDocument> ControlDocument = new(() => Load("control-messages.json"));
    private static readonly Lazy<JsonDocument> AudioDocument = new(() => Load("audio-frames.json"));

    private static JsonDocument Load(string fileName)
    {
        var path = Path.Combine(AppContext.BaseDirectory, "vectors", fileName);
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(
                $"Golden vector file not found at '{path}'. The test project must copy " +
                "protocol/vectors/*.json into its output directory under 'vectors/'.", path);
        }

        return JsonDocument.Parse(File.ReadAllBytes(path));
    }

    public static IReadOnlyList<ControlVector> ControlVectors()
    {
        var vectors = new List<ControlVector>();
        foreach (var element in ControlDocument.Value.RootElement.EnumerateArray())
        {
            vectors.Add(new ControlVector(
                element.GetProperty("name").GetString()!,
                element.GetProperty("message"),
                element.GetProperty("hex").GetString()!));
        }

        return vectors;
    }

    public static IReadOnlyList<AudioVector> AudioVectors()
    {
        var vectors = new List<AudioVector>();
        foreach (var element in AudioDocument.Value.RootElement.EnumerateArray())
        {
            vectors.Add(new AudioVector(
                element.GetProperty("name").GetString()!,
                element.GetProperty("sequence").GetUInt32(),
                element.GetProperty("timestampUs").GetUInt64(),
                element.GetProperty("pcmHex").GetString()!,
                element.GetProperty("hex").GetString()!));
        }

        return vectors;
    }

    public static ControlVector Control(string name) => ControlVectors().Single(v => v.Name == name);

    public static AudioVector Audio(string name) => AudioVectors().Single(v => v.Name == name);

    public static IEnumerable<object[]> ControlVectorNames() =>
        ControlVectors().Select(v => new object[] { v.Name });

    public static IEnumerable<object[]> AudioVectorNames() =>
        AudioVectors().Select(v => new object[] { v.Name });
}
```

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/GoldenVectorTests.cs`:

```csharp
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

/// <summary>
/// protocol-v1.md section 10: an implementation is conformant only if it
/// produces and accepts the exact bytes in protocol/vectors/. Every case is
/// driven from the committed files, so a vector that is added, changed or
/// dropped changes this suite automatically instead of drifting from it.
/// </summary>
public class GoldenVectorTests
{
    [Fact]
    public void TheVectorFilesHoldTheCaseCountsTheContractPromises()
    {
        Assert.Equal(11, VectorFixtures.ControlVectors().Count);
        Assert.Equal(3, VectorFixtures.AudioVectors().Count);
    }

    [Fact]
    public void EveryControlMessageTypeInTheProtocolHasAVector()
    {
        var covered = VectorFixtures.ControlVectors()
            .Select(vector => ControlCodec.FromJsonElement(vector.Message)["type"] as string)
            .OrderBy(type => type, StringComparer.Ordinal)
            .ToArray();

        Assert.Equal(
            ControlCodec.RequiredFields.Keys.OrderBy(type => type, StringComparer.Ordinal).ToArray(),
            covered);
    }

    [Theory]
    [MemberData(nameof(VectorFixtures.ControlVectorNames), MemberType = typeof(VectorFixtures))]
    public void ControlVectorEncodesToExpectedBytes(string name)
    {
        var vector = VectorFixtures.Control(name);
        var message = ControlCodec.FromJsonElement(vector.Message);

        var frame = FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message));

        Assert.Equal(vector.Hex, Convert.ToHexString(frame).ToLowerInvariant());
    }

    [Theory]
    [MemberData(nameof(VectorFixtures.ControlVectorNames), MemberType = typeof(VectorFixtures))]
    public void ControlVectorDecodesToExpectedMessage(string name)
    {
        var vector = VectorFixtures.Control(name);
        var bytes = Convert.FromHexString(vector.Hex);

        Assert.True(FrameCodec.TryDecodeFrame(bytes, out var type, out var payload, out var consumed));
        Assert.Equal(FrameType.Control, type);
        Assert.Equal(bytes.Length, consumed);

        var decoded = ControlCodec.Decode(payload);
        var expected = ControlCodec.FromJsonElement(vector.Message);

        Assert.True(
            ControlCodec.DeepEquals(expected, decoded),
            $"vector '{name}' decoded to a different message than its 'message' field");
    }

    [Theory]
    [MemberData(nameof(VectorFixtures.AudioVectorNames), MemberType = typeof(VectorFixtures))]
    public void AudioVectorEncodesToExpectedBytes(string name)
    {
        var vector = VectorFixtures.Audio(name);
        var pcm = Convert.FromHexString(vector.PcmHex);

        Assert.Equal(ProtocolConstants.PcmBytesPerFrame, pcm.Length);

        var frame = FrameCodec.EncodeFrame(
            FrameType.Audio,
            AudioPayloadCodec.EncodeAudioPayload(vector.Sequence, vector.TimestampUs, pcm));

        Assert.Equal(vector.Hex, Convert.ToHexString(frame).ToLowerInvariant());
        Assert.Equal(ProtocolConstants.AudioEnvelopeSize, frame.Length);
    }

    [Theory]
    [MemberData(nameof(VectorFixtures.AudioVectorNames), MemberType = typeof(VectorFixtures))]
    public void AudioVectorDecodesToExpectedFrame(string name)
    {
        var vector = VectorFixtures.Audio(name);
        var bytes = Convert.FromHexString(vector.Hex);

        Assert.True(FrameCodec.TryDecodeFrame(bytes, out var type, out var payload, out var consumed));
        Assert.Equal(FrameType.Audio, type);
        Assert.Equal(bytes.Length, consumed);
        Assert.Equal(ProtocolConstants.AudioPayloadSize, payload.Length);

        var frame = AudioPayloadCodec.DecodeAudioPayload(payload);

        Assert.Equal(vector.Sequence, frame.Sequence);
        Assert.Equal(vector.TimestampUs, frame.CaptureTimestampUs);
        Assert.Equal(Convert.FromHexString(vector.PcmHex), frame.Pcm);
    }

    [Fact]
    public void AudioVectorTimestampsAdvanceByOneFrameDuration()
    {
        var frame0 = VectorFixtures.Audio("frame-0");
        var frame1 = VectorFixtures.Audio("frame-1");
        var frame49 = VectorFixtures.Audio("frame-49");

        Assert.Equal(0u, frame0.Sequence);
        Assert.Equal(0ul, frame0.TimestampUs);
        Assert.Equal(1u, frame1.Sequence);
        Assert.Equal((ulong)ProtocolConstants.FrameDurationUs, frame1.TimestampUs);
        Assert.Equal(49u, frame49.Sequence);
        Assert.Equal((ulong)(49 * ProtocolConstants.FrameDurationUs), frame49.TimestampUs);
    }

    [Fact]
    public void ConcatenatedVectorsDecodeAsAStreamWouldDeliverThem()
    {
        var ping = Convert.FromHexString(VectorFixtures.Control("PING").Hex);
        var pong = Convert.FromHexString(VectorFixtures.Control("PONG").Hex);
        var stream = ping.Concat(pong).ToArray();

        Assert.True(FrameCodec.TryDecodeFrame(stream, out _, out var firstPayload, out var firstConsumed));
        Assert.Equal("PING", ControlCodec.Decode(firstPayload)["type"]);
        Assert.Equal(ping.Length, firstConsumed);

        Assert.True(FrameCodec.TryDecodeFrame(stream.AsSpan(firstConsumed), out _, out var secondPayload, out var secondConsumed));
        Assert.Equal("PONG", ControlCodec.Decode(secondPayload)["type"]);
        Assert.Equal(pong.Length, secondConsumed);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~GoldenVectorTests"
```

Expected: FAIL. If Tasks 2 to 4 are complete this suite should already pass on the first run — that is the point of writing the codecs against the document rather than against the fixtures. If it fails, the failure is a real conformance defect and must be fixed in the codec, never by editing `protocol/vectors/*.json`. The two failure shapes to expect and their causes:

- `ControlVectorEncodesToExpectedBytes` differing at a byte where the reference has a raw UTF-8 sequence and the C# output has `\u00XX` means `WriterOptions.Encoder` is not `JavaScriptEncoder.UnsafeRelaxedJsonEscaping`.
- `ControlVectorEncodesToExpectedBytes` differing in property order means `WriteObject` is not sorting with `StringComparer.Ordinal`, or is sorting only the top level and not nested objects (`START`, `START_ACK`).

- [ ] **Step 3: Implement**

There is no production code to add in this task; Tasks 2 to 4 are the implementation. If any assertion fails, fix it in `windows/SharedMic.Agent/Protocol/ControlCodec.cs`, `FrameCodec.cs`, or `AudioPayloadCodec.cs`, and re-run. To see exactly what the reference implementation produces for a message while debugging, run this on the Mac (or anywhere with the harness virtualenv):

```sh
cd harness
.venv/bin/python -c "from sharedmic_protocol.control import encode_control; from sharedmic_protocol.framing import encode_frame; print(encode_frame(1, encode_control({'v':1,'type':'PING','seq':1})).hex())"
```

and confirm the reference suite itself is still green:

```sh
cd harness
.venv/bin/python -m pytest tests/test_vectors.py -v
```

Expected: 26 passed.

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~GoldenVectorTests"
```

Expected: PASS, 32 tests (4 facts plus 11 + 11 + 3 + 3 theory cases).

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent.Tests/GoldenVectorTests.cs
git commit -m "Phase 1 Task 5: data-driven golden-vector conformance over all 14 committed vectors"
```

---

### Task 6: Pairing token, pairing string, and HMAC proof

**Files:**
- Create: `windows/SharedMic.Agent/Security/PairingToken.cs`
- Create: `windows/SharedMic.Agent/Security/AuthProof.cs`
- Test: `windows/SharedMic.Agent.Tests/PairingAndAuthTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.TokenBytes`, `ProtocolConstants.NonceBytes`.
- Produces: `static class PairingToken` with `byte[] Generate()`, `string Encode(ReadOnlySpan<byte> token)`, `byte[] Decode(string text)`; `static class AuthProof` with `byte[] GenerateNonce()`, `string Compute(byte[] token, byte[] nonce)`, `bool Verify(byte[] token, byte[] nonce, string? proof)`.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/PairingAndAuthTests.cs`:

```csharp
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class PairingAndAuthTests
{
    [Fact]
    public void TokenIs256Bits()
    {
        Assert.Equal(32, PairingToken.Generate().Length);
        Assert.Equal(ProtocolConstants.TokenBytes, PairingToken.Generate().Length);
    }

    [Fact]
    public void TokensAreNotRepeated()
    {
        var tokens = new HashSet<string>();
        for (var i = 0; i < 64; i++)
        {
            Assert.True(tokens.Add(Convert.ToHexString(PairingToken.Generate())));
        }
    }

    [Fact]
    public void EncodesTheWorkedExampleFromTheContract()
    {
        var token = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();

        Assert.Equal(
            "AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ",
            PairingToken.Encode(token));
    }

    [Fact]
    public void PairingStringIsAlwaysFiftyEightCharactersInGroupsOfEight()
    {
        for (var i = 0; i < 20; i++)
        {
            var text = PairingToken.Encode(PairingToken.Generate());

            Assert.Equal(58, text.Length);
            var groups = text.Split('-');
            Assert.Equal(7, groups.Length);
            Assert.All(groups.Take(6), group => Assert.Equal(8, group.Length));
            Assert.Equal(4, groups[6].Length);
            Assert.DoesNotContain('=', text);
            Assert.Equal(text.ToUpperInvariant(), text);
        }
    }

    [Fact]
    public void EncodeDecodeIsTheIdentity()
    {
        for (var i = 0; i < 20; i++)
        {
            var token = PairingToken.Generate();
            Assert.Equal(token, PairingToken.Decode(PairingToken.Encode(token)));
        }
    }

    [Fact]
    public void DecodeToleratesHumanTranscription()
    {
        var token = PairingToken.Generate();
        var text = PairingToken.Encode(token);

        Assert.Equal(token, PairingToken.Decode(text.ToLowerInvariant()));
        Assert.Equal(token, PairingToken.Decode(text.Replace("-", " ")));
        Assert.Equal(token, PairingToken.Decode(text.Replace("-", "")));
        Assert.Equal(token, PairingToken.Decode("  " + text.Replace("-", "\t") + "\r\n"));
    }

    [Fact]
    public void DecodeRejectsGarbage()
    {
        Assert.Throws<FormatException>(() => PairingToken.Decode("hello, world!"));
        Assert.Throws<FormatException>(() => PairingToken.Decode(""));
    }

    [Fact]
    public void DecodeRejectsWrongLength()
    {
        var token = PairingToken.Generate();
        var text = PairingToken.Encode(token);

        Assert.Throws<FormatException>(() => PairingToken.Decode(text.Substring(0, 20)));
        Assert.Throws<FormatException>(() => PairingToken.Decode(text + "-AAAAAAAA"));
    }

    [Fact]
    public void DecodeDoesNotMapConfusableCharacters()
    {
        var token = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var text = PairingToken.Encode(token);

        // '0' and '1' are outside the RFC 4648 alphabet, so they are deleted,
        // not corrected. Deleting a character shortens the decode below 32
        // bytes, which the length check must reject.
        Assert.Throws<FormatException>(() => PairingToken.Decode(text.Replace("O", "0")));
    }

    [Fact]
    public void NonceIs256BitsAndFreshEveryTime()
    {
        var nonces = new HashSet<string>();
        for (var i = 0; i < 64; i++)
        {
            var nonce = AuthProof.GenerateNonce();
            Assert.Equal(ProtocolConstants.NonceBytes, nonce.Length);
            Assert.True(nonces.Add(Convert.ToHexString(nonce)));
        }
    }

    [Fact]
    public void ProofMatchesTheReferenceHmac()
    {
        Assert.Equal(
            "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a",
            AuthProof.Compute(new byte[32], new byte[32]));

        var token = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
        var nonce = Enumerable.Range(32, 32).Select(i => (byte)i).ToArray();

        Assert.Equal(
            "62215de7bddcea7e2c4047ff6bb94f8d18262fc8b3f3648134bb7d44158ff84d",
            AuthProof.Compute(token, nonce));
    }

    [Fact]
    public void ProofIsLowercaseHexOfSixtyFourCharacters()
    {
        var proof = AuthProof.Compute(PairingToken.Generate(), AuthProof.GenerateNonce());

        Assert.Equal(64, proof.Length);
        Assert.Equal(proof.ToLowerInvariant(), proof);
    }

    [Fact]
    public void VerifyAcceptsTheMatchingProof()
    {
        var token = PairingToken.Generate();
        var nonce = AuthProof.GenerateNonce();

        Assert.True(AuthProof.Verify(token, nonce, AuthProof.Compute(token, nonce)));
    }

    [Fact]
    public void VerifyRejectsAWrongTokenAWrongNonceAndMalformedProofs()
    {
        var token = PairingToken.Generate();
        var nonce = AuthProof.GenerateNonce();
        var proof = AuthProof.Compute(token, nonce);

        Assert.False(AuthProof.Verify(PairingToken.Generate(), nonce, proof));
        Assert.False(AuthProof.Verify(token, AuthProof.GenerateNonce(), proof));
        Assert.False(AuthProof.Verify(token, nonce, null));
        Assert.False(AuthProof.Verify(token, nonce, ""));
        Assert.False(AuthProof.Verify(token, nonce, "not hex at all"));
        Assert.False(AuthProof.Verify(token, nonce, proof.Substring(0, 62)));
        Assert.False(AuthProof.Verify(token, nonce, proof + "00"));
    }

    [Fact]
    public void ProofIsComputedOverRawNonceBytesNotTheHexString()
    {
        var token = PairingToken.Generate();
        var nonce = AuthProof.GenerateNonce();
        var hexBytes = System.Text.Encoding.ASCII.GetBytes(Convert.ToHexString(nonce).ToLowerInvariant());

        Assert.NotEqual(AuthProof.Compute(token, hexBytes), AuthProof.Compute(token, nonce));
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PairingAndAuthTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'Security' does not exist in the namespace 'SharedMic.Agent'`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Security/PairingToken.cs`:

```csharp
using System.Security.Cryptography;
using System.Text;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// The 256-bit pairing secret of protocol-v1.md section 11.1 and the pairing
/// string of section 11.2. The token is the HMAC key in the section 6
/// handshake; it never crosses the wire in any form.
///
/// The pairing string is RFC 4648 base32, uppercase, unpadded, hyphen-grouped
/// in runs of 8. Decoding is deliberately tolerant because a human is retyping
/// 52 characters off a screen: uppercase, delete everything outside [A-Z2-7],
/// then require exactly 32 bytes back.
///
/// Do not add confusable-character mapping (0 to O, 1 to I or L). A typed '0'
/// is deleted rather than corrected, and the length check then rejects the
/// result. An implementation that maps confusables would accept strings the
/// macOS side rejects; that would be a protocol version change.
/// </summary>
public static class PairingToken
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    private const int GroupSize = 8;

    public static byte[] Generate()
    {
        var token = new byte[ProtocolConstants.TokenBytes];
        RandomNumberGenerator.Fill(token);
        return token;
    }

    public static string Encode(ReadOnlySpan<byte> token)
    {
        var raw = new StringBuilder();
        var buffer = 0;
        var bitsInBuffer = 0;

        foreach (var value in token)
        {
            buffer = (buffer << 8) | value;
            bitsInBuffer += 8;
            while (bitsInBuffer >= 5)
            {
                bitsInBuffer -= 5;
                raw.Append(Alphabet[(buffer >> bitsInBuffer) & 0x1F]);
            }
        }

        if (bitsInBuffer > 0)
        {
            raw.Append(Alphabet[(buffer << (5 - bitsInBuffer)) & 0x1F]);
        }

        var text = raw.ToString();
        var grouped = new StringBuilder(text.Length + ((text.Length - 1) / GroupSize));
        for (var offset = 0; offset < text.Length; offset += GroupSize)
        {
            if (offset > 0)
            {
                grouped.Append('-');
            }

            grouped.Append(text, offset, Math.Min(GroupSize, text.Length - offset));
        }

        return grouped.ToString();
    }

    public static byte[] Decode(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var cleaned = new StringBuilder(text.Length);
        foreach (var character in text.ToUpperInvariant())
        {
            if (Alphabet.IndexOf(character) >= 0)
            {
                cleaned.Append(character);
            }
        }

        var symbols = cleaned.ToString();
        var remainder = symbols.Length % 8;
        if (remainder is 1 or 3 or 6)
        {
            throw new FormatException(
                $"pairing string has an invalid base32 length ({symbols.Length} usable characters)");
        }

        var bytes = new List<byte>((symbols.Length * 5) / 8);
        var buffer = 0;
        var bitsInBuffer = 0;
        foreach (var character in symbols)
        {
            buffer = (buffer << 5) | Alphabet.IndexOf(character);
            bitsInBuffer += 5;
            if (bitsInBuffer >= 8)
            {
                bitsInBuffer -= 8;
                bytes.Add((byte)((buffer >> bitsInBuffer) & 0xFF));
            }
        }

        if (bytes.Count != ProtocolConstants.TokenBytes)
        {
            throw new FormatException(
                $"pairing string decodes to {bytes.Count} bytes, expected {ProtocolConstants.TokenBytes}");
        }

        return bytes.ToArray();
    }
}
```

`windows/SharedMic.Agent/Security/AuthProof.cs`:

```csharp
using System.Security.Cryptography;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// The challenge-response of protocol-v1.md section 6: the server issues a
/// fresh 32-byte nonce per connection, and the client proves possession of a
/// pairing token with HMAC-SHA256 over the RAW nonce bytes, not over the hex
/// string. Verification is constant time.
///
/// Verify() checks ONE token. With several paired devices the agent checks
/// every stored token in turn; PairedDeviceStore.Identify owns that loop and is
/// responsible for not short-circuiting it. Constant-time-per-token is this
/// class's job; constant-time-across-the-list is that one's.
///
/// Never log the token, the nonce, or an offered proof.
/// </summary>
public static class AuthProof
{
    public static byte[] GenerateNonce()
    {
        var nonce = new byte[ProtocolConstants.NonceBytes];
        RandomNumberGenerator.Fill(nonce);
        return nonce;
    }

    public static string Compute(byte[] token, byte[] nonce) =>
        Convert.ToHexString(HMACSHA256.HashData(token, nonce)).ToLowerInvariant();

    public static bool Verify(byte[] token, byte[] nonce, string? proof)
    {
        if (string.IsNullOrEmpty(proof))
        {
            return false;
        }

        byte[] offered;
        try
        {
            offered = Convert.FromHexString(proof);
        }
        catch (FormatException)
        {
            return false;
        }

        var expected = HMACSHA256.HashData(token, nonce);
        return CryptographicOperations.FixedTimeEquals(expected, offered);
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PairingAndAuthTests"
```

Expected: PASS, 15 tests.

Then cross-check the pairing string and the proof against the reference implementation, on the Mac:

```sh
cd harness
.venv/bin/python -c "
from sharedmic_protocol.auth import encode_pairing_string, auth_proof
print(encode_pairing_string(bytes(range(32))))
print(auth_proof(bytes(32), bytes(32)))
print(auth_proof(bytes(range(32)), bytes(range(32, 64))))
"
```

Expected output, matching the three constants asserted above:

```
AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ
33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a
62215de7bddcea7e2c4047ff6bb94f8d18262fc8b3f3648134bb7d44158ff84d
```

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Security windows/SharedMic.Agent.Tests/PairingAndAuthTests.cs
git commit -m "Phase 1 Task 6: 256-bit pairing token, base32 pairing string, HMAC-SHA256 proof"
```

---

### Task 7: Authentication rate limiter

**Files:**
- Create: `windows/SharedMic.Agent/Security/AuthRateLimiter.cs`
- Test: `windows/SharedMic.Agent.Tests/AuthRateLimiterTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.MaxAuthFailures`, `ProtocolConstants.AuthLockoutDuration`.
- Produces: `sealed class AuthRateLimiter` with constructor `AuthRateLimiter(int maxFailures = ProtocolConstants.MaxAuthFailures, TimeSpan? lockoutDuration = null, Func<DateTimeOffset>? clock = null)`, constant `const int MaxTrackedPeers = 1024`, static helper `static string PeerKey(EndPoint? endPoint)`, and members `long TotalFailures`, `long LockoutCount`, `int TrackedPeers`, `int ConsecutiveFailures(string peer)`, `bool IsLockedOut(string peer)`, `TimeSpan LockoutRemaining(string peer)`, `bool TryBeginAttempt(string peer)`, `void RecordFailure(string peer)`, `void RecordSuccess(string peer)`.

One instance is shared by every connection, as before — but the 5-failure/30-second counter inside it is **keyed on the peer's source IP address, with the source port excluded**, per the "Authentication rate limiting" block in Global Constraints. The reasoning, restated because this is the one place it is implemented:

- A **per-device** counter cannot exist. Identifying the device *is* the thing being attempted, and the only pre-identification hint, `clientId`, is unauthenticated — keying on it would let an attacker lock out a named Mac by impersonating it.
- A **per-connection** counter never throttles anything: one failed `HELLO` closes the connection, so the count never reaches 5.
- A **single global** counter lets any host that can reach port 47800 lock every paired Mac out indefinitely, five failures at a time. That is the outcome this design must not have.
- Keying on the **address without the port** keeps §11.4's actual requirement — the counter must not be resettable by picking a new source port — while confining the refusal to the host that earned it.

Agent-wide `TotalFailures` and `LockoutCount` are still tracked, still shown in the tray, and still logged, but they **refuse nothing**; they are the alarm that says "someone is hammering the listener".

The clock is injectable so the 30-second lockout is testable without a 30-second test.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/AuthRateLimiterTests.cs`:

```csharp
using System.Net;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class AuthRateLimiterTests
{
    private const string Attacker = "192.168.1.66";
    private const string MacStudio = "192.168.1.10";
    private const string MacBook = "192.168.1.11";

    private sealed class TestClock
    {
        public DateTimeOffset Now { get; set; } = new(2026, 8, 10, 12, 0, 0, TimeSpan.Zero);

        public DateTimeOffset Read() => Now;

        public void Advance(TimeSpan amount) => Now += amount;
    }

    private static void Fail(AuthRateLimiter limiter, string peer, int times)
    {
        for (var i = 0; i < times; i++)
        {
            limiter.RecordFailure(peer);
        }
    }

    [Fact]
    public void DefaultsMatchTheContract()
    {
        var limiter = new AuthRateLimiter();

        Assert.False(limiter.IsLockedOut(Attacker));
        Assert.True(limiter.TryBeginAttempt(Attacker));
        Assert.Equal(TimeSpan.Zero, limiter.LockoutRemaining(Attacker));
        Assert.Equal(5, ProtocolConstants.MaxAuthFailures);
        Assert.Equal(TimeSpan.FromSeconds(30), ProtocolConstants.AuthLockoutDuration);
    }

    [Fact]
    public void FourFailuresDoNotLockOut()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        Fail(limiter, Attacker, 4);

        Assert.False(limiter.IsLockedOut(Attacker));
        Assert.True(limiter.TryBeginAttempt(Attacker));
        Assert.Equal(4, limiter.ConsecutiveFailures(Attacker));
    }

    [Fact]
    public void FifthConsecutiveFailureLocksOutForThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        Fail(limiter, Attacker, 5);

        Assert.True(limiter.IsLockedOut(Attacker));
        Assert.False(limiter.TryBeginAttempt(Attacker));
        Assert.Equal(TimeSpan.FromSeconds(30), limiter.LockoutRemaining(Attacker));
        Assert.Equal(1, limiter.LockoutCount);
        Assert.Equal(5, limiter.TotalFailures);
    }

    /// <summary>
    /// The reason this limiter is keyed at all. One host failing five times must
    /// not take every paired Mac offline for 30 seconds — that would make a
    /// fleet-wide outage available to anything that can open a TCP connection.
    /// </summary>
    [Fact]
    public void OneLockedOutPeerDoesNotLockOutAnyOtherPeer()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        Fail(limiter, Attacker, 5);

        Assert.True(limiter.IsLockedOut(Attacker));
        Assert.False(limiter.IsLockedOut(MacStudio));
        Assert.False(limiter.IsLockedOut(MacBook));
        Assert.True(limiter.TryBeginAttempt(MacStudio));
        Assert.True(limiter.TryBeginAttempt(MacBook));
        Assert.Equal(0, limiter.ConsecutiveFailures(MacStudio));
    }

    [Fact]
    public void FailuresFromDifferentPeersDoNotAccumulateIntoOneLockout()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 4; i++)
        {
            limiter.RecordFailure(Attacker);
            limiter.RecordFailure(MacStudio);
        }

        Assert.False(limiter.IsLockedOut(Attacker));
        Assert.False(limiter.IsLockedOut(MacStudio));
        Assert.Equal(0, limiter.LockoutCount);
        Assert.Equal(8, limiter.TotalFailures);
    }

    [Fact]
    public void LockoutExpiresAfterThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        Fail(limiter, Attacker, 5);

        clock.Advance(TimeSpan.FromSeconds(29));
        Assert.True(limiter.IsLockedOut(Attacker));

        clock.Advance(TimeSpan.FromSeconds(1.5));
        Assert.False(limiter.IsLockedOut(Attacker));
        Assert.True(limiter.TryBeginAttempt(Attacker));
        Assert.Equal(TimeSpan.Zero, limiter.LockoutRemaining(Attacker));
    }

    [Fact]
    public void CounterResetsAfterALockoutSoTheNextFiveFailuresLockAgain()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        Fail(limiter, Attacker, 5);

        clock.Advance(TimeSpan.FromSeconds(31));
        Assert.Equal(0, limiter.ConsecutiveFailures(Attacker));

        Fail(limiter, Attacker, 4);
        Assert.False(limiter.IsLockedOut(Attacker));

        limiter.RecordFailure(Attacker);
        Assert.True(limiter.IsLockedOut(Attacker));
        Assert.Equal(2, limiter.LockoutCount);
    }

    [Fact]
    public void SuccessClearsTheConsecutiveCountForThatPeerOnly()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        Fail(limiter, MacStudio, 4);
        Fail(limiter, Attacker, 4);
        limiter.RecordSuccess(MacStudio);
        limiter.RecordFailure(MacStudio);

        Assert.Equal(1, limiter.ConsecutiveFailures(MacStudio));
        Assert.Equal(4, limiter.ConsecutiveFailures(Attacker));
        Assert.False(limiter.IsLockedOut(MacStudio));
    }

    [Fact]
    public void ACorrectTokenFromALockedOutPeerIsAlsoRefused()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        Fail(limiter, Attacker, 5);

        // The caller must consult TryBeginAttempt before verifying anything, so
        // the lockout is not a per-credential check: even a valid proof from
        // that address is refused without being evaluated.
        Assert.False(limiter.TryBeginAttempt(Attacker));
    }

    [Fact]
    public void ShortLockoutsAreConfigurableSoIntegrationTestsDoNotWaitThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(maxFailures: 2, lockoutDuration: TimeSpan.FromMilliseconds(200), clock: clock.Read);

        Fail(limiter, Attacker, 2);

        Assert.True(limiter.IsLockedOut(Attacker));
        clock.Advance(TimeSpan.FromMilliseconds(250));
        Assert.False(limiter.IsLockedOut(Attacker));
    }

    /// <summary>
    /// protocol-v1.md section 11.4's stated concern: the count must not be
    /// resettable by picking a new source port. Excluding the port from the key
    /// is exactly what satisfies that.
    /// </summary>
    [Fact]
    public void PeerKeyExcludesTheSourcePortSoReconnectingDoesNotResetTheCount()
    {
        var first = AuthRateLimiter.PeerKey(new IPEndPoint(IPAddress.Parse("192.168.1.66"), 51000));
        var second = AuthRateLimiter.PeerKey(new IPEndPoint(IPAddress.Parse("192.168.1.66"), 51001));

        Assert.Equal(first, second);
        Assert.Equal("192.168.1.66", first);
        Assert.NotEqual(first, AuthRateLimiter.PeerKey(new IPEndPoint(IPAddress.Parse("192.168.1.67"), 51000)));
    }

    [Fact]
    public void PeerKeyCollapsesIpv4MappedIpv6SoOneHostIsOneCounter()
    {
        var mapped = AuthRateLimiter.PeerKey(
            new IPEndPoint(IPAddress.Parse("192.168.1.66").MapToIPv6(), 51000));

        Assert.Equal("192.168.1.66", mapped);
    }

    [Fact]
    public void PeerKeyHandlesAnUnknownEndpointWithoutThrowing()
    {
        Assert.Equal("unknown", AuthRateLimiter.PeerKey(null));
    }

    /// <summary>
    /// An attacker who sprays source addresses must not be able to grow the
    /// table without bound. Expired entries are evicted first, and the table is
    /// capped.
    /// </summary>
    [Fact]
    public void TheTableIsBoundedAndPrunesExpiredEntries()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 2000; i++)
        {
            limiter.RecordFailure($"10.0.{i / 256}.{i % 256}");
        }

        Assert.True(limiter.TrackedPeers <= AuthRateLimiter.MaxTrackedPeers,
            $"tracked {limiter.TrackedPeers} peers, cap is {AuthRateLimiter.MaxTrackedPeers}");
        Assert.Equal(2000, limiter.TotalFailures);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~AuthRateLimiterTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'AuthRateLimiter' could not be found`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Security/AuthRateLimiter.cs`:

```csharp
using System.Net;
using System.Net.Sockets;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// protocol-v1.md section 11.4: after 5 consecutive failed authentication
/// attempts, refuse further attempts for 30 seconds. A failed attempt is any
/// connection that reaches the section 6 handshake without producing a
/// verified HELLO: a wrong mac, a malformed or non-HELLO message, or the
/// 5-second pre-auth deadline expiring.
///
/// Without this, the handshake is an unthrottled HMAC verification oracle
/// reachable by anything that can open a TCP connection to the listener.
///
/// SCOPE, and why. The counter is keyed on the peer's source IP ADDRESS, with
/// the source PORT deliberately excluded. The alternatives were all worse:
///
///   per device      impossible. The device is identified BY the proof, so
///                   before a proof verifies there is nothing to key on but
///                   clientId, which is unauthenticated. Keying on clientId
///                   would let an attacker lock out a named Mac by claiming to
///                   be it.
///   per connection  never throttles. A failed HELLO closes the connection, so
///                   the count never reaches 2.
///   one global      lets any host that can reach port 47800 lock out EVERY
///                   paired Mac indefinitely, five failures at a time. With one
///                   paired Mac that was an annoyance; with several it is a
///                   fleet outage handed to a single attacker.
///
/// Excluding the port preserves section 11.4's actual requirement — the count
/// must not be resettable by choosing a new source port — while confining the
/// refusal to the host that earned it.
///
/// TotalFailures and LockoutCount are agent-wide and REFUSE NOTHING. They exist
/// so the tray and the logs can show that the listener is being hammered.
/// </summary>
public sealed class AuthRateLimiter
{
    /// <summary>An attacker spraying source addresses must not grow this table without bound.</summary>
    public const int MaxTrackedPeers = 1024;

    private sealed class PeerState
    {
        public int ConsecutiveFailures;
        public DateTimeOffset LockedUntil = DateTimeOffset.MinValue;
        public DateTimeOffset LastSeen;
    }

    private readonly int _maxFailures;
    private readonly TimeSpan _lockoutDuration;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();
    private readonly Dictionary<string, PeerState> _peers = new(StringComparer.Ordinal);

    private long _totalFailures;
    private long _lockoutCount;

    public AuthRateLimiter(
        int maxFailures = ProtocolConstants.MaxAuthFailures,
        TimeSpan? lockoutDuration = null,
        Func<DateTimeOffset>? clock = null)
    {
        if (maxFailures < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maxFailures));
        }

        _maxFailures = maxFailures;
        _lockoutDuration = lockoutDuration ?? ProtocolConstants.AuthLockoutDuration;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    /// <summary>
    /// The key a connection is counted under: the remote address, never the
    /// port. An IPv4-mapped IPv6 address (what a dual-stack socket reports for
    /// an IPv4 peer) collapses to its IPv4 form so one host is one counter.
    /// </summary>
    public static string PeerKey(EndPoint? endPoint)
    {
        if (endPoint is not IPEndPoint ip)
        {
            return "unknown";
        }

        var address = ip.Address;
        if (address.AddressFamily == AddressFamily.InterNetworkV6 && address.IsIPv4MappedToIPv6)
        {
            address = address.MapToIPv4();
        }

        return address.ToString();
    }

    /// <summary>Agent-wide total of failed attempts. Advisory: it refuses nothing.</summary>
    public long TotalFailures
    {
        get
        {
            lock (_gate)
            {
                return _totalFailures;
            }
        }
    }

    /// <summary>Agent-wide count of lockouts applied, across all peers. Advisory.</summary>
    public long LockoutCount
    {
        get
        {
            lock (_gate)
            {
                return _lockoutCount;
            }
        }
    }

    public int TrackedPeers
    {
        get
        {
            lock (_gate)
            {
                return _peers.Count;
            }
        }
    }

    public int ConsecutiveFailures(string peer)
    {
        lock (_gate)
        {
            if (!_peers.TryGetValue(peer, out var state))
            {
                return 0;
            }

            Expire(state);
            return state.ConsecutiveFailures;
        }
    }

    public bool IsLockedOut(string peer)
    {
        lock (_gate)
        {
            if (!_peers.TryGetValue(peer, out var state))
            {
                return false;
            }

            Expire(state);
            return _clock() < state.LockedUntil;
        }
    }

    public TimeSpan LockoutRemaining(string peer)
    {
        lock (_gate)
        {
            if (!_peers.TryGetValue(peer, out var state))
            {
                return TimeSpan.Zero;
            }

            var remaining = state.LockedUntil - _clock();
            return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
        }
    }

    /// <summary>
    /// Call this before verifying any proof. False means this peer is locked
    /// out and the connection must be closed without evaluating the credential.
    /// Every other peer is unaffected.
    /// </summary>
    public bool TryBeginAttempt(string peer) => !IsLockedOut(peer);

    public void RecordFailure(string peer)
    {
        lock (_gate)
        {
            _totalFailures++;

            var state = GetOrAdd(peer);
            Expire(state);
            state.ConsecutiveFailures++;
            if (state.ConsecutiveFailures >= _maxFailures)
            {
                state.LockedUntil = _clock() + _lockoutDuration;
                state.ConsecutiveFailures = 0;
                _lockoutCount++;
            }
        }
    }

    public void RecordSuccess(string peer)
    {
        lock (_gate)
        {
            // A success clears only this peer. It must not clear an attacker's
            // counter just because a legitimate Mac authenticated.
            _peers.Remove(peer);
        }
    }

    private PeerState GetOrAdd(string peer)
    {
        if (_peers.TryGetValue(peer, out var existing))
        {
            existing.LastSeen = _clock();
            return existing;
        }

        if (_peers.Count >= MaxTrackedPeers)
        {
            Prune();
        }

        var state = new PeerState { LastSeen = _clock() };
        _peers[peer] = state;
        return state;
    }

    /// <summary>
    /// Drop every entry that is neither locked out nor recently active, then, if
    /// that was not enough, the oldest entries by last activity. Called under
    /// _gate only.
    /// </summary>
    private void Prune()
    {
        var now = _clock();

        foreach (var key in _peers
                     .Where(pair => pair.Value.LockedUntil <= now &&
                                    now - pair.Value.LastSeen > _lockoutDuration)
                     .Select(pair => pair.Key)
                     .ToList())
        {
            _peers.Remove(key);
        }

        if (_peers.Count < MaxTrackedPeers)
        {
            return;
        }

        foreach (var key in _peers
                     .OrderBy(pair => pair.Value.LastSeen)
                     .Take((_peers.Count - MaxTrackedPeers) + 1)
                     .Select(pair => pair.Key)
                     .ToList())
        {
            _peers.Remove(key);
        }
    }

    private void Expire(PeerState state)
    {
        if (state.LockedUntil != DateTimeOffset.MinValue && _clock() >= state.LockedUntil)
        {
            state.LockedUntil = DateTimeOffset.MinValue;
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~AuthRateLimiterTests"
```

Expected: PASS, 14 tests. `OneLockedOutPeerDoesNotLockOutAnyOtherPeer` is the one that encodes the decision above; if a later change makes the counter global again, that is the test that must fail.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Security/AuthRateLimiter.cs windows/SharedMic.Agent.Tests/AuthRateLimiterTests.cs
git commit -m "Phase 1 Task 7: 5-attempt/30-second authentication lockout, keyed per source address"
```

---

### Task 8: Session state machine

**Files:**
- Create: `windows/SharedMic.Agent/Session/SessionStateMachine.cs`
- Test: `windows/SharedMic.Agent.Tests/SessionStateMachineTests.cs`

**Interfaces:**
- Consumes: nothing beyond the BCL.
- Produces: `enum SessionState { Idle, Active }`; `readonly record struct StartOutcome(bool Accepted, string SessionId, string? Reason, bool StartedNewSession)`; `readonly record struct StopOutcome(string SessionId, bool EndedSession)`; `sealed class SessionStateMachine` with constructor `SessionStateMachine(Func<string>? sessionIdFactory = null)` and members `static string DefaultSessionId()`, `SessionState State`, `string? SessionId`, `long SessionsStarted`, `StartOutcome HandleStart(bool micPresent)`, `StopOutcome HandleStop(string requestedSessionId)`, `void Reset()`.

This is one of the three pure units spec §3.1 names. It performs no I/O and is **not thread-safe by design**.

That last point used to be justified by "`ControlConnection` dispatches every control message from a single read loop". With several Macs connected at once that is no longer sufficient on its own: there is one session shared across many connections, each with its own read loop. The resolution is that **nothing outside `SessionArbiter` (Task 9) ever touches a `SessionStateMachine`**. The arbiter owns exactly one instance, serializes every call to it behind a lock, and adds the owner tracking the machine deliberately does not have. Keeping the machine ignorant of owners and locks is what keeps it a pure unit that spec §3.1 can point at.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/SessionStateMachineTests.cs`:

```csharp
using SharedMic.Agent.Session;
using Xunit;

namespace SharedMic.Agent.Tests;

public class SessionStateMachineTests
{
    private static SessionStateMachine Counting()
    {
        var next = 0;
        return new SessionStateMachine(() => $"sess-{++next:0000}");
    }

    [Fact]
    public void StartsIdle()
    {
        var machine = Counting();

        Assert.Equal(SessionState.Idle, machine.State);
        Assert.Null(machine.SessionId);
        Assert.Equal(0, machine.SessionsStarted);
    }

    [Fact]
    public void StartOpensASession()
    {
        var machine = Counting();

        var outcome = machine.HandleStart(micPresent: true);

        Assert.True(outcome.Accepted);
        Assert.True(outcome.StartedNewSession);
        Assert.Null(outcome.Reason);
        Assert.Equal("sess-0001", outcome.SessionId);
        Assert.Equal(SessionState.Active, machine.State);
        Assert.Equal(1, machine.SessionsStarted);
    }

    [Fact]
    public void DuplicateStartIsIdempotentAndDoesNotOpenASecondSession()
    {
        var machine = Counting();

        var first = machine.HandleStart(micPresent: true);
        var second = machine.HandleStart(micPresent: true);

        Assert.Equal(first.SessionId, second.SessionId);
        Assert.True(second.Accepted);
        Assert.False(second.StartedNewSession);
        Assert.Equal(1, machine.SessionsStarted);
    }

    [Fact]
    public void StartIsRejectedWithMicUnavailableWhenTheMicIsAbsent()
    {
        var machine = Counting();

        var outcome = machine.HandleStart(micPresent: false);

        Assert.False(outcome.Accepted);
        Assert.Equal("MIC_UNAVAILABLE", outcome.Reason);
        Assert.Equal(SessionState.Idle, machine.State);
        Assert.Equal(0, machine.SessionsStarted);
    }

    [Fact]
    public void MicLossDoesNotEndAnAlreadyActiveSessionThroughStart()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        var outcome = machine.HandleStart(micPresent: false);

        Assert.False(outcome.Accepted);
        Assert.Equal(SessionState.Active, machine.State);
    }

    [Fact]
    public void StopEndsTheActiveSessionAndReportsItsId()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        var outcome = machine.HandleStop("sess-0001");

        Assert.True(outcome.EndedSession);
        Assert.Equal("sess-0001", outcome.SessionId);
        Assert.Equal(SessionState.Idle, machine.State);
    }

    [Fact]
    public void StopWhileIdleSucceedsAndEchoesTheRequestedId()
    {
        var machine = Counting();

        var outcome = machine.HandleStop("");

        Assert.False(outcome.EndedSession);
        Assert.Equal("", outcome.SessionId);
        Assert.Equal(SessionState.Idle, machine.State);
    }

    [Fact]
    public void DuplicateStopSucceeds()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        var first = machine.HandleStop("sess-0001");
        var second = machine.HandleStop("sess-0001");

        Assert.True(first.EndedSession);
        Assert.False(second.EndedSession);
        Assert.Equal("sess-0001", second.SessionId);
    }

    [Fact]
    public void StopIsNotRejectedOnASessionIdMismatch()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        var outcome = machine.HandleStop("sess-from-a-previous-connection");

        Assert.True(outcome.EndedSession);
        Assert.Equal("sess-0001", outcome.SessionId);
        Assert.Equal(SessionState.Idle, machine.State);
    }

    [Fact]
    public void StartAfterStopOpensAGenuinelyNewSession()
    {
        var machine = Counting();

        var first = machine.HandleStart(micPresent: true);
        machine.HandleStop(first.SessionId);
        var second = machine.HandleStart(micPresent: true);

        Assert.NotEqual(first.SessionId, second.SessionId);
        Assert.True(second.StartedNewSession);
        Assert.Equal(2, machine.SessionsStarted);
    }

    [Fact]
    public void ResetReturnsToIdleWithoutCountingASession()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        machine.Reset();

        Assert.Equal(SessionState.Idle, machine.State);
        Assert.Null(machine.SessionId);
        Assert.Equal(1, machine.SessionsStarted);
    }

    [Fact]
    public void DefaultSessionIdsAreDistinct()
    {
        var ids = new HashSet<string>();
        for (var i = 0; i < 64; i++)
        {
            Assert.True(ids.Add(SessionStateMachine.DefaultSessionId()));
        }
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~SessionStateMachineTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'Session' does not exist in the namespace 'SharedMic.Agent'`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Session/SessionStateMachine.cs`:

```csharp
using System.Security.Cryptography;

namespace SharedMic.Agent.Session;

public enum SessionState
{
    Idle,
    Active,
}

/// <summary>Result of handling a START (protocol-v1.md section 7).</summary>
public readonly record struct StartOutcome(bool Accepted, string SessionId, string? Reason, bool StartedNewSession);

/// <summary>Result of handling a STOP (protocol-v1.md section 7).</summary>
public readonly record struct StopOutcome(string SessionId, bool EndedSession);

/// <summary>
/// Session lifecycle as a pure transition function, per design spec section
/// 3.1. No I/O, no sockets, no timers.
///
/// Both START and STOP are idempotent (protocol-v1.md section 7). A duplicate
/// START while active returns the EXISTING sessionId and does not restart
/// anything, which is what makes it safe for the Mac to retry START after a
/// reconnect without knowing whether the previous one landed. A STOP while
/// idle still succeeds, and STOP is never rejected on a sessionId mismatch:
/// STOP means "make sure no session is active".
///
/// This type knows nothing about WHO holds the session, and that is deliberate.
/// There is one session across every connected Mac; deciding whose START opens
/// it, whose START is refused with SESSION_IN_USE, and whose disconnect ends it
/// belongs to SessionArbiter, which owns the single instance of this class and
/// is the only caller of it.
///
/// Not thread-safe by design. SessionArbiter serializes every call.
///
/// Phase 1 note: an active session streams nothing. There is no capture path
/// yet, so State == Active means only that a session identifier is allocated.
/// </summary>
public sealed class SessionStateMachine
{
    private readonly Func<string> _sessionIdFactory;
    private string? _sessionId;

    public SessionStateMachine(Func<string>? sessionIdFactory = null) =>
        _sessionIdFactory = sessionIdFactory ?? DefaultSessionId;

    public static string DefaultSessionId() =>
        "sess-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();

    public SessionState State => _sessionId is null ? SessionState.Idle : SessionState.Active;

    public string? SessionId => _sessionId;

    public long SessionsStarted { get; private set; }

    public StartOutcome HandleStart(bool micPresent)
    {
        if (_sessionId is not null)
        {
            // An already-active session is not disturbed by a later mic loss
            // report; that path is a STATUS in Phase 2, not a START outcome.
            return new StartOutcome(true, _sessionId, null, false);
        }

        if (!micPresent)
        {
            return new StartOutcome(false, string.Empty, "MIC_UNAVAILABLE", false);
        }

        _sessionId = _sessionIdFactory();
        SessionsStarted++;
        return new StartOutcome(true, _sessionId, null, true);
    }

    public StopOutcome HandleStop(string requestedSessionId)
    {
        var ended = _sessionId;
        _sessionId = null;
        return ended is null
            ? new StopOutcome(requestedSessionId, false)
            : new StopOutcome(ended, true);
    }

    public void Reset() => _sessionId = null;
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~SessionStateMachineTests"
```

Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Session windows/SharedMic.Agent.Tests/SessionStateMachineTests.cs
git commit -m "Phase 1 Task 8: pure session state machine with idempotent START and STOP"
```

---

### Task 9: Session arbiter — one session, many connections

There is one microphone, so there is one session; there are several paired Macs, so there are several connections competing for it. This task is the whole of that arbitration, and it is deliberately separate from Task 8 so the pure state machine stays pure.

**The Python mock proves nothing here.** `MockWindowsServer` gives every connection its own `_session_id`, so two mock clients both get `START_ACK` and no harness test drives two authenticated clients at once. Everything in this task is proved by these local xUnit tests and by the loopback tests in Tasks 14 and 15 — never by `harness/tests` and never by `drive_windows_agent.py`.

**Files:**
- Create: `windows/SharedMic.Agent/Session/SessionArbiter.cs`
- Test: `windows/SharedMic.Agent.Tests/SessionArbiterTests.cs`

**Interfaces:**
- Consumes: `SessionState`, `SessionStateMachine(Func<string>?)`, `SessionStateMachine.HandleStart(bool)`, `SessionStateMachine.HandleStop(string)`, `SessionStateMachine.Reset()`, `SessionStateMachine.State`, `SessionStateMachine.SessionId`, `SessionStateMachine.SessionsStarted` (Task 8).
- Produces: `readonly record struct SessionGrant(bool Accepted, string SessionId, string? Reason, string? HolderName, bool StartedNewSession)`; `readonly record struct SessionRelease(string SessionId, bool EndedSession)`; `sealed class SessionArbiter` with constants `const string MicUnavailable = "MIC_UNAVAILABLE"` and `const string SessionInUse = "SESSION_IN_USE"`, constructor `SessionArbiter(Func<string>? sessionIdFactory = null)`, and members `string? ActiveSessionId`, `string? HolderId`, `string? HolderName`, `long SessionsStarted`, `SessionGrant Start(string ownerId, string ownerName, bool micPresent)`, `SessionRelease Stop(string ownerId, string requestedSessionId)`, `bool EndSessionOwnedBy(string ownerId)`, `void Reset()`.

`ownerId` is the **connection's** identifier, not the device's: one paired Mac may hold two connections open, and only the one that received the `START_ACK` owns the session. `ownerName` is the owner-assigned friendly name of the paired device behind that connection — the value that travels as the advisory `holder` field in a `START_NACK`.

**This task runs on Windows.** It is pure — no sockets, no timers — so it is the cheapest place to get the multi-device rules right.

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/SessionArbiterTests.cs`:

```csharp
using SharedMic.Agent.Session;
using Xunit;

namespace SharedMic.Agent.Tests;

public class SessionArbiterTests
{
    private static SessionArbiter Counting()
    {
        var next = 0;
        return new SessionArbiter(() => $"sess-{++next:0000}");
    }

    [Fact]
    public void StartsIdleWithNoHolder()
    {
        var arbiter = Counting();

        Assert.Null(arbiter.ActiveSessionId);
        Assert.Null(arbiter.HolderId);
        Assert.Null(arbiter.HolderName);
        Assert.Equal(0, arbiter.SessionsStarted);
    }

    [Fact]
    public void TheFirstStartGrantsTheSessionAndRecordsTheHolder()
    {
        var arbiter = Counting();

        var grant = arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        Assert.True(grant.Accepted);
        Assert.True(grant.StartedNewSession);
        Assert.Null(grant.Reason);
        Assert.Equal("sess-0001", grant.SessionId);
        Assert.Equal("Mac Studio", grant.HolderName);
        Assert.Equal("conn-a", arbiter.HolderId);
        Assert.Equal("Mac Studio", arbiter.HolderName);
        Assert.Equal(1, arbiter.SessionsStarted);
    }

    [Fact]
    public void TheHolderRepeatingStartGetsTheSameSessionIdAndNoSecondSession()
    {
        var arbiter = Counting();

        var first = arbiter.Start("conn-a", "Mac Studio", micPresent: true);
        var second = arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        Assert.True(second.Accepted);
        Assert.False(second.StartedNewSession);
        Assert.Equal(first.SessionId, second.SessionId);
        Assert.Equal(1, arbiter.SessionsStarted);
    }

    [Fact]
    public void ASecondDeviceIsRefusedWithSessionInUseAndTheHolderName()
    {
        var arbiter = Counting();
        arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        var refused = arbiter.Start("conn-b", "MacBook Pro", micPresent: true);

        Assert.False(refused.Accepted);
        Assert.Equal("SESSION_IN_USE", refused.Reason);
        Assert.Equal(SessionArbiter.SessionInUse, refused.Reason);
        Assert.Equal("Mac Studio", refused.HolderName);
        Assert.Equal(string.Empty, refused.SessionId);
        Assert.False(refused.StartedNewSession);
    }

    [Fact]
    public void ARefusalLeavesTheExistingSessionCompletelyUndisturbed()
    {
        var arbiter = Counting();
        var granted = arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        arbiter.Start("conn-b", "MacBook Pro", micPresent: true);
        arbiter.Start("conn-c", "Mac mini", micPresent: true);

        Assert.Equal(granted.SessionId, arbiter.ActiveSessionId);
        Assert.Equal("conn-a", arbiter.HolderId);
        Assert.Equal(1, arbiter.SessionsStarted);
    }

    /// <summary>
    /// Otherwise any paired Mac could cancel another's session with one message.
    /// </summary>
    [Fact]
    public void StopFromANonHolderEndsNothingButStillSucceeds()
    {
        var arbiter = Counting();
        var granted = arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        var release = arbiter.Stop("conn-b", "sess-whatever");

        Assert.False(release.EndedSession);
        Assert.Equal("sess-whatever", release.SessionId);
        Assert.Equal(granted.SessionId, arbiter.ActiveSessionId);
        Assert.Equal("conn-a", arbiter.HolderId);
    }

    [Fact]
    public void StopFromTheHolderEndsTheSessionAndReleasesTheHold()
    {
        var arbiter = Counting();
        var granted = arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        var release = arbiter.Stop("conn-a", granted.SessionId);

        Assert.True(release.EndedSession);
        Assert.Equal(granted.SessionId, release.SessionId);
        Assert.Null(arbiter.ActiveSessionId);
        Assert.Null(arbiter.HolderId);
        Assert.Null(arbiter.HolderName);
    }

    [Fact]
    public void TheHolderIsNotRejectedOnAStaleSessionId()
    {
        var arbiter = Counting();
        arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        var release = arbiter.Stop("conn-a", "sess-from-a-previous-connection");

        Assert.True(release.EndedSession);
        Assert.Equal("sess-0001", release.SessionId);
    }

    [Fact]
    public void StopWhileIdleSucceedsAndEchoesTheRequestedId()
    {
        var arbiter = Counting();

        var release = arbiter.Stop("conn-b", "");

        Assert.False(release.EndedSession);
        Assert.Equal("", release.SessionId);
    }

    [Fact]
    public void AfterTheHolderStopsTheOtherDeviceCanStart()
    {
        var arbiter = Counting();
        var first = arbiter.Start("conn-a", "Mac Studio", micPresent: true);
        arbiter.Stop("conn-a", first.SessionId);

        var second = arbiter.Start("conn-b", "MacBook Pro", micPresent: true);

        Assert.True(second.Accepted);
        Assert.True(second.StartedNewSession);
        Assert.NotEqual(first.SessionId, second.SessionId);
        Assert.Equal("conn-b", arbiter.HolderId);
        Assert.Equal(2, arbiter.SessionsStarted);
    }

    /// <summary>
    /// The load-bearing rule. A Mac that crashes, sleeps, or has its cable
    /// pulled never sends STOP. Without this, every other paired Mac is locked
    /// out until the 45-second dead-peer timer fires — and if the session were
    /// only ever released by STOP, forever.
    /// </summary>
    [Fact]
    public void LosingTheOwningConnectionEndsTheSession()
    {
        var arbiter = Counting();
        arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        Assert.True(arbiter.EndSessionOwnedBy("conn-a"));

        Assert.Null(arbiter.ActiveSessionId);
        Assert.Null(arbiter.HolderId);
        Assert.True(arbiter.Start("conn-b", "MacBook Pro", micPresent: true).Accepted);
    }

    [Fact]
    public void LosingANonOwningConnectionDoesNotEndTheSession()
    {
        var arbiter = Counting();
        var granted = arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        Assert.False(arbiter.EndSessionOwnedBy("conn-b"));

        Assert.Equal(granted.SessionId, arbiter.ActiveSessionId);
        Assert.Equal("conn-a", arbiter.HolderId);
    }

    [Fact]
    public void LosingAConnectionWhileIdleIsANoOp()
    {
        var arbiter = Counting();

        Assert.False(arbiter.EndSessionOwnedBy("conn-a"));

        Assert.Null(arbiter.ActiveSessionId);
        Assert.Equal(0, arbiter.SessionsStarted);
    }

    [Fact]
    public void MicUnavailableIsStillRefusedWhenNobodyHoldsTheSession()
    {
        var arbiter = Counting();

        var refused = arbiter.Start("conn-a", "Mac Studio", micPresent: false);

        Assert.False(refused.Accepted);
        Assert.Equal("MIC_UNAVAILABLE", refused.Reason);
        Assert.Null(refused.HolderName);
        Assert.Equal(0, arbiter.SessionsStarted);
    }

    /// <summary>
    /// SESSION_IN_USE is the more specific and more actionable answer, and a
    /// session cannot be active without the mic having been present when it
    /// opened, so it takes precedence.
    /// </summary>
    [Fact]
    public void SessionInUseTakesPrecedenceOverMicUnavailable()
    {
        var arbiter = Counting();
        arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        var refused = arbiter.Start("conn-b", "MacBook Pro", micPresent: false);

        Assert.Equal("SESSION_IN_USE", refused.Reason);
        Assert.Equal("Mac Studio", refused.HolderName);
    }

    /// <summary>
    /// The arbiter passes the holder's name through verbatim, including a blank
    /// one. Suppressing a useless advisory value is the message layer's job:
    /// ControlMessages.StartNack omits the field for null, empty or whitespace.
    /// </summary>
    [Fact]
    public void ABlankHolderNameIsPassedThroughRatherThanInvented()
    {
        var arbiter = Counting();
        arbiter.Start("conn-a", "", micPresent: true);

        var refused = arbiter.Start("conn-b", "MacBook Pro", micPresent: true);

        Assert.Equal("SESSION_IN_USE", refused.Reason);
        Assert.Equal("", refused.HolderName);
        Assert.False(ControlMessagesHolderPresent(refused.HolderName));
    }

    private static bool ControlMessagesHolderPresent(string? holder) =>
        SharedMic.Agent.Protocol.ControlMessages
            .StartNack("r", SessionArbiter.SessionInUse, holder)
            .ContainsKey("holder");

    /// <summary>
    /// Unlike SessionStateMachine, this type is reached from every connection's
    /// read loop at once, so the "one session" rule has to survive a race.
    /// </summary>
    [Fact]
    public void ConcurrentStartsGrantExactlyOneSession()
    {
        var arbiter = Counting();
        var grants = new SessionGrant[32];

        Parallel.For(0, grants.Length, index =>
        {
            grants[index] = arbiter.Start($"conn-{index}", $"Mac {index}", micPresent: true);
        });

        Assert.Equal(1, grants.Count(grant => grant.Accepted));
        Assert.Equal(1, arbiter.SessionsStarted);
        Assert.All(
            grants.Where(grant => !grant.Accepted),
            grant => Assert.Equal("SESSION_IN_USE", grant.Reason));
    }

    [Fact]
    public void ResetClearsTheSessionAndTheHolderWithoutCountingANewOne()
    {
        var arbiter = Counting();
        arbiter.Start("conn-a", "Mac Studio", micPresent: true);

        arbiter.Reset();

        Assert.Null(arbiter.ActiveSessionId);
        Assert.Null(arbiter.HolderId);
        Assert.Null(arbiter.HolderName);
        Assert.Equal(1, arbiter.SessionsStarted);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~SessionArbiterTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'SessionArbiter' could not be found`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Session/SessionArbiter.cs`:

```csharp
namespace SharedMic.Agent.Session;

/// <summary>Outcome of one connection's START (protocol-v1.md section 7).</summary>
public readonly record struct SessionGrant(
    bool Accepted,
    string SessionId,
    string? Reason,
    string? HolderName,
    bool StartedNewSession);

/// <summary>Outcome of one connection's STOP (protocol-v1.md section 7).</summary>
public readonly record struct SessionRelease(string SessionId, bool EndedSession);

/// <summary>
/// One microphone, one session, several paired Macs. This type owns the single
/// SessionStateMachine and everything the machine deliberately does not know:
/// who holds the session, who is refused, and when a lost connection gives it
/// back.
///
/// Rules, all of which have a test in SessionArbiterTests:
///
///   - The connection that received the START_ACK owns the session. ownerId is
///     the CONNECTION's id, not the device's: one Mac may hold two connections
///     and only one of them can own the session.
///   - A START from any other connection while the session is held is refused
///     with SESSION_IN_USE and the holder's friendly name, and changes nothing.
///   - A STOP from a connection that does not hold the session ends nothing and
///     still succeeds. The alternative lets any paired Mac cancel another's
///     session with one message.
///   - EndSessionOwnedBy is called when the owning connection closes for ANY
///     reason — STOP is not the only way a session ends. Dead-peer detection
///     and a socket error both come through here. Without it a crashed Mac
///     locks every other Mac out.
///
/// Every method takes _gate. Unlike SessionStateMachine, this object is reached
/// concurrently from every connection's read loop.
/// </summary>
public sealed class SessionArbiter
{
    public const string MicUnavailable = "MIC_UNAVAILABLE";
    public const string SessionInUse = "SESSION_IN_USE";

    private readonly SessionStateMachine _machine;
    private readonly object _gate = new();

    private string? _ownerId;
    private string? _ownerName;

    public SessionArbiter(Func<string>? sessionIdFactory = null) =>
        _machine = new SessionStateMachine(sessionIdFactory);

    public string? ActiveSessionId
    {
        get
        {
            lock (_gate)
            {
                return _machine.SessionId;
            }
        }
    }

    /// <summary>The connection id that holds the session, or null when idle.</summary>
    public string? HolderId
    {
        get
        {
            lock (_gate)
            {
                return _ownerId;
            }
        }
    }

    /// <summary>The friendly name of the device that holds the session, or null when idle.</summary>
    public string? HolderName
    {
        get
        {
            lock (_gate)
            {
                return _ownerName;
            }
        }
    }

    public long SessionsStarted
    {
        get
        {
            lock (_gate)
            {
                return _machine.SessionsStarted;
            }
        }
    }

    public SessionGrant Start(string ownerId, string ownerName, bool micPresent)
    {
        lock (_gate)
        {
            if (_machine.State == SessionState.Active && !string.Equals(_ownerId, ownerId, StringComparison.Ordinal))
            {
                // Refused, not queued and not superseded: the holder keeps it.
                return new SessionGrant(false, string.Empty, SessionInUse, _ownerName, false);
            }

            var outcome = _machine.HandleStart(micPresent);
            if (!outcome.Accepted)
            {
                return new SessionGrant(false, string.Empty, outcome.Reason, null, false);
            }

            _ownerId = ownerId;
            _ownerName = ownerName;
            return new SessionGrant(true, outcome.SessionId, null, ownerName, outcome.StartedNewSession);
        }
    }

    public SessionRelease Stop(string ownerId, string requestedSessionId)
    {
        lock (_gate)
        {
            if (_machine.State == SessionState.Active && !string.Equals(_ownerId, ownerId, StringComparison.Ordinal))
            {
                // Someone else's session. STOP still succeeds — protocol-v1.md
                // section 7 never rejects a STOP — but it ends nothing.
                return new SessionRelease(requestedSessionId, false);
            }

            var outcome = _machine.HandleStop(requestedSessionId);
            if (outcome.EndedSession)
            {
                _ownerId = null;
                _ownerName = null;
            }

            return new SessionRelease(outcome.SessionId, outcome.EndedSession);
        }
    }

    /// <summary>
    /// Release the session if this connection holds it. Called on every exit
    /// path of a connection — STOP, clean close, socket error, dead peer,
    /// agent shutdown. Returns true when a session was actually ended, which is
    /// what the caller logs.
    /// </summary>
    public bool EndSessionOwnedBy(string ownerId)
    {
        lock (_gate)
        {
            if (_machine.State != SessionState.Active ||
                !string.Equals(_ownerId, ownerId, StringComparison.Ordinal))
            {
                return false;
            }

            _machine.Reset();
            _ownerId = null;
            _ownerName = null;
            return true;
        }
    }

    public void Reset()
    {
        lock (_gate)
        {
            _machine.Reset();
            _ownerId = null;
            _ownerName = null;
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~SessionArbiterTests"
```

Expected: PASS, 18 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Session/SessionArbiter.cs windows/SharedMic.Agent.Tests/SessionArbiterTests.cs
git commit -m "Phase 1 Task 9: session arbiter, one session across many connected Macs"
```

---

### Task 10: Priority send queue

**Files:**
- Create: `windows/SharedMic.Agent/Net/PrioritySendQueue.cs`
- Test: `windows/SharedMic.Agent.Tests/PrioritySendQueueTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.AudioQueueCapacity`.
- Produces: `sealed class PrioritySendQueue` with constructor `PrioritySendQueue(int audioCapacity = ProtocolConstants.AudioQueueCapacity)` and members `void EnqueueControl(byte[] frame)`, `void EnqueueAudio(byte[] frame)`, `bool TryDequeue(out byte[] frame)`, `ValueTask<byte[]> DequeueAsync(CancellationToken cancellationToken)`, `int DiscardAudio()`, `long ControlFramesQueued`, `long AudioFramesOffered`, `long AudioFramesEvicted`, `long AudioFramesDiscarded`, `int ControlDepth`, `int AudioDepth`.

Built now, exercised in Phase 2: nothing in Phase 1 ever calls `EnqueueAudio` on a live connection.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/PrioritySendQueueTests.cs`:

```csharp
using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class PrioritySendQueueTests
{
    private static byte[] Marker(FrameType type, byte tag) => new[] { (byte)type, tag };

    [Fact]
    public void DefaultAudioCapacityIsTwentyFiveFrames()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < ProtocolConstants.AudioQueueCapacity; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        Assert.Equal(25, queue.AudioDepth);
        Assert.Equal(0, queue.AudioFramesEvicted);
    }

    [Fact]
    public void ControlIsAlwaysDrainedBeforeAnyAudio()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 25; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        queue.EnqueueControl(Marker(FrameType.Control, 0xFF));

        Assert.True(queue.TryDequeue(out var first));
        Assert.Equal(Marker(FrameType.Control, 0xFF), first);
    }

    [Fact]
    public void OverflowDropsTheOldestFrameAndCountsExactlyOneEvictionPerFrameEvicted()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 30; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        Assert.Equal(30, queue.AudioFramesOffered);
        Assert.Equal(5, queue.AudioFramesEvicted);
        Assert.Equal(25, queue.AudioDepth);

        var survivors = new List<byte>();
        while (queue.TryDequeue(out var frame))
        {
            survivors.Add(frame[1]);
        }

        // The LAST 25 offered survive, so the oldest 5 were the ones evicted,
        // not an arbitrary 5.
        Assert.Equal(Enumerable.Range(5, 25).Select(i => (byte)i).ToArray(), survivors.ToArray());
    }

    [Fact]
    public void ControlIsUnbounded()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 5000; i++)
        {
            queue.EnqueueControl(Marker(FrameType.Control, (byte)(i % 256)));
        }

        Assert.Equal(5000, queue.ControlDepth);
        Assert.Equal(5000, queue.ControlFramesQueued);
    }

    [Fact]
    public void TeardownDiscardsAreCountedSeparatelyFromOverflowEvictions()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 30; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        var discarded = queue.DiscardAudio();

        Assert.Equal(25, discarded);
        Assert.Equal(25, queue.AudioFramesDiscarded);
        Assert.Equal(5, queue.AudioFramesEvicted);
        Assert.Equal(0, queue.AudioDepth);
    }

    [Fact]
    public void FrameCountersReconcile()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 40; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        var sent = 0;
        for (var i = 0; i < 10; i++)
        {
            Assert.True(queue.TryDequeue(out _));
            sent++;
        }

        var discarded = queue.DiscardAudio();

        // offered = sent + evicted + discarded
        Assert.Equal(queue.AudioFramesOffered, sent + queue.AudioFramesEvicted + discarded);
    }

    [Fact]
    public void TryDequeueReportsFalseOnAnEmptyQueue()
    {
        var queue = new PrioritySendQueue();

        Assert.False(queue.TryDequeue(out var frame));
        Assert.Empty(frame);
    }

    [Fact]
    public async Task DequeueAsyncWaitsUntilSomethingIsQueued()
    {
        var queue = new PrioritySendQueue();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));

        var pending = queue.DequeueAsync(cancellation.Token).AsTask();
        Assert.False(pending.IsCompleted);

        queue.EnqueueControl(Marker(FrameType.Control, 1));

        Assert.Equal(Marker(FrameType.Control, 1), await pending);
    }

    [Fact]
    public async Task DequeueAsyncPrefersControlOverQueuedAudio()
    {
        var queue = new PrioritySendQueue();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));

        queue.EnqueueAudio(Marker(FrameType.Audio, 1));
        queue.EnqueueControl(Marker(FrameType.Control, 2));

        Assert.Equal(Marker(FrameType.Control, 2), await queue.DequeueAsync(cancellation.Token));
        Assert.Equal(Marker(FrameType.Audio, 1), await queue.DequeueAsync(cancellation.Token));
    }

    [Fact]
    public async Task DequeueAsyncHonoursCancellation()
    {
        var queue = new PrioritySendQueue();
        using var cancellation = new CancellationTokenSource();

        var pending = queue.DequeueAsync(cancellation.Token).AsTask();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
    }

    [Fact]
    public async Task DiscardingAudioWhileAWaiterIsPendingDoesNotHandItAPhantomFrame()
    {
        var queue = new PrioritySendQueue();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));

        queue.EnqueueAudio(Marker(FrameType.Audio, 1));
        var first = await queue.DequeueAsync(cancellation.Token);
        Assert.Equal(Marker(FrameType.Audio, 1), first);

        queue.EnqueueAudio(Marker(FrameType.Audio, 2));
        queue.DiscardAudio();

        var pending = queue.DequeueAsync(cancellation.Token).AsTask();
        await Task.Delay(100, cancellation.Token);
        Assert.False(pending.IsCompleted);

        queue.EnqueueControl(Marker(FrameType.Control, 3));
        Assert.Equal(Marker(FrameType.Control, 3), await pending);
    }

    [Fact]
    public void EnqueueAudioNeverBlocksEvenWhenFull()
    {
        var queue = new PrioritySendQueue(audioCapacity: 2);
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();

        for (var i = 0; i < 10000; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)(i % 256)));
        }

        stopwatch.Stop();
        Assert.Equal(2, queue.AudioDepth);
        Assert.Equal(9998, queue.AudioFramesEvicted);
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(5), $"enqueue took {stopwatch.Elapsed}");
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PrioritySendQueueTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'Net' does not exist in the namespace 'SharedMic.Agent'`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Net/PrioritySendQueue.cs`:

```csharp
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Net;

/// <summary>
/// protocol-v1.md section 9. One TCP/TLS connection carries both control and
/// audio, so the sender needs a rule for what goes on the wire first:
///
///   - Control messages are queued UNBOUNDEDLY and are ALWAYS drained before
///     any audio frame. A STOP_ACK or a STATUS must never be stuck behind a
///     backlog of audio.
///   - Audio is a bounded ring of 25 frames (500 ms at 50 fps) that drops the
///     OLDEST frame on overflow and NEVER blocks. Audio production must never
///     be slowed by a stalled connection.
///
/// The two loss counters are kept apart deliberately: evictions mean the
/// network could not keep up and are worth alarming on; teardown discards are
/// intended behavior and alarming on them would be noise. Folding them into one
/// counter makes the number that matters unreadable, and breaks the identity
/// offered = sent + evicted + discarded.
///
/// Phase 1 never calls EnqueueAudio on a live connection.
/// </summary>
public sealed class PrioritySendQueue
{
    private readonly int _audioCapacity;
    private readonly Queue<byte[]> _control = new();
    private readonly Queue<byte[]> _audio = new();
    private readonly SemaphoreSlim _available = new(0);
    private readonly object _gate = new();

    private long _controlFramesQueued;
    private long _audioFramesOffered;
    private long _audioFramesEvicted;
    private long _audioFramesDiscarded;

    public PrioritySendQueue(int audioCapacity = ProtocolConstants.AudioQueueCapacity)
    {
        if (audioCapacity < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(audioCapacity));
        }

        _audioCapacity = audioCapacity;
    }

    public long ControlFramesQueued
    {
        get { lock (_gate) { return _controlFramesQueued; } }
    }

    public long AudioFramesOffered
    {
        get { lock (_gate) { return _audioFramesOffered; } }
    }

    public long AudioFramesEvicted
    {
        get { lock (_gate) { return _audioFramesEvicted; } }
    }

    public long AudioFramesDiscarded
    {
        get { lock (_gate) { return _audioFramesDiscarded; } }
    }

    public int ControlDepth
    {
        get { lock (_gate) { return _control.Count; } }
    }

    public int AudioDepth
    {
        get { lock (_gate) { return _audio.Count; } }
    }

    public void EnqueueControl(byte[] frame)
    {
        lock (_gate)
        {
            _control.Enqueue(frame);
            _controlFramesQueued++;
        }

        _available.Release();
    }

    public void EnqueueAudio(byte[] frame)
    {
        bool evicted;
        lock (_gate)
        {
            _audioFramesOffered++;
            evicted = _audio.Count >= _audioCapacity;
            if (evicted)
            {
                _audio.Dequeue();
                _audioFramesEvicted++;
            }

            _audio.Enqueue(frame);
        }

        // On an eviction the depth is unchanged, so no new permit is owed.
        if (!evicted)
        {
            _available.Release();
        }
    }

    public bool TryDequeue(out byte[] frame)
    {
        lock (_gate)
        {
            if (_control.Count > 0)
            {
                frame = _control.Dequeue();
                _available.Wait(0);
                return true;
            }

            if (_audio.Count > 0)
            {
                frame = _audio.Dequeue();
                _available.Wait(0);
                return true;
            }
        }

        frame = Array.Empty<byte>();
        return false;
    }

    public async ValueTask<byte[]> DequeueAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            await _available.WaitAsync(cancellationToken).ConfigureAwait(false);

            lock (_gate)
            {
                if (_control.Count > 0)
                {
                    return _control.Dequeue();
                }

                if (_audio.Count > 0)
                {
                    return _audio.Dequeue();
                }
            }

            // A concurrent DiscardAudio removed the frame this permit stood
            // for. Wait again rather than dequeue from an empty queue.
        }
    }

    /// <summary>
    /// Drop every queued audio frame, as at session teardown. Counted as
    /// discards, never as evictions. Returns the number dropped.
    /// </summary>
    public int DiscardAudio()
    {
        lock (_gate)
        {
            var discarded = _audio.Count;
            _audio.Clear();
            _audioFramesDiscarded += discarded;

            // Give back the permits those frames owned, inside the lock, so the
            // permit count and the queue depth stay consistent for any waiter.
            for (var i = 0; i < discarded; i++)
            {
                _available.Wait(0);
            }

            return discarded;
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PrioritySendQueueTests"
```

Expected: PASS, 12 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Net/PrioritySendQueue.cs windows/SharedMic.Agent.Tests/PrioritySendQueueTests.cs
git commit -m "Phase 1 Task 10: priority send queue, unbounded control, 25-frame drop-oldest audio ring"
```

---

### Task 11: Incremental frame reader

**Files:**
- Create: `windows/SharedMic.Agent/Net/FrameReader.cs`
- Test: `windows/SharedMic.Agent.Tests/FrameReaderTests.cs`

**Interfaces:**
- Consumes: `FrameCodec.TryDecodeFrame(...)`, `FrameType`, `ProtocolException`, `ProtocolConstants.EnvelopeSize`, `ProtocolConstants.MaxPayloadBytes`.
- Produces: `readonly record struct ReceivedFrame(FrameType Type, byte[] Payload)`; `sealed class FrameReader` with constructor `FrameReader(Stream stream)` and `Task<ReceivedFrame?> ReadFrameAsync(CancellationToken cancellationToken)` returning `null` on clean end-of-stream.

The harness README names extracting this shared reader as "a good first task in Phase 1"; this is the C# half of that observation.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/FrameReaderTests.cs`:

```csharp
using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class FrameReaderTests
{
    private static CancellationToken ShortDeadline() => new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token;

    [Fact]
    public async Task ReadsTwoConcatenatedFramesFromOneBuffer()
    {
        var first = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 1 });
        var second = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 2, 2 });
        using var stream = new MemoryStream(first.Concat(second).ToArray());
        var reader = new FrameReader(stream);

        var a = await reader.ReadFrameAsync(ShortDeadline());
        var b = await reader.ReadFrameAsync(ShortDeadline());
        var end = await reader.ReadFrameAsync(ShortDeadline());

        Assert.Equal(new byte[] { 1 }, a!.Value.Payload);
        Assert.Equal(new byte[] { 2, 2 }, b!.Value.Payload);
        Assert.Null(end);
    }

    [Fact]
    public async Task ReassemblesAFrameSplitAcrossReads()
    {
        var payload = new byte[600];
        Random.Shared.NextBytes(payload);
        var frame = FrameCodec.EncodeFrame(FrameType.Control, payload);
        using var stream = new ChunkedStream(frame, chunkSize: 7);
        var reader = new FrameReader(stream);

        var received = await reader.ReadFrameAsync(ShortDeadline());

        Assert.Equal(FrameType.Control, received!.Value.Type);
        Assert.Equal(payload, received.Value.Payload);
    }

    [Fact]
    public async Task ReadsAFullSizeAudioEnvelope()
    {
        var pcm = new byte[ProtocolConstants.PcmBytesPerFrame];
        Random.Shared.NextBytes(pcm);
        var frame = FrameCodec.EncodeFrame(FrameType.Audio, AudioPayloadCodec.EncodeAudioPayload(3u, 60000ul, pcm));
        using var stream = new ChunkedStream(frame, chunkSize: 511);
        var reader = new FrameReader(stream);

        var received = await reader.ReadFrameAsync(ShortDeadline());

        Assert.Equal(FrameType.Audio, received!.Value.Type);
        Assert.Equal(ProtocolConstants.AudioPayloadSize, received.Value.Payload.Length);
    }

    [Fact]
    public async Task ReturnsNullOnACleanEndOfStream()
    {
        using var stream = new MemoryStream(Array.Empty<byte>());
        var reader = new FrameReader(stream);

        Assert.Null(await reader.ReadFrameAsync(ShortDeadline()));
    }

    [Fact]
    public async Task ThrowsWhenTheStreamEndsMidFrame()
    {
        var frame = FrameCodec.EncodeFrame(FrameType.Control, new byte[] { 1, 2, 3, 4 });
        using var stream = new MemoryStream(frame.AsSpan(0, frame.Length - 2).ToArray());
        var reader = new FrameReader(stream);

        var error = await Assert.ThrowsAsync<ProtocolException>(() => reader.ReadFrameAsync(ShortDeadline()));
        Assert.Contains("mid-frame", error.Message);
    }

    [Fact]
    public async Task PropagatesAnUnknownFrameTypeAsAProtocolViolation()
    {
        using var stream = new MemoryStream(new byte[] { 9, 0, 0, 0, 0 });
        var reader = new FrameReader(stream);

        await Assert.ThrowsAsync<ProtocolException>(() => reader.ReadFrameAsync(ShortDeadline()));
    }

    [Fact]
    public async Task PropagatesAnOversizedLengthAsAProtocolViolation()
    {
        using var stream = new MemoryStream(new byte[] { 1, 0x00, 0x10, 0x00, 0x01, 0x00 });
        var reader = new FrameReader(stream);

        await Assert.ThrowsAsync<ProtocolException>(() => reader.ReadFrameAsync(ShortDeadline()));
    }

    /// <summary>A stream that hands out at most `chunkSize` bytes per read.</summary>
    private sealed class ChunkedStream : Stream
    {
        private readonly byte[] _data;
        private readonly int _chunkSize;
        private int _position;

        public ChunkedStream(byte[] data, int chunkSize)
        {
            _data = data;
            _chunkSize = chunkSize;
        }

        public override bool CanRead => true;

        public override bool CanSeek => false;

        public override bool CanWrite => false;

        public override long Length => _data.Length;

        public override long Position
        {
            get => _position;
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var take = Math.Min(Math.Min(count, _chunkSize), _data.Length - _position);
            Array.Copy(_data, _position, buffer, offset, take);
            _position += take;
            return take;
        }

        public override void Flush()
        {
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~FrameReaderTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'FrameReader' could not be found`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Net/FrameReader.cs`:

```csharp
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Net;

public readonly record struct ReceivedFrame(FrameType Type, byte[] Payload);

/// <summary>
/// Reads whole envelopes off a byte stream, buffering partial data rather than
/// guessing (protocol-v1.md section 3). Returns null on a clean end of stream,
/// and throws <see cref="ProtocolException"/> on a violation, which the caller
/// must answer by closing the connection.
///
/// One reader belongs to one connection and one reading thread; it is not
/// thread-safe.
/// </summary>
public sealed class FrameReader
{
    private const int InitialBufferSize = 8192;
    private static readonly int MaxBufferSize = ProtocolConstants.EnvelopeSize + ProtocolConstants.MaxPayloadBytes;

    private readonly Stream _stream;
    private byte[] _buffer = new byte[InitialBufferSize];
    private int _length;

    public FrameReader(Stream stream) => _stream = stream;

    public async Task<ReceivedFrame?> ReadFrameAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            if (FrameCodec.TryDecodeFrame(_buffer.AsSpan(0, _length), out var type, out var payload, out var consumed))
            {
                Buffer.BlockCopy(_buffer, consumed, _buffer, 0, _length - consumed);
                _length -= consumed;
                return new ReceivedFrame(type, payload);
            }

            if (_length == _buffer.Length)
            {
                if (_buffer.Length >= MaxBufferSize)
                {
                    throw new ProtocolException(
                        $"buffered {_length} bytes without completing a frame, which exceeds the maximum envelope size");
                }

                Array.Resize(ref _buffer, Math.Min(_buffer.Length * 2, MaxBufferSize));
            }

            var read = await _stream.ReadAsync(_buffer.AsMemory(_length), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                if (_length == 0)
                {
                    return null;
                }

                throw new ProtocolException($"connection closed mid-frame with {_length} buffered bytes");
            }

            _length += read;
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~FrameReaderTests"
```

Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Net/FrameReader.cs windows/SharedMic.Agent.Tests/FrameReaderTests.cs
git commit -m "Phase 1 Task 11: incremental frame reader with close-on-violation semantics"
```

---

### Task 12: Device certificate and DPAPI-protected identity store

**Files:**
- Create: `windows/SharedMic.Agent/Security/DeviceCertificate.cs`
- Create: `windows/SharedMic.Agent/Security/IdentityStore.cs`
- Test: `windows/SharedMic.Agent.Tests/IdentityTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.CertificateCommonName`, `ProtocolConstants.CertificateValidityDays`, `ProtocolConstants.CertificateBackdate`.
- Produces: `static class DeviceCertificate` with `X509Certificate2 CreateSelfSigned(string commonName = ProtocolConstants.CertificateCommonName)` and `string Fingerprint(X509Certificate2 certificate)`; `sealed record AgentIdentity(string ServerId, X509Certificate2 Certificate, string Fingerprint)`; `sealed class IdentityStore` with constructor `IdentityStore(string directory)`, `static string DefaultDirectory`, `AgentIdentity LoadOrCreate()`, `void Reset()`.

**The agent identity no longer carries a pairing token.** It used to: there was one token, so it sat next to the certificate. With a list of paired devices, each with its own token, tokens move to `PairedDeviceStore` (Task 13) and `AgentIdentity` is reduced to what is genuinely one-per-agent — the server identifier and the certificate the Mac pins. Anything that previously read `identity.Token` or `identity.PairingString` now goes through the device store instead.

**This task runs on Windows.** DPAPI (`ProtectedData`) is Windows-only, and so is the Schannel-compatible PKCS#12 round-trip.

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/IdentityTests.cs`:

```csharp
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class IdentityTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), "sharedmic-identity-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }

    [Fact]
    public void CertificateMatchesTheRequiredProfile()
    {
        using var certificate = DeviceCertificate.CreateSelfSigned();

        Assert.Equal("CN=shared-mic", certificate.Subject);
        Assert.Equal(certificate.Subject, certificate.Issuer);
        Assert.True(certificate.HasPrivateKey);

        using var key = certificate.GetECDsaPublicKey();
        Assert.NotNull(key);
        Assert.Equal(256, key!.KeySize);

        Assert.Equal("1.2.840.10045.4.3.2", certificate.SignatureAlgorithm.Value);

        var chainLengthDays = (certificate.NotAfter - certificate.NotBefore).TotalDays;
        Assert.InRange(chainLengthDays, 3649.9, 3650.1);
        Assert.True(certificate.NotBefore.ToUniversalTime() < DateTime.UtcNow);
    }

    [Fact]
    public void CertificateCarriesASubjectAlternativeNameMatchingTheCommonName()
    {
        using var certificate = DeviceCertificate.CreateSelfSigned();

        // Look the extension up by OID and wrap it, rather than relying on
        // X509Certificate2.Extensions to hand back a strongly typed instance.
        var raw = certificate.Extensions
            .Cast<X509Extension>()
            .SingleOrDefault(extension => extension.Oid?.Value == "2.5.29.17");

        Assert.NotNull(raw);

        var san = new X509SubjectAlternativeNameExtension(raw!.RawData, raw.Critical);
        Assert.Equal(new[] { "shared-mic" }, san.EnumerateDnsNames().ToArray());
    }

    [Fact]
    public void FingerprintIsLowercaseHexSha256OfTheDerEncoding()
    {
        using var certificate = DeviceCertificate.CreateSelfSigned();

        var fingerprint = DeviceCertificate.Fingerprint(certificate);

        Assert.Equal(64, fingerprint.Length);
        Assert.Equal(fingerprint.ToLowerInvariant(), fingerprint);
        Assert.Equal(
            Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant(),
            fingerprint);
    }

    [Fact]
    public void DistinctCertificatesHaveDistinctFingerprints()
    {
        using var a = DeviceCertificate.CreateSelfSigned();
        using var b = DeviceCertificate.CreateSelfSigned();

        Assert.NotEqual(DeviceCertificate.Fingerprint(a), DeviceCertificate.Fingerprint(b));
    }

    [Fact]
    public void FirstRunGeneratesEverythingAndSecondRunReusesIt()
    {
        var store = new IdentityStore(_directory);

        var first = store.LoadOrCreate();
        var second = store.LoadOrCreate();

        Assert.Equal(first.Fingerprint, second.Fingerprint);
        Assert.Equal(first.ServerId, second.ServerId);
        Assert.True(first.Certificate.HasPrivateKey);
        Assert.True(second.Certificate.HasPrivateKey);
    }

    /// <summary>
    /// Pairing tokens live in PairedDeviceStore now, one per device. The
    /// identity store must not resurrect a single agent-wide token.
    /// </summary>
    [Fact]
    public void TheIdentityStoreHoldsNoPairingToken()
    {
        var store = new IdentityStore(_directory);
        store.LoadOrCreate();

        Assert.False(File.Exists(Path.Combine(_directory, "token.dpapi")));
        Assert.Null(typeof(AgentIdentity).GetProperty("Token"));
        Assert.Null(typeof(AgentIdentity).GetProperty("PairingString"));
    }

    [Fact]
    public void PrivateKeyIsNotStoredInPlaintextOnDisk()
    {
        var store = new IdentityStore(_directory);
        var identity = store.LoadOrCreate();

        var onDisk = File.ReadAllBytes(Path.Combine(_directory, "device-cert.dpapi"));

        // A PKCS#12 blob always starts with a DER SEQUENCE tag (0x30). A DPAPI
        // blob starts with its own provider GUID, so a plaintext export would
        // be visible immediately.
        Assert.NotEqual(0x30, onDisk[0]);
        Assert.False(ContainsSubsequence(onDisk, identity.Certificate.RawData));
    }

    [Fact]
    public void ResetForcesRegenerationOfANewCertificate()
    {
        var store = new IdentityStore(_directory);
        var first = store.LoadOrCreate();

        store.Reset();
        var second = store.LoadOrCreate();

        Assert.NotEqual(first.Fingerprint, second.Fingerprint);
    }

    private static bool ContainsSubsequence(byte[] haystack, byte[] needle)
    {
        if (needle.Length == 0 || needle.Length > haystack.Length)
        {
            return false;
        }

        for (var i = 0; i <= haystack.Length - needle.Length; i++)
        {
            if (haystack.AsSpan(i, needle.Length).SequenceEqual(needle))
            {
                return true;
            }
        }

        return false;
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~IdentityTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'DeviceCertificate' could not be found` and the same for `IdentityStore`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Security/DeviceCertificate.cs`:

```csharp
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// The device certificate profile of protocol-v1.md section 11.3. There is no
/// CA anywhere in this design; the certificate exists only so the Mac can pin
/// the SHA-256 of its DER encoding.
///
/// Profile, all of it load-bearing for the Swift client:
///   key type   EC P-256 (secp256r1)
///   signature  ECDSA with SHA-256, self-signed, issuer equals subject
///   subject    CN = shared-mic
///   SAN        REQUIRED, one dNSName byte-identical to the subject CN
///   validity   3,650 days, starting 5 minutes in the past
///   chain      none, one certificate long
///
/// The SAN is not decorative: Network.framework and URLSession evaluate a
/// certificate before handing it to a custom trust callback and some stacks
/// reject a SAN-less certificate at that earlier stage, producing a failure
/// that looks like a network error rather than a certificate problem.
/// </summary>
public static class DeviceCertificate
{
    public static X509Certificate2 CreateSelfSigned(string commonName = ProtocolConstants.CertificateCommonName)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest($"CN={commonName}", key, HashAlgorithmName.SHA256);

        var san = new SubjectAlternativeNameBuilder();
        san.AddDnsName(commonName);
        request.CertificateExtensions.Add(san.Build());

        var now = DateTimeOffset.UtcNow;
        using var ephemeral = request.CreateSelfSigned(
            now - ProtocolConstants.CertificateBackdate,
            now.AddDays(ProtocolConstants.CertificateValidityDays));

        // Schannel, the TLS stack behind SslStream on Windows, cannot serve the
        // ephemeral key CreateSelfSigned() produces. Round-tripping through a
        // PKCS#12 blob gives the certificate a key handle SslStream accepts.
        var pkcs12 = ephemeral.Export(X509ContentType.Pkcs12);
        try
        {
            return X509CertificateLoader.LoadPkcs12(
                pkcs12,
                password: null,
                X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pkcs12);
        }
    }

    /// <summary>Lowercase hex SHA-256 of the certificate's DER encoding. This is the entire trust model.</summary>
    public static string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant();
}
```

`windows/SharedMic.Agent/Security/IdentityStore.cs`:

```csharp
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace SharedMic.Agent.Security;

/// <summary>
/// What the agent is, independent of who is paired with it: its server
/// identifier and its device certificate. Never log any field except ServerId
/// and Fingerprint.
///
/// There is deliberately no Token here. Pairing tokens are per device and live
/// in PairedDeviceStore; an agent-wide token is exactly the assumption the
/// multi-Mac design removes.
/// </summary>
public sealed record AgentIdentity(string ServerId, X509Certificate2 Certificate, string Fingerprint);

/// <summary>
/// First-run generation and at-rest protection of the agent identity, per
/// design spec section 7.1: the certificate's private key is DPAPI-protected
/// under the current user. Regenerating it is explicit, never automatic — every
/// paired Mac's pin breaks when it changes.
/// </summary>
public sealed class IdentityStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("shared-mic/v1/identity");

    private readonly string _directory;

    public IdentityStore(string directory) => _directory = directory;

    public static string DefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SharedMic");

    private string CertificatePath => Path.Combine(_directory, "device-cert.dpapi");

    private string ServerIdPath => Path.Combine(_directory, "server-id.txt");

    public AgentIdentity LoadOrCreate()
    {
        Directory.CreateDirectory(_directory);

        var certificate = LoadOrCreateCertificate();
        var serverId = LoadOrCreateServerId();

        return new AgentIdentity(serverId, certificate, DeviceCertificate.Fingerprint(certificate));
    }

    public void Reset()
    {
        foreach (var path in new[] { CertificatePath, ServerIdPath })
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    private X509Certificate2 LoadOrCreateCertificate()
    {
        if (File.Exists(CertificatePath))
        {
            var stored = Unprotect(File.ReadAllBytes(CertificatePath));
            try
            {
                return X509CertificateLoader.LoadPkcs12(
                    stored,
                    password: null,
                    X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(stored);
            }
        }

        var certificate = DeviceCertificate.CreateSelfSigned();
        var pkcs12 = certificate.Export(X509ContentType.Pkcs12);
        try
        {
            WriteProtected(CertificatePath, pkcs12);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pkcs12);
        }

        return certificate;
    }

    private string LoadOrCreateServerId()
    {
        if (File.Exists(ServerIdPath))
        {
            var stored = File.ReadAllText(ServerIdPath).Trim();
            if (stored.Length > 0)
            {
                return stored;
            }
        }

        var serverId = Environment.MachineName.Trim();
        if (serverId.Length == 0)
        {
            serverId = "shared-mic-windows";
        }

        File.WriteAllText(ServerIdPath, serverId);
        return serverId;
    }

    private static void WriteProtected(string path, byte[] plaintext) =>
        File.WriteAllBytes(path, ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser));

    private static byte[] Unprotect(byte[] ciphertext) =>
        ProtectedData.Unprotect(ciphertext, Entropy, DataProtectionScope.CurrentUser);
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~IdentityTests"
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Security/DeviceCertificate.cs windows/SharedMic.Agent/Security/IdentityStore.cs windows/SharedMic.Agent.Tests/IdentityTests.cs
git commit -m "Phase 1 Task 12: P-256 device certificate with SAN and DPAPI-protected identity store"
```

---

### Task 13: Paired-device store — many tokens, revocation, identify-by-proof

The list of Macs allowed to connect, and the only thing that turns an HMAC proof into an identity.

**The Python mock proves nothing here either.** `MockWindowsServer` holds a single `self._token` and compares against it. Nothing in `harness/tests` exercises a second token, a revoked token, or identification by proof. These xUnit tests are the entire evidence.

**Files:**
- Create: `windows/SharedMic.Agent/Security/PairedDeviceStore.cs`
- Test: `windows/SharedMic.Agent.Tests/PairedDeviceStoreTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.TokenBytes`; `PairingToken.Generate()`, `PairingToken.Encode(ReadOnlySpan<byte>)`, `PairingToken.Decode(string)`; `AuthProof.Verify(byte[], byte[], string?)`.
- Produces: `sealed record PairedDevice(string DeviceId, string FriendlyName, byte[] Token, DateTimeOffset PairedAt)` with computed property `string PairingString`; `sealed class PairedDeviceStore` with constructor `PairedDeviceStore(string directory)`, and members `int Count`, `IReadOnlyList<PairedDevice> List()`, `PairedDevice Pair(string friendlyName)`, `bool Revoke(string deviceId)`, `PairedDevice? Identify(byte[] nonce, string? proof)`.

Three properties this task exists to guarantee:

1. **Every token is DPAPI-protected at rest**, not just the first one. The whole list is one protected blob, written atomically so a crash mid-write cannot lose every pairing at once.
2. **`Identify` iterates every stored token and does not short-circuit.** `AuthProof.Verify` is constant-time for one token; this loop is what makes the *number* of HMAC evaluations independent of which device matched, or of whether any did. It has no `break` and no early `return`, deliberately.
3. **Revocation is deletion.** There is no tombstone and no distinct "revoked" answer, so a proof from a revoked device produces exactly what a proof from a stranger produces: `null`, the same amount of work, and — at the caller — the same silent close and the same rate-limiter failure. A distinguishable response would tell an attacker that a token was once valid.

**This task runs on Windows.** DPAPI is Windows-only.

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/PairedDeviceStoreTests.cs`:

```csharp
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class PairedDeviceStoreTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), "sharedmic-devices-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }

    private static byte[] Nonce() => AuthProof.GenerateNonce();

    [Fact]
    public void AFreshAgentHasNoPairedDevices()
    {
        var store = new PairedDeviceStore(_directory);

        Assert.Equal(0, store.Count);
        Assert.Empty(store.List());
        Assert.Null(store.Identify(Nonce(), new string('a', 64)));
    }

    [Fact]
    public void PairingMintsAFullSizedTokenAndAUsablePairingString()
    {
        var store = new PairedDeviceStore(_directory);

        var device = store.Pair("Mac Studio");

        Assert.Equal(ProtocolConstants.TokenBytes, device.Token.Length);
        Assert.Equal(58, device.PairingString.Length);
        Assert.Equal(device.Token, PairingToken.Decode(device.PairingString));
        Assert.Equal("Mac Studio", device.FriendlyName);
        Assert.NotEmpty(device.DeviceId);
        Assert.Equal(1, store.Count);
    }

    [Fact]
    public void EveryDeviceGetsItsOwnFreshToken()
    {
        var store = new PairedDeviceStore(_directory);

        var a = store.Pair("Mac Studio");
        var b = store.Pair("MacBook Pro");
        var c = store.Pair("Mac mini");

        Assert.Equal(3, store.Count);
        Assert.Equal(3, new HashSet<string>(new[] { a, b, c }.Select(d => Convert.ToHexString(d.Token))).Count);
        Assert.Equal(3, new HashSet<string>(new[] { a, b, c }.Select(d => d.DeviceId)).Count);
    }

    [Fact]
    public void ABlankFriendlyNameIsReplacedSoTheHolderFieldIsAlwaysUsable()
    {
        var store = new PairedDeviceStore(_directory);

        Assert.Equal("Mac 1", store.Pair("").FriendlyName);
        Assert.Equal("Mac 2", store.Pair("   ").FriendlyName);
        Assert.Equal("Mac Studio", store.Pair("Mac Studio").FriendlyName);
    }

    [Fact]
    public void DevicesPersistAcrossInstances()
    {
        var first = new PairedDeviceStore(_directory);
        var paired = first.Pair("Mac Studio");

        var second = new PairedDeviceStore(_directory);

        Assert.Equal(1, second.Count);
        Assert.Equal(paired.DeviceId, second.List()[0].DeviceId);
        Assert.Equal(paired.Token, second.List()[0].Token);
        Assert.Equal(paired.FriendlyName, second.List()[0].FriendlyName);
    }

    [Fact]
    public void NoTokenIsStoredInPlaintextOnDisk()
    {
        var store = new PairedDeviceStore(_directory);
        var a = store.Pair("Mac Studio");
        var b = store.Pair("MacBook Pro");

        var onDisk = File.ReadAllBytes(Path.Combine(_directory, "paired-devices.dpapi"));

        Assert.False(ContainsSubsequence(onDisk, a.Token), "the first device's raw token is on disk");
        Assert.False(ContainsSubsequence(onDisk, b.Token), "the second device's raw token is on disk");
        Assert.DoesNotContain(
            Convert.ToHexString(a.Token).ToLowerInvariant(),
            System.Text.Encoding.Latin1.GetString(onDisk),
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void IdentifyFindsTheDeviceWhoseTokenSignedTheProof()
    {
        var store = new PairedDeviceStore(_directory);
        store.Pair("Mac Studio");
        var target = store.Pair("MacBook Pro");
        store.Pair("Mac mini");

        var nonce = Nonce();
        var identified = store.Identify(nonce, AuthProof.Compute(target.Token, nonce));

        Assert.NotNull(identified);
        Assert.Equal(target.DeviceId, identified!.DeviceId);
        Assert.Equal("MacBook Pro", identified.FriendlyName);
    }

    /// <summary>
    /// Position in the list must not matter: the loop checks every token.
    /// </summary>
    [Fact]
    public void EveryDeviceIsIdentifiableWhateverItsPositionInTheList()
    {
        var store = new PairedDeviceStore(_directory);
        var devices = Enumerable.Range(0, 50).Select(i => store.Pair($"Mac {i}")).ToList();

        foreach (var device in devices)
        {
            var nonce = Nonce();
            var identified = store.Identify(nonce, AuthProof.Compute(device.Token, nonce));

            Assert.Equal(device.DeviceId, identified?.DeviceId);
        }
    }

    [Fact]
    public void IdentifyRejectsAnUnknownTokenAMalformedProofAndAMissingOne()
    {
        var store = new PairedDeviceStore(_directory);
        var device = store.Pair("Mac Studio");
        var nonce = Nonce();

        Assert.Null(store.Identify(nonce, AuthProof.Compute(PairingToken.Generate(), nonce)));
        Assert.Null(store.Identify(nonce, "not hex at all"));
        Assert.Null(store.Identify(nonce, ""));
        Assert.Null(store.Identify(nonce, null));
        Assert.Null(store.Identify(Nonce(), AuthProof.Compute(device.Token, nonce)));
    }

    [Fact]
    public void RevokingOneDeviceLeavesEveryOtherDeviceWorking()
    {
        var store = new PairedDeviceStore(_directory);
        var revoked = store.Pair("Mac Studio");
        var kept = store.Pair("MacBook Pro");

        Assert.True(store.Revoke(revoked.DeviceId));

        var nonce = Nonce();
        Assert.Null(store.Identify(nonce, AuthProof.Compute(revoked.Token, nonce)));
        Assert.Equal(kept.DeviceId, store.Identify(nonce, AuthProof.Compute(kept.Token, nonce))?.DeviceId);
        Assert.Equal(1, store.Count);
    }

    /// <summary>
    /// A revoked device must be indistinguishable from a stranger. Revocation is
    /// deletion, so both produce the same null and the same silent close at the
    /// caller — nothing tells an attacker that a token was once valid.
    /// </summary>
    [Fact]
    public void ARevokedDeviceIsIndistinguishableFromOneThatNeverExisted()
    {
        var store = new PairedDeviceStore(_directory);
        var revoked = store.Pair("Mac Studio");
        store.Pair("MacBook Pro");
        store.Revoke(revoked.DeviceId);

        var nonce = Nonce();

        Assert.Null(store.Identify(nonce, AuthProof.Compute(revoked.Token, nonce)));
        Assert.Null(store.Identify(nonce, AuthProof.Compute(PairingToken.Generate(), nonce)));
    }

    [Fact]
    public void RevocationPersistsAndAnUnknownIdIsRefusedWithoutThrowing()
    {
        var store = new PairedDeviceStore(_directory);
        var revoked = store.Pair("Mac Studio");
        store.Pair("MacBook Pro");

        Assert.True(store.Revoke(revoked.DeviceId));
        Assert.False(store.Revoke(revoked.DeviceId));
        Assert.False(store.Revoke("dev-doesnotexist"));

        Assert.Equal(1, new PairedDeviceStore(_directory).Count);
    }

    [Fact]
    public void RevokingEveryDeviceLeavesAnAgentThatAuthenticatesNobody()
    {
        var store = new PairedDeviceStore(_directory);
        var device = store.Pair("Mac Studio");
        var nonce = Nonce();
        var proof = AuthProof.Compute(device.Token, nonce);

        Assert.NotNull(store.Identify(nonce, proof));
        Assert.True(store.Revoke(device.DeviceId));

        Assert.Equal(0, store.Count);
        Assert.Null(store.Identify(nonce, proof));
    }

    [Fact]
    public void ListIsOrderedByPairingTimeAndIsASnapshot()
    {
        var store = new PairedDeviceStore(_directory);
        var first = store.Pair("Mac Studio");
        var second = store.Pair("MacBook Pro");

        var snapshot = store.List();
        store.Pair("Mac mini");

        Assert.Equal(new[] { first.DeviceId, second.DeviceId }, snapshot.Select(d => d.DeviceId).ToArray());
        Assert.True(snapshot[0].PairedAt <= snapshot[1].PairedAt);
        Assert.Equal(3, store.Count);
    }

    private static bool ContainsSubsequence(byte[] haystack, byte[] needle)
    {
        if (needle.Length == 0 || needle.Length > haystack.Length)
        {
            return false;
        }

        for (var i = 0; i <= haystack.Length - needle.Length; i++)
        {
            if (haystack.AsSpan(i, needle.Length).SequenceEqual(needle))
            {
                return true;
            }
        }

        return false;
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PairedDeviceStoreTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'PairedDeviceStore' could not be found`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Security/PairedDeviceStore.cs`:

```csharp
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// One Mac that is allowed to connect. Never log Token, and never show it: the
/// user sees PairingString, once, at pairing time.
///
/// FriendlyName is assigned by the Windows user when the device is paired. It is
/// NOT the clientId the Mac sends in HELLO — that value arrives unauthenticated
/// and is a display label only. This is the name that travels as the advisory
/// "holder" field of a START_NACK, so it has to be one the owner chose.
/// </summary>
public sealed record PairedDevice(string DeviceId, string FriendlyName, byte[] Token, DateTimeOffset PairedAt)
{
    /// <summary>The base32 string the tray shows and the user retypes on that Mac.</summary>
    public string PairingString => PairingToken.Encode(Token);
}

/// <summary>
/// The list of paired devices, DPAPI-protected as a single blob under the
/// current user (design spec section 7.1), and the identification path the
/// section 6 handshake runs.
///
/// Identification is by PROOF ONLY. There is no lookup key: HELLO's clientId is
/// unauthenticated, so using it to choose which token to check would let an
/// attacker aim at a particular device. Identify() walks every stored token,
/// and deliberately does not stop at the first match, so the amount of HMAC
/// work does not depend on which device matched or on whether any did.
///
/// Revocation is deletion. A revoked device produces exactly what an unknown
/// one produces — null — so nothing distinguishes "this token used to work"
/// from "this token never worked".
/// </summary>
public sealed class PairedDeviceStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("shared-mic/v1/paired-devices");

    private sealed record StoredDevice(string DeviceId, string FriendlyName, string TokenHex, DateTimeOffset PairedAt);

    private readonly string _directory;
    private readonly object _gate = new();
    private readonly List<PairedDevice> _devices = new();

    public PairedDeviceStore(string directory)
    {
        _directory = directory;
        Load();
    }

    private string StorePath => Path.Combine(_directory, "paired-devices.dpapi");

    public int Count
    {
        get
        {
            lock (_gate)
            {
                return _devices.Count;
            }
        }
    }

    /// <summary>A snapshot, oldest pairing first. Callers may hold it while the list changes.</summary>
    public IReadOnlyList<PairedDevice> List()
    {
        lock (_gate)
        {
            return _devices.ToArray();
        }
    }

    /// <summary>
    /// Mint a fresh 256-bit token for a new Mac and persist it. The returned
    /// PairingString is the only time the token is displayable; it is not
    /// recoverable in a form the user should ever see again except from this
    /// same record.
    /// </summary>
    public PairedDevice Pair(string friendlyName)
    {
        lock (_gate)
        {
            var name = string.IsNullOrWhiteSpace(friendlyName)
                ? $"Mac {_devices.Count + 1}"
                : friendlyName.Trim();

            var device = new PairedDevice(
                "dev-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLowerInvariant(),
                name,
                PairingToken.Generate(),
                DateTimeOffset.UtcNow);

            _devices.Add(device);
            Save();
            return device;
        }
    }

    public bool Revoke(string deviceId)
    {
        lock (_gate)
        {
            var index = _devices.FindIndex(device =>
                string.Equals(device.DeviceId, deviceId, StringComparison.Ordinal));
            if (index < 0)
            {
                return false;
            }

            // Deliberately not ZeroMemory on the token array: Identify() may be
            // walking a snapshot that shares it right now, and zeroing under a
            // concurrent verify would corrupt that comparison. Dropping the
            // reference is enough — Save() below is what actually removes the
            // token from disk.
            _devices.RemoveAt(index);
            Save();
            return true;
        }
    }

    /// <summary>
    /// The section 6 verification: which paired device, if any, holds the token
    /// that produced this proof over this nonce. Returns null for no match, for
    /// a malformed proof, and for a revoked device — all three are the same
    /// answer on purpose.
    /// </summary>
    public PairedDevice? Identify(byte[] nonce, string? proof)
    {
        PairedDevice[] snapshot;
        lock (_gate)
        {
            snapshot = _devices.ToArray();
        }

        PairedDevice? matched = null;
        foreach (var device in snapshot)
        {
            // No break, and no early return. Every stored token is evaluated on
            // every attempt so the work done does not reveal which device
            // matched, or that none did.
            if (AuthProof.Verify(device.Token, nonce, proof))
            {
                matched ??= device;
            }
        }

        return matched;
    }

    private void Load()
    {
        if (!File.Exists(StorePath))
        {
            return;
        }

        var plaintext = ProtectedData.Unprotect(
            File.ReadAllBytes(StorePath), Entropy, DataProtectionScope.CurrentUser);
        try
        {
            var stored = JsonSerializer.Deserialize<List<StoredDevice>>(plaintext) ?? new List<StoredDevice>();
            foreach (var device in stored)
            {
                var token = Convert.FromHexString(device.TokenHex);
                if (token.Length != ProtocolConstants.TokenBytes)
                {
                    throw new InvalidOperationException(
                        $"paired device '{device.DeviceId}' has a {token.Length}-byte token, " +
                        $"expected {ProtocolConstants.TokenBytes}");
                }

                _devices.Add(new PairedDevice(device.DeviceId, device.FriendlyName, token, device.PairedAt));
            }

            _devices.Sort((left, right) => left.PairedAt.CompareTo(right.PairedAt));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    /// <summary>
    /// Called under _gate. Writes to a temporary file and moves it into place,
    /// so an interrupted write cannot leave every pairing lost at once.
    /// </summary>
    private void Save()
    {
        Directory.CreateDirectory(_directory);

        var stored = _devices
            .Select(device => new StoredDevice(
                device.DeviceId,
                device.FriendlyName,
                Convert.ToHexString(device.Token).ToLowerInvariant(),
                device.PairedAt))
            .ToList();

        var plaintext = JsonSerializer.SerializeToUtf8Bytes(stored);
        try
        {
            var protectedBytes = ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser);
            var temporary = StorePath + ".tmp";
            File.WriteAllBytes(temporary, protectedBytes);
            File.Move(temporary, StorePath, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PairedDeviceStoreTests"
```

Expected: PASS, 14 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Security/PairedDeviceStore.cs windows/SharedMic.Agent.Tests/PairedDeviceStoreTests.cs
git commit -m "Phase 1 Task 13: DPAPI-protected paired-device list with revocation and identify-by-proof"
```

---

### Task 14: Control connection — handshake, session lifecycle, heartbeat

**Files:**
- Create: `windows/SharedMic.Agent/AgentOptions.cs`
- Create: `windows/SharedMic.Agent/AgentStatus.cs`
- Create: `windows/SharedMic.Agent/Diagnostics/AgentLog.cs`
- Create: `windows/SharedMic.Agent/Diagnostics/AgentMetrics.cs`
- Create: `windows/SharedMic.Agent/Net/ControlConnection.cs`
- Test: `windows/SharedMic.Agent.Tests/LoopbackPeer.cs`
- Test: `windows/SharedMic.Agent.Tests/ControlConnectionTests.cs`

**Interfaces:**
- Consumes: `FrameCodec`, `FrameType`, `ControlCodec`, `ControlMessages` (including `StartNack(string, string, string?)`), `ProtocolException`, `ProtocolConstants`; `FrameReader(Stream)` / `ReadFrameAsync(CancellationToken)`; `PrioritySendQueue`; `AuthProof.GenerateNonce()`; `PairedDevice`, `PairedDeviceStore.Identify(byte[], string?)`; `AuthRateLimiter.PeerKey(EndPoint?)` / `TryBeginAttempt(string)` / `RecordFailure(string)` / `RecordSuccess(string)` / `IsLockedOut(string)` / `LockoutRemaining(string)`; `AgentIdentity(string ServerId, X509Certificate2 Certificate, string Fingerprint)`; `SessionArbiter.Start(string, string, bool)` / `Stop(string, string)` / `EndSessionOwnedBy(string)` / `HolderName` / `SessionsStarted`.
- Produces: `enum AgentStatus { Disconnected, Idle, Error }`; `sealed class AgentOptions` (init-only properties listed below); `static class AgentLog` with `Info(string)`, `Warn(string)`, `Error(string)`; `sealed class AgentMetrics` with an `Increment*` method per counter and `AgentMetricsSnapshot Snapshot()`; `sealed record AgentMetricsSnapshot(...)`; `sealed class ControlConnection : IAsyncDisposable` with constructor `ControlConnection(Stream stream, AgentIdentity identity, AgentOptions options, PairedDeviceStore devices, AuthRateLimiter rateLimiter, SessionArbiter sessions, AgentMetrics metrics)`, members `string ConnectionId`, `bool IsAuthenticated`, `PairedDevice? Device`, `string RemoteDescription { get; init; }`, `string PeerKey { get; init; }`, `PrioritySendQueue SendQueue`, `SessionArbiter Sessions`, `event Action<ControlConnection>? Authenticated`, `Task RunAsync(CancellationToken cancellationToken)`, `void Close()`, `ValueTask DisposeAsync()`.

Four things changed here from the single-Mac draft, and every one of them is invisible to the Python conformance suite:

- **The connection no longer owns a session.** It owns a `ConnectionId` and shares one `SessionArbiter` with every other connection. `Session` (a `SessionStateMachine`) is gone from this type's surface; `Sessions` (the shared arbiter) replaces it.
- **The connection no longer holds a token.** It calls `PairedDeviceStore.Identify` and gets back a `PairedDevice`, or null.
- **`clientId` is logged and otherwise ignored.** It never chooses a token and never becomes the device's name.
- **Every exit path releases the session** through `EndSessionOwnedBy(ConnectionId)` in `RunAsync`'s `finally`. `STOP`, a clean close, a socket error, a protocol violation, and dead-peer detection all arrive there, because dead-peer detection works by cancelling the read loop.

**This task runs on Windows.** Tests use a real loopback TCP socket pair, so no TLS is involved yet and the whole exchange is inspectable. **They are also the only place the multi-connection rules are tested against real sockets** — the mock Windows server gives every connection its own session, so `harness/tests` would pass an implementation that gets all of this wrong.

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/LoopbackPeer.cs`:

```csharp
using System.Net;
using System.Net.Sockets;
using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;

namespace SharedMic.Agent.Tests;

/// <summary>
/// A connected pair of NetworkStreams over 127.0.0.1 plus client-side protocol
/// helpers, so ControlConnection can be driven exactly as the Mac would drive
/// it without TLS in the way.
/// </summary>
public sealed class LoopbackPeer : IAsyncDisposable
{
    private readonly TcpListener _listener;
    private readonly TcpClient _clientSide;
    private readonly TcpClient _serverSide;
    private readonly FrameReader _reader;

    private LoopbackPeer(TcpListener listener, TcpClient clientSide, TcpClient serverSide)
    {
        _listener = listener;
        _clientSide = clientSide;
        _serverSide = serverSide;
        ClientStream = clientSide.GetStream();
        ServerStream = serverSide.GetStream();
        _reader = new FrameReader(ClientStream);
    }

    public NetworkStream ClientStream { get; }

    public NetworkStream ServerStream { get; }

    public static async Task<LoopbackPeer> CreateAsync()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var connecting = new TcpClient();
        var accepting = listener.AcceptTcpClientAsync();
        await connecting.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
        var accepted = await accepting;
        connecting.NoDelay = true;
        accepted.NoDelay = true;
        return new LoopbackPeer(listener, connecting, accepted);
    }

    public async Task SendControlAsync(IReadOnlyDictionary<string, object?> message, CancellationToken cancellationToken)
    {
        var frame = FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message));
        await ClientStream.WriteAsync(frame, cancellationToken);
        await ClientStream.FlushAsync(cancellationToken);
    }

    public async Task SendRawAsync(byte[] bytes, CancellationToken cancellationToken)
    {
        await ClientStream.WriteAsync(bytes, cancellationToken);
        await ClientStream.FlushAsync(cancellationToken);
    }

    /// <summary>Read the next frame the agent sent, or null if it closed the connection.</summary>
    public async Task<ReceivedFrame?> ReadFrameAsync(CancellationToken cancellationToken)
    {
        try
        {
            return await _reader.ReadFrameAsync(cancellationToken);
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException or ProtocolException)
        {
            return null;
        }
    }

    /// <summary>Read the next control message the agent sent, or null if it closed the connection.</summary>
    public async Task<Dictionary<string, object?>?> ReadControlAsync(CancellationToken cancellationToken)
    {
        var frame = await ReadFrameAsync(cancellationToken);
        if (frame is null)
        {
            return null;
        }

        if (frame.Value.Type != FrameType.Control)
        {
            throw new InvalidOperationException($"expected a CONTROL frame, got {frame.Value.Type}");
        }

        return ControlCodec.Decode(frame.Value.Payload);
    }

    /// <summary>Complete GREETING then HELLO, returning the GREETING that was received.</summary>
    public async Task<Dictionary<string, object?>> AuthenticateAsync(byte[] token, CancellationToken cancellationToken)
    {
        var greeting = await ReadControlAsync(cancellationToken)
                       ?? throw new InvalidOperationException("the agent closed before sending GREETING");
        var nonce = Convert.FromHexString((string)greeting["nonce"]!);
        await SendControlAsync(
            ControlMessages.Hello("mock-mac", AuthProof.Compute(token, nonce)),
            cancellationToken);
        return greeting;
    }

    /// <summary>True when the agent closed the connection within the timeout.</summary>
    public async Task<bool> WaitForCloseAsync(TimeSpan timeout)
    {
        using var cancellation = new CancellationTokenSource(timeout);
        try
        {
            while (true)
            {
                var frame = await ReadFrameAsync(cancellation.Token);
                if (frame is null)
                {
                    return true;
                }
            }
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await ClientStream.DisposeAsync();
        await ServerStream.DisposeAsync();
        _clientSide.Dispose();
        _serverSide.Dispose();
        _listener.Stop();
    }
}
```

`windows/SharedMic.Agent.Tests/ControlConnectionTests.cs`:

```csharp
using SharedMic.Agent;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class ControlConnectionTests : IDisposable
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    // One certificate for the whole class. ControlConnection never uses it (it
    // is handed an already-established stream), and generating one per test
    // would leave a user key container behind for every test in the class.
    private static readonly System.Security.Cryptography.X509Certificates.X509Certificate2 SharedCertificate =
        DeviceCertificate.CreateSelfSigned();

    private static readonly AgentIdentity Identity =
        new("win-test", SharedCertificate, DeviceCertificate.Fingerprint(SharedCertificate));

    private readonly string _root =
        Path.Combine(Path.GetTempPath(), "sharedmic-connection-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    /// <summary>A paired-device list of its own, in a throwaway directory.</summary>
    private PairedDeviceStore NewStore()
    {
        var directory = Path.Combine(_root, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        return new PairedDeviceStore(directory);
    }

    private static AgentOptions FastOptions(bool micPresent = true) => new()
    {
        MicPresent = micPresent,
        DeviceLabel = "USB Microphone",
        HelloDeadline = TimeSpan.FromMilliseconds(400),
        PeerDeadTimeout = TimeSpan.FromMilliseconds(600),
        LivenessPollInterval = TimeSpan.FromMilliseconds(50),
    };

    private sealed class Fixture : IAsyncDisposable
    {
        public Fixture(LoopbackPeer peer, ControlConnection connection, Task run, CancellationTokenSource cancellation)
        {
            Peer = peer;
            Connection = connection;
            Run = run;
            Cancellation = cancellation;
        }

        public LoopbackPeer Peer { get; }

        public ControlConnection Connection { get; }

        public Task Run { get; }

        public CancellationTokenSource Cancellation { get; }

        public async ValueTask DisposeAsync()
        {
            Connection.Close();
            Cancellation.Cancel();
            try
            {
                await Run.WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (Exception)
            {
                // The connection is being torn down; a cancellation or IO fault here is expected.
            }

            await Connection.DisposeAsync();
            await Peer.DisposeAsync();
            Cancellation.Dispose();
        }
    }

    private static async Task<Fixture> StartAsync(
        PairedDeviceStore devices,
        AgentOptions options,
        AuthRateLimiter? limiter = null,
        SessionArbiter? sessions = null,
        AgentMetrics? metrics = null,
        string peerKey = "127.0.0.1")
    {
        var peer = await LoopbackPeer.CreateAsync();
        var connection = new ControlConnection(
            peer.ServerStream,
            Identity,
            options,
            devices,
            limiter ?? new AuthRateLimiter(),
            sessions ?? new SessionArbiter(),
            metrics ?? new AgentMetrics())
        {
            RemoteDescription = $"loopback[{peerKey}]",
            PeerKey = peerKey,
        };

        var cancellation = new CancellationTokenSource();
        var run = connection.RunAsync(cancellation.Token);
        return new Fixture(peer, connection, run, cancellation);
    }

    [Fact]
    public async Task SendsGreetingImmediatelyWithASixtyFourCharacterNonce()
    {
        var devices = NewStore();
        devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        var greeting = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.NotNull(greeting);
        Assert.Equal("GREETING", greeting!["type"]);
        Assert.Equal("win-test", greeting["serverId"]);
        Assert.Equal(64, ((string)greeting["nonce"]!).Length);
        Assert.Equal(32, Convert.FromHexString((string)greeting["nonce"]!).Length);
    }

    [Fact]
    public async Task NonceIsFreshPerConnection()
    {
        var devices = NewStore();
        devices.Pair("Mac Studio");
        using var cancellation = new CancellationTokenSource(Timeout);

        await using var first = await StartAsync(devices, FastOptions());
        await using var second = await StartAsync(devices, FastOptions());

        var a = await first.Peer.ReadControlAsync(cancellation.Token);
        var b = await second.Peer.ReadControlAsync(cancellation.Token);

        Assert.NotEqual(a!["nonce"], b!["nonce"]);
    }

    [Fact]
    public async Task ValidHelloIsAnsweredWithHelloAck()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("HELLO_ACK", ack!["type"]);
        Assert.Equal("win-test", ack["serverId"]);
        Assert.Equal(true, ack["micPresent"]);
        Assert.Equal("USB Microphone", ack["deviceLabel"]);
    }

    /// <summary>
    /// The proof, and only the proof, says which device this is. Several tokens
    /// are stored and the connection presents the third one's.
    /// </summary>
    [Fact]
    public async Task TheProofAloneIdentifiesWhichPairedDeviceConnected()
    {
        var devices = NewStore();
        devices.Pair("Mac Studio");
        devices.Pair("MacBook Pro");
        var mini = devices.Pair("Mac mini");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mini.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.True(fixture.Connection.IsAuthenticated);
        Assert.Equal(mini.DeviceId, fixture.Connection.Device?.DeviceId);
        Assert.Equal("Mac mini", fixture.Connection.Device?.FriendlyName);
    }

    /// <summary>
    /// clientId arrives unauthenticated. It must not select a token and must not
    /// become the device's name — otherwise "call yourself Mac Studio" would be
    /// an attack.
    /// </summary>
    [Fact]
    public async Task ALyingClientIdChangesNothingAboutTheIdentifiedDevice()
    {
        var devices = NewStore();
        var studio = devices.Pair("Mac Studio");
        devices.Pair("MacBook Pro");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        var greeting = await fixture.Peer.ReadControlAsync(cancellation.Token);
        var nonce = Convert.FromHexString((string)greeting!["nonce"]!);
        await fixture.Peer.SendControlAsync(
            ControlMessages.Hello("MacBook Pro", AuthProof.Compute(studio.Token, nonce)),
            cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("HELLO_ACK", ack!["type"]);
        Assert.Equal(studio.DeviceId, fixture.Connection.Device?.DeviceId);
        Assert.Equal("Mac Studio", fixture.Connection.Device?.FriendlyName);
    }

    [Fact]
    public async Task WrongProofClosesTheConnectionWithoutReplying()
    {
        var devices = NewStore();
        devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        var greeting = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("GREETING", greeting!["type"]);

        await fixture.Peer.SendControlAsync(
            ControlMessages.Hello("mock-mac", new string('a', 64)),
            cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        Assert.False(fixture.Connection.IsAuthenticated);
        Assert.Null(fixture.Connection.Device);
    }

    /// <summary>
    /// A revoked device gets exactly the stranger's treatment: closed without a
    /// reply, nothing that says the token was ever valid.
    /// </summary>
    [Fact]
    public async Task ARevokedDeviceIsRefusedExactlyLikeAStranger()
    {
        var devices = NewStore();
        var revoked = devices.Pair("Old MacBook");
        devices.Pair("Mac Studio");
        devices.Revoke(revoked.DeviceId);

        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(revoked.Token, cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        Assert.False(fixture.Connection.IsAuthenticated);
    }

    [Fact]
    public async Task PingBeforeAuthenticationClosesTheConnection()
    {
        var devices = NewStore();
        devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Ping(1), cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task AudioFrameFromTheClientIsAProtocolViolationAtAnyPoint()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        var audio = FrameCodec.EncodeFrame(
            FrameType.Audio,
            AudioPayloadCodec.EncodeAudioPayload(0u, 0ul, new byte[ProtocolConstants.PcmBytesPerFrame]));
        await fixture.Peer.SendRawAsync(audio, cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task UnknownEnvelopeTypeClosesTheConnection()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendRawAsync(new byte[] { 7, 0, 0, 0, 0 }, cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task WrongProtocolVersionClosesTheConnection()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        var payload = System.Text.Encoding.UTF8.GetBytes("{\"seq\":1,\"type\":\"PING\",\"v\":2}");
        await fixture.Peer.SendRawAsync(FrameCodec.EncodeFrame(FrameType.Control, payload), cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task IdleConnectionIsClosedAtThePreAuthDeadline()
    {
        var devices = NewStore();
        devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        var greeting = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("GREETING", greeting!["type"]);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task PingIsAnsweredWithAMatchingPong()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        foreach (var seq in new long[] { 1, 2, 99 })
        {
            await fixture.Peer.SendControlAsync(ControlMessages.Ping(seq), cancellation.Token);
            var pong = await fixture.Peer.ReadControlAsync(cancellation.Token);

            Assert.Equal("PONG", pong!["type"]);
            Assert.Equal(seq, pong["seq"]);
        }
    }

    [Fact]
    public async Task DuplicateStartReturnsTheSameSessionIdAndStreamsNothing()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        var sessions = new SessionArbiter();
        await using var fixture = await StartAsync(devices, FastOptions(), sessions: sessions);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        var first = await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0002"), cancellation.Token);
        var second = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("START_ACK", first!["type"]);
        Assert.Equal("req-0001", first["requestId"]);
        Assert.Equal("START_ACK", second!["type"]);
        Assert.Equal("req-0002", second["requestId"]);
        Assert.Equal(first["sessionId"], second["sessionId"]);
        Assert.True(ControlCodec.DeepEquals(ControlCodec.Normalize(ControlMessages.AudioFormat), first["format"]));
        Assert.Equal(1, sessions.SessionsStarted);
    }

    /// <summary>
    /// Two paired Macs, two live connections, one session. The mock Windows
    /// server would hand both of them a START_ACK, so this is the only place the
    /// rule is checked over a real socket.
    /// </summary>
    [Fact]
    public async Task ASecondConnectionIsNackedWithSessionInUseAndTheHolderName()
    {
        var devices = NewStore();
        var studio = devices.Pair("Mac Studio");
        var laptop = devices.Pair("MacBook Pro");
        var sessions = new SessionArbiter();
        using var cancellation = new CancellationTokenSource(Timeout);

        await using var holder = await StartAsync(devices, FastOptions(), sessions: sessions);
        await using var other = await StartAsync(devices, FastOptions(), sessions: sessions);

        await holder.Peer.AuthenticateAsync(studio.Token, cancellation.Token);
        await holder.Peer.ReadControlAsync(cancellation.Token);
        await other.Peer.AuthenticateAsync(laptop.Token, cancellation.Token);
        await other.Peer.ReadControlAsync(cancellation.Token);

        await holder.Peer.SendControlAsync(ControlMessages.Start("req-h"), cancellation.Token);
        var granted = await holder.Peer.ReadControlAsync(cancellation.Token);

        await other.Peer.SendControlAsync(ControlMessages.Start("req-o"), cancellation.Token);
        var refused = await other.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("START_ACK", granted!["type"]);
        Assert.Equal("START_NACK", refused!["type"]);
        Assert.Equal("req-o", refused["requestId"]);
        Assert.Equal("SESSION_IN_USE", refused["reason"]);
        Assert.Equal("Mac Studio", refused["holder"]);
        Assert.Equal(1, sessions.SessionsStarted);
    }

    [Fact]
    public async Task ARefusedSecondConnectionStaysHealthyAndDoesNotDisturbTheHolder()
    {
        var devices = NewStore();
        var studio = devices.Pair("Mac Studio");
        var laptop = devices.Pair("MacBook Pro");
        var sessions = new SessionArbiter();
        using var cancellation = new CancellationTokenSource(Timeout);

        await using var holder = await StartAsync(devices, FastOptions(), sessions: sessions);
        await using var other = await StartAsync(devices, FastOptions(), sessions: sessions);

        await holder.Peer.AuthenticateAsync(studio.Token, cancellation.Token);
        await holder.Peer.ReadControlAsync(cancellation.Token);
        await other.Peer.AuthenticateAsync(laptop.Token, cancellation.Token);
        await other.Peer.ReadControlAsync(cancellation.Token);

        await holder.Peer.SendControlAsync(ControlMessages.Start("req-h"), cancellation.Token);
        var granted = await holder.Peer.ReadControlAsync(cancellation.Token);
        await other.Peer.SendControlAsync(ControlMessages.Start("req-o"), cancellation.Token);
        await other.Peer.ReadControlAsync(cancellation.Token);

        // The refused connection is still a good connection.
        await other.Peer.SendControlAsync(ControlMessages.Ping(7), cancellation.Token);
        var pong = await other.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("PONG", pong!["type"]);
        Assert.Equal(7L, pong["seq"]);

        // And the holder still holds exactly what it was given.
        await holder.Peer.SendControlAsync(ControlMessages.Start("req-h2"), cancellation.Token);
        var again = await holder.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("START_ACK", again!["type"]);
        Assert.Equal(granted!["sessionId"], again["sessionId"]);
    }

    /// <summary>
    /// Otherwise any paired Mac could end another's session with one message.
    /// </summary>
    [Fact]
    public async Task StopFromANonHolderIsAckedButEndsNothing()
    {
        var devices = NewStore();
        var studio = devices.Pair("Mac Studio");
        var laptop = devices.Pair("MacBook Pro");
        var sessions = new SessionArbiter();
        using var cancellation = new CancellationTokenSource(Timeout);

        await using var holder = await StartAsync(devices, FastOptions(), sessions: sessions);
        await using var other = await StartAsync(devices, FastOptions(), sessions: sessions);

        await holder.Peer.AuthenticateAsync(studio.Token, cancellation.Token);
        await holder.Peer.ReadControlAsync(cancellation.Token);
        await other.Peer.AuthenticateAsync(laptop.Token, cancellation.Token);
        await other.Peer.ReadControlAsync(cancellation.Token);

        await holder.Peer.SendControlAsync(ControlMessages.Start("req-h"), cancellation.Token);
        var granted = await holder.Peer.ReadControlAsync(cancellation.Token);
        var sessionId = (string)granted!["sessionId"]!;

        await other.Peer.SendControlAsync(ControlMessages.Stop("req-o", sessionId), cancellation.Token);
        var ack = await other.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("STOP_ACK", ack!["type"]);
        Assert.Equal(sessionId, sessions.ActiveSessionId);
        Assert.Equal(holder.Connection.ConnectionId, sessions.HolderId);
    }

    /// <summary>
    /// THE load-bearing test of the multi-Mac design. A Mac that crashes never
    /// sends STOP. If the session survived its connection, every other Mac would
    /// be locked out until the 45-second dead-peer timer — and if only STOP ever
    /// released it, forever.
    /// </summary>
    [Fact]
    public async Task ClosingTheOwningConnectionReleasesTheSessionForEveryoneElse()
    {
        var devices = NewStore();
        var studio = devices.Pair("Mac Studio");
        var laptop = devices.Pair("MacBook Pro");
        var sessions = new SessionArbiter();
        var metrics = new AgentMetrics();
        using var cancellation = new CancellationTokenSource(Timeout);

        await using var other = await StartAsync(devices, FastOptions(), sessions: sessions, metrics: metrics);
        await other.Peer.AuthenticateAsync(laptop.Token, cancellation.Token);
        await other.Peer.ReadControlAsync(cancellation.Token);

        var holder = await StartAsync(devices, FastOptions(), sessions: sessions, metrics: metrics);
        await holder.Peer.AuthenticateAsync(studio.Token, cancellation.Token);
        await holder.Peer.ReadControlAsync(cancellation.Token);
        await holder.Peer.SendControlAsync(ControlMessages.Start("req-h"), cancellation.Token);
        await holder.Peer.ReadControlAsync(cancellation.Token);
        Assert.NotNull(sessions.ActiveSessionId);

        // The holder vanishes without a STOP.
        await holder.DisposeAsync();

        await WaitUntilAsync(() => sessions.ActiveSessionId is null, TimeSpan.FromSeconds(5));

        Assert.Null(sessions.ActiveSessionId);
        Assert.Null(sessions.HolderId);
        Assert.Equal(1, metrics.Snapshot().SessionsEndedByDisconnect);

        await other.Peer.SendControlAsync(ControlMessages.Start("req-o"), cancellation.Token);
        var granted = await other.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("START_ACK", granted!["type"]);
    }

    /// <summary>
    /// Same rule, reached the other way: the peer stops talking and the 45 s
    /// dead-peer rule (600 ms here) closes it. The release must not depend on a
    /// clean disconnect.
    /// </summary>
    [Fact]
    public async Task DeadPeerDetectionAlsoReleasesTheSession()
    {
        var devices = NewStore();
        var studio = devices.Pair("Mac Studio");
        var sessions = new SessionArbiter();
        var metrics = new AgentMetrics();
        await using var fixture = await StartAsync(devices, FastOptions(), sessions: sessions, metrics: metrics);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(studio.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-h"), cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.NotNull(sessions.ActiveSessionId);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        await WaitUntilAsync(() => sessions.ActiveSessionId is null, TimeSpan.FromSeconds(5));

        Assert.Null(sessions.ActiveSessionId);
        Assert.Equal(1, metrics.Snapshot().DeadPeerDisconnects);
        Assert.Equal(1, metrics.Snapshot().SessionsEndedByDisconnect);
    }

    [Fact]
    public async Task NoAudioIsSentWhileASessionIsActiveBecausePhase1HasNoCapturePath()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        await Task.Delay(300, cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Ping(1), cancellation.Token);

        // If any AUDIO frame had been produced it would arrive before the PONG,
        // and ReadControlAsync would throw on a non-CONTROL frame.
        var pong = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("PONG", pong!["type"]);
        Assert.Equal(0, fixture.Connection.SendQueue.AudioFramesOffered);
    }

    [Fact]
    public async Task StopWithoutStartStillReturnsStopAckEchoingTheRequestedSessionId()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Stop("req-0003", ""), cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("STOP_ACK", ack!["type"]);
        Assert.Equal("req-0003", ack["requestId"]);
        Assert.Equal("", ack["sessionId"]);
    }

    [Fact]
    public async Task DuplicateStopSucceedsAndAStaleSessionIdIsNotRejected()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        var started = await fixture.Peer.ReadControlAsync(cancellation.Token);
        var sessionId = (string)started!["sessionId"]!;

        await fixture.Peer.SendControlAsync(ControlMessages.Stop("req-0003", "sess-stale-from-last-time"), cancellation.Token);
        var first = await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Stop("req-0004", sessionId), cancellation.Token);
        var second = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("STOP_ACK", first!["type"]);
        Assert.Equal(sessionId, first["sessionId"]);
        Assert.Equal("STOP_ACK", second!["type"]);
        Assert.Equal(sessionId, second["sessionId"]);
    }

    [Fact]
    public async Task StartAfterStopOpensANewSession()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        var sessions = new SessionArbiter();
        await using var fixture = await StartAsync(devices, FastOptions(), sessions: sessions);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("r1"), cancellation.Token);
        var first = await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Stop("r2", (string)first!["sessionId"]!), cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("r3"), cancellation.Token);
        var second = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.NotEqual(first["sessionId"], second!["sessionId"]);
        Assert.Equal(2, sessions.SessionsStarted);
    }

    [Fact]
    public async Task StartIsNackedWithMicUnavailableAndNoHolderWhenNoMicIsConfigured()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions(micPresent: false));
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal(false, ack!["micPresent"]);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0002"), cancellation.Token);
        var nack = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("START_NACK", nack!["type"]);
        Assert.Equal("req-0002", nack["requestId"]);
        Assert.Equal("MIC_UNAVAILABLE", nack["reason"]);
        Assert.False(nack.ContainsKey("holder"));
    }

    [Fact]
    public async Task ASilentAuthenticatedPeerIsDeclaredDead()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        var metrics = new AgentMetrics();
        await using var fixture = await StartAsync(devices, FastOptions(), metrics: metrics);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(1, metrics.Snapshot().DeadPeerDisconnects);
    }

    [Fact]
    public async Task HeartbeatTrafficKeepsTheConnectionAlivePastTheDeadPeerTimeout()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        await using var fixture = await StartAsync(devices, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        for (var seq = 1; seq <= 6; seq++)
        {
            await Task.Delay(200, cancellation.Token);
            await fixture.Peer.SendControlAsync(ControlMessages.Ping(seq), cancellation.Token);
            var pong = await fixture.Peer.ReadControlAsync(cancellation.Token);
            Assert.Equal((long)seq, pong!["seq"]);
        }
    }

    [Fact]
    public async Task FiveFailedAttemptsFromOneAddressLockOutEvenACorrectToken()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        var limiter = new AuthRateLimiter(lockoutDuration: TimeSpan.FromSeconds(30));
        using var cancellation = new CancellationTokenSource(Timeout);

        for (var attempt = 0; attempt < 5; attempt++)
        {
            await using var bad = await StartAsync(devices, FastOptions(), limiter, peerKey: "192.168.1.66");
            await bad.Peer.ReadControlAsync(cancellation.Token);
            await bad.Peer.SendControlAsync(
                ControlMessages.Hello("mock-mac", new string('b', 64)),
                cancellation.Token);
            Assert.True(await bad.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        }

        Assert.True(limiter.IsLockedOut("192.168.1.66"));

        await using var good = await StartAsync(devices, FastOptions(), limiter, peerKey: "192.168.1.66");
        await good.Peer.AuthenticateAsync(mac.Token, cancellation.Token);

        Assert.True(await good.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        Assert.False(good.Connection.IsAuthenticated);
    }

    /// <summary>
    /// The point of keying the limiter: one attacker's lockout must not take the
    /// other paired Macs down with it.
    /// </summary>
    [Fact]
    public async Task AnAttackerLockedOutAtOneAddressDoesNotBlockAPairedMacAtAnother()
    {
        var devices = NewStore();
        var mac = devices.Pair("Mac Studio");
        var limiter = new AuthRateLimiter(lockoutDuration: TimeSpan.FromSeconds(30));
        using var cancellation = new CancellationTokenSource(Timeout);

        for (var attempt = 0; attempt < 5; attempt++)
        {
            await using var bad = await StartAsync(devices, FastOptions(), limiter, peerKey: "192.168.1.66");
            await bad.Peer.ReadControlAsync(cancellation.Token);
            await bad.Peer.SendControlAsync(
                ControlMessages.Hello("attacker", new string('b', 64)),
                cancellation.Token);
            Assert.True(await bad.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        }

        Assert.True(limiter.IsLockedOut("192.168.1.66"));

        await using var good = await StartAsync(devices, FastOptions(), limiter, peerKey: "192.168.1.10");
        await good.Peer.AuthenticateAsync(mac.Token, cancellation.Token);
        var ack = await good.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("HELLO_ACK", ack!["type"]);
        Assert.True(good.Connection.IsAuthenticated);
    }

    [Fact]
    public async Task ThePreAuthDeadlineCountsAsAFailedAttempt()
    {
        var devices = NewStore();
        devices.Pair("Mac Studio");
        var limiter = new AuthRateLimiter();
        await using var fixture = await StartAsync(devices, FastOptions(), limiter, peerKey: "192.168.1.66");
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));

        Assert.Equal(1, limiter.ConsecutiveFailures("192.168.1.66"));
    }

    /// <summary>Poll a condition that a background task satisfies, without sleeping a fixed time.</summary>
    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (condition())
            {
                return;
            }

            await Task.Delay(25);
        }
    }
}
```

Teardown discard counting is proved in Task 10 against `PrioritySendQueue` directly rather than here: with no capture path, the only way to put audio in the queue on a live connection is to enqueue it from the test, and the writer loop drains it before `STOP` can be sent, so the assertion would be a race rather than a check.

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~ControlConnectionTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'ControlConnection' could not be found`, plus the same for `AgentOptions`, `AgentMetrics` and `AgentLog`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/AgentStatus.cs`:

```csharp
namespace SharedMic.Agent;

/// <summary>
/// The tray states Phase 1 can actually reach. Design spec section 11 lists
/// Starting, Streaming, Degraded, Disabled and Held as well; those depend on
/// audio capture and automatic demand, so they arrive in Phase 2 and Phase 3.
/// </summary>
public enum AgentStatus
{
    Disconnected,
    Idle,
    Error,
}
```

`windows/SharedMic.Agent/AgentOptions.cs`:

```csharp
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;

namespace SharedMic.Agent;

/// <summary>
/// Runtime configuration. The timer values are init-only properties rather than
/// constants precisely so tests can inject short deadlines: protocol-v1.md's
/// harness does the same for the 5 s pre-auth deadline so the suite does not
/// pay it in wall time.
///
/// MicPresent is a configuration flag in Phase 1, not a device query. There is
/// no DeviceManager yet; the flag exists so the START_NACK and micPresent paths
/// are exercisable before Phase 2 wires a real WASAPI device.
/// </summary>
public sealed class AgentOptions
{
    public int Port { get; init; } = ProtocolConstants.DefaultPort;

    public bool MicPresent { get; init; } = true;

    public string DeviceLabel { get; init; } = "(no device selected)";

    public string DataDirectory { get; init; } = IdentityStore.DefaultDirectory;

    public bool Headless { get; init; }

    /// <summary>
    /// Friendly names to pair at startup, one per --pair flag. Each mints a
    /// fresh 256-bit token and prints its pairing string. This is how a headless
    /// run adds a second, third or fourth Mac; the tray does the same job with a
    /// dialog.
    /// </summary>
    public IReadOnlyList<string> PairDevices { get; init; } = Array.Empty<string>();

    /// <summary>The device id given to --revoke, if any.</summary>
    public string? RevokeDeviceId { get; init; }

    /// <summary>Bind only 127.0.0.1 instead of every private interface. Used by tests.</summary>
    public bool LoopbackOnly { get; init; }

    public TimeSpan HelloDeadline { get; init; } = ProtocolConstants.HelloDeadline;

    public TimeSpan PeerDeadTimeout { get; init; } = ProtocolConstants.PeerDeadTimeout;

    public TimeSpan LivenessPollInterval { get; init; } = TimeSpan.FromSeconds(1);

    public TimeSpan TlsHandshakeTimeout { get; init; } = TimeSpan.FromSeconds(5);
}
```

`windows/SharedMic.Agent/Diagnostics/AgentLog.cs`:

```csharp
namespace SharedMic.Agent.Diagnostics;

/// <summary>
/// Lifecycle events and counters only. Design spec section 7.3: audio payload
/// is never logged or persisted. Never pass a pairing token, a private key, a
/// nonce or an offered HMAC proof to any method here.
/// </summary>
public static class AgentLog
{
    private static readonly object Gate = new();

    public static void Info(string message) => Write("INFO ", message);

    public static void Warn(string message) => Write("WARN ", message);

    public static void Error(string message) => Write("ERROR", message);

    private static void Write(string level, string message)
    {
        lock (Gate)
        {
            Console.WriteLine($"{DateTimeOffset.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ} {level} {message}");
        }
    }
}
```

`windows/SharedMic.Agent/Diagnostics/AgentMetrics.cs`:

```csharp
namespace SharedMic.Agent.Diagnostics;

public sealed record AgentMetricsSnapshot(
    long ConnectionsAccepted,
    long ConnectionsAuthenticated,
    long AuthFailures,
    long AuthRefusedByLockout,
    long ControlMessagesSent,
    long ControlMessagesReceived,
    long PingsReceived,
    long SessionsStarted,
    long SessionsRefusedAsInUse,
    long SessionsEndedByDisconnect,
    long DeadPeerDisconnects,
    long UnexpectedControlMessages,
    long AudioFramesSent);

/// <summary>
/// The subset of design spec section 11's counters that Phase 1 can produce.
/// Per-connection audio queue counters (offered, evicted, discarded) live on
/// PrioritySendQueue and are read from there.
///
/// SessionsRefusedAsInUse and SessionsEndedByDisconnect exist because with
/// several paired Macs those two events are the ones a user asks about: "why
/// did my Start do nothing" and "did the other Mac's session actually get
/// released when it went away".
/// </summary>
public sealed class AgentMetrics
{
    private long _connectionsAccepted;
    private long _connectionsAuthenticated;
    private long _authFailures;
    private long _authRefusedByLockout;
    private long _controlMessagesSent;
    private long _controlMessagesReceived;
    private long _pingsReceived;
    private long _sessionsStarted;
    private long _sessionsRefusedAsInUse;
    private long _sessionsEndedByDisconnect;
    private long _deadPeerDisconnects;
    private long _unexpectedControlMessages;
    private long _audioFramesSent;

    public void IncrementConnectionsAccepted() => Interlocked.Increment(ref _connectionsAccepted);

    public void IncrementConnectionsAuthenticated() => Interlocked.Increment(ref _connectionsAuthenticated);

    public void IncrementAuthFailures() => Interlocked.Increment(ref _authFailures);

    public void IncrementAuthRefusedByLockout() => Interlocked.Increment(ref _authRefusedByLockout);

    public void IncrementControlMessagesSent() => Interlocked.Increment(ref _controlMessagesSent);

    public void IncrementControlMessagesReceived() => Interlocked.Increment(ref _controlMessagesReceived);

    public void IncrementPingsReceived() => Interlocked.Increment(ref _pingsReceived);

    public void IncrementSessionsStarted() => Interlocked.Increment(ref _sessionsStarted);

    public void IncrementSessionsRefusedAsInUse() => Interlocked.Increment(ref _sessionsRefusedAsInUse);

    public void IncrementSessionsEndedByDisconnect() => Interlocked.Increment(ref _sessionsEndedByDisconnect);

    public void IncrementDeadPeerDisconnects() => Interlocked.Increment(ref _deadPeerDisconnects);

    public void IncrementUnexpectedControlMessages() => Interlocked.Increment(ref _unexpectedControlMessages);

    public void IncrementAudioFramesSent() => Interlocked.Increment(ref _audioFramesSent);

    public AgentMetricsSnapshot Snapshot() => new(
        Interlocked.Read(ref _connectionsAccepted),
        Interlocked.Read(ref _connectionsAuthenticated),
        Interlocked.Read(ref _authFailures),
        Interlocked.Read(ref _authRefusedByLockout),
        Interlocked.Read(ref _controlMessagesSent),
        Interlocked.Read(ref _controlMessagesReceived),
        Interlocked.Read(ref _pingsReceived),
        Interlocked.Read(ref _sessionsStarted),
        Interlocked.Read(ref _sessionsRefusedAsInUse),
        Interlocked.Read(ref _sessionsEndedByDisconnect),
        Interlocked.Read(ref _deadPeerDisconnects),
        Interlocked.Read(ref _unexpectedControlMessages),
        Interlocked.Read(ref _audioFramesSent));
}
```

`windows/SharedMic.Agent/Net/ControlConnection.cs`:

```csharp
using System.Security.Cryptography;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using SharedMic.Agent.Session;

namespace SharedMic.Agent.Net;

/// <summary>
/// One authenticated conversation with one Mac, over one already-established
/// duplex stream (an SslStream in production, a loopback NetworkStream in
/// tests). Owns the section 6 handshake, the section 7 session lifecycle, the
/// section 8 dead-peer rule, and the section 9 writer loop.
///
/// Several of these run at once — one per connected paired Mac. What is NOT
/// per-connection is the session: every instance shares one SessionArbiter and
/// at most one of them holds the microphone at a time.
///
/// The session is released in RunAsync's finally, through
/// EndSessionOwnedBy(ConnectionId). That is the single point every exit path
/// funnels through — STOP, a clean close, a socket error, a protocol violation,
/// dead-peer detection, and agent shutdown — which is what makes "a session
/// ends when its connection ends" true rather than aspirational.
///
/// Phase 1 has no capture path, so nothing ever calls SendQueue.EnqueueAudio on
/// a live connection and an active session carries zero audio bytes.
///
/// Threading: every control message for THIS connection is handled on its own
/// single read loop. The shared arbiter and the shared rate limiter both take
/// their own locks, because other connections' read loops reach them too. The
/// writer runs on its own task and touches only the queue and the stream.
/// </summary>
public sealed class ControlConnection : IAsyncDisposable
{
    private readonly Stream _stream;
    private readonly AgentIdentity _identity;
    private readonly AgentOptions _options;
    private readonly PairedDeviceStore _devices;
    private readonly AuthRateLimiter _rateLimiter;
    private readonly SessionArbiter _sessions;
    private readonly AgentMetrics _metrics;
    private readonly PrioritySendQueue _queue = new();
    private readonly CancellationTokenSource _closing = new();
    private readonly byte[] _nonce = AuthProof.GenerateNonce();

    private long _lastPeerActivityTicks;

    public ControlConnection(
        Stream stream,
        AgentIdentity identity,
        AgentOptions options,
        PairedDeviceStore devices,
        AuthRateLimiter rateLimiter,
        SessionArbiter sessions,
        AgentMetrics metrics)
    {
        _stream = stream;
        _identity = identity;
        _options = options;
        _devices = devices;
        _rateLimiter = rateLimiter;
        _sessions = sessions;
        _metrics = metrics;
    }

    /// <summary>Raised once HELLO_ACK has been queued, so the listener can refresh its status.</summary>
    public event Action<ControlConnection>? Authenticated;

    /// <summary>
    /// Identifies this connection to the arbiter. Not the device: one Mac may
    /// hold two connections, and only the one that got the START_ACK owns the
    /// session.
    /// </summary>
    public string ConnectionId { get; } =
        "conn-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLowerInvariant();

    public bool IsAuthenticated { get; private set; }

    /// <summary>The paired device the proof identified, or null before authentication.</summary>
    public PairedDevice? Device { get; private set; }

    public string RemoteDescription { get; init; } = "unknown";

    /// <summary>The rate-limiter key: the peer's address, without its port.</summary>
    public string PeerKey { get; init; } = "unknown";

    public PrioritySendQueue SendQueue => _queue;

    public SessionArbiter Sessions => _sessions;

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _closing.Token);
        var token = linked.Token;

        Touch();
        SendControl(ControlMessages.Greeting(_identity.ServerId, Convert.ToHexString(_nonce).ToLowerInvariant()));

        var writer = Task.Run(() => WriteLoopAsync(token), CancellationToken.None);
        var liveness = Task.Run(() => LivenessLoopAsync(token), CancellationToken.None);

        try
        {
            await ReadLoopAsync(token).ConfigureAwait(false);
        }
        finally
        {
            Close();

            // A session ends when its connection ends — not only on STOP. This
            // one line is what stops a crashed or unplugged Mac from locking
            // every other paired Mac out. Dead-peer detection arrives here too,
            // because it works by cancelling this read loop.
            if (_sessions.EndSessionOwnedBy(ConnectionId))
            {
                _metrics.IncrementSessionsEndedByDisconnect();
                AgentLog.Info(
                    $"{RemoteDescription} went away while holding the session; " +
                    "the session is released and another paired Mac may take it");
            }

            _queue.DiscardAudio();

            try
            {
                await writer.ConfigureAwait(false);
            }
            catch (Exception)
            {
                // The writer's own error handling already closed the connection.
            }

            try
            {
                await liveness.ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Cancellation during teardown.
            }

            // protocol-v1.md section 3 requires the receiver to CLOSE the
            // connection on a violation, not merely stop reading. Disposing the
            // stream here is what makes that true for every exit path, rather
            // than only when the owner remembers to dispose this object.
            try
            {
                await _stream.DisposeAsync().ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Disposing an already-faulted stream is not interesting.
            }
        }
    }

    public void Close()
    {
        try
        {
            _closing.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // Already torn down.
        }
    }

    public async ValueTask DisposeAsync()
    {
        Close();

        try
        {
            await _stream.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception)
        {
            // Disposing an already-faulted stream is not interesting.
        }

        _closing.Dispose();
    }

    private async Task ReadLoopAsync(CancellationToken cancellationToken)
    {
        var reader = new FrameReader(_stream);
        var helloDeadline = DateTimeOffset.UtcNow + _options.HelloDeadline;

        while (!cancellationToken.IsCancellationRequested)
        {
            ReceivedFrame? frame;
            using var readCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            if (!IsAuthenticated)
            {
                var remaining = helloDeadline - DateTimeOffset.UtcNow;
                if (remaining <= TimeSpan.Zero)
                {
                    FailAuthentication("the 5-second pre-auth deadline expired");
                    return;
                }

                readCancellation.CancelAfter(remaining);
            }

            try
            {
                frame = await reader.ReadFrameAsync(readCancellation.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                if (!IsAuthenticated && !cancellationToken.IsCancellationRequested)
                {
                    FailAuthentication("the 5-second pre-auth deadline expired");
                }

                return;
            }
            catch (ProtocolException exception)
            {
                AgentLog.Warn($"closing {RemoteDescription}: protocol violation: {exception.Message}");
                if (!IsAuthenticated)
                {
                    FailAuthentication(exception.Message);
                }

                return;
            }
            catch (Exception exception) when (exception is IOException or ObjectDisposedException)
            {
                return;
            }

            if (frame is null)
            {
                AgentLog.Info($"{RemoteDescription} closed the connection");
                if (!IsAuthenticated)
                {
                    FailAuthentication("the peer closed before authenticating");
                }

                return;
            }

            Touch();

            if (frame.Value.Type != FrameType.Control)
            {
                // The Mac never sends AUDIO in this protocol, so receiving one
                // is a violation at any point in the connection's lifetime.
                AgentLog.Warn($"closing {RemoteDescription}: received a {frame.Value.Type} frame from the client");
                if (!IsAuthenticated)
                {
                    FailAuthentication("received an AUDIO frame before authentication");
                }

                return;
            }

            Dictionary<string, object?> message;
            try
            {
                message = ControlCodec.Decode(frame.Value.Payload);
            }
            catch (ProtocolException exception)
            {
                AgentLog.Warn($"closing {RemoteDescription}: {exception.Message}");
                if (!IsAuthenticated)
                {
                    FailAuthentication(exception.Message);
                }

                return;
            }

            _metrics.IncrementControlMessagesReceived();

            if (!IsAuthenticated)
            {
                if (!TryAuthenticate(message))
                {
                    return;
                }

                continue;
            }

            Handle(message);
        }
    }

    private bool TryAuthenticate(IReadOnlyDictionary<string, object?> message)
    {
        if (!_rateLimiter.TryBeginAttempt(PeerKey))
        {
            _metrics.IncrementAuthRefusedByLockout();
            AgentLog.Warn(
                $"authentication from {RemoteDescription} refused: {PeerKey} is locked out for another " +
                $"{_rateLimiter.LockoutRemaining(PeerKey).TotalSeconds:F0} s after " +
                $"{ProtocolConstants.MaxAuthFailures} consecutive failures");
            return false;
        }

        var type = message["type"] as string;
        if (type != "HELLO")
        {
            FailAuthentication($"expected HELLO before authentication, got {type}");
            return false;
        }

        // clientId is a DISPLAY LABEL and nothing else. It arrives before any
        // proof has been checked, so it must not choose which token to test and
        // must not become the device's name. The proof identifies the device;
        // this string only ever reaches a log line.
        var claimedName = message.GetValueOrDefault("clientId") as string ?? "(unnamed)";

        var device = _devices.Identify(_nonce, message["mac"] as string);
        if (device is null)
        {
            // Identical treatment for a wrong token, a malformed proof, and a
            // revoked device. Nothing here reveals which of the three it was.
            FailAuthentication("no paired device's token produced this proof");
            return false;
        }

        _rateLimiter.RecordSuccess(PeerKey);
        Device = device;
        IsAuthenticated = true;
        _metrics.IncrementConnectionsAuthenticated();

        // Queue HELLO_ACK before flipping any observable state, so nothing can
        // slip ahead of it on the control queue.
        SendControl(ControlMessages.HelloAck(_identity.ServerId, _options.MicPresent, _options.DeviceLabel));
        AgentLog.Info(
            $"authenticated paired device '{device.FriendlyName}' ({device.DeviceId}) from " +
            $"{RemoteDescription}; it called itself '{claimedName}' (untrusted, display only)");
        Authenticated?.Invoke(this);
        return true;
    }

    private void FailAuthentication(string reason)
    {
        _rateLimiter.RecordFailure(PeerKey);
        _metrics.IncrementAuthFailures();

        var lockout = _rateLimiter.IsLockedOut(PeerKey)
            ? $" — {PeerKey} is now locked out for {_rateLimiter.LockoutRemaining(PeerKey).TotalSeconds:F0} s"
            : string.Empty;
        AgentLog.Warn($"authentication from {RemoteDescription} failed: {reason}{lockout}");
    }

    private void Handle(IReadOnlyDictionary<string, object?> message)
    {
        switch (message["type"] as string)
        {
            case "PING":
                if (message["seq"] is not long seq)
                {
                    AgentLog.Warn($"ignoring a PING from {RemoteDescription} whose seq is not an integer");
                    break;
                }

                _metrics.IncrementPingsReceived();
                SendControl(ControlMessages.Pong(seq));
                break;

            case "START":
            {
                if (message["requestId"] is not string requestId)
                {
                    AgentLog.Warn($"ignoring a START from {RemoteDescription} whose requestId is not a string");
                    break;
                }

                var grant = _sessions.Start(ConnectionId, Device?.FriendlyName ?? string.Empty, _options.MicPresent);
                if (!grant.Accepted)
                {
                    if (grant.Reason == SessionArbiter.SessionInUse)
                    {
                        _metrics.IncrementSessionsRefusedAsInUse();
                        AgentLog.Info(
                            $"START {requestId} from '{Device?.FriendlyName}' refused: " +
                            $"'{grant.HolderName}' holds the session");
                    }
                    else
                    {
                        AgentLog.Info($"START {requestId} rejected: {grant.Reason}");
                    }

                    // The holder name is advisory and is omitted by
                    // ControlMessages.StartNack when it is null or blank, which
                    // is exactly the MIC_UNAVAILABLE case.
                    SendControl(ControlMessages.StartNack(requestId, grant.Reason!, grant.HolderName));
                    break;
                }

                if (grant.StartedNewSession)
                {
                    _metrics.IncrementSessionsStarted();
                    AgentLog.Info(
                        $"session {grant.SessionId} started by '{Device?.FriendlyName}' " +
                        "(Phase 1: no capture, no audio will be sent)");
                }
                else
                {
                    AgentLog.Info($"duplicate START {requestId} returned the existing session {grant.SessionId}");
                }

                SendControl(ControlMessages.StartAck(requestId, grant.SessionId));
                break;
            }

            case "STOP":
            {
                if (message["requestId"] is not string requestId)
                {
                    AgentLog.Warn($"ignoring a STOP from {RemoteDescription} whose requestId is not a string");
                    break;
                }

                var requested = message["sessionId"] as string ?? string.Empty;

                // A STOP from a connection that does not hold the session ends
                // nothing and still succeeds. Anything else would let any paired
                // Mac cancel another's session with one message.
                var release = _sessions.Stop(ConnectionId, requested);
                var discarded = _queue.DiscardAudio();
                if (release.EndedSession)
                {
                    AgentLog.Info($"session {release.SessionId} ended; discarded {discarded} queued audio frames");
                }

                SendControl(ControlMessages.StopAck(requestId, release.SessionId));
                break;
            }

            default:
                // The reference server ignores rather than closes here, and
                // matching it avoids an interoperability hazard over a message
                // the contract does not require either side to reject.
                _metrics.IncrementUnexpectedControlMessages();
                AgentLog.Warn(
                    $"ignoring an unexpected control message type '{message["type"]}' from an authenticated peer");
                break;
        }
    }

    private async Task WriteLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var frame = await _queue.DequeueAsync(cancellationToken).ConfigureAwait(false);
                await _stream.WriteAsync(frame, cancellationToken).ConfigureAwait(false);
                await _stream.FlushAsync(cancellationToken).ConfigureAwait(false);

                if (frame.Length > 0 && frame[0] == (byte)FrameType.Control)
                {
                    _metrics.IncrementControlMessagesSent();
                }
                else
                {
                    _metrics.IncrementAudioFramesSent();
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Normal teardown.
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException)
        {
            AgentLog.Warn($"write to {RemoteDescription} failed: {exception.GetType().Name}");
            Close();
        }
    }

    private async Task LivenessLoopAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await Task.Delay(_options.LivenessPollInterval, cancellationToken).ConfigureAwait(false);

                if (!IsAuthenticated)
                {
                    continue;
                }

                var idle = TimeSpan.FromTicks(DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastPeerActivityTicks));
                if (idle > _options.PeerDeadTimeout)
                {
                    _metrics.IncrementDeadPeerDisconnects();
                    AgentLog.Warn(
                        $"{RemoteDescription} sent nothing for {idle.TotalSeconds:F0} s " +
                        $"(limit {_options.PeerDeadTimeout.TotalSeconds:F0} s) — declaring the peer dead");
                    Close();
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // Normal teardown.
        }
    }

    private void SendControl(IReadOnlyDictionary<string, object?> message) =>
        _queue.EnqueueControl(FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message)));

    private void Touch() => Interlocked.Exchange(ref _lastPeerActivityTicks, DateTime.UtcNow.Ticks);
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~ControlConnectionTests"
```

Expected: PASS, 29 tests. The five that matter most here are `ASecondConnectionIsNackedWithSessionInUseAndTheHolderName`, `StopFromANonHolderIsAckedButEndsNothing`, `ClosingTheOwningConnectionReleasesTheSessionForEveryoneElse`, `DeadPeerDetectionAlsoReleasesTheSession` and `AnAttackerLockedOutAtOneAddressDoesNotBlockAPairedMacAtAnother` — none of which has any equivalent in the Python conformance suite.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/AgentOptions.cs windows/SharedMic.Agent/AgentStatus.cs windows/SharedMic.Agent/Diagnostics windows/SharedMic.Agent/Net/ControlConnection.cs windows/SharedMic.Agent.Tests/LoopbackPeer.cs windows/SharedMic.Agent.Tests/ControlConnectionTests.cs
git commit -m "Phase 1 Task 14: control connection with handshake, arbitrated sessions, dead-peer detection"
```

---

### Task 15: TLS 1.3 listener bound to private interfaces

**Files:**
- Create: `windows/SharedMic.Agent/Net/PrivateAddress.cs`
- Create: `windows/SharedMic.Agent/Net/TlsListener.cs`
- Test: `windows/SharedMic.Agent.Tests/PrivateAddressTests.cs`
- Test: `windows/SharedMic.Agent.Tests/TlsListenerTests.cs`

**Interfaces:**
- Consumes: `AgentIdentity`, `AgentOptions`, `PairedDeviceStore`, `AuthRateLimiter.PeerKey(EndPoint?)`, `SessionArbiter.HolderName`, `AgentMetrics`, `AgentStatus`, `AgentLog`, `ControlConnection(Stream, AgentIdentity, AgentOptions, PairedDeviceStore, AuthRateLimiter, SessionArbiter, AgentMetrics)` with `ConnectionId`, `PeerKey`, `Device`, `RunAsync`, `Close`, `DisposeAsync`, and the `Authenticated` event.
- Produces: `static class PrivateAddress` with `bool IsPrivate(IPAddress address)` and `IReadOnlyList<IPAddress> Enumerate()`; `sealed class TlsListener : IAsyncDisposable` with constructor `TlsListener(AgentIdentity identity, AgentOptions options, PairedDeviceStore devices, AuthRateLimiter rateLimiter, SessionArbiter sessions, AgentMetrics metrics, Action<AgentStatus, string?> onStatus)`, members `IReadOnlyList<IPEndPoint> Endpoints`, `int AuthenticatedConnections`, `void Start()`, `ValueTask DisposeAsync()`.

**Supersession is gone.** The previous draft closed the older connection as soon as a new one authenticated, on the theory that there was only ever one Mac. There are several, they are all trusted, and they all stay connected; the microphone is arbitrated by `SessionArbiter`, not by hanging up on people. What the listener keeps is the rule that made supersession safe in the first place: **nothing observable happens until a connection authenticates**, so an unauthenticated peer still cannot affect anyone.

**This task runs on Windows.** Its tests are the only ones in the plan that put two authenticated Macs on real TLS at the same time.

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/PrivateAddressTests.cs`:

```csharp
using System.Net;
using SharedMic.Agent.Net;
using Xunit;

namespace SharedMic.Agent.Tests;

public class PrivateAddressTests
{
    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("10.0.0.1")]
    [InlineData("10.255.255.254")]
    [InlineData("172.16.0.1")]
    [InlineData("172.31.255.254")]
    [InlineData("192.168.1.5")]
    [InlineData("169.254.10.20")]
    [InlineData("::1")]
    [InlineData("fe80::1")]
    [InlineData("fd00::1")]
    public void PrivateAddressesAreAccepted(string address)
    {
        Assert.True(PrivateAddress.IsPrivate(IPAddress.Parse(address)));
    }

    [Theory]
    [InlineData("8.8.8.8")]
    [InlineData("1.1.1.1")]
    [InlineData("172.15.255.255")]
    [InlineData("172.32.0.1")]
    [InlineData("192.169.0.1")]
    [InlineData("11.0.0.1")]
    [InlineData("2606:4700:4700::1111")]
    public void PublicAddressesAreRejected(string address)
    {
        Assert.False(PrivateAddress.IsPrivate(IPAddress.Parse(address)));
    }

    [Fact]
    public void EnumerationAlwaysIncludesLoopbackAndOnlyPrivateAddresses()
    {
        var addresses = PrivateAddress.Enumerate();

        Assert.Contains(IPAddress.Loopback, addresses);
        Assert.All(addresses, address => Assert.True(PrivateAddress.IsPrivate(address)));
    }
}
```

`windows/SharedMic.Agent.Tests/TlsListenerTests.cs`:

```csharp
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using SharedMic.Agent;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class TlsListenerTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), "sharedmic-listener-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }

    private static AgentOptions LoopbackOptions(int port) => new()
    {
        Port = port,
        LoopbackOnly = true,
        MicPresent = true,
        DeviceLabel = "USB Microphone",
        HelloDeadline = TimeSpan.FromSeconds(2),
        PeerDeadTimeout = TimeSpan.FromSeconds(30),
        LivenessPollInterval = TimeSpan.FromMilliseconds(200),
        TlsHandshakeTimeout = TimeSpan.FromSeconds(5),
    };

    /// <summary>Connect the way a pinning client does: no CA, no hostname check, compare the DER SHA-256.</summary>
    private static async Task<SslStream> ConnectPinnedAsync(IPEndPoint endpoint, string expectedFingerprint)
    {
        var client = new TcpClient();
        await client.ConnectAsync(endpoint);
        client.NoDelay = true;

        var actualFingerprint = string.Empty;
        var ssl = new SslStream(
            client.GetStream(),
            leaveInnerStreamOpen: false,
            (_, certificate, _, _) =>
            {
                actualFingerprint = certificate is null
                    ? string.Empty
                    : Convert.ToHexString(SHA256.HashData(certificate.GetRawCertData())).ToLowerInvariant();
                return true;
            });

        await ssl.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = "shared-mic",
            EnabledSslProtocols = SslProtocols.Tls13,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
        });

        Assert.Equal(expectedFingerprint, actualFingerprint);
        return ssl;
    }

    /// <summary>A connected, authenticated Mac: the TLS stream plus the reader that owns its buffer.</summary>
    private sealed class Client : IAsyncDisposable
    {
        public Client(SslStream stream)
        {
            Stream = stream;
            Reader = new FrameReader(stream);
        }

        public SslStream Stream { get; }

        public FrameReader Reader { get; }

        public async Task SendAsync(IReadOnlyDictionary<string, object?> message, CancellationToken cancellationToken)
        {
            var frame = FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message));
            await Stream.WriteAsync(frame, cancellationToken);
            await Stream.FlushAsync(cancellationToken);
        }

        public async Task<Dictionary<string, object?>> ReadAsync(CancellationToken cancellationToken)
        {
            var frame = await Reader.ReadFrameAsync(cancellationToken)
                        ?? throw new InvalidOperationException("the agent closed the connection");
            return ControlCodec.Decode(frame.Payload);
        }

        public async Task<bool> IsClosedAsync(CancellationToken cancellationToken)
        {
            try
            {
                return await Reader.ReadFrameAsync(cancellationToken) is null;
            }
            catch (Exception exception) when (exception is IOException or ProtocolException or ObjectDisposedException)
            {
                return true;
            }
        }

        public async ValueTask DisposeAsync() => await Stream.DisposeAsync();
    }

    [Fact]
    public async Task AcceptsAPinnedTls13ConnectionAndCompletesTheHandshake()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var devices = new PairedDeviceStore(_directory);
        var mac = devices.Pair("Mac Studio");
        var statuses = new List<AgentStatus>();
        await using var listener = new TlsListener(
            identity,
            LoopbackOptions(port: 0),
            devices,
            new AuthRateLimiter(),
            new SessionArbiter(),
            new AgentMetrics(),
            (status, _) => statuses.Add(status));

        listener.Start();
        var endpoint = listener.Endpoints.Single();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15));

        await using var ssl = await ConnectPinnedAsync(endpoint, identity.Fingerprint);

        Assert.Equal(SslProtocols.Tls13, ssl.SslProtocol);

        var reader = new FrameReader(ssl);
        var greetingFrame = await reader.ReadFrameAsync(cancellation.Token);
        var greeting = ControlCodec.Decode(greetingFrame!.Value.Payload);

        Assert.Equal("GREETING", greeting["type"]);
        Assert.Equal(identity.ServerId, greeting["serverId"]);

        var nonce = Convert.FromHexString((string)greeting["nonce"]!);
        var hello = FrameCodec.EncodeFrame(
            FrameType.Control,
            ControlCodec.Encode(ControlMessages.Hello("mock-mac", AuthProof.Compute(mac.Token, nonce))));
        await ssl.WriteAsync(hello, cancellation.Token);
        await ssl.FlushAsync(cancellation.Token);

        var ackFrame = await reader.ReadFrameAsync(cancellation.Token);
        var ack = ControlCodec.Decode(ackFrame!.Value.Payload);

        Assert.Equal("HELLO_ACK", ack["type"]);
        Assert.Contains(AgentStatus.Idle, statuses);
    }

    [Fact]
    public async Task BindsTheConfiguredPortOnLoopback()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var port = FreeLoopbackPort();
        await using var listener = new TlsListener(
            identity,
            LoopbackOptions(port),
            new PairedDeviceStore(_directory),
            new AuthRateLimiter(),
            new SessionArbiter(),
            new AgentMetrics(),
            (_, _) => { });

        listener.Start();

        Assert.Single(listener.Endpoints);
        Assert.Equal(port, listener.Endpoints[0].Port);
        Assert.Equal(IPAddress.Loopback, listener.Endpoints[0].Address);
    }

    /// <summary>
    /// The rule the old draft had backwards. Two paired Macs connect, both
    /// authenticate, and BOTH stay up. No supersession.
    /// </summary>
    [Fact]
    public async Task TwoPairedMacsStayAuthenticatedAtTheSameTime()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var devices = new PairedDeviceStore(_directory);
        var studio = devices.Pair("Mac Studio");
        var laptop = devices.Pair("MacBook Pro");
        await using var listener = new TlsListener(
            identity,
            LoopbackOptions(port: 0),
            devices,
            new AuthRateLimiter(),
            new SessionArbiter(),
            new AgentMetrics(),
            (_, _) => { });

        listener.Start();
        var endpoint = listener.Endpoints.Single();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));

        await using var first = await AuthenticateAsync(endpoint, identity, studio.Token, cancellation.Token);
        await using var second = await AuthenticateAsync(endpoint, identity, laptop.Token, cancellation.Token);

        // Both connections are still alive and still answering.
        await first.SendAsync(ControlMessages.Ping(1), cancellation.Token);
        Assert.Equal("PONG", (await first.ReadAsync(cancellation.Token))["type"]);
        await second.SendAsync(ControlMessages.Ping(2), cancellation.Token);
        Assert.Equal("PONG", (await second.ReadAsync(cancellation.Token))["type"]);

        Assert.Equal(2, listener.AuthenticatedConnections);
    }

    [Fact]
    public async Task OnlyOneOfTwoConnectedMacsGetsTheSession()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var devices = new PairedDeviceStore(_directory);
        var studio = devices.Pair("Mac Studio");
        var laptop = devices.Pair("MacBook Pro");
        var sessions = new SessionArbiter();
        await using var listener = new TlsListener(
            identity,
            LoopbackOptions(port: 0),
            devices,
            new AuthRateLimiter(),
            sessions,
            new AgentMetrics(),
            (_, _) => { });

        listener.Start();
        var endpoint = listener.Endpoints.Single();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));

        await using var holder = await AuthenticateAsync(endpoint, identity, studio.Token, cancellation.Token);
        await using var other = await AuthenticateAsync(endpoint, identity, laptop.Token, cancellation.Token);

        await holder.SendAsync(ControlMessages.Start("req-h"), cancellation.Token);
        var granted = await holder.ReadAsync(cancellation.Token);

        await other.SendAsync(ControlMessages.Start("req-o"), cancellation.Token);
        var refused = await other.ReadAsync(cancellation.Token);

        Assert.Equal("START_ACK", granted["type"]);
        Assert.Equal("START_NACK", refused["type"]);
        Assert.Equal("SESSION_IN_USE", refused["reason"]);
        Assert.Equal("Mac Studio", refused["holder"]);
        Assert.Equal(1, sessions.SessionsStarted);
        Assert.Equal(studio.DeviceId, listener.SessionHolderDeviceId);
        Assert.Equal(2, listener.AuthenticatedConnections);
    }

    /// <summary>
    /// Over real TLS this time: the holder's socket goes away without a STOP and
    /// the other Mac can take the session.
    /// </summary>
    [Fact]
    public async Task WhenTheHolderDisconnectsTheOtherMacCanTakeTheSession()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var devices = new PairedDeviceStore(_directory);
        var studio = devices.Pair("Mac Studio");
        var laptop = devices.Pair("MacBook Pro");
        var sessions = new SessionArbiter();
        await using var listener = new TlsListener(
            identity,
            LoopbackOptions(port: 0),
            devices,
            new AuthRateLimiter(),
            sessions,
            new AgentMetrics(),
            (_, _) => { });

        listener.Start();
        var endpoint = listener.Endpoints.Single();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));

        var holder = await AuthenticateAsync(endpoint, identity, studio.Token, cancellation.Token);
        await using var other = await AuthenticateAsync(endpoint, identity, laptop.Token, cancellation.Token);

        await holder.SendAsync(ControlMessages.Start("req-h"), cancellation.Token);
        Assert.Equal("START_ACK", (await holder.ReadAsync(cancellation.Token))["type"]);

        await other.SendAsync(ControlMessages.Start("req-o1"), cancellation.Token);
        Assert.Equal("START_NACK", (await other.ReadAsync(cancellation.Token))["type"]);

        // No STOP: just a dead socket, the way a crash or a closed lid looks.
        await holder.DisposeAsync();
        await WaitUntilAsync(() => sessions.ActiveSessionId is null, TimeSpan.FromSeconds(10));

        await other.SendAsync(ControlMessages.Start("req-o2"), cancellation.Token);
        var granted = await other.ReadAsync(cancellation.Token);

        Assert.Equal("START_ACK", granted["type"]);
        Assert.Equal(2, sessions.SessionsStarted);
    }

    [Fact]
    public async Task AClientThatNeverSendsHelloIsDroppedAtTheDeadline()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var limiter = new AuthRateLimiter();
        await using var listener = new TlsListener(
            identity,
            LoopbackOptions(port: 0),
            new PairedDeviceStore(_directory),
            limiter,
            new SessionArbiter(),
            new AgentMetrics(),
            (_, _) => { });

        listener.Start();
        var endpoint = listener.Endpoints.Single();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));

        await using var ssl = await ConnectPinnedAsync(endpoint, identity.Fingerprint);
        var client = new Client(ssl);
        await client.Reader.ReadFrameAsync(cancellation.Token);

        Assert.True(await client.IsClosedAsync(cancellation.Token));

        // The connection came from loopback, so that is the key it was counted
        // under. AuthRateLimiter.PeerKey drops the source port.
        Assert.Equal(1, limiter.ConsecutiveFailures("127.0.0.1"));
    }

    private static async Task<Client> AuthenticateAsync(
        IPEndPoint endpoint,
        AgentIdentity identity,
        byte[] token,
        CancellationToken cancellationToken)
    {
        var client = new Client(await ConnectPinnedAsync(endpoint, identity.Fingerprint));
        var greeting = await client.ReadAsync(cancellationToken);
        var nonce = Convert.FromHexString((string)greeting["nonce"]!);
        await client.SendAsync(
            ControlMessages.Hello("mock-mac", AuthProof.Compute(token, nonce)),
            cancellationToken);
        var ack = await client.ReadAsync(cancellationToken);
        Assert.Equal("HELLO_ACK", ack["type"]);
        return client;
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            if (condition())
            {
                return;
            }

            await Task.Delay(25);
        }
    }

    private static int FreeLoopbackPort()
    {
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        var port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return port;
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PrivateAddressTests|FullyQualifiedName~TlsListenerTests"
```

Expected: FAIL with `CS0246: The type or namespace name 'PrivateAddress' could not be found` and `CS0246: The type or namespace name 'TlsListener' could not be found`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Net/PrivateAddress.cs`:

```csharp
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace SharedMic.Agent.Net;

/// <summary>
/// protocol-v1.md section 2 and design spec section 7.3: the listener binds to
/// private interfaces only and is never exposed to the public Internet. This is
/// a pure classifier so it can be unit tested without a network.
/// </summary>
public static class PrivateAddress
{
    public static bool IsPrivate(IPAddress address)
    {
        ArgumentNullException.ThrowIfNull(address);

        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return IPAddress.IsLoopback(address) || address.IsIPv6LinkLocal || address.IsIPv6UniqueLocal;
        }

        if (address.AddressFamily != AddressFamily.InterNetwork)
        {
            return false;
        }

        var octets = address.GetAddressBytes();
        return octets[0] switch
        {
            127 => true,                                      // 127.0.0.0/8 loopback
            10 => true,                                       // 10.0.0.0/8
            172 => octets[1] >= 16 && octets[1] <= 31,         // 172.16.0.0/12
            192 => octets[1] == 168,                           // 192.168.0.0/16
            169 => octets[1] == 254,                           // 169.254.0.0/16 link-local
            _ => false,
        };
    }

    public static IReadOnlyList<IPAddress> Enumerate()
    {
        var addresses = new List<IPAddress>();

        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up)
            {
                continue;
            }

            foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
            {
                if (IsPrivate(unicast.Address) && !addresses.Contains(unicast.Address))
                {
                    addresses.Add(unicast.Address);
                }
            }
        }

        if (!addresses.Contains(IPAddress.Loopback))
        {
            addresses.Add(IPAddress.Loopback);
        }

        return addresses;
    }
}
```

`windows/SharedMic.Agent/Net/TlsListener.cs`:

```csharp
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Security;
using SharedMic.Agent.Session;

namespace SharedMic.Agent.Net;

/// <summary>
/// The TCP 47800 listener of protocol-v1.md section 2. One TcpListener per
/// private interface address; TLS 1.3 wraps every accepted connection
/// immediately, with Windows as the TLS server. There is no CA: the certificate
/// exists only so the Mac can pin the SHA-256 of its DER encoding.
///
/// Every paired Mac may be connected at once. There is NO supersession: a newly
/// authenticated connection does not displace an older one, because the thing
/// they contend over is the microphone session, and SessionArbiter arbitrates
/// that without anyone being hung up on.
///
/// What survives from the superseding design is the rule that made it safe:
/// nothing observable happens until a connection authenticates, so opening a
/// socket buys an attacker nothing.
/// </summary>
public sealed class TlsListener : IAsyncDisposable
{
    private readonly AgentIdentity _identity;
    private readonly AgentOptions _options;
    private readonly PairedDeviceStore _devices;
    private readonly AuthRateLimiter _rateLimiter;
    private readonly SessionArbiter _sessions;
    private readonly AgentMetrics _metrics;
    private readonly Action<AgentStatus, string?> _onStatus;
    private readonly List<TcpListener> _listeners = new();
    private readonly List<Task> _acceptLoops = new();
    private readonly CancellationTokenSource _stopping = new();
    private readonly object _gate = new();
    private readonly List<ControlConnection> _authenticated = new();

    public TlsListener(
        AgentIdentity identity,
        AgentOptions options,
        PairedDeviceStore devices,
        AuthRateLimiter rateLimiter,
        SessionArbiter sessions,
        AgentMetrics metrics,
        Action<AgentStatus, string?> onStatus)
    {
        _identity = identity;
        _options = options;
        _devices = devices;
        _rateLimiter = rateLimiter;
        _sessions = sessions;
        _metrics = metrics;
        _onStatus = onStatus;
    }

    public IReadOnlyList<IPEndPoint> Endpoints { get; private set; } = Array.Empty<IPEndPoint>();

    /// <summary>How many paired Macs are authenticated right now.</summary>
    public int AuthenticatedConnections
    {
        get
        {
            lock (_gate)
            {
                return _authenticated.Count;
            }
        }
    }

    /// <summary>
    /// Which PAIRED DEVICE holds the session, or null when nobody does. The
    /// arbiter tracks the owning CONNECTION; this resolves that connection to
    /// the device behind it, which is what the tray needs to mark a row.
    /// </summary>
    public string? SessionHolderDeviceId
    {
        get
        {
            if (_sessions.HolderId is not { } holderId)
            {
                return null;
            }

            lock (_gate)
            {
                return _authenticated
                    .FirstOrDefault(connection =>
                        string.Equals(connection.ConnectionId, holderId, StringComparison.Ordinal))
                    ?.Device?.DeviceId;
            }
        }
    }

    public void Start()
    {
        var addresses = _options.LoopbackOnly
            ? new[] { IPAddress.Loopback }
            : PrivateAddress.Enumerate().ToArray();

        var endpoints = new List<IPEndPoint>();
        foreach (var address in addresses)
        {
            var listener = new TcpListener(address, _options.Port);
            try
            {
                listener.Start();
            }
            catch (SocketException exception)
            {
                AgentLog.Warn($"cannot bind {address}:{_options.Port}: {exception.SocketErrorCode}");
                continue;
            }

            _listeners.Add(listener);
            var bound = (IPEndPoint)listener.LocalEndpoint;
            endpoints.Add(bound);
            AgentLog.Info($"listening on {bound} (private interfaces only)");
            _acceptLoops.Add(Task.Run(() => AcceptLoopAsync(listener, _stopping.Token), CancellationToken.None));
        }

        if (_listeners.Count == 0)
        {
            throw new InvalidOperationException(
                $"no private interface accepted a bind on port {_options.Port}");
        }

        Endpoints = endpoints;
        _onStatus(AgentStatus.Disconnected, null);
    }

    public async ValueTask DisposeAsync()
    {
        _stopping.Cancel();

        foreach (var listener in _listeners)
        {
            try
            {
                listener.Stop();
            }
            catch (SocketException)
            {
                // Already stopped.
            }
        }

        ControlConnection[] live;
        lock (_gate)
        {
            live = _authenticated.ToArray();
            _authenticated.Clear();
        }

        foreach (var connection in live)
        {
            connection.Close();
        }

        foreach (var loop in _acceptLoops)
        {
            try
            {
                await loop.WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Shutting down; a cancelled or faulted accept loop is expected.
            }
        }

        _stopping.Dispose();
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (Exception exception)
                when (exception is OperationCanceledException or SocketException or ObjectDisposedException)
            {
                return;
            }

            _ = Task.Run(() => ServeAsync(client, cancellationToken), CancellationToken.None);
        }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken cancellationToken)
    {
        var remote = client.Client.RemoteEndPoint?.ToString() ?? "unknown";
        _metrics.IncrementConnectionsAccepted();
        AgentLog.Info($"connection from {remote}");

        SslStream? ssl = null;
        ControlConnection? connection = null;

        try
        {
            client.NoDelay = true;
            ssl = new SslStream(client.GetStream(), leaveInnerStreamOpen: false);

            using var handshake = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            handshake.CancelAfter(_options.TlsHandshakeTimeout);

            await ssl.AuthenticateAsServerAsync(
                new SslServerAuthenticationOptions
                {
                    ServerCertificate = _identity.Certificate,
                    ClientCertificateRequired = false,
                    EnabledSslProtocols = SslProtocols.Tls13,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                },
                handshake.Token).ConfigureAwait(false);

            AgentLog.Info($"TLS handshake with {remote} negotiated {ssl.SslProtocol}");

            connection = new ControlConnection(
                ssl, _identity, _options, _devices, _rateLimiter, _sessions, _metrics)
            {
                RemoteDescription = remote,
                PeerKey = AuthRateLimiter.PeerKey(client.Client.RemoteEndPoint),
            };
            connection.Authenticated += Adopt;

            await connection.RunAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception)
            when (exception is AuthenticationException or IOException or OperationCanceledException
                      or SocketException or ObjectDisposedException)
        {
            AgentLog.Warn($"connection from {remote} ended: {exception.GetType().Name}: {exception.Message}");
        }
        finally
        {
            if (connection is not null)
            {
                connection.Authenticated -= Adopt;
                lock (_gate)
                {
                    _authenticated.Remove(connection);
                }

                await connection.DisposeAsync().ConfigureAwait(false);
            }
            else if (ssl is not null)
            {
                await ssl.DisposeAsync().ConfigureAwait(false);
            }

            client.Dispose();
            AgentLog.Info($"connection from {remote} closed");
            PublishStatus();
        }
    }

    /// <summary>
    /// Record a connection that has authenticated. It joins the others; it does
    /// not replace them.
    /// </summary>
    private void Adopt(ControlConnection connection)
    {
        int count;
        lock (_gate)
        {
            if (!_authenticated.Contains(connection))
            {
                _authenticated.Add(connection);
            }

            count = _authenticated.Count;
        }

        AgentLog.Info(
            $"'{connection.Device?.FriendlyName}' authenticated from {connection.RemoteDescription}; " +
            $"{count} paired Mac(s) now connected");
        PublishStatus();
    }

    private void PublishStatus()
    {
        int count;
        lock (_gate)
        {
            count = _authenticated.Count;
        }

        if (count == 0)
        {
            _onStatus(AgentStatus.Disconnected, null);
            return;
        }

        var holder = _sessions.HolderName;
        var detail = string.IsNullOrWhiteSpace(holder)
            ? $"{count} connected"
            : $"{count} connected, {holder} active";

        _onStatus(AgentStatus.Idle, detail);
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PrivateAddressTests|FullyQualifiedName~TlsListenerTests"
```

Expected: PASS, 24 tests (17 `PrivateAddress` theory cases plus 1 fact, and 6 listener facts).

If `AcceptsAPinnedTls13ConnectionAndCompletesTheHandshake` fails with `AuthenticationException: The client and server cannot communicate, because they do not possess a common algorithm`, the Windows host's Schannel does not support TLS 1.3 as a server. That is an OS-version finding (TLS 1.3 server support needs Windows 11 or Windows Server 2022). Report it; do not lower `EnabledSslProtocols`, because protocol-v1.md section 2 makes TLS 1.3 part of the contract.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Net/PrivateAddress.cs windows/SharedMic.Agent/Net/TlsListener.cs windows/SharedMic.Agent.Tests/PrivateAddressTests.cs windows/SharedMic.Agent.Tests/TlsListenerTests.cs
git commit -m "Phase 1 Task 15: TLS 1.3 listener on port 47800, private interfaces only, concurrent Macs"
```

---

### Task 16: Runnable headless host and Python interoperability

This is the first task whose deliverable is a program a person runs. It is also the first evidence that the C# agent and the Python reference implementation actually interoperate, rather than each matching the document separately.

**Files:**
- Create: `windows/SharedMic.Agent/Program.cs`
- Create: `harness/tools/drive_windows_agent.py`

**Interfaces:**
- Consumes: `AgentOptions` (all init-only properties), `IdentityStore(string)` / `LoadOrCreate()`, `AgentIdentity.ServerId` / `.Fingerprint` / `.PairingString`, `AuthRateLimiter()`, `AgentMetrics()` / `Snapshot()`, `TlsListener(AgentIdentity, AgentOptions, AuthRateLimiter, AgentMetrics, Action<AgentStatus, string?>)` / `Start()` / `Endpoints` / `DisposeAsync()`, `AgentLog.Info/Warn/Error`, `AgentStatus`.
- Produces: `static class Program` with `static AgentOptions ParseArguments(string[] args)` and `static int Main(string[] args)`; a Python driver `harness/tools/drive_windows_agent.py` with `--host`, `--port`, `--pairing`, `--fingerprint`, `--mode {session,nack,lockout}` and `--timeout`.

**Program parsing and startup run on Windows. The Python driver runs on the Mac (or on Windows with a venv there).**

- [ ] **Step 1: Write the failing test**

Add this test class to the end of `windows/SharedMic.Agent.Tests/ProjectSetupTests.cs`, after the existing `ProjectSetupTests` class:

```csharp
public class ProgramArgumentTests
{
    [Fact]
    public void DefaultsMatchTheContract()
    {
        var options = SharedMic.Agent.Program.ParseArguments(Array.Empty<string>());

        Assert.Equal(47800, options.Port);
        Assert.True(options.MicPresent);
        Assert.False(options.Headless);
        Assert.False(options.LoopbackOnly);
        Assert.Equal(TimeSpan.FromSeconds(5), options.HelloDeadline);
        Assert.Equal(TimeSpan.FromSeconds(45), options.PeerDeadTimeout);
        Assert.Empty(options.PairDevices);
        Assert.Null(options.RevokeDeviceId);
    }

    [Fact]
    public void ParsesEveryFlag()
    {
        var options = SharedMic.Agent.Program.ParseArguments(new[]
        {
            "--port", "47999",
            "--no-mic",
            "--device-label", "Samson Meteorite",
            "--data-dir", @"C:\temp\sharedmic",
            "--headless",
            "--loopback-only",
            "--revoke", "dev-0badcafe",
        });

        Assert.Equal(47999, options.Port);
        Assert.False(options.MicPresent);
        Assert.Equal("Samson Meteorite", options.DeviceLabel);
        Assert.Equal(@"C:\temp\sharedmic", options.DataDirectory);
        Assert.True(options.Headless);
        Assert.True(options.LoopbackOnly);
        Assert.Equal("dev-0badcafe", options.RevokeDeviceId);
    }

    /// <summary>
    /// Several Macs means several pairings, so --pair repeats. Order is kept so
    /// the printed pairing strings line up with the names the user gave.
    /// </summary>
    [Fact]
    public void PairFlagRepeatsOncePerMac()
    {
        var options = SharedMic.Agent.Program.ParseArguments(new[]
        {
            "--pair", "Mac Studio",
            "--pair", "MacBook Pro",
        });

        Assert.Equal(new[] { "Mac Studio", "MacBook Pro" }, options.PairDevices.ToArray());
    }

    [Fact]
    public void RejectsAnUnknownFlag()
    {
        Assert.Throws<ArgumentException>(() => SharedMic.Agent.Program.ParseArguments(new[] { "--wat" }));
    }

    [Fact]
    public void RejectsANonNumericPort()
    {
        Assert.Throws<ArgumentException>(() => SharedMic.Agent.Program.ParseArguments(new[] { "--port", "eleven" }));
    }

    [Fact]
    public void RejectsAFlagMissingItsValue()
    {
        Assert.Throws<ArgumentException>(() => SharedMic.Agent.Program.ParseArguments(new[] { "--port" }));
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~ProgramArgumentTests"
```

Expected: FAIL with `CS0234: The type or namespace name 'Program' does not exist in the namespace 'SharedMic.Agent'`.

`ProjectSetupTests.cs` needs `using System.Linq;` if `ImplicitUsings` has been turned off for any reason; with the `.csproj` from Task 1 it is already implicit.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Program.cs`:

```csharp
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Net;
using SharedMic.Agent.Security;
using SharedMic.Agent.Session;

namespace SharedMic.Agent;

public static class Program
{
    public static AgentOptions ParseArguments(string[] args)
    {
        var port = Protocol.ProtocolConstants.DefaultPort;
        var micPresent = true;
        var deviceLabel = "(no device selected)";
        var dataDirectory = IdentityStore.DefaultDirectory;
        var headless = false;
        var loopbackOnly = false;
        var pairDevices = new List<string>();
        string? revokeDeviceId = null;

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--port":
                    port = int.TryParse(Next(args, ref i, "--port"), out var parsed)
                        ? parsed
                        : throw new ArgumentException("--port expects an integer");
                    break;
                case "--no-mic":
                    micPresent = false;
                    break;
                case "--device-label":
                    deviceLabel = Next(args, ref i, "--device-label");
                    break;
                case "--data-dir":
                    dataDirectory = Next(args, ref i, "--data-dir");
                    break;
                case "--headless":
                    headless = true;
                    break;
                case "--loopback-only":
                    loopbackOnly = true;
                    break;
                case "--pair":
                    pairDevices.Add(Next(args, ref i, "--pair"));
                    break;
                case "--revoke":
                    revokeDeviceId = Next(args, ref i, "--revoke");
                    break;
                default:
                    throw new ArgumentException($"unknown argument '{args[i]}'");
            }
        }

        return new AgentOptions
        {
            Port = port,
            MicPresent = micPresent,
            DeviceLabel = deviceLabel,
            DataDirectory = dataDirectory,
            Headless = headless,
            LoopbackOnly = loopbackOnly,
            PairDevices = pairDevices,
            RevokeDeviceId = revokeDeviceId,
        };
    }

    [STAThread]
    public static int Main(string[] args)
    {
        AgentOptions options;
        try
        {
            options = ParseArguments(args);
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine(exception.Message);
            Console.Error.WriteLine(
                "usage: SharedMic.Agent [--port N] [--no-mic] [--device-label TEXT] " +
                "[--data-dir PATH] [--headless] [--loopback-only] [--pair NAME]... [--revoke DEVICE_ID]");
            return 2;
        }

        var identity = new IdentityStore(options.DataDirectory).LoadOrCreate();
        var devices = new PairedDeviceStore(options.DataDirectory);
        var metrics = new AgentMetrics();
        var rateLimiter = new AuthRateLimiter();
        var sessions = new SessionArbiter();

        ApplyDeviceCommands(devices, options);
        PrintBanner(identity, devices, options);

        var listener = new TlsListener(
            identity,
            options,
            devices,
            rateLimiter,
            sessions,
            metrics,
            (status, detail) => AgentLog.Info($"status: {status}{(detail is null ? string.Empty : $" ({detail})")}"));

        try
        {
            listener.Start();
        }
        catch (InvalidOperationException exception)
        {
            AgentLog.Error(exception.Message);
            return 1;
        }

        using var quit = new ManualResetEventSlim(false);
        Console.CancelKeyPress += (_, eventArgs) =>
        {
            eventArgs.Cancel = true;
            quit.Set();
        };

        AgentLog.Info("running. Press Ctrl+C to quit.");
        quit.Wait();

        AgentLog.Info($"final counters: {metrics.Snapshot()}");
        listener.DisposeAsync().AsTask().GetAwaiter().GetResult();
        return 0;
    }

    /// <summary>
    /// --revoke first, then --pair, then the first-run default. Revoking before
    /// pairing means "--revoke old --pair new" in one invocation does what it
    /// reads like.
    /// </summary>
    private static void ApplyDeviceCommands(PairedDeviceStore devices, AgentOptions options)
    {
        if (options.RevokeDeviceId is { } deviceId)
        {
            AgentLog.Info(devices.Revoke(deviceId)
                ? $"revoked paired device {deviceId}; it can no longer authenticate"
                : $"no paired device has id '{deviceId}'; nothing was revoked");
        }

        foreach (var name in options.PairDevices)
        {
            var device = devices.Pair(name);
            AgentLog.Info($"paired '{device.FriendlyName}' as {device.DeviceId}");
        }

        if (devices.Count == 0)
        {
            var device = devices.Pair("Mac 1");
            AgentLog.Info(
                $"no paired devices found, so '{device.FriendlyName}' ({device.DeviceId}) was created " +
                "for the first Mac. Use --pair NAME to add more.");
        }
    }

    private static void PrintBanner(AgentIdentity identity, PairedDeviceStore devices, AgentOptions options)
    {
        // Never print a raw token. A pairing string is the same secret in base32
        // and is meant for the user's eyes; the fingerprint is public by
        // construction.
        Console.WriteLine("shared-mic Windows agent, Phase 1 (transport and security only, no audio capture)");
        Console.WriteLine($"  serverId:       {identity.ServerId}");
        Console.WriteLine($"  port:           {options.Port}");
        Console.WriteLine($"  micPresent:     {options.MicPresent}");
        Console.WriteLine($"  deviceLabel:    {options.DeviceLabel}");
        Console.WriteLine($"  data directory: {options.DataDirectory}");
        Console.WriteLine($"  fingerprint:    {identity.Fingerprint}");
        Console.WriteLine($"  paired devices: {devices.Count} (one session at a time across all of them)");

        foreach (var device in devices.List())
        {
            Console.WriteLine(
                $"    {device.DeviceId}  {device.FriendlyName,-20}  paired {device.PairedAt:yyyy-MM-dd}");
            Console.WriteLine($"      pairing string: {device.PairingString}");
        }

        Console.WriteLine();
    }

    private static string Next(string[] args, ref int index, string flag)
    {
        if (index + 1 >= args.Length)
        {
            throw new ArgumentException($"{flag} expects a value");
        }

        return args[++index];
    }
}
```

`harness/tools/drive_windows_agent.py`:

```python
#!/usr/bin/env python3
"""Drive a real Windows agent from the mock Mac client.

This is the Phase 1 interoperability check: it points the Phase 0 reference
client at the C# agent and asserts the behavior protocol-v1.md requires of the
Windows side. It is a development tool, not part of the conformance suite.

Run it from `harness/` with the virtualenv interpreter explicitly:

    .venv/bin/python tools/drive_windows_agent.py \
        --host 192.168.1.50 --port 47800 \
        --pairing AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ \
        --fingerprint <the 64 hex characters the agent printed at startup> \
        --mode session

Modes:
    session  handshake, PING/PONG, idempotent START/STOP, zero audio bytes
    nack     assert START is answered with START_NACK (run the agent with --no-mic)
    lockout  five bad-token attempts, then assert even the correct token is
             refused, then assert it is accepted again after 30 seconds
    multi    two paired Macs at once: both authenticate, only one gets the
             session, the other is refused with SESSION_IN_USE, and the session
             is released when the holder's socket goes away. Needs a second
             pairing string via --second-pairing.

A caution about what this tool can and cannot prove. `MockMacClient` is a
faithful CLIENT, so `--mode multi` really does exercise the Windows agent's
arbitration. What it cannot check is the advisory `holder` field: the client
raises `SessionRejected(reason)` and drops the rest of the message. The holder
name is asserted by the C# tests instead. And nothing here can be replaced by
the conformance suite in `harness/tests` — `MockWindowsServer` gives every
connection its own session, so it would happily agree with a wrong agent.
"""

import argparse
import sys
import time

from sharedmic_protocol.auth import decode_pairing_string
from sharedmic_protocol.client import MockMacClient, SessionRejected
from sharedmic_protocol.tls import client_context

CONNECT_FAILURES = (ConnectionError, TimeoutError, OSError)


def connect(args, token, client_id="mock-mac"):
    client = MockMacClient(
        token,
        args.host,
        args.port,
        client_id=client_id,
        ssl_context=client_context(),
        expected_fingerprint=args.fingerprint,
    )
    hello_ack = client.connect(timeout=args.timeout)
    return client, hello_ack


def run_session(args, token):
    client, hello_ack = connect(args, token)
    try:
        print(f"HELLO_ACK          {hello_ack}")

        for seq in range(3):
            client.ping()
        print("PING/PONG x3       ok (each PONG carried the matching seq)")

        first = client.start_session()
        second = client.start_session()
        if first["sessionId"] != second["sessionId"]:
            raise SystemExit(
                f"FAIL duplicate START created a second session: "
                f"{first['sessionId']} then {second['sessionId']}"
            )
        if second["format"] != {"sampleRate": 48000, "channels": 1, "sampleFormat": "s16le"}:
            raise SystemExit(f"FAIL START_ACK format is not the fixed v1 format: {second['format']}")
        print(f"START idempotent   ok (sessionId={first['sessionId']})")

        time.sleep(2.0)
        if client.audio_frames_received != 0:
            raise SystemExit(
                f"FAIL Phase 1 must stream no audio, received {client.audio_frames_received} frames"
            )
        print("zero audio bytes   ok (2 s with an active session, nothing received)")

        client.stop_session()
        client.stop_session()
        print("STOP idempotent    ok (two STOP_ACKs)")

        client.ping()
        print("still healthy      ok (PING answered after two STOPs)")
    finally:
        client.close()

    print("\nPASS session checks")


def run_nack(args, token):
    client, hello_ack = connect(args, token)
    try:
        if hello_ack["micPresent"] is not False:
            raise SystemExit(
                "FAIL run the agent with --no-mic for this mode; HELLO_ACK reported micPresent=true"
            )
        try:
            client.start_session()
        except SessionRejected as rejected:
            if rejected.reason != "MIC_UNAVAILABLE":
                raise SystemExit(f"FAIL START_NACK reason was {rejected.reason!r}, expected MIC_UNAVAILABLE")
            print(f"START_NACK         ok (reason={rejected.reason})")
        else:
            raise SystemExit("FAIL START was accepted even though the agent reports no microphone")

        client.ping()
        print("still healthy      ok (a rejected START does not close the connection)")
    finally:
        client.close()

    print("\nPASS NACK checks")


def run_lockout(args, token):
    wrong = bytes(32)
    if wrong == token:
        wrong = bytes([1]) * 32

    for attempt in range(1, 6):
        try:
            client, _ = connect(args, wrong)
            client.close()
            raise SystemExit(f"FAIL attempt {attempt} with a wrong token authenticated")
        except CONNECT_FAILURES as failure:
            print(f"bad attempt {attempt}      refused ({type(failure).__name__})")

    try:
        client, _ = connect(args, token)
        client.close()
        raise SystemExit("FAIL the correct token authenticated during the 30 s lockout window")
    except CONNECT_FAILURES as failure:
        print(f"correct token      refused during lockout ({type(failure).__name__})  <- expected")

    print("waiting 31 s for the lockout to expire...")
    time.sleep(31)

    client, hello_ack = connect(args, token)
    client.close()
    print(f"after lockout      authenticated ok (serverId={hello_ack['serverId']})")

    print("\nPASS lockout checks")


def run_multi(args, token, second_token):
    """Two paired Macs, one session.

    The Windows agent must keep both connections authenticated, grant the
    session to exactly one of them, refuse the other with SESSION_IN_USE, and
    release the session when the holder's socket goes away without a STOP.
    """
    holder, holder_ack = connect(args, token, client_id="mock-mac-holder")
    other, other_ack = connect(args, second_token, client_id="mock-mac-other")
    try:
        print(f"both authenticated   ok (serverId={holder_ack['serverId']}, {other_ack['serverId']})")

        granted = holder.start_session()
        print(f"first START          ok (sessionId={granted['sessionId']})")

        try:
            other.start_session()
        except SessionRejected as rejected:
            if rejected.reason != "SESSION_IN_USE":
                raise SystemExit(
                    f"FAIL second START was refused with {rejected.reason!r}, expected SESSION_IN_USE"
                )
            print(f"second START         refused ({rejected.reason})  <- expected")
        else:
            raise SystemExit("FAIL two Macs were both given a session; there is only one microphone")

        holder.ping()
        other.ping()
        print("both still healthy   ok (a refusal does not close either connection)")

        # No STOP. This is what a crashed or sleeping Mac looks like.
        holder.close()
        print("holder disconnected  (no STOP sent, socket simply closed)")

        deadline = time.monotonic() + 10.0
        while True:
            try:
                taken = other.start_session()
                break
            except SessionRejected as rejected:
                if time.monotonic() > deadline:
                    raise SystemExit(
                        "FAIL the session was never released after the holder disconnected "
                        f"(still {rejected.reason})"
                    )
                time.sleep(0.25)

        if taken["sessionId"] == granted["sessionId"]:
            raise SystemExit("FAIL the second Mac was handed the first Mac's session id")
        print(f"second START retried ok (sessionId={taken['sessionId']})")

        other.stop_session()
    finally:
        other.close()
        holder.close()

    print("\nPASS multi-device checks")


def main(argv):
    parser = argparse.ArgumentParser(description="Drive a Windows shared-mic agent from the mock Mac client.")
    parser.add_argument("--host", required=True, help="the Windows host's address")
    parser.add_argument("--port", type=int, default=47800)
    parser.add_argument("--pairing", required=True, help="the pairing string the agent printed or the tray shows")
    parser.add_argument(
        "--second-pairing",
        help="a second paired device's pairing string; required for --mode multi",
    )
    parser.add_argument("--fingerprint", required=True, help="the 64-character lowercase hex fingerprint")
    parser.add_argument("--mode", choices=("session", "nack", "lockout", "multi"), default="session")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)

    token = decode_pairing_string(args.pairing)
    print(f"pairing string decoded to {len(token)} bytes")

    if args.mode == "session":
        run_session(args, token)
    elif args.mode == "nack":
        run_nack(args, token)
    elif args.mode == "multi":
        if not args.second_pairing:
            parser.error("--mode multi needs --second-pairing (pair a second Mac with --pair on the agent)")
        second_token = decode_pairing_string(args.second_pairing)
        if second_token == token:
            parser.error("--second-pairing must be a different device's pairing string")
        run_multi(args, token, second_token)
    else:
        run_lockout(args, token)

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [ ] **Step 4: Run and confirm it passes**

First the C# tests, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~ProgramArgumentTests"
```

Expected: PASS, 6 tests.

Then the interoperability run. **On Windows**, start the agent with two paired Macs and leave it running:

```powershell
dotnet run --project SharedMic.Agent -- --headless --device-label "USB Microphone" --pair "Mac Studio" --pair "MacBook Pro"
```

Expected: a banner listing `serverId`, `port: 47800`, the 64-character `fingerprint`, `paired devices: 2`, and for each device a `dev-XXXXXXXX` id, its name, and its 58-character pairing string — then one `listening on <address>:47800 (private interfaces only)` line per private interface. Copy the fingerprint and both pairing strings, and note one of the listed non-loopback addresses.

Note that `--pair` mints a device every time it runs. Pass it once per Mac, then restart the agent without it; the banner reprints the stored devices.

**On the Mac**, from `harness/`, run all three modes. Replace `<host>`, `<pairing>` and `<fingerprint>` with the values from the banner:

```sh
cd harness
.venv/bin/python tools/drive_windows_agent.py --host <host> --port 47800 --pairing <pairing> --fingerprint <fingerprint> --mode session
```

Expected: the run ends with `PASS session checks`, having printed `HELLO_ACK`, `PING/PONG x3 ok`, `START idempotent ok`, `zero audio bytes ok`, `STOP idempotent ok` and `still healthy ok`.

Stop the agent (Ctrl+C), restart it with `--no-mic`, and run:

```powershell
dotnet run --project SharedMic.Agent -- --headless --no-mic
```

```sh
cd harness
.venv/bin/python tools/drive_windows_agent.py --host <host> --port 47800 --pairing <pairing> --fingerprint <fingerprint> --mode nack
```

Expected: `PASS NACK checks`.

Restart the agent without `--no-mic`, then run the lockout mode. It deliberately takes about 40 seconds:

```sh
cd harness
.venv/bin/python tools/drive_windows_agent.py --host <host> --port 47800 --pairing <pairing> --fingerprint <fingerprint> --mode lockout
```

Expected: five `bad attempt N refused` lines, one `correct token refused during lockout` line, and `PASS lockout checks`. On the agent's console, expect five `authentication ... failed: no paired device's token produced this proof` lines with the fifth carrying `<mac-address> is now locked out for 30 s`, then one `authentication ... refused: <mac-address> is locked out for another N s`. The address in those lines is the Mac's, not the agent's — that is the per-source keying working.

Then the multi-device run, which is the interoperability evidence for the whole one-session rule. Use **both** pairing strings from the banner:

```sh
cd harness
.venv/bin/python tools/drive_windows_agent.py --host <host> --port 47800 \
    --pairing <first-pairing> --second-pairing <second-pairing> \
    --fingerprint <fingerprint> --mode multi
```

Expected: `both authenticated ok`, `first START ok`, `second START refused (SESSION_IN_USE)`, `both still healthy ok`, `holder disconnected`, `second START retried ok` with a **different** `sessionId`, and `PASS multi-device checks`. On the agent's console, expect a `START ... refused: 'Mac Studio' holds the session` line and, after the holder's socket closes, `went away while holding the session; the session is released and another paired Mac may take it`.

If the retry loop times out with `FAIL the session was never released after the holder disconnected`, the connection-close teardown in Task 14 is not wired up — that is the exact bug this mode exists to catch, and no test in `harness/tests` would have caught it.

Finally, prove the pin is the trust anchor by running with a deliberately wrong fingerprint:

```sh
cd harness
.venv/bin/python tools/drive_windows_agent.py --host <host> --port 47800 --pairing <pairing> --fingerprint 0000000000000000000000000000000000000000000000000000000000000000 --mode session
```

Expected: the driver raises `sharedmic_protocol.client.FingerprintMismatch: server certificate fingerprint does not match the pinned value` and exits non-zero, with no `HELLO` ever sent.

Confirm the harness's own suite is still green, since this task added a file under `harness/`:

```sh
cd harness
.venv/bin/python -m pytest -q
```

Expected: 101 passed.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Program.cs windows/SharedMic.Agent.Tests/ProjectSetupTests.cs harness/tools/drive_windows_agent.py
git commit -m "Phase 1 Task 16: headless agent host and Python interoperability driver"
```

---

### Task 17: Tray UI and project documentation

**Files:**
- Create: `windows/SharedMic.Agent/Ui/TrayApp.cs`
- Modify: `windows/SharedMic.Agent/Program.cs`
- Modify: `CLAUDE.md`
- Test: `windows/SharedMic.Agent.Tests/TrayAppTests.cs`

**Interfaces:**
- Consumes: `AgentStatus`, `AgentIdentity.ServerId` / `.Fingerprint`, `AgentOptions`, `PairedDevice`, `PairedDeviceStore.List()` / `Pair(string)` / `Revoke(string)` / `Count`, `TlsListener.SessionHolderDeviceId`, `AgentLog`, `AgentMetrics`, `AuthRateLimiter`, `IdentityStore`, `SessionArbiter`.
- Produces: `sealed class TrayApp : ApplicationContext` with constructor `TrayApp(AgentIdentity identity, PairedDeviceStore devices, Func<string?> sessionHolderDeviceId, AgentOptions options, Func<Task> onQuitAsync)`, members `static string FormatStatus(AgentStatus status, string? detail)`, `static string FormatDevice(PairedDevice device, string? holderDeviceId)`, `void SetStatus(AgentStatus status, string? detail)`, `void RefreshDevices()`; `Program.Main` updated to run the tray unless `--headless`.

The tray is where "several paired Macs" becomes visible to a person: it lists every paired device, marks the one holding the session, offers each device's pairing string, revokes any of them, and pairs a new one.

**This task runs on Windows.** The last step is a manual visual check, because a `NotifyIcon` cannot be asserted on meaningfully in a headless test run — so the two pure formatting functions carry the automated coverage.

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/TrayAppTests.cs`:

```csharp
using SharedMic.Agent;
using SharedMic.Agent.Security;
using SharedMic.Agent.Ui;
using Xunit;

namespace SharedMic.Agent.Tests;

public class TrayAppTests
{
    private static PairedDevice Device(string id, string name) =>
        new(id, name, new byte[32], new DateTimeOffset(2026, 8, 10, 12, 0, 0, TimeSpan.Zero));

    [Fact]
    public void MarksTheDeviceThatHoldsTheSession()
    {
        var studio = Device("dev-aaaaaaaa", "Mac Studio");
        var laptop = Device("dev-bbbbbbbb", "MacBook Pro");

        Assert.Equal("Mac Studio  — using the mic", TrayApp.FormatDevice(studio, "dev-aaaaaaaa"));
        Assert.Equal("MacBook Pro", TrayApp.FormatDevice(laptop, "dev-aaaaaaaa"));
        Assert.Equal("Mac Studio", TrayApp.FormatDevice(studio, null));
    }

    /// <summary>
    /// Two Macs can share a friendly name; the mark follows the device id, not
    /// the label, so only one row is ever marked.
    /// </summary>
    [Fact]
    public void TheHolderMarkFollowsTheDeviceIdNotTheName()
    {
        var first = Device("dev-aaaaaaaa", "Mac");
        var second = Device("dev-bbbbbbbb", "Mac");

        Assert.Equal("Mac  — using the mic", TrayApp.FormatDevice(first, "dev-aaaaaaaa"));
        Assert.Equal("Mac", TrayApp.FormatDevice(second, "dev-aaaaaaaa"));
    }

    [Fact]
    public void FormatsTheThreeStatusesPhase1CanReach()
    {
        Assert.Equal("Status: Disconnected", TrayApp.FormatStatus(AgentStatus.Disconnected, null));
        Assert.Equal("Status: Idle", TrayApp.FormatStatus(AgentStatus.Idle, null));
        Assert.Equal("Status: Error", TrayApp.FormatStatus(AgentStatus.Error, null));
    }

    [Fact]
    public void IncludesADetailWhenOneIsGiven()
    {
        Assert.Equal(
            "Status: Error (no private interface accepted a bind on port 47800)",
            TrayApp.FormatStatus(AgentStatus.Error, "no private interface accepted a bind on port 47800"));

        Assert.Equal(
            "Status: Idle (2 connected, Mac Studio active)",
            TrayApp.FormatStatus(AgentStatus.Idle, "2 connected, Mac Studio active"));
    }

    [Fact]
    public void TreatsAnEmptyDetailAsNoDetail()
    {
        Assert.Equal("Status: Idle", TrayApp.FormatStatus(AgentStatus.Idle, ""));
        Assert.Equal("Status: Idle", TrayApp.FormatStatus(AgentStatus.Idle, "   "));
    }

    [Fact]
    public void NotifyIconTextStaysWithinTheWindowsLimit()
    {
        // NotifyIcon.Text throws above 63 characters, and a long device label
        // or bind error is exactly how that happens in the field.
        var text = TrayApp.FormatStatus(AgentStatus.Error, new string('x', 200));

        Assert.True(text.Length <= 63, $"tray text was {text.Length} characters");
        Assert.StartsWith("Status: Error (", text);
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~TrayAppTests"
```

Expected: FAIL with `CS0234: The type or namespace name 'Ui' does not exist in the namespace 'SharedMic.Agent'`.

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Ui/TrayApp.cs`:

```csharp
using System.Drawing;
using System.Windows.Forms;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Security;

namespace SharedMic.Agent.Ui;

/// <summary>
/// The minimal Phase 1 tray: current status, the paired Macs and which of them
/// is using the microphone, each one's pairing string, revoke, pair-a-new-one,
/// and quit. Design spec section 11's full status list and diagnostics view
/// arrive with the audio path and automatic demand; there is no device picker
/// or level meter here because there is no capture path to feed one.
///
/// Never show or copy a raw token, only a pairing string.
/// </summary>
public sealed class TrayApp : ApplicationContext
{
    private const int MaxNotifyIconTextLength = 63;

    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _devicesItem;
    private readonly PairedDeviceStore _devices;
    private readonly Func<string?> _sessionHolderDeviceId;
    private readonly Func<Task> _onQuitAsync;

    public TrayApp(
        AgentIdentity identity,
        PairedDeviceStore devices,
        Func<string?> sessionHolderDeviceId,
        AgentOptions options,
        Func<Task> onQuitAsync)
    {
        _devices = devices;
        _sessionHolderDeviceId = sessionHolderDeviceId;
        _onQuitAsync = onQuitAsync;

        _statusItem = new ToolStripMenuItem(FormatStatus(AgentStatus.Disconnected, null)) { Enabled = false };
        _devicesItem = new ToolStripMenuItem("Paired Macs");

        var pairNew = new ToolStripMenuItem("Pair a new Mac...");
        pairNew.Click += (_, _) => PairNewDevice();

        var fingerprintHeader = new ToolStripMenuItem("Certificate fingerprint (click to copy)") { Enabled = false };
        var fingerprintValue = new ToolStripMenuItem(identity.Fingerprint);
        fingerprintValue.Click += (_, _) =>
        {
            Clipboard.SetText(identity.Fingerprint);
            AgentLog.Info("certificate fingerprint copied to the clipboard");
        };

        var quit = new ToolStripMenuItem("Quit");
        quit.Click += async (_, _) => await QuitAsync();

        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(_devicesItem);
        menu.Items.Add(pairNew);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(fingerprintHeader);
        menu.Items.Add(fingerprintValue);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quit);

        // Rebuild the device list every time the menu opens, so the "using the
        // mic" mark is current without polling.
        menu.Opening += (_, _) => RefreshDevices();

        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = FormatStatus(AgentStatus.Disconnected, null),
            ContextMenuStrip = menu,
            Visible = true,
            BalloonTipTitle = "shared-mic",
            BalloonTipText =
                $"Listening on port {options.Port}. Pair each Mac from this menu; " +
                "one of them uses the microphone at a time.",
        };

        RefreshDevices();
    }

    /// <summary>
    /// Tray label text. Clamped to 63 characters because NotifyIcon.Text throws
    /// above that, and a long bind error is exactly how that happens.
    /// </summary>
    public static string FormatStatus(AgentStatus status, string? detail)
    {
        var text = string.IsNullOrWhiteSpace(detail)
            ? $"Status: {status}"
            : $"Status: {status} ({detail})";

        if (text.Length > MaxNotifyIconTextLength)
        {
            text = text.Substring(0, MaxNotifyIconTextLength - 3) + "...";
        }

        return text;
    }

    /// <summary>
    /// One row of the paired-Macs submenu. The holder mark is matched on device
    /// id, not on the friendly name, because two Macs may share a name.
    /// </summary>
    public static string FormatDevice(PairedDevice device, string? holderDeviceId) =>
        string.Equals(device.DeviceId, holderDeviceId, StringComparison.Ordinal)
            ? $"{device.FriendlyName}  — using the mic"
            : device.FriendlyName;

    /// <summary>Rebuild the paired-Macs submenu from the store. UI thread only.</summary>
    public void RefreshDevices()
    {
        var holder = _sessionHolderDeviceId();

        _devicesItem.DropDownItems.Clear();

        var paired = _devices.List();
        if (paired.Count == 0)
        {
            _devicesItem.DropDownItems.Add(new ToolStripMenuItem("(none yet)") { Enabled = false });
            return;
        }

        foreach (var device in paired)
        {
            var row = new ToolStripMenuItem(FormatDevice(device, holder));

            var copyPairing = new ToolStripMenuItem("Copy pairing string");
            copyPairing.Click += (_, _) =>
            {
                Clipboard.SetText(device.PairingString);
                AgentLog.Info($"pairing string for '{device.FriendlyName}' copied to the clipboard");
            };

            var revoke = new ToolStripMenuItem("Revoke this Mac...");
            revoke.Click += (_, _) => RevokeDevice(device);

            row.DropDownItems.Add(new ToolStripMenuItem($"Paired {device.PairedAt:yyyy-MM-dd HH:mm}") { Enabled = false });
            row.DropDownItems.Add(new ToolStripMenuItem(device.DeviceId) { Enabled = false });
            row.DropDownItems.Add(new ToolStripSeparator());
            row.DropDownItems.Add(copyPairing);
            row.DropDownItems.Add(revoke);

            _devicesItem.DropDownItems.Add(row);
        }
    }

    private void PairNewDevice()
    {
        var name = PromptForName();
        if (name is null)
        {
            return;
        }

        var device = _devices.Pair(name);
        RefreshDevices();
        Clipboard.SetText(device.PairingString);
        AgentLog.Info($"paired '{device.FriendlyName}' as {device.DeviceId}");

        MessageBox.Show(
            $"Paired '{device.FriendlyName}'.\n\nPairing string (already copied to the clipboard):\n\n" +
            $"{device.PairingString}\n\nType it into that Mac's SharedMic menu.",
            "shared-mic",
            MessageBoxButtons.OK,
            MessageBoxIcon.Information);
    }

    private void RevokeDevice(PairedDevice device)
    {
        var confirmed = MessageBox.Show(
            $"Revoke '{device.FriendlyName}'?\n\nThat Mac will no longer be able to connect, and " +
            "pairing it again means a new pairing string.",
            "shared-mic",
            MessageBoxButtons.YesNo,
            MessageBoxIcon.Warning);

        if (confirmed != DialogResult.Yes)
        {
            return;
        }

        if (_devices.Revoke(device.DeviceId))
        {
            AgentLog.Info($"revoked '{device.FriendlyName}' ({device.DeviceId})");
        }

        RefreshDevices();
    }

    /// <summary>
    /// WinForms has no input box, and a whole dialog class for one field would
    /// be worse than this. Returns null when the user cancels or enters nothing.
    /// </summary>
    private static string? PromptForName()
    {
        using var form = new Form
        {
            Text = "Pair a new Mac",
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            ClientSize = new Size(360, 120),
            MinimizeBox = false,
            MaximizeBox = false,
        };

        var label = new Label
        {
            Text = "Name for this Mac (shown when it is using the mic):",
            AutoSize = true,
            Location = new Point(12, 15),
        };

        var input = new TextBox { Location = new Point(12, 40), Width = 336 };
        var ok = new Button { Text = "Pair", DialogResult = DialogResult.OK, Location = new Point(192, 75), Width = 75 };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Location = new Point(273, 75), Width = 75 };

        form.Controls.Add(label);
        form.Controls.Add(input);
        form.Controls.Add(ok);
        form.Controls.Add(cancel);
        form.AcceptButton = ok;
        form.CancelButton = cancel;

        if (form.ShowDialog() != DialogResult.OK)
        {
            return null;
        }

        var name = input.Text.Trim();
        return name.Length == 0 ? null : name;
    }

    /// <summary>Safe to call from any thread; marshals onto the UI thread when needed.</summary>
    public void SetStatus(AgentStatus status, string? detail)
    {
        var text = FormatStatus(status, detail);

        void Apply()
        {
            _statusItem.Text = text;
            _icon.Text = text;
        }

        if (_icon.ContextMenuStrip is { InvokeRequired: true } menu)
        {
            menu.BeginInvoke(Apply);
        }
        else
        {
            Apply();
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _icon.Visible = false;
            _icon.Dispose();
        }

        base.Dispose(disposing);
    }

    private async Task QuitAsync()
    {
        AgentLog.Info("quit requested from the tray");
        _icon.Visible = false;
        await _onQuitAsync();
        ExitThread();
    }
}
```

Replace `windows/SharedMic.Agent/Program.cs` in full with this version, which keeps `ParseArguments` unchanged and adds the tray host:

```csharp
using System.Windows.Forms;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Net;
using SharedMic.Agent.Security;
using SharedMic.Agent.Session;
using SharedMic.Agent.Ui;

namespace SharedMic.Agent;

public static class Program
{
    public static AgentOptions ParseArguments(string[] args)
    {
        var port = Protocol.ProtocolConstants.DefaultPort;
        var micPresent = true;
        var deviceLabel = "(no device selected)";
        var dataDirectory = IdentityStore.DefaultDirectory;
        var headless = false;
        var loopbackOnly = false;
        var pairDevices = new List<string>();
        string? revokeDeviceId = null;

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--port":
                    port = int.TryParse(Next(args, ref i, "--port"), out var parsed)
                        ? parsed
                        : throw new ArgumentException("--port expects an integer");
                    break;
                case "--no-mic":
                    micPresent = false;
                    break;
                case "--device-label":
                    deviceLabel = Next(args, ref i, "--device-label");
                    break;
                case "--data-dir":
                    dataDirectory = Next(args, ref i, "--data-dir");
                    break;
                case "--headless":
                    headless = true;
                    break;
                case "--loopback-only":
                    loopbackOnly = true;
                    break;
                case "--pair":
                    pairDevices.Add(Next(args, ref i, "--pair"));
                    break;
                case "--revoke":
                    revokeDeviceId = Next(args, ref i, "--revoke");
                    break;
                default:
                    throw new ArgumentException($"unknown argument '{args[i]}'");
            }
        }

        return new AgentOptions
        {
            Port = port,
            MicPresent = micPresent,
            DeviceLabel = deviceLabel,
            DataDirectory = dataDirectory,
            Headless = headless,
            LoopbackOnly = loopbackOnly,
            PairDevices = pairDevices,
            RevokeDeviceId = revokeDeviceId,
        };
    }

    [STAThread]
    public static int Main(string[] args)
    {
        AgentOptions options;
        try
        {
            options = ParseArguments(args);
        }
        catch (ArgumentException exception)
        {
            Console.Error.WriteLine(exception.Message);
            Console.Error.WriteLine(
                "usage: SharedMic.Agent [--port N] [--no-mic] [--device-label TEXT] " +
                "[--data-dir PATH] [--headless] [--loopback-only] [--pair NAME]... [--revoke DEVICE_ID]");
            return 2;
        }

        var identity = new IdentityStore(options.DataDirectory).LoadOrCreate();
        var devices = new PairedDeviceStore(options.DataDirectory);
        var metrics = new AgentMetrics();
        var rateLimiter = new AuthRateLimiter();
        var sessions = new SessionArbiter();

        ApplyDeviceCommands(devices, options);
        PrintBanner(identity, devices, options);

        TrayApp? tray = null;
        var listener = new TlsListener(
            identity,
            options,
            devices,
            rateLimiter,
            sessions,
            metrics,
            (status, detail) =>
            {
                AgentLog.Info($"status: {status}{(string.IsNullOrWhiteSpace(detail) ? string.Empty : $" ({detail})")}");
                tray?.SetStatus(status, detail);
            });

        try
        {
            listener.Start();
        }
        catch (InvalidOperationException exception)
        {
            AgentLog.Error(exception.Message);
            tray?.SetStatus(AgentStatus.Error, exception.Message);
            return 1;
        }

        if (options.Headless)
        {
            using var quit = new ManualResetEventSlim(false);
            Console.CancelKeyPress += (_, eventArgs) =>
            {
                eventArgs.Cancel = true;
                quit.Set();
            };

            AgentLog.Info("running headless. Press Ctrl+C to quit.");
            quit.Wait();
        }
        else
        {
            ApplicationConfiguration.Initialize();
            tray = new TrayApp(
                identity,
                devices,
                () => listener.SessionHolderDeviceId,
                options,
                async () =>
                {
                    AgentLog.Info($"final counters: {metrics.Snapshot()}");
                    await listener.DisposeAsync();
                });
            tray.SetStatus(AgentStatus.Disconnected, $"port {options.Port}");

            AgentLog.Info("running with a tray icon. Use the tray menu to quit.");
            Application.Run(tray);
            return 0;
        }

        AgentLog.Info($"final counters: {metrics.Snapshot()}");
        listener.DisposeAsync().AsTask().GetAwaiter().GetResult();
        return 0;
    }

    /// <summary>
    /// --revoke first, then --pair, then the first-run default. Revoking before
    /// pairing means "--revoke old --pair new" in one invocation does what it
    /// reads like.
    /// </summary>
    private static void ApplyDeviceCommands(PairedDeviceStore devices, AgentOptions options)
    {
        if (options.RevokeDeviceId is { } deviceId)
        {
            AgentLog.Info(devices.Revoke(deviceId)
                ? $"revoked paired device {deviceId}; it can no longer authenticate"
                : $"no paired device has id '{deviceId}'; nothing was revoked");
        }

        foreach (var name in options.PairDevices)
        {
            var device = devices.Pair(name);
            AgentLog.Info($"paired '{device.FriendlyName}' as {device.DeviceId}");
        }

        if (devices.Count == 0)
        {
            var device = devices.Pair("Mac 1");
            AgentLog.Info(
                $"no paired devices found, so '{device.FriendlyName}' ({device.DeviceId}) was created " +
                "for the first Mac. Use --pair NAME or the tray to add more.");
        }
    }

    private static void PrintBanner(AgentIdentity identity, PairedDeviceStore devices, AgentOptions options)
    {
        // Never print a raw token. A pairing string is the same secret in base32
        // and is meant for the user's eyes; the fingerprint is public by
        // construction.
        Console.WriteLine("shared-mic Windows agent, Phase 1 (transport and security only, no audio capture)");
        Console.WriteLine($"  serverId:       {identity.ServerId}");
        Console.WriteLine($"  port:           {options.Port}");
        Console.WriteLine($"  micPresent:     {options.MicPresent}");
        Console.WriteLine($"  deviceLabel:    {options.DeviceLabel}");
        Console.WriteLine($"  data directory: {options.DataDirectory}");
        Console.WriteLine($"  fingerprint:    {identity.Fingerprint}");
        Console.WriteLine($"  paired devices: {devices.Count} (one session at a time across all of them)");

        foreach (var device in devices.List())
        {
            Console.WriteLine(
                $"    {device.DeviceId}  {device.FriendlyName,-20}  paired {device.PairedAt:yyyy-MM-dd}");
            Console.WriteLine($"      pairing string: {device.PairingString}");
        }

        Console.WriteLine();
    }

    private static string Next(string[] args, ref int index, string flag)
    {
        if (index + 1 >= args.Length)
        {
            throw new ArgumentException($"{flag} expects a value");
        }

        return args[++index];
    }
}
```

Then replace the `## Commands` section of the repository root `CLAUDE.md` — the whole block from the `## Commands` heading down to but not including `## Design constraints that are not negotiable` — with this. Every command below must have actually been run before it is written here:

````markdown
## Commands

The macOS agent project is created in a later phase; there is nothing to build for it yet. The
protocol harness, both Phase 0 probes, and the Phase 1 Windows agent exist now.

**Windows agent (from `windows\`, on the Windows host).** Requires the .NET 10 SDK. The
`net10.0-windows` target framework means these do not run on the Mac, which has only .NET 6.

```powershell
dotnet build SharedMic.Windows.sln
dotnet test SharedMic.Windows.sln
dotnet run --project SharedMic.Agent                             # tray icon plus a console log
dotnet run --project SharedMic.Agent -- --headless               # console only, Ctrl+C to quit
dotnet run --project SharedMic.Agent -- --pair "Mac Studio"      # add a Mac and print its pairing string
dotnet run --project SharedMic.Agent -- --revoke dev-0badcafe    # remove one Mac; the others keep working
```

Several Macs can be paired and connected at once; **one of them holds the microphone session at a
time**, and a `START` from any other is answered `START_NACK{reason:"SESSION_IN_USE"}`. A session
ends when its connection ends, so a Mac that crashes does not lock the others out.

The `.csproj` files are XML: **never put a doubled hyphen inside an XML comment.** It is illegal
XML and fails the build with `MSB4025`.

**Harness (from `harness/`).** There is no bare `python` on the Mac and the system `python3` has no
`pytest` installed — use the project virtualenv's interpreter explicitly. Note the leading dot in
`.venv`; a stale `harness/venv` also exists and is not usable.

```sh
cd harness
.venv/bin/python -m pytest -v                 # the conformance suite (101 tests)
.venv/bin/python tools/generate_vectors.py    # regenerate protocol/vectors/*.json, a deliberate act
.venv/bin/python tools/drive_windows_agent.py --host <windows-host> --port 47800 \
    --pairing <pairing-string> --fingerprint <hex> --mode session
```

`drive_windows_agent.py` points the mock Mac client at a running Windows agent. Its `--mode` values
are `session` (handshake, heartbeat, idempotent START/STOP, zero audio bytes), `nack` (run the agent
with `--no-mic`), `lockout` (five bad-token attempts then the 30-second refusal), and `multi` (two
paired Macs, one session, release on disconnect — needs `--second-pairing`).

**The conformance suite does not cover multi-device behaviour.** `MockWindowsServer` keeps one token
and gives every connection its own session, so paired-device identification, `SESSION_IN_USE`, and
release-on-disconnect are covered by the C# tests and by `--mode multi`, not by `pytest`.

**macOS demand-detection probe (from `probes/macos-demand/`).** Built and run on the target Mac
(macOS 26.6.1); see `docs/superpowers/probes/2026-08-08-macos-demand-findings.md`:

```sh
cd probes/macos-demand
swiftc -O -o demand-probe DemandProbe.swift
./demand-probe --self-test   # automated; ./demand-probe --watch for live manual observation
```

**Windows WASAPI latency probe (from `probes/windows-wasapi-latency/`).** Windows-only; see
`docs/superpowers/probes/2026-08-08-windows-wasapi-findings.md`:

```powershell
cd probes\windows-wasapi-latency\WasapiLatencyProbe
dotnet build --no-incremental
dotnet run --project WasapiLatencyProbe -- 20
```
````

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~TrayAppTests"
```

Expected: PASS, 6 tests.

Then the full suite, which is the end-of-batch build and test for the whole phase:

```powershell
dotnet build SharedMic.Windows.sln
dotnet test SharedMic.Windows.sln
```

Expected: `Build succeeded. 0 Warning(s) 0 Error(s)`, then all tests passing — 2 (Task 1) + 11 (2) + 7 (3) + 21 (4) + 32 (5) + 15 (6) + 14 (7) + 12 (8) + 18 (9) + 12 (10) + 7 (11) + 8 (12) + 14 (13) + 29 (14) + 24 (15) + 6 (16) + 6 (17) = **238 tests**.

Then the manual tray check, on Windows:

```powershell
dotnet run --project SharedMic.Agent
```

Confirm each of the following by looking at the screen, and record the result:

1. A tray icon appears in the notification area.
2. Hovering it shows `Status: Disconnected (port 47800)`.
3. Right-clicking shows: a disabled status line, a `Paired Macs` submenu, `Pair a new Mac...`, the certificate fingerprint, and `Quit`.
4. `Paired Macs` lists every device the console banner printed, by the name it was given.
5. `Pair a new Mac...` asks for a name, then shows the new 58-character pairing string and copies it to the clipboard. The device appears in `Paired Macs` immediately, and the console logs `paired '<name>' as dev-XXXXXXXX`.
6. Opening a device's submenu offers `Copy pairing string` and `Revoke this Mac...`. Copy one and paste it somewhere to confirm it matches the banner.
7. With the agent still running, complete a `--mode multi` run from the Mac (command in Task 16). While both clients are connected the tray hover text reads `Status: Idle (2 connected, ...)`, and while one holds the session that device's row is marked `— using the mic`. After the driver exits it returns to `Status: Disconnected`.
8. `Revoke this Mac...` asks for confirmation, removes the row, and logs `revoked '<name>'`. Re-running the driver with that device's pairing string now fails to authenticate.
9. `Quit` removes the icon and exits the process; the console prints `final counters:` with a non-zero `ConnectionsAuthenticated` and a non-zero `SessionsRefusedAsInUse`.

Finally confirm the harness suite is untouched, from the Mac:

```sh
cd harness
.venv/bin/python -m pytest -q
```

Expected: 101 passed.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Ui/TrayApp.cs windows/SharedMic.Agent/Program.cs windows/SharedMic.Agent.Tests/TrayAppTests.cs CLAUDE.md
git commit -m "Phase 1 Task 17: tray UI with paired devices, session holder, revoke and pair; document Phase 1 commands"
```

---

## Phase 1 scope coverage

Each item of the Phase 1 scope list and the task that implements it:

| Scope item | Task |
|---|---|
| TLS 1.3 listener on TCP 47800, private interfaces only | 15 (`TlsListener`, `PrivateAddress`) |
| Self-signed P-256 device certificate at first run, SAN required | 12 (`DeviceCertificate`) |
| Private key DPAPI-protected | 12 (`IdentityStore`) |
| 256-bit pairing token per paired device, generated and persisted | 13 (`PairedDeviceStore`), 6 (`PairingToken.Generate`) |
| Every token DPAPI-protected at rest | 13 (`PairedDeviceStore.Save`) |
| Several paired Macs, individually revocable | 13 (`Pair`, `Revoke`), 16 (`--pair`, `--revoke`), 17 (tray) |
| Identification by proof alone, no lookup key, `clientId` untrusted | 13 (`Identify`), 14 (`TryAuthenticate`) |
| Pairing string displayed | 6 (encoding), 16 (console banner), 17 (tray menu, per device) |
| `GREETING` → `HELLO` → `HELLO_ACK` with HMAC-SHA256 challenge-response | 14 (`ControlConnection.TryAuthenticate`), 6 (`AuthProof`) |
| 5-second pre-auth deadline | 14 (`ReadLoopAsync`) |
| 5-attempt / 30-second lockout, keyed per source address | 7 (`AuthRateLimiter`), 14 (wired in and counted), 16 (`--mode lockout`) |
| Frame envelope codec byte-matching the vectors | 2, 5 |
| Control-message codec byte-matching the vectors | 4, 5 |
| Audio payload codec byte-matching the vectors | 3, 5 |
| Priority send queue: unbounded control, 25-frame drop-oldest audio | 10, 14 (teardown discard) |
| Session state machine, idempotent `START`/`STOP` | 8, 14 |
| One session across all connections, `SESSION_IN_USE` with the holder's name | 9 (`SessionArbiter`), 4 (`StartNack` advisory field), 14, 15 |
| A session ends when its connection ends, including on dead-peer | 9 (`EndSessionOwnedBy`), 14 (`RunAsync` finally) |
| Heartbeat: `PONG` with matching `seq` | 14 |
| Dead-peer detection at 45 s | 14 (`LivenessLoopAsync`) |
| Tray: status, paired Macs, session holder, pair, revoke, quit | 17 |
| Verifiable against `MockMacClient` | 16 (`session`, `nack`, `lockout`, `multi`, plus the fingerprint-mismatch check) |

## Explicitly out of scope for Phase 1

Stated here so a reviewer does not read an omission as an oversight:

- **All audio capture.** No WASAPI, no `MicCaptureService`, no `PcmNormalizer`, no `DeviceManager`, no device enumeration, no level meter. `AudioPayloadCodec` and `PrioritySendQueue.EnqueueAudio` exist and are tested, but nothing calls them on a live connection. A `START` returns `START_ACK` and streams nothing.
- **Device selection.** `micPresent` and `deviceLabel` are configuration flags (`--no-mic`, `--device-label`), not device queries.
- **Telling a refused Mac when the session frees up.** A `START_NACK{SESSION_IN_USE}` is a one-shot answer; there is no queue and no push notification when the holder releases. The refused Mac retries. Phase 2's `STATUS` is the natural carrier for "the mic is free now", and this plan deliberately does not invent a twelfth message type for it.
- **Renaming a paired device.** Names are set at pairing time. Renaming is a tray convenience, not a Phase 1 requirement; revoke and re-pair achieves it.
- **`STATUS` emission.** The message type, its factory and its vector coverage all exist, but Phase 1 has no device watcher to trigger a hot-unplug or replug, so the agent never sends one.
- **Launch at login**, the **diagnostics view**, and **mDNS/Bonjour discovery** — Phase 4.
- **The macOS agent.** Phase 1 of the design spec covers both ends; this plan is the Windows half. The Mac's `START`/`STOP` response timers (2 s / 1 s), reconnect with exponential backoff, and Keychain storage are Mac-side and are not implemented here.
- **Windows Firewall rule creation.** Spec §7.3 calls for a Private-profile rule. Creating it needs elevation, so Phase 1 binds correctly and leaves the rule to a manual step or a later packaging task; note it in the Phase 1 report rather than adding an elevation prompt.
- **Signing and packaging.** `dotnet run` is the Phase 1 delivery mechanism.

## Contract observations found while planning

Points in `protocol/protocol-v1.md` that a reader must resolve before implementing, recorded here so the choices this plan makes are visible rather than buried:

1. **§8 does not say whether Windows sends `PING`.** The table's `PING` row says the Mac sends it and that "Windows applies the same 15 s interval and dead-peer rule to *absent* `PING`s", while §5 states the direction as Mac → Windows only. This plan reads it as: Windows never sends `PING`, and monitors peer silence instead. `ProtocolConstants.HeartbeatInterval` is therefore defined but unused by the Windows agent in Phase 1.
2. **What "45 s without a `PONG`" means for the side that does not send `PING`.** The plan measures 45 s of silence from the peer, resetting on any received frame, which is the only reading available to a side that receives `PING`s rather than sending them.
3. **The contract does not say what to do with a well-formed but wrong-direction control message after authentication** — for example a `GREETING` or a `START_ACK` arriving from the Mac. The reference `MockWindowsServer._handle` silently ignores anything that is not `PING`/`START`/`STOP`. This plan matches that (log, count, do not close) rather than closing, to avoid an interoperability hazard over behavior the contract does not specify. §11.4's counter and §3's close rules are unaffected.
4. **§7's `STOP_ACK{sessionId}` is ambiguous when no session is active.** "the session that was ended" has no referent. The reference server sends `ended or msg["sessionId"]`, i.e. it echoes the request's `sessionId`. This plan does the same, and `SessionStateMachine.HandleStop` takes the requested identifier for exactly that reason.
5. **§11.4 does not say whether the lockout window resets the consecutive-failure count or extends on further attempts.** This plan resets the count when the lockout is applied and refuses attempts without counting them while locked out, so a persistent attacker gets 30-second windows rather than an ever-growing one. Either reading satisfies the stated `MUST`; the choice is recorded because two implementations could differ observably here.

   **§11.4's "per Windows agent, not per source address" does not survive several paired Macs, and this plan deviates from it deliberately.** A single global counter means one host that can reach port 47800 can keep every paired Mac permanently unable to authenticate, five failures at a time. This plan keys the counter on the source **address** with the source **port excluded**, which preserves the stated concern (a new source port must not reset the count) while confining the refusal to the offending host. Agent-wide totals are still kept and surfaced, but as an alarm rather than as a gate. See Task 7 for the full argument, and `OneLockedOutPeerDoesNotLockOutAnyOtherPeer` for the test that pins it.
6. **§11.3's validity row says "3,650 days, starting 5 minutes in the past".** Read literally that is a 3,650-day span ending 5 minutes before `now + 3650 days`. The reference implementation uses `now - 5 min` to `now + 3650 days`, a span of 3,650 days plus 5 minutes. This plan matches the reference; the `IdentityTests` assertion allows the ±0.1-day slack that difference implies.
7. **§4's "sequence resets to 0 at the start of each session" is `[CARRIED]` and untested anywhere.** Phase 1 never emits audio, so nothing here can prove it either. Phase 2 must add the test the harness lacks: assert a second session's first frame carries `sequence == 0`.
8. **§2 requires binding "private interfaces only" but does not define the set.** This plan takes it as RFC 1918 (`10/8`, `172.16/12`, `192.168/16`), loopback (`127/8`, `::1`), IPv4 link-local (`169.254/16`), and IPv6 link-local and unique-local. `PrivateAddressTests` pins that reading so a future disagreement is a visible test change.
9. **A second Mac connecting is now answered, and the answer is not supersession.** An earlier draft of §7 said a newly authenticated connection supersedes the older one. With several paired Macs that is wrong: all of them stay connected, and the microphone is arbitrated instead. A `START` from a device that does not hold the session is refused with `START_NACK{reason:"SESSION_IN_USE", holder}`; the connection is not touched. What carries over from the superseding design is the rule that made it safe — nothing observable happens until a connection has authenticated.

10. **§7's "`STOP` means make sure no session is active" needed a scope it did not have.** With one Mac the sentence was unambiguous. With several, taken literally it lets any paired Mac end any other's session with one message. This plan reads it as **"make sure no session is active *on this connection*"**: a `STOP` from a non-holder still returns `STOP_ACK` (§7 never rejects a `STOP`) and ends nothing. `SessionArbiter.Stop` takes the owner id for exactly that reason, and `StopFromANonHolderEndsNothingButStillSucceeds` pins it.

11. **`START_NACK` gains the protocol's first optional field.** `holder` is present only with `reason: "SESSION_IN_USE"`, and is omitted rather than sent blank. Both codecs already tolerate unknown fields — `ControlCodec.Validate` checks that required fields are present and says nothing about extras, and the Python reference does the same — so this needs no version bump. A receiver that ignores it still works; the macOS plan specifies what to show when it is absent.

12. **The conformance harness cannot see any of §7's multi-connection rules.** `MockWindowsServer` gives every connection its own `_session_id` and holds one token, so it would agree with an implementation that has no device list, no arbitration and no release-on-disconnect. Tasks 9, 13, 14 and 15 carry that weight in C#, and `drive_windows_agent.py --mode multi` is the only end-to-end check. This is stated in each of those tasks, because "the suite is green" is otherwise a misleading signal here.
