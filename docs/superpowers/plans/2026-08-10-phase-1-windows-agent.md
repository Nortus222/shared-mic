# Windows Agent Phase 1 — Transport and Security Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Windows tray agent that a macOS client (or the Python `MockMacClient`) can connect to over TLS 1.3, pair with, authenticate against by HMAC challenge-response, and hold a healthy, heartbeat-monitored session with — producing wire bytes that byte-match `protocol/vectors/*.json`, and capturing no audio at all.

**Architecture:** A single `SharedMic.Agent` project holds four layers: a pure `Protocol/` codec layer (envelope framing, audio-payload framing, canonical control-message JSON) that is the only thing the golden-vector tests touch; a `Security/` layer (pairing token, base32 pairing string, HMAC proof, rate limiter, P-256 device certificate, DPAPI-protected identity store); a `Net/` layer (TLS listener bound to private interfaces, incremental frame reader, priority send queue, and the `ControlConnection` state machine that runs the handshake, session lifecycle and heartbeat); and a thin `Ui/` tray shell. `Session/SessionStateMachine` is a pure transition function with no I/O, exactly as spec §3.1 requires. Every network-facing task is verified twice: by a C# test over a loopback socket, and by pointing the Python `MockMacClient` at the running agent.

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
| `START_NACK` | `requestId`, `reason` (string) |
| `STOP` | `requestId`, `sessionId` |
| `STOP_ACK` | `requestId`, `sessionId` |
| `STATUS` | `micPresent` (bool), `active` (bool), `deviceLabel` (string) — these three fields are the whole message, there is no `errors` field |
| `PING` | `seq` (integer) |
| `PONG` | `seq` (integer), which MUST equal the `PING`'s `seq` |

`preferredFormat`/`format` are always exactly `{"sampleRate":48000,"channels":1,"sampleFormat":"s16le"}`.

**Handshake (protocol §6).** Windows sends `GREETING{serverId, nonce}` immediately after the TLS handshake; `nonce` is 32 fresh random bytes, lowercase hex, **never reused across connections**. The Mac replies `HELLO{clientId, mac}` where `mac = lowercase_hex(HMAC-SHA256(token, nonce))` computed over the **raw 32 nonce bytes, not the hex string**. Windows verifies with a **constant-time** comparison and replies `HELLO_ACK`, or closes without replying. **The token never crosses the wire.** **5-second pre-auth deadline**: from TLS handshake completion, Windows gives the Mac 5 seconds to deliver a valid `HELLO` — no message, an unparseable message, a non-`HELLO` message, or a failing `mac` all mean close. No `START`/`STOP`/`PING`/`STATUS`/`AUDIO` is valid before authentication. **Any frame whose envelope `type` is not `CONTROL` is rejected unconditionally at any point in the connection's lifetime** — the Mac never sends `AUDIO`.

**Session lifecycle (protocol §7).** `START` and `STOP` are idempotent. A duplicate `START` while active returns `START_ACK` carrying the **existing** `sessionId` and format, does not create a second session, and does not reset the audio `sequence` counter. A `STOP` while idle still returns `STOP_ACK`; Windows does not reject `STOP` on `sessionId` mismatch — `STOP` means "make sure no session is active". A `STOP` sent with no session active MAY carry an empty string or a stale `sessionId`. `sequence` resets to `0` at each `START_ACK` (implement the reset; the harness does not prove it). **No `AUDIO` frame may be sent outside an active session, and an idle connection MUST carry zero audio bytes.** In Phase 1 a session carries zero audio bytes at all times, active or not.

**Timers (protocol §8).**

| Timer | Value | Who runs it | Effect on expiry |
|---|---|---|---|
| `START` response | 2 s | Mac | (Mac-side; not implemented here) |
| `STOP` response | 1 s | Mac | (Mac-side; not implemented here) |
| `PING` interval | 15 s | Mac sends; **Windows replies `PONG` immediately** and applies the same 15 s interval and dead-peer rule to *absent* `PING`s | — |
| Peer dead | **45 s** without peer traffic (three missed heartbeats) | Both sides | Windows closes the connection and accepts a new one |
| Pre-auth (`HELLO`) deadline | **5 s** | Windows, per new connection | Close the connection |

**Send priority (protocol §9).** Control messages are queued **unboundedly** and are **always drained before any audio frame**. Audio is a **bounded ring of 25 frames (500 ms at 50 fps) that drops the oldest frame on overflow and never blocks**. Two drop counters, kept separate: **evicted on overflow** (network could not keep up — alarm-worthy) and **discarded at session teardown** (intended). The identity `offered = received + evicted + discarded` must close, to within one frame in flight.

**Pairing token and string (protocol §11.1, §11.2).** The token is **32 bytes (256 bits) from a cryptographically secure random source**, generated at first run, never regenerated except by explicit re-pair, and never on the wire. Displayed as: **RFC 4648 base32** (`A`–`Z` then `2`–`7`), **uppercase**, **unpadded** (strip the four `=`), **hyphen-grouped in runs of 8** with a single `-` (U+002D). 32 bytes → 52 base32 characters → six groups of 8 plus a final group of 4 → **always 58 characters**. Worked example:

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

**Authentication rate limiting (protocol §11.4).** After **5 consecutive failed attempts**, refuse further attempts for **30 seconds**. A failed attempt is any connection that reaches §6 without producing a verified `HELLO` — wrong `mac`, malformed or non-`HELLO` message, or the 5-second deadline expiring. **The lockout is counted per Windows agent, not per source address.** Surface it in the UI.

**Privacy and logging (spec §7.3).** Audio payload is never logged or persisted. Logs carry lifecycle events and counters only. Never log the pairing token, the private key, or the raw `mac` proof.

**Phase 1 is transport and security only.** No WASAPI, no `MicCaptureService`, no `PcmNormalizer`, no `DeviceManager`, no device enumeration, no audio capture of any kind. A `START` establishes a session and returns `START_ACK`; it does not open a microphone and streams nothing.

**Known platform risk to watch.** TLS 1.3 server support in Schannel requires Windows 11 / Windows Server 2022 or later. Task 13 logs `SslStream.SslProtocol` after every handshake; if it is not `Tls13`, the Windows host's OS version is the cause and the finding must be reported rather than worked around by lowering `EnabledSslProtocols`.

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
      AuthRateLimiter.cs                      5 consecutive failures then a 30 s agent-wide lockout
      DeviceCertificate.cs                    self-signed P-256 certificate with SAN, DER SHA-256 fingerprint
      IdentityStore.cs                        DPAPI-protected persistence of token, certificate and serverId
    Net/
      FrameReader.cs                          incremental envelope reader over any Stream
      PrioritySendQueue.cs                    unbounded control queue, bounded 25-frame drop-oldest audio ring
      ControlConnection.cs                    handshake, pre-auth deadline, session lifecycle, heartbeat, writer loop
      PrivateAddress.cs                       RFC1918 / loopback / link-local classification and enumeration
      TlsListener.cs                          TCP 47800 bind per private interface, TLS 1.3, connection supervision
    Session/
      SessionStateMachine.cs                  pure START/STOP transition function, idempotent
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
    PrioritySendQueueTests.cs
    FrameReaderTests.cs
    IdentityTests.cs                          certificate profile, fingerprint, DPAPI round-trip
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
- Produces: `static class ControlCodec` with `IReadOnlyDictionary<string, string[]> RequiredFields`, `byte[] Encode(IReadOnlyDictionary<string, object?> message)`, `Dictionary<string, object?> Decode(ReadOnlySpan<byte> payload)`, `Dictionary<string, object?> Normalize(IReadOnlyDictionary<string, object?> message)`, `void Validate(IReadOnlyDictionary<string, object?> message)`, `Dictionary<string, object?> FromJsonElement(JsonElement element)`, `bool DeepEquals(object? left, object? right)`; `static class ControlMessages` with `IReadOnlyDictionary<string, object?> AudioFormat` and factories `Greeting(string serverId, string nonceHex)`, `Hello(string clientId, string mac)`, `HelloAck(string serverId, bool micPresent, string deviceLabel)`, `Start(string requestId)`, `StartAck(string requestId, string sessionId)`, `StartNack(string requestId, string reason)`, `Stop(string requestId, string sessionId)`, `StopAck(string requestId, string sessionId)`, `Status(bool micPresent, bool active, string deviceLabel)`, `Ping(long seq)`, `Pong(long seq)` — each returning `Dictionary<string, object?>`.

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
/// guess about.
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

    public static Dictionary<string, object?> StartNack(string requestId, string reason) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "START_NACK",
            ["requestId"] = requestId,
            ["reason"] = reason,
        };

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

Expected: PASS, 17 tests.

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
/// fresh 32-byte nonce per connection, and the client proves possession of the
/// pairing token with HMAC-SHA256 over the RAW nonce bytes, not over the hex
/// string. Verification is constant time.
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
- Produces: `sealed class AuthRateLimiter` with constructor `AuthRateLimiter(int maxFailures = ProtocolConstants.MaxAuthFailures, TimeSpan? lockoutDuration = null, Func<DateTimeOffset>? clock = null)` and members `int ConsecutiveFailures`, `long LockoutCount`, `bool IsLockedOut`, `TimeSpan LockoutRemaining`, `bool TryBeginAttempt()`, `void RecordFailure()`, `void RecordSuccess()`.

The clock is injectable so the 30-second lockout is testable without a 30-second test. The limiter is agent-wide (one instance shared by every connection), because protocol §11.4 requires the count not be resettable by choosing a new source port.

**This task runs on Windows.**

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/AuthRateLimiterTests.cs`:

```csharp
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class AuthRateLimiterTests
{
    private sealed class TestClock
    {
        public DateTimeOffset Now { get; set; } = new(2026, 8, 10, 12, 0, 0, TimeSpan.Zero);

        public DateTimeOffset Read() => Now;

        public void Advance(TimeSpan amount) => Now += amount;
    }

    [Fact]
    public void DefaultsMatchTheContract()
    {
        var limiter = new AuthRateLimiter();

        Assert.False(limiter.IsLockedOut);
        Assert.True(limiter.TryBeginAttempt());
        Assert.Equal(TimeSpan.Zero, limiter.LockoutRemaining);
        Assert.Equal(5, ProtocolConstants.MaxAuthFailures);
        Assert.Equal(TimeSpan.FromSeconds(30), ProtocolConstants.AuthLockoutDuration);
    }

    [Fact]
    public void FourFailuresDoNotLockOut()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 4; i++)
        {
            limiter.RecordFailure();
        }

        Assert.False(limiter.IsLockedOut);
        Assert.True(limiter.TryBeginAttempt());
        Assert.Equal(4, limiter.ConsecutiveFailures);
    }

    [Fact]
    public void FifthConsecutiveFailureLocksOutForThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 5; i++)
        {
            limiter.RecordFailure();
        }

        Assert.True(limiter.IsLockedOut);
        Assert.False(limiter.TryBeginAttempt());
        Assert.Equal(TimeSpan.FromSeconds(30), limiter.LockoutRemaining);
        Assert.Equal(1, limiter.LockoutCount);
    }

    [Fact]
    public void LockoutExpiresAfterThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 5; i++)
        {
            limiter.RecordFailure();
        }

        clock.Advance(TimeSpan.FromSeconds(29));
        Assert.True(limiter.IsLockedOut);

        clock.Advance(TimeSpan.FromSeconds(1.5));
        Assert.False(limiter.IsLockedOut);
        Assert.True(limiter.TryBeginAttempt());
        Assert.Equal(TimeSpan.Zero, limiter.LockoutRemaining);
    }

    [Fact]
    public void CounterResetsAfterALockoutSoTheNextFiveFailuresLockAgain()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 5; i++)
        {
            limiter.RecordFailure();
        }

        clock.Advance(TimeSpan.FromSeconds(31));
        Assert.Equal(0, limiter.ConsecutiveFailures);

        for (var i = 0; i < 4; i++)
        {
            limiter.RecordFailure();
        }

        Assert.False(limiter.IsLockedOut);

        limiter.RecordFailure();
        Assert.True(limiter.IsLockedOut);
        Assert.Equal(2, limiter.LockoutCount);
    }

    [Fact]
    public void SuccessClearsTheConsecutiveCount()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        limiter.RecordFailure();
        limiter.RecordFailure();
        limiter.RecordFailure();
        limiter.RecordFailure();
        limiter.RecordSuccess();
        limiter.RecordFailure();

        Assert.Equal(1, limiter.ConsecutiveFailures);
        Assert.False(limiter.IsLockedOut);
    }

    [Fact]
    public void ACorrectTokenIsAlsoRefusedWhileLockedOut()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 5; i++)
        {
            limiter.RecordFailure();
        }

        // The caller must consult TryBeginAttempt before verifying anything, so
        // the lockout is not a per-credential check but a per-agent one.
        Assert.False(limiter.TryBeginAttempt());
    }

    [Fact]
    public void ShortLockoutsAreConfigurableSoIntegrationTestsDoNotWaitThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(maxFailures: 2, lockoutDuration: TimeSpan.FromMilliseconds(200), clock: clock.Read);

        limiter.RecordFailure();
        limiter.RecordFailure();

        Assert.True(limiter.IsLockedOut);
        clock.Advance(TimeSpan.FromMilliseconds(250));
        Assert.False(limiter.IsLockedOut);
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
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// protocol-v1.md section 11.4: after 5 consecutive failed authentication
/// attempts, refuse further attempts for 30 seconds. A failed attempt is any
/// connection that reaches the section 6 handshake without producing a
/// verified HELLO: a wrong mac, a malformed or non-HELLO message, or the
/// 5-second pre-auth deadline expiring.
///
/// The lockout is counted PER AGENT, not per source address. One instance is
/// shared by every connection, so an attacker choosing source ports freely
/// cannot reset it.
///
/// Without this, the handshake is an unthrottled HMAC verification oracle
/// reachable by anything that can open a TCP connection to the listener.
/// </summary>
public sealed class AuthRateLimiter
{
    private readonly int _maxFailures;
    private readonly TimeSpan _lockoutDuration;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();

    private int _consecutiveFailures;
    private long _lockoutCount;
    private DateTimeOffset _lockedUntil = DateTimeOffset.MinValue;

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

    public int ConsecutiveFailures
    {
        get
        {
            lock (_gate)
            {
                ExpireLockout();
                return _consecutiveFailures;
            }
        }
    }

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

    public bool IsLockedOut
    {
        get
        {
            lock (_gate)
            {
                ExpireLockout();
                return _clock() < _lockedUntil;
            }
        }
    }

    public TimeSpan LockoutRemaining
    {
        get
        {
            lock (_gate)
            {
                var remaining = _lockedUntil - _clock();
                return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
            }
        }
    }

    /// <summary>
    /// Call this before verifying any proof. False means the agent is locked
    /// out and the connection must be closed without evaluating the credential.
    /// </summary>
    public bool TryBeginAttempt() => !IsLockedOut;

    public void RecordFailure()
    {
        lock (_gate)
        {
            ExpireLockout();
            _consecutiveFailures++;
            if (_consecutiveFailures >= _maxFailures)
            {
                _lockedUntil = _clock() + _lockoutDuration;
                _consecutiveFailures = 0;
                _lockoutCount++;
            }
        }
    }

    public void RecordSuccess()
    {
        lock (_gate)
        {
            _consecutiveFailures = 0;
            _lockedUntil = DateTimeOffset.MinValue;
        }
    }

    private void ExpireLockout()
    {
        if (_lockedUntil != DateTimeOffset.MinValue && _clock() >= _lockedUntil)
        {
            _lockedUntil = DateTimeOffset.MinValue;
        }
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~AuthRateLimiterTests"
```

Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Security/AuthRateLimiter.cs windows/SharedMic.Agent.Tests/AuthRateLimiterTests.cs
git commit -m "Phase 1 Task 7: agent-wide 5-attempt/30-second authentication lockout"
```

---

### Task 8: Session state machine

**Files:**
- Create: `windows/SharedMic.Agent/Session/SessionStateMachine.cs`
- Test: `windows/SharedMic.Agent.Tests/SessionStateMachineTests.cs`

**Interfaces:**
- Consumes: nothing beyond the BCL.
- Produces: `enum SessionState { Idle, Active }`; `readonly record struct StartOutcome(bool Accepted, string SessionId, string? Reason, bool StartedNewSession)`; `readonly record struct StopOutcome(string SessionId, bool EndedSession)`; `sealed class SessionStateMachine` with constructor `SessionStateMachine(Func<string>? sessionIdFactory = null)` and members `static string DefaultSessionId()`, `SessionState State`, `string? SessionId`, `long SessionsStarted`, `StartOutcome HandleStart(bool micPresent)`, `StopOutcome HandleStop(string requestedSessionId)`, `void Reset()`.

This is one of the three pure units spec §3.1 names. It performs no I/O and is not thread-safe by design: `ControlConnection` dispatches every control message from a single read loop.

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
/// STOP means "make sure no session is active on this connection".
///
/// Not thread-safe by design. ControlConnection dispatches every control
/// message from its single read loop.
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

### Task 9: Priority send queue

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
git commit -m "Phase 1 Task 9: priority send queue, unbounded control, 25-frame drop-oldest audio ring"
```

---

### Task 10: Incremental frame reader

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
git commit -m "Phase 1 Task 10: incremental frame reader with close-on-violation semantics"
```

---

### Task 11: Device certificate and DPAPI-protected identity store

**Files:**
- Create: `windows/SharedMic.Agent/Security/DeviceCertificate.cs`
- Create: `windows/SharedMic.Agent/Security/IdentityStore.cs`
- Test: `windows/SharedMic.Agent.Tests/IdentityTests.cs`

**Interfaces:**
- Consumes: `ProtocolConstants.CertificateCommonName`, `ProtocolConstants.CertificateValidityDays`, `ProtocolConstants.CertificateBackdate`, `ProtocolConstants.TokenBytes`; `PairingToken.Generate()`, `PairingToken.Encode(ReadOnlySpan<byte>)`.
- Produces: `static class DeviceCertificate` with `X509Certificate2 CreateSelfSigned(string commonName = ProtocolConstants.CertificateCommonName)` and `string Fingerprint(X509Certificate2 certificate)`; `sealed record AgentIdentity(string ServerId, byte[] Token, X509Certificate2 Certificate, string Fingerprint)` with computed property `string PairingString`; `sealed class IdentityStore` with constructor `IdentityStore(string directory)`, `static string DefaultDirectory`, `AgentIdentity LoadOrCreate()`, `void Reset()`.

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

        Assert.Equal(ProtocolConstants.TokenBytes, first.Token.Length);
        Assert.Equal(first.Token, second.Token);
        Assert.Equal(first.Fingerprint, second.Fingerprint);
        Assert.Equal(first.ServerId, second.ServerId);
        Assert.Equal(58, first.PairingString.Length);
        Assert.True(first.Certificate.HasPrivateKey);
        Assert.True(second.Certificate.HasPrivateKey);
    }

    [Fact]
    public void TokenIsNotStoredInPlaintextOnDisk()
    {
        var store = new IdentityStore(_directory);
        var identity = store.LoadOrCreate();

        var onDisk = File.ReadAllBytes(Path.Combine(_directory, "token.dpapi"));

        Assert.True(onDisk.Length > identity.Token.Length);
        Assert.False(ContainsSubsequence(onDisk, identity.Token), "the raw token is present in the protected file");
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
    public void ResetForcesRegenerationOfANewTokenAndCertificate()
    {
        var store = new IdentityStore(_directory);
        var first = store.LoadOrCreate();

        store.Reset();
        var second = store.LoadOrCreate();

        Assert.NotEqual(Convert.ToHexString(first.Token), Convert.ToHexString(second.Token));
        Assert.NotEqual(first.Fingerprint, second.Fingerprint);
    }

    [Fact]
    public void PairingStringRoundTripsToTheStoredToken()
    {
        var store = new IdentityStore(_directory);
        var identity = store.LoadOrCreate();

        Assert.Equal(identity.Token, PairingToken.Decode(identity.PairingString));
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
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// Everything the agent is: its server identifier, its 256-bit pairing token,
/// and its device certificate. Never log any field except ServerId and
/// Fingerprint.
/// </summary>
public sealed record AgentIdentity(string ServerId, byte[] Token, X509Certificate2 Certificate, string Fingerprint)
{
    /// <summary>The base32 string the tray shows and the user retypes on the Mac.</summary>
    public string PairingString => PairingToken.Encode(Token);
}

/// <summary>
/// First-run generation and at-rest protection of the agent identity, per
/// design spec section 7.1: the token and the certificate's private key are
/// DPAPI-protected under the current user. Regenerating them is an explicit
/// re-pair, never automatic.
/// </summary>
public sealed class IdentityStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("shared-mic/v1/identity");

    private readonly string _directory;

    public IdentityStore(string directory) => _directory = directory;

    public static string DefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SharedMic");

    private string TokenPath => Path.Combine(_directory, "token.dpapi");

    private string CertificatePath => Path.Combine(_directory, "device-cert.dpapi");

    private string ServerIdPath => Path.Combine(_directory, "server-id.txt");

    public AgentIdentity LoadOrCreate()
    {
        Directory.CreateDirectory(_directory);

        var token = LoadOrCreateToken();
        var certificate = LoadOrCreateCertificate();
        var serverId = LoadOrCreateServerId();

        return new AgentIdentity(serverId, token, certificate, DeviceCertificate.Fingerprint(certificate));
    }

    public void Reset()
    {
        foreach (var path in new[] { TokenPath, CertificatePath, ServerIdPath })
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    private byte[] LoadOrCreateToken()
    {
        byte[] token;
        if (File.Exists(TokenPath))
        {
            token = Unprotect(File.ReadAllBytes(TokenPath));
        }
        else
        {
            token = PairingToken.Generate();
            WriteProtected(TokenPath, token);
        }

        if (token.Length != ProtocolConstants.TokenBytes)
        {
            throw new InvalidOperationException(
                $"the stored pairing token is {token.Length} bytes, expected {ProtocolConstants.TokenBytes}");
        }

        return token;
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

Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Security/DeviceCertificate.cs windows/SharedMic.Agent/Security/IdentityStore.cs windows/SharedMic.Agent.Tests/IdentityTests.cs
git commit -m "Phase 1 Task 11: P-256 device certificate with SAN and DPAPI-protected identity store"
```

---

### Task 12: Control connection — handshake, session lifecycle, heartbeat

**Files:**
- Create: `windows/SharedMic.Agent/AgentOptions.cs`
- Create: `windows/SharedMic.Agent/AgentStatus.cs`
- Create: `windows/SharedMic.Agent/Diagnostics/AgentLog.cs`
- Create: `windows/SharedMic.Agent/Diagnostics/AgentMetrics.cs`
- Create: `windows/SharedMic.Agent/Net/ControlConnection.cs`
- Test: `windows/SharedMic.Agent.Tests/LoopbackPeer.cs`
- Test: `windows/SharedMic.Agent.Tests/ControlConnectionTests.cs`

**Interfaces:**
- Consumes: `FrameCodec`, `FrameType`, `ControlCodec`, `ControlMessages`, `ProtocolException`, `ProtocolConstants`; `FrameReader(Stream)` / `ReadFrameAsync(CancellationToken)`; `PrioritySendQueue`; `AuthProof.GenerateNonce()` / `AuthProof.Verify(byte[], byte[], string?)`; `AuthRateLimiter.TryBeginAttempt()` / `RecordFailure()` / `RecordSuccess()` / `IsLockedOut` / `LockoutRemaining`; `AgentIdentity(string ServerId, byte[] Token, X509Certificate2 Certificate, string Fingerprint)`; `SessionStateMachine.HandleStart(bool)` / `HandleStop(string)` / `Reset()`.
- Produces: `enum AgentStatus { Disconnected, Idle, Error }`; `sealed class AgentOptions` (init-only properties listed below); `static class AgentLog` with `Info(string)`, `Warn(string)`, `Error(string)`; `sealed class AgentMetrics` with an `Increment*` method per counter and `AgentMetricsSnapshot Snapshot()`; `sealed record AgentMetricsSnapshot(...)`; `sealed class ControlConnection : IAsyncDisposable` with constructor `ControlConnection(Stream stream, AgentIdentity identity, AgentOptions options, AuthRateLimiter rateLimiter, AgentMetrics metrics)`, members `bool IsAuthenticated`, `string RemoteDescription { get; init; }`, `PrioritySendQueue SendQueue`, `SessionStateMachine Session`, `event Action<ControlConnection>? Authenticated`, `Task RunAsync(CancellationToken cancellationToken)`, `void Close()`, `ValueTask DisposeAsync()`.

**This task runs on Windows.** Tests use a real loopback TCP socket pair, so no TLS is involved yet and the whole exchange is inspectable.

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

public class ControlConnectionTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    // One certificate for the whole class. ControlConnection never uses it (it
    // is handed an already-established stream), and generating one per test
    // would leave a user key container behind for every test in the class.
    private static readonly System.Security.Cryptography.X509Certificates.X509Certificate2 SharedCertificate =
        DeviceCertificate.CreateSelfSigned();

    private static AgentIdentity NewIdentity(byte[] token) =>
        new("win-test", token, SharedCertificate, DeviceCertificate.Fingerprint(SharedCertificate));

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
        byte[] token,
        AgentOptions options,
        AuthRateLimiter? limiter = null,
        AgentMetrics? metrics = null)
    {
        var peer = await LoopbackPeer.CreateAsync();
        var connection = new ControlConnection(
            peer.ServerStream,
            NewIdentity(token),
            options,
            limiter ?? new AuthRateLimiter(),
            metrics ?? new AgentMetrics())
        {
            RemoteDescription = "loopback",
        };

        var cancellation = new CancellationTokenSource();
        var run = connection.RunAsync(cancellation.Token);
        return new Fixture(peer, connection, run, cancellation);
    }

    [Fact]
    public async Task SendsGreetingImmediatelyWithASixtyFourCharacterNonce()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
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
        var token = PairingToken.Generate();
        using var cancellation = new CancellationTokenSource(Timeout);

        await using var first = await StartAsync(token, FastOptions());
        await using var second = await StartAsync(token, FastOptions());

        var a = await first.Peer.ReadControlAsync(cancellation.Token);
        var b = await second.Peer.ReadControlAsync(cancellation.Token);

        Assert.NotEqual(a!["nonce"], b!["nonce"]);
    }

    [Fact]
    public async Task ValidHelloIsAnsweredWithHelloAck()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("HELLO_ACK", ack!["type"]);
        Assert.Equal("win-test", ack["serverId"]);
        Assert.Equal(true, ack["micPresent"]);
        Assert.Equal("USB Microphone", ack["deviceLabel"]);
    }

    [Fact]
    public async Task WrongProofClosesTheConnectionWithoutReplying()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        var greeting = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("GREETING", greeting!["type"]);

        await fixture.Peer.SendControlAsync(
            ControlMessages.Hello("mock-mac", new string('a', 64)),
            cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        Assert.False(fixture.Connection.IsAuthenticated);
    }

    [Fact]
    public async Task PingBeforeAuthenticationClosesTheConnection()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Ping(1), cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task AudioFrameFromTheClientIsAProtocolViolationAtAnyPoint()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
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
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendRawAsync(new byte[] { 7, 0, 0, 0, 0 }, cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task WrongProtocolVersionClosesTheConnection()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        var payload = System.Text.Encoding.UTF8.GetBytes("{\"seq\":1,\"type\":\"PING\",\"v\":2}");
        await fixture.Peer.SendRawAsync(FrameCodec.EncodeFrame(FrameType.Control, payload), cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task IdleConnectionIsClosedAtThePreAuthDeadline()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        var greeting = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("GREETING", greeting!["type"]);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
    }

    [Fact]
    public async Task PingIsAnsweredWithAMatchingPong()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
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
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
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
        Assert.Equal(1, fixture.Connection.Session.SessionsStarted);
    }

    [Fact]
    public async Task NoAudioIsSentWhileASessionIsActiveBecausePhase1HasNoCapturePath()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
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
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
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
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
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
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("r1"), cancellation.Token);
        var first = await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Stop("r2", (string)first!["sessionId"]!), cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("r3"), cancellation.Token);
        var second = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.NotEqual(first["sessionId"], second!["sessionId"]);
        Assert.Equal(2, fixture.Connection.Session.SessionsStarted);
    }

    [Fact]
    public async Task StartIsNackedWithMicUnavailableWhenNoMicIsConfigured()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions(micPresent: false));
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal(false, ack!["micPresent"]);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0002"), cancellation.Token);
        var nack = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("START_NACK", nack!["type"]);
        Assert.Equal("req-0002", nack["requestId"]);
        Assert.Equal("MIC_UNAVAILABLE", nack["reason"]);
    }

    [Fact]
    public async Task ASilentAuthenticatedPeerIsDeclaredDead()
    {
        var token = PairingToken.Generate();
        var metrics = new AgentMetrics();
        await using var fixture = await StartAsync(token, FastOptions(), metrics: metrics);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(1, metrics.Snapshot().DeadPeerDisconnects);
    }

    [Fact]
    public async Task HeartbeatTrafficKeepsTheConnectionAlivePastTheDeadPeerTimeout()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, FastOptions());
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
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
    public async Task FiveFailedAttemptsLockOutEvenACorrectToken()
    {
        var token = PairingToken.Generate();
        var limiter = new AuthRateLimiter(lockoutDuration: TimeSpan.FromSeconds(30));
        using var cancellation = new CancellationTokenSource(Timeout);

        for (var attempt = 0; attempt < 5; attempt++)
        {
            await using var bad = await StartAsync(token, FastOptions(), limiter);
            await bad.Peer.ReadControlAsync(cancellation.Token);
            await bad.Peer.SendControlAsync(
                ControlMessages.Hello("mock-mac", new string('b', 64)),
                cancellation.Token);
            Assert.True(await bad.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        }

        Assert.True(limiter.IsLockedOut);

        await using var good = await StartAsync(token, FastOptions(), limiter);
        await good.Peer.AuthenticateAsync(token, cancellation.Token);

        Assert.True(await good.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));
        Assert.False(good.Connection.IsAuthenticated);
    }

    [Fact]
    public async Task ThePreAuthDeadlineCountsAsAFailedAttempt()
    {
        var token = PairingToken.Generate();
        var limiter = new AuthRateLimiter();
        await using var fixture = await StartAsync(token, FastOptions(), limiter);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));

        Assert.Equal(1, limiter.ConsecutiveFailures);
    }
}
```

Teardown discard counting is proved in Task 9 against `PrioritySendQueue` directly rather than here: with no capture path, the only way to put audio in the queue on a live connection is to enqueue it from the test, and the writer loop drains it before `STOP` can be sent, so the assertion would be a race rather than a check.

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
    long DeadPeerDisconnects,
    long UnexpectedControlMessages,
    long AudioFramesSent);

/// <summary>
/// The subset of design spec section 11's counters that Phase 1 can produce.
/// Per-connection audio queue counters (offered, evicted, discarded) live on
/// PrioritySendQueue and are read from there.
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
        Interlocked.Read(ref _deadPeerDisconnects),
        Interlocked.Read(ref _unexpectedControlMessages),
        Interlocked.Read(ref _audioFramesSent));
}
```

`windows/SharedMic.Agent/Net/ControlConnection.cs`:

```csharp
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
/// Phase 1 has no capture path, so nothing ever calls SendQueue.EnqueueAudio on
/// a live connection and an active session carries zero audio bytes.
///
/// Threading: every control message is handled on the single read loop, which
/// is why SessionStateMachine does not need to be thread-safe. The writer runs
/// on its own task and touches only the queue and the stream.
/// </summary>
public sealed class ControlConnection : IAsyncDisposable
{
    private readonly Stream _stream;
    private readonly AgentIdentity _identity;
    private readonly AgentOptions _options;
    private readonly AuthRateLimiter _rateLimiter;
    private readonly AgentMetrics _metrics;
    private readonly SessionStateMachine _session = new();
    private readonly PrioritySendQueue _queue = new();
    private readonly CancellationTokenSource _closing = new();
    private readonly byte[] _nonce = AuthProof.GenerateNonce();

    private long _lastPeerActivityTicks;

    public ControlConnection(
        Stream stream,
        AgentIdentity identity,
        AgentOptions options,
        AuthRateLimiter rateLimiter,
        AgentMetrics metrics)
    {
        _stream = stream;
        _identity = identity;
        _options = options;
        _rateLimiter = rateLimiter;
        _metrics = metrics;
    }

    /// <summary>Raised once HELLO_ACK has been queued, so the listener can supersede an older connection.</summary>
    public event Action<ControlConnection>? Authenticated;

    public bool IsAuthenticated { get; private set; }

    public string RemoteDescription { get; init; } = "unknown";

    public PrioritySendQueue SendQueue => _queue;

    public SessionStateMachine Session => _session;

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
            _session.Reset();
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
        if (!_rateLimiter.TryBeginAttempt())
        {
            _metrics.IncrementAuthRefusedByLockout();
            AgentLog.Warn(
                $"authentication from {RemoteDescription} refused: locked out for another " +
                $"{_rateLimiter.LockoutRemaining.TotalSeconds:F0} s after 5 consecutive failures");
            return false;
        }

        var type = message["type"] as string;
        if (type != "HELLO")
        {
            FailAuthentication($"expected HELLO before authentication, got {type}");
            return false;
        }

        if (message["mac"] is not string mac || !AuthProof.Verify(_identity.Token, _nonce, mac))
        {
            FailAuthentication("the HMAC proof did not verify");
            return false;
        }

        _rateLimiter.RecordSuccess();
        IsAuthenticated = true;
        _metrics.IncrementConnectionsAuthenticated();

        // Queue HELLO_ACK before flipping any observable state, so nothing can
        // slip ahead of it on the control queue.
        SendControl(ControlMessages.HelloAck(_identity.ServerId, _options.MicPresent, _options.DeviceLabel));
        AgentLog.Info($"authenticated client '{message.GetValueOrDefault("clientId")}' from {RemoteDescription}");
        Authenticated?.Invoke(this);
        return true;
    }

    private void FailAuthentication(string reason)
    {
        _rateLimiter.RecordFailure();
        _metrics.IncrementAuthFailures();

        var lockout = _rateLimiter.IsLockedOut
            ? $" — the agent is now locked out for {_rateLimiter.LockoutRemaining.TotalSeconds:F0} s"
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

                var outcome = _session.HandleStart(_options.MicPresent);
                if (!outcome.Accepted)
                {
                    AgentLog.Info($"START {requestId} rejected: {outcome.Reason}");
                    SendControl(ControlMessages.StartNack(requestId, outcome.Reason!));
                    break;
                }

                if (outcome.StartedNewSession)
                {
                    _metrics.IncrementSessionsStarted();
                    AgentLog.Info($"session {outcome.SessionId} started (Phase 1: no capture, no audio will be sent)");
                }
                else
                {
                    AgentLog.Info($"duplicate START {requestId} returned the existing session {outcome.SessionId}");
                }

                SendControl(ControlMessages.StartAck(requestId, outcome.SessionId));
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
                var outcome = _session.HandleStop(requested);
                var discarded = _queue.DiscardAudio();
                if (outcome.EndedSession)
                {
                    AgentLog.Info($"session {outcome.SessionId} ended; discarded {discarded} queued audio frames");
                }

                SendControl(ControlMessages.StopAck(requestId, outcome.SessionId));
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

Expected: PASS, 20 tests.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/AgentOptions.cs windows/SharedMic.Agent/AgentStatus.cs windows/SharedMic.Agent/Diagnostics windows/SharedMic.Agent/Net/ControlConnection.cs windows/SharedMic.Agent.Tests/LoopbackPeer.cs windows/SharedMic.Agent.Tests/ControlConnectionTests.cs
git commit -m "Phase 1 Task 12: control connection with handshake, idempotent sessions, dead-peer detection"
```

---

### Task 13: TLS 1.3 listener bound to private interfaces

**Files:**
- Create: `windows/SharedMic.Agent/Net/PrivateAddress.cs`
- Create: `windows/SharedMic.Agent/Net/TlsListener.cs`
- Test: `windows/SharedMic.Agent.Tests/PrivateAddressTests.cs`
- Test: `windows/SharedMic.Agent.Tests/TlsListenerTests.cs`

**Interfaces:**
- Consumes: `AgentIdentity`, `AgentOptions`, `AuthRateLimiter`, `AgentMetrics`, `AgentStatus`, `AgentLog`, `ControlConnection(Stream, AgentIdentity, AgentOptions, AuthRateLimiter, AgentMetrics)` with `RunAsync`, `Close`, `DisposeAsync`, and the `Authenticated` event.
- Produces: `static class PrivateAddress` with `bool IsPrivate(IPAddress address)` and `IReadOnlyList<IPAddress> Enumerate()`; `sealed class TlsListener : IAsyncDisposable` with constructor `TlsListener(AgentIdentity identity, AgentOptions options, AuthRateLimiter rateLimiter, AgentMetrics metrics, Action<AgentStatus, string?> onStatus)`, members `IReadOnlyList<IPEndPoint> Endpoints`, `void Start()`, `ValueTask DisposeAsync()`.

**This task runs on Windows.**

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

    [Fact]
    public async Task AcceptsAPinnedTls13ConnectionAndCompletesTheHandshake()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var options = LoopbackOptions(port: 0);
        var statuses = new List<AgentStatus>();
        await using var listener = new TlsListener(
            identity,
            options,
            new AuthRateLimiter(),
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
            ControlCodec.Encode(ControlMessages.Hello("mock-mac", AuthProof.Compute(identity.Token, nonce))));
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
            new AuthRateLimiter(),
            new AgentMetrics(),
            (_, _) => { });

        listener.Start();

        Assert.Single(listener.Endpoints);
        Assert.Equal(port, listener.Endpoints[0].Port);
        Assert.Equal(IPAddress.Loopback, listener.Endpoints[0].Address);
    }

    [Fact]
    public async Task ANewlyAuthenticatedConnectionSupersedesTheOlderOne()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        await using var listener = new TlsListener(
            identity,
            LoopbackOptions(port: 0),
            new AuthRateLimiter(),
            new AgentMetrics(),
            (_, _) => { });

        listener.Start();
        var endpoint = listener.Endpoints.Single();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));

        var first = await AuthenticateAsync(endpoint, identity, cancellation.Token);
        var second = await AuthenticateAsync(endpoint, identity, cancellation.Token);

        // The first connection must be torn down once the second authenticates.
        var firstReader = new FrameReader(first);
        var closed = false;
        try
        {
            closed = await firstReader.ReadFrameAsync(cancellation.Token) is null;
        }
        catch (Exception exception) when (exception is IOException or ProtocolException or ObjectDisposedException)
        {
            closed = true;
        }

        Assert.True(closed, "the superseded connection was not closed");

        await second.DisposeAsync();
        await first.DisposeAsync();
    }

    [Fact]
    public async Task AClientThatNeverSendsHelloIsDroppedAtTheDeadline()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var limiter = new AuthRateLimiter();
        await using var listener = new TlsListener(
            identity,
            LoopbackOptions(port: 0),
            limiter,
            new AgentMetrics(),
            (_, _) => { });

        listener.Start();
        var endpoint = listener.Endpoints.Single();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(20));

        await using var ssl = await ConnectPinnedAsync(endpoint, identity.Fingerprint);
        var reader = new FrameReader(ssl);
        await reader.ReadFrameAsync(cancellation.Token);

        var closed = false;
        try
        {
            closed = await reader.ReadFrameAsync(cancellation.Token) is null;
        }
        catch (Exception exception) when (exception is IOException or ProtocolException or ObjectDisposedException)
        {
            closed = true;
        }

        Assert.True(closed);
        Assert.Equal(1, limiter.ConsecutiveFailures);
    }

    private static async Task<SslStream> AuthenticateAsync(
        IPEndPoint endpoint,
        AgentIdentity identity,
        CancellationToken cancellationToken)
    {
        var ssl = await ConnectPinnedAsync(endpoint, identity.Fingerprint);
        var reader = new FrameReader(ssl);
        var greeting = ControlCodec.Decode((await reader.ReadFrameAsync(cancellationToken))!.Value.Payload);
        var nonce = Convert.FromHexString((string)greeting["nonce"]!);
        var hello = FrameCodec.EncodeFrame(
            FrameType.Control,
            ControlCodec.Encode(ControlMessages.Hello("mock-mac", AuthProof.Compute(identity.Token, nonce))));
        await ssl.WriteAsync(hello, cancellationToken);
        await ssl.FlushAsync(cancellationToken);
        var ack = ControlCodec.Decode((await reader.ReadFrameAsync(cancellationToken))!.Value.Payload);
        Assert.Equal("HELLO_ACK", ack["type"]);
        return ssl;
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

namespace SharedMic.Agent.Net;

/// <summary>
/// The TCP 47800 listener of protocol-v1.md section 2. One TcpListener per
/// private interface address; TLS 1.3 wraps every accepted connection
/// immediately, with Windows as the TLS server. There is no CA: the certificate
/// exists only so the Mac can pin the SHA-256 of its DER encoding.
///
/// A newly authenticated connection supersedes an older one. The swap happens
/// only AFTER the new connection authenticates, so an unauthenticated attacker
/// cannot kick a live session by opening a socket.
/// </summary>
public sealed class TlsListener : IAsyncDisposable
{
    private readonly AgentIdentity _identity;
    private readonly AgentOptions _options;
    private readonly AuthRateLimiter _rateLimiter;
    private readonly AgentMetrics _metrics;
    private readonly Action<AgentStatus, string?> _onStatus;
    private readonly List<TcpListener> _listeners = new();
    private readonly List<Task> _acceptLoops = new();
    private readonly CancellationTokenSource _stopping = new();
    private readonly object _gate = new();

    private ControlConnection? _current;

    public TlsListener(
        AgentIdentity identity,
        AgentOptions options,
        AuthRateLimiter rateLimiter,
        AgentMetrics metrics,
        Action<AgentStatus, string?> onStatus)
    {
        _identity = identity;
        _options = options;
        _rateLimiter = rateLimiter;
        _metrics = metrics;
        _onStatus = onStatus;
    }

    public IReadOnlyList<IPEndPoint> Endpoints { get; private set; } = Array.Empty<IPEndPoint>();

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

        ControlConnection? current;
        lock (_gate)
        {
            current = _current;
            _current = null;
        }

        current?.Close();

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

            connection = new ControlConnection(ssl, _identity, _options, _rateLimiter, _metrics)
            {
                RemoteDescription = remote,
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
                    if (ReferenceEquals(_current, connection))
                    {
                        _current = null;
                    }
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

    private void Adopt(ControlConnection connection)
    {
        ControlConnection? previous;
        lock (_gate)
        {
            previous = _current;
            _current = connection;
        }

        if (previous is not null && !ReferenceEquals(previous, connection))
        {
            AgentLog.Info("a newer authenticated connection superseded the previous one");
            previous.Close();
        }

        PublishStatus();
    }

    private void PublishStatus()
    {
        bool connected;
        lock (_gate)
        {
            connected = _current is not null;
        }

        _onStatus(connected ? AgentStatus.Idle : AgentStatus.Disconnected, null);
    }
}
```

- [ ] **Step 4: Run and confirm it passes**

Run, from the repo's `windows` directory on Windows:

```powershell
dotnet test SharedMic.Windows.sln --filter "FullyQualifiedName~PrivateAddressTests|FullyQualifiedName~TlsListenerTests"
```

Expected: PASS, 22 tests (17 `PrivateAddress` theory cases plus 1 fact, and 4 listener facts).

If `AcceptsAPinnedTls13ConnectionAndCompletesTheHandshake` fails with `AuthenticationException: The client and server cannot communicate, because they do not possess a common algorithm`, the Windows host's Schannel does not support TLS 1.3 as a server. That is an OS-version finding (TLS 1.3 server support needs Windows 11 or Windows Server 2022). Report it; do not lower `EnabledSslProtocols`, because protocol-v1.md section 2 makes TLS 1.3 part of the contract.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Net/PrivateAddress.cs windows/SharedMic.Agent/Net/TlsListener.cs windows/SharedMic.Agent.Tests/PrivateAddressTests.cs windows/SharedMic.Agent.Tests/TlsListenerTests.cs
git commit -m "Phase 1 Task 13: TLS 1.3 listener on port 47800, private interfaces only"
```

---

### Task 14: Runnable headless host and Python interoperability

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
        });

        Assert.Equal(47999, options.Port);
        Assert.False(options.MicPresent);
        Assert.Equal("Samson Meteorite", options.DeviceLabel);
        Assert.Equal(@"C:\temp\sharedmic", options.DataDirectory);
        Assert.True(options.Headless);
        Assert.True(options.LoopbackOnly);
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

- [ ] **Step 3: Implement**

`windows/SharedMic.Agent/Program.cs`:

```csharp
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Net;
using SharedMic.Agent.Security;

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
                "[--data-dir PATH] [--headless] [--loopback-only]");
            return 2;
        }

        var identity = new IdentityStore(options.DataDirectory).LoadOrCreate();
        var metrics = new AgentMetrics();
        var rateLimiter = new AuthRateLimiter();

        PrintBanner(identity, options);

        var listener = new TlsListener(
            identity,
            options,
            rateLimiter,
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

    private static void PrintBanner(AgentIdentity identity, AgentOptions options)
    {
        // Never print the token itself. The pairing string is meant for the
        // user's eyes and the fingerprint is public by construction.
        Console.WriteLine("shared-mic Windows agent, Phase 1 (transport and security only, no audio capture)");
        Console.WriteLine($"  serverId:       {identity.ServerId}");
        Console.WriteLine($"  port:           {options.Port}");
        Console.WriteLine($"  micPresent:     {options.MicPresent}");
        Console.WriteLine($"  deviceLabel:    {options.DeviceLabel}");
        Console.WriteLine($"  data directory: {options.DataDirectory}");
        Console.WriteLine($"  fingerprint:    {identity.Fingerprint}");
        Console.WriteLine($"  pairing string: {identity.PairingString}");
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


def main(argv):
    parser = argparse.ArgumentParser(description="Drive a Windows shared-mic agent from the mock Mac client.")
    parser.add_argument("--host", required=True, help="the Windows host's address")
    parser.add_argument("--port", type=int, default=47800)
    parser.add_argument("--pairing", required=True, help="the pairing string the agent printed or the tray shows")
    parser.add_argument("--fingerprint", required=True, help="the 64-character lowercase hex fingerprint")
    parser.add_argument("--mode", choices=("session", "nack", "lockout"), default="session")
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)

    token = decode_pairing_string(args.pairing)
    print(f"pairing string decoded to {len(token)} bytes")

    if args.mode == "session":
        run_session(args, token)
    elif args.mode == "nack":
        run_nack(args, token)
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

Expected: PASS, 5 tests.

Then the interoperability run. **On Windows**, start the agent and leave it running:

```powershell
dotnet run --project SharedMic.Agent -- --headless --device-label "USB Microphone"
```

Expected: a banner listing `serverId`, `port: 47800`, the 64-character `fingerprint`, and a 58-character `pairing string`, then one `listening on <address>:47800 (private interfaces only)` line per private interface. Copy the fingerprint and the pairing string, and note one of the listed non-loopback addresses.

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

Expected: five `bad attempt N refused` lines, one `correct token refused during lockout` line, and `PASS lockout checks`. On the agent's console, expect five `authentication ... failed: the HMAC proof did not verify` lines with the fifth carrying `the agent is now locked out for 30 s`, then one `authentication ... refused: locked out for another N s`.

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
git commit -m "Phase 1 Task 14: headless agent host and Python interoperability driver"
```

---

### Task 15: Tray UI and project documentation

**Files:**
- Create: `windows/SharedMic.Agent/Ui/TrayApp.cs`
- Modify: `windows/SharedMic.Agent/Program.cs`
- Modify: `CLAUDE.md`
- Test: `windows/SharedMic.Agent.Tests/TrayAppTests.cs`

**Interfaces:**
- Consumes: `AgentStatus`, `AgentIdentity.PairingString` / `.ServerId` / `.Fingerprint`, `AgentOptions`, `TlsListener`, `AgentLog`, `AgentMetrics`, `AuthRateLimiter`, `IdentityStore`.
- Produces: `sealed class TrayApp : ApplicationContext` with constructor `TrayApp(AgentIdentity identity, AgentOptions options, Func<Task> onQuitAsync)`, members `static string FormatStatus(AgentStatus status, string? detail)`, `void SetStatus(AgentStatus status, string? detail)`; `Program.Main` updated to run the tray unless `--headless`.

**This task runs on Windows.** The last step is a manual visual check, because a `NotifyIcon` cannot be asserted on meaningfully in a headless test run.

- [ ] **Step 1: Write the failing test**

`windows/SharedMic.Agent.Tests/TrayAppTests.cs`:

```csharp
using SharedMic.Agent;
using SharedMic.Agent.Ui;
using Xunit;

namespace SharedMic.Agent.Tests;

public class TrayAppTests
{
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
            "Status: Idle (192.168.1.9)",
            TrayApp.FormatStatus(AgentStatus.Idle, "192.168.1.9"));
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
/// The minimal Phase 1 tray: current status, the pairing string the user
/// retypes on the Mac, and a way to quit. Design spec section 11's full status
/// list and diagnostics view arrive with the audio path and automatic demand;
/// there is no device picker or level meter here because there is no capture
/// path to feed one.
///
/// Never show or copy the raw token, only the pairing string.
/// </summary>
public sealed class TrayApp : ApplicationContext
{
    private const int MaxNotifyIconTextLength = 63;

    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _statusItem;
    private readonly Func<Task> _onQuitAsync;

    public TrayApp(AgentIdentity identity, AgentOptions options, Func<Task> onQuitAsync)
    {
        _onQuitAsync = onQuitAsync;

        _statusItem = new ToolStripMenuItem(FormatStatus(AgentStatus.Disconnected, null)) { Enabled = false };

        var pairingHeader = new ToolStripMenuItem("Pairing string (click to copy)") { Enabled = false };
        var pairingValue = new ToolStripMenuItem(identity.PairingString);
        pairingValue.Click += (_, _) =>
        {
            Clipboard.SetText(identity.PairingString);
            AgentLog.Info("pairing string copied to the clipboard");
        };

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
        menu.Items.Add(pairingHeader);
        menu.Items.Add(pairingValue);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(fingerprintHeader);
        menu.Items.Add(fingerprintValue);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quit);

        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = FormatStatus(AgentStatus.Disconnected, null),
            ContextMenuStrip = menu,
            Visible = true,
            BalloonTipTitle = "shared-mic",
            BalloonTipText = $"Listening on port {options.Port}. Pair the Mac with the string in this menu.",
        };
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
                "[--data-dir PATH] [--headless] [--loopback-only]");
            return 2;
        }

        var identity = new IdentityStore(options.DataDirectory).LoadOrCreate();
        var metrics = new AgentMetrics();
        var rateLimiter = new AuthRateLimiter();

        PrintBanner(identity, options);

        TrayApp? tray = null;
        var listener = new TlsListener(
            identity,
            options,
            rateLimiter,
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
            tray = new TrayApp(identity, options, async () =>
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

    private static void PrintBanner(AgentIdentity identity, AgentOptions options)
    {
        // Never print the token itself. The pairing string is meant for the
        // user's eyes and the fingerprint is public by construction.
        Console.WriteLine("shared-mic Windows agent, Phase 1 (transport and security only, no audio capture)");
        Console.WriteLine($"  serverId:       {identity.ServerId}");
        Console.WriteLine($"  port:           {options.Port}");
        Console.WriteLine($"  micPresent:     {options.MicPresent}");
        Console.WriteLine($"  deviceLabel:    {options.DeviceLabel}");
        Console.WriteLine($"  data directory: {options.DataDirectory}");
        Console.WriteLine($"  fingerprint:    {identity.Fingerprint}");
        Console.WriteLine($"  pairing string: {identity.PairingString}");
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
dotnet run --project SharedMic.Agent                 # tray icon plus a console log
dotnet run --project SharedMic.Agent -- --headless   # console only, Ctrl+C to quit
```

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
with `--no-mic`), and `lockout` (five bad-token attempts then the 30-second refusal).

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

Expected: PASS, 4 tests.

Then the full suite, which is the end-of-batch build and test for the whole phase:

```powershell
dotnet build SharedMic.Windows.sln
dotnet test SharedMic.Windows.sln
```

Expected: `Build succeeded. 0 Warning(s) 0 Error(s)`, then all tests passing — 2 + 11 + 7 + 17 + 32 + 15 + 8 + 12 + 12 + 7 + 9 + 20 + 22 + 5 + 4 = **183 tests**.

Then the manual tray check, on Windows:

```powershell
dotnet run --project SharedMic.Agent
```

Confirm each of the following by looking at the screen, and record the result:

1. A tray icon appears in the notification area.
2. Hovering it shows `Status: Disconnected (port 47800)`.
3. Right-clicking shows: a disabled status line, the pairing string, the certificate fingerprint, and `Quit`.
4. The pairing string shown in the menu is 58 characters and identical to the one the console banner printed.
5. Clicking the pairing string copies it; paste it somewhere to confirm, and confirm the console logs `pairing string copied to the clipboard`.
6. With the agent still running, complete a `--mode session` run from the Mac (command in Task 14). While it is connected, the tray hover text changes to `Status: Idle`; after the driver exits it returns to `Status: Disconnected`.
7. `Quit` removes the icon and exits the process; the console prints `final counters:` with a non-zero `ConnectionsAuthenticated`.

Finally confirm the harness suite is untouched, from the Mac:

```sh
cd harness
.venv/bin/python -m pytest -q
```

Expected: 101 passed.

- [ ] **Step 5: Commit**

```bash
git add windows/SharedMic.Agent/Ui/TrayApp.cs windows/SharedMic.Agent/Program.cs windows/SharedMic.Agent.Tests/TrayAppTests.cs CLAUDE.md
git commit -m "Phase 1 Task 15: tray UI with status, pairing string and quit; document Phase 1 commands"
```

---

## Phase 1 scope coverage

Each item of the Phase 1 scope list and the task that implements it:

| Scope item | Task |
|---|---|
| TLS 1.3 listener on TCP 47800, private interfaces only | 13 (`TlsListener`, `PrivateAddress`) |
| Self-signed P-256 device certificate at first run, SAN required | 11 (`DeviceCertificate`) |
| Private key DPAPI-protected | 11 (`IdentityStore`) |
| 256-bit pairing token generated and persisted | 11 (`IdentityStore.LoadOrCreate`), 6 (`PairingToken.Generate`) |
| Pairing string displayed | 6 (encoding), 14 (console banner), 15 (tray menu) |
| `GREETING` → `HELLO` → `HELLO_ACK` with HMAC-SHA256 challenge-response | 12 (`ControlConnection.TryAuthenticate`), 6 (`AuthProof`) |
| 5-second pre-auth deadline | 12 (`ReadLoopAsync`) |
| 5-attempt / 30-second lockout | 7 (`AuthRateLimiter`), 12 (wired in and counted), 14 (`--mode lockout`) |
| Frame envelope codec byte-matching the vectors | 2, 5 |
| Control-message codec byte-matching the vectors | 4, 5 |
| Audio payload codec byte-matching the vectors | 3, 5 |
| Priority send queue: unbounded control, 25-frame drop-oldest audio | 9, 12 (teardown discard) |
| Session state machine, idempotent `START`/`STOP` | 8, 12 |
| Heartbeat: `PONG` with matching `seq` | 12 |
| Dead-peer detection at 45 s | 12 (`LivenessLoopAsync`) |
| Minimal tray: status, pairing string, quit | 15 |
| Verifiable against `MockMacClient` | 14 (all three modes plus the fingerprint-mismatch check) |

## Explicitly out of scope for Phase 1

Stated here so a reviewer does not read an omission as an oversight:

- **All audio capture.** No WASAPI, no `MicCaptureService`, no `PcmNormalizer`, no `DeviceManager`, no device enumeration, no level meter. `AudioPayloadCodec` and `PrioritySendQueue.EnqueueAudio` exist and are tested, but nothing calls them on a live connection. A `START` returns `START_ACK` and streams nothing.
- **Device selection.** `micPresent` and `deviceLabel` are configuration flags (`--no-mic`, `--device-label`), not device queries.
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
6. **§11.3's validity row says "3,650 days, starting 5 minutes in the past".** Read literally that is a 3,650-day span ending 5 minutes before `now + 3650 days`. The reference implementation uses `now - 5 min` to `now + 3650 days`, a span of 3,650 days plus 5 minutes. This plan matches the reference; the `IdentityTests` assertion allows the ±0.1-day slack that difference implies.
7. **§4's "sequence resets to 0 at the start of each session" is `[CARRIED]` and untested anywhere.** Phase 1 never emits audio, so nothing here can prove it either. Phase 2 must add the test the harness lacks: assert a second session's first frame carries `sequence == 0`.
8. **§2 requires binding "private interfaces only" but does not define the set.** This plan takes it as RFC 1918 (`10/8`, `172.16/12`, `192.168/16`), loopback (`127/8`, `::1`), IPv4 link-local (`169.254/16`), and IPv6 link-local and unique-local. `PrivateAddressTests` pins that reading so a future disagreement is a visible test change.
9. **Nothing in the contract says what a Windows agent should do when a second Mac connects.** This plan supersedes: the newer connection wins, but only once it has authenticated, so an unauthenticated peer cannot displace a live session.
