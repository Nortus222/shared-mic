using SharedMic.Agent;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
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

    /// <summary>
    /// An out-of-range port reached new TcpListener(address, port) and died with
    /// an unhandled ArgumentOutOfRangeException; only SocketException and
    /// InvalidOperationException were handled there. It is a usage error and is
    /// now rejected as one.
    /// </summary>
    [Theory]
    [InlineData("0")]
    [InlineData("-1")]
    [InlineData("65536")]
    [InlineData("99999")]
    public void RejectsAPortOutsideTheLegalRange(string port)
    {
        Assert.Throws<ArgumentException>(
            () => SharedMic.Agent.Program.ParseArguments(new[] { "--port", port }));
    }

    [Theory]
    [InlineData("1")]
    [InlineData("65535")]
    public void AcceptsThePortRangeEndpoints(string port)
    {
        Assert.Equal(int.Parse(port), SharedMic.Agent.Program.ParseArguments(new[] { "--port", port }).Port);
    }
}

/// <summary>
/// Startup behaviour that is security-relevant rather than cosmetic: what the
/// banner is allowed to print, and what happens when the identity file cannot
/// be decrypted.
/// </summary>
public class ProgramStartupTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), "sharedmic-startup-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }

    [Fact]
    public void TheBannerPrintsThePairingStringOnlyOnTheRunThatMintedTheIdentity()
    {
        var options = new AgentOptions { DataDirectory = _directory };

        var firstStore = new IdentityStore(_directory);
        Assert.True(SharedMic.Agent.Program.TryLoadIdentity(firstStore, out var minted, out var firstExit));
        Assert.Equal(0, firstExit);
        Assert.True(firstStore.WasNewlyCreated);

        var firstBanner = new StringWriter();
        SharedMic.Agent.Program.PrintBanner(firstBanner, minted, options, firstStore.WasNewlyCreated);
        Assert.Contains(minted.PairingString, firstBanner.ToString(), StringComparison.Ordinal);

        // A second start loads the SAME identity - and must not write the live
        // credential into the log again. The tray menu stays the way to see it.
        var secondStore = new IdentityStore(_directory);
        Assert.True(SharedMic.Agent.Program.TryLoadIdentity(secondStore, out var loaded, out _));
        Assert.False(secondStore.WasNewlyCreated);
        Assert.Equal(minted.PairingString, loaded.PairingString);

        var secondBanner = new StringWriter();
        SharedMic.Agent.Program.PrintBanner(secondBanner, loaded, options, secondStore.WasNewlyCreated);
        var text = secondBanner.ToString();
        Assert.DoesNotContain(loaded.PairingString, text, StringComparison.Ordinal);
        Assert.Contains("tray menu", text, StringComparison.Ordinal);

        // The public, non-secret fields are still there both times.
        Assert.Contains(loaded.Fingerprint, text, StringComparison.Ordinal);
    }

    [Fact]
    public void AnUndecryptableIdentityFailsWithAnActionableMessageAndLeavesTheFileAlone()
    {
        var store = new IdentityStore(_directory);
        Assert.True(SharedMic.Agent.Program.TryLoadIdentity(store, out _, out _));

        // Damage the DPAPI blob: the same shape of failure a Windows password
        // reset or a profile migration produces.
        var path = store.IdentityFilePath;
        var onDisk = File.ReadAllBytes(path);
        File.WriteAllBytes(path, onDisk.AsSpan(0, onDisk.Length / 2).ToArray());

        var broken = new IdentityStore(_directory);
        Assert.False(SharedMic.Agent.Program.TryLoadIdentity(broken, out var identity, out var exitCode));
        Assert.Null(identity);

        // Exit 3 is the corrupt-store code and must stay distinct from exit 4,
        // the unusable-data-directory code: opposite remedies.
        Assert.Equal(3, exitCode);

        // Never auto-deleted and never silently re-minted: a fresh identity here
        // would change the fingerprint and strand the Mac at its pinned-cert
        // hard stop with no explanation.
        Assert.True(File.Exists(path), "the damaged identity file must be left for the user to delete");
    }

    /// <summary>
    /// The owner's real failure: `--data-dir $env:TEMP\sharedmic-check4` typed
    /// into bash, where $env does not expand and the backslash collapses,
    /// yielding the literal ":TEMPsharedmic-check4". Directory.CreateDirectory
    /// threw IOException and the process died with a raw stack trace - in tray
    /// mode, with no console to read it in. It must fail cleanly instead, on its
    /// own exit code.
    /// </summary>
    [Theory]
    [InlineData(":TEMPsharedmic-check4")]
    [InlineData("bad|name")]
    [InlineData("")]
    public void AnUnusableDataDirectoryFailsCleanlyOnItsOwnExitCode(string directory)
    {
        var store = new IdentityStore(directory);

        var loaded = SharedMic.Agent.Program.TryLoadIdentity(store, out var identity, out var exitCode);

        Assert.False(loaded);
        Assert.Null(identity);

        // 4, not 3: this is a bad argument, not a damaged identity. Sending the
        // user down the corrupt-store path would have them delete a file that is
        // fine and re-pair the Mac for nothing.
        Assert.Equal(4, exitCode);
    }
}
