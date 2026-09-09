using SharedMic.Agent;
using SharedMic.Agent.Audio;
using SharedMic.Agent.Diagnostics;
using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class ControlConnectionAudioTests
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);

    private static readonly System.Security.Cryptography.X509Certificates.X509Certificate2 SharedCertificate =
        DeviceCertificate.CreateSelfSigned();

    private sealed class Fixture : IAsyncDisposable
    {
        public Fixture(
            LoopbackPeer peer,
            ControlConnection connection,
            AudioContext audio,
            FakeCaptureFactory captures,
            FakeEndpointProvider devices,
            Task run,
            CancellationTokenSource cancellation)
        {
            Peer = peer;
            Connection = connection;
            Audio = audio;
            Captures = captures;
            Devices = devices;
            Run = run;
            Cancellation = cancellation;
        }

        public LoopbackPeer Peer { get; }

        public ControlConnection Connection { get; }

        public AudioContext Audio { get; }

        public FakeCaptureFactory Captures { get; }

        public FakeEndpointProvider Devices { get; }

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
            }

            await Connection.DisposeAsync();
            Audio.Dispose();
            await Peer.DisposeAsync();
            Cancellation.Dispose();
        }
    }

    private static async Task<Fixture> StartAsync(byte[] token, bool present = true)
    {
        var devices = new FakeEndpointProvider
        {
            Present = present,
            FriendlyName = "Microphone (Samson Meteorite Mic)",
        };
        var captures = new FakeCaptureFactory();
        var audio = new AudioContext(new DeviceManager(devices), captures);
        var options = new AgentOptions
        {
            MicPresent = true,
            DeviceLabel = "USB Microphone",
            HelloDeadline = TimeSpan.FromSeconds(2),
            PeerDeadTimeout = TimeSpan.FromSeconds(3),
            LivenessPollInterval = TimeSpan.FromMilliseconds(50),
        };
        var peer = await LoopbackPeer.CreateAsync();
        var connection = new ControlConnection(
            peer.ServerStream,
            new AgentIdentity("win-test", token, SharedCertificate, DeviceCertificate.Fingerprint(SharedCertificate)),
            options,
            new AuthRateLimiter(),
            new AgentMetrics(),
            audio)
        {
            RemoteDescription = "loopback",
        };
        var cancellation = new CancellationTokenSource();
        var run = connection.RunAsync(cancellation.Token);
        return new Fixture(peer, connection, audio, captures, devices, run, cancellation);
    }

    private static async Task<AudioFrame> ReadAudioAsync(LoopbackPeer peer, CancellationToken token)
    {
        ReceivedFrame? frame = await peer.ReadFrameAsync(token);
        Assert.True(frame.HasValue, "the agent closed before sending the expected AUDIO frame");
        Assert.Equal(FrameType.Audio, frame!.Value.Type);
        Assert.Equal(ProtocolConstants.AudioPayloadSize, frame.Value.Payload.Length);
        return AudioPayloadCodec.DecodeAudioPayload(frame.Value.Payload);
    }

    private static async Task AssertQuietAsync(LoopbackPeer peer, CancellationToken token)
    {
        await peer.SendControlAsync(ControlMessages.Ping(7), token);
        var pong = await peer.ReadControlAsync(token);
        Assert.Equal("PONG", pong!["type"]);
    }

    [Fact]
    public async Task HelloAckCarriesLivePresenceAndHardwareLabel()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        var helloAck = await fixture.Peer.ReadControlAsync(cancellation.Token);

        Assert.Equal("HELLO_ACK", helloAck!["type"]);
        Assert.Equal(true, helloAck["micPresent"]);
        Assert.Equal("Microphone (Samson Meteorite Mic)", helloAck["deviceLabel"]);
    }

    [Fact]
    public async Task StartStreamsFullFramesWithZeroBasedSequenceAndMonotonicTimestamps()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("START_ACK", ack!["type"]);

        fixture.Captures.Capture.Push(new float[960 * 2 * 3]);

        for (uint expected = 0; expected < 3; expected++)
        {
            AudioFrame frame = await ReadAudioAsync(fixture.Peer, cancellation.Token);
            Assert.Equal(expected, frame.Sequence);
            Assert.Equal((ulong)expected * 20000ul, frame.CaptureTimestampUs);
            Assert.Equal(ProtocolConstants.PcmBytesPerFrame, frame.Pcm.Length);
        }
    }

    [Fact]
    public async Task DuplicateStartKeepsTheSessionAndDoesNotResetTheSequence()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        var first = await fixture.Peer.ReadControlAsync(cancellation.Token);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        AudioFrame before = await ReadAudioAsync(fixture.Peer, cancellation.Token);
        Assert.Equal(0u, before.Sequence);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0002"), cancellation.Token);
        var second = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("START_ACK", second!["type"]);
        Assert.Equal(first!["sessionId"], second["sessionId"]);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        AudioFrame after = await ReadAudioAsync(fixture.Peer, cancellation.Token);
        Assert.Equal(1u, after.Sequence);
        Assert.Equal(20000ul, after.CaptureTimestampUs);
    }

    [Fact]
    public async Task NewSessionAfterStopResetsTheSequenceToZero()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        fixture.Captures.Capture.Push(new float[960 * 2 * 2]);
        await ReadAudioAsync(fixture.Peer, cancellation.Token);
        await ReadAudioAsync(fixture.Peer, cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Stop("req-0002", ""), cancellation.Token);
        var stopAck = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("STOP_ACK", stopAck!["type"]);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        await AssertQuietAsync(fixture.Peer, cancellation.Token);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0003"), cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        AudioFrame reopened = await ReadAudioAsync(fixture.Peer, cancellation.Token);
        Assert.Equal(0u, reopened.Sequence);
        Assert.Equal(0ul, reopened.CaptureTimestampUs);
    }

    [Fact]
    public async Task FailedCaptureOpenIsNackedAndLeavesNoSessionBehind()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        fixture.Captures.ThrowOnOpen = true;
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        var nack = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("START_NACK", nack!["type"]);
        Assert.Equal("MIC_UNAVAILABLE", nack["reason"]);

        fixture.Captures.ThrowOnOpen = false;
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0002"), cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("START_ACK", ack!["type"]);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        AudioFrame frame = await ReadAudioAsync(fixture.Peer, cancellation.Token);
        Assert.Equal(0u, frame.Sequence);
    }

    [Fact]
    public async Task StartIsNackedWhenTheMicrophoneIsAbsent()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token, present: false);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        var helloAck = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal(false, helloAck!["micPresent"]);

        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        var nack = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("START_NACK", nack!["type"]);
        Assert.Equal("MIC_UNAVAILABLE", nack["reason"]);
    }

    [Fact]
    public async Task MicLossMidSessionEndsTheSessionAndSendsStatus()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        var ack = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("START_ACK", ack!["type"]);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        await ReadAudioAsync(fixture.Peer, cancellation.Token);

        fixture.Devices.Present = false;
        fixture.Devices.RaiseDevicesChanged();

        var status = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("STATUS", status!["type"]);
        Assert.Equal(false, status["micPresent"]);
        Assert.Equal(false, status["active"]);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        await AssertQuietAsync(fixture.Peer, cancellation.Token);

        fixture.Devices.Present = true;
        fixture.Devices.RaiseDevicesChanged();

        var replugged = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("STATUS", replugged!["type"]);
        Assert.Equal(true, replugged["micPresent"]);
        Assert.Equal(false, replugged["active"]);
    }

    [Fact]
    public async Task CaptureLossMidSessionEndsTheSessionAndSendsStatus()
    {
        var token = PairingToken.Generate();
        await using var fixture = await StartAsync(token);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);
        await fixture.Peer.SendControlAsync(ControlMessages.Start("req-0001"), cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        await ReadAudioAsync(fixture.Peer, cancellation.Token);

        fixture.Captures.Capture.RaiseCaptureLost();

        var status = await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.Equal("STATUS", status!["type"]);
        Assert.Equal(true, status["micPresent"]);
        Assert.Equal(false, status["active"]);

        fixture.Captures.Capture.Push(new float[960 * 2]);
        await AssertQuietAsync(fixture.Peer, cancellation.Token);
    }

    private sealed class FakeEndpointProvider : IAudioEndpointProvider
    {
        public bool Present { get; set; }

        public string FriendlyName { get; set; } = "Fake Microphone";

        public event Action? DevicesChanged;

        public bool IsPresent(string endpointId) => Present;

        public string GetFriendlyName(string endpointId) => FriendlyName;

        public void RaiseDevicesChanged() => DevicesChanged?.Invoke();

        public void Dispose()
        {
        }
    }

    private sealed class FakeCaptureFactory : IAudioCaptureFactory
    {
        public bool ThrowOnOpen { get; set; }

        public FakeCapture Capture { get; } = new();

        public IAudioCapture Open(string endpointId)
        {
            if (ThrowOnOpen)
            {
                throw new IOException("no device");
            }

            return Capture;
        }
    }

    private sealed class FakeCapture : IAudioCapture
    {
        public int SampleRate => 48000;

        public int Channels => 2;

        public event Action<float[]>? DataAvailable;

        public event Action? CaptureLost;

        public void Push(float[] interleaved) => DataAvailable?.Invoke(interleaved);

        public void RaiseCaptureLost() => CaptureLost?.Invoke();

        public void Start()
        {
        }

        public void Stop()
        {
        }

        public void Dispose()
        {
        }
    }
}


