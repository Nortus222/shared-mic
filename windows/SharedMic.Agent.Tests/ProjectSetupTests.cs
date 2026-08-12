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
