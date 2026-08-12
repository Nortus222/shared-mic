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

    // The two deadlines are per-test rather than one shared pair of tiny values.
    // A test that WANTS a deadline to fire passes a short one; every other test
    // needs enough slack that xUnit's parallel collections cannot make a
    // Task.Delay overshoot into a spurious disconnect. With the brief's shared
    // 600 ms dead-peer timeout and 200 ms heartbeat gaps the margin was 3x, and
    // HeartbeatTrafficKeepsTheConnectionAlivePastTheDeadPeerTimeout failed
    // intermittently when the whole 172-test suite ran together: a 200 ms
    // Task.Delay is not a 200 ms wall-clock gap on a saturated thread pool.
    private static AgentOptions FastOptions(
        bool micPresent = true,
        int helloDeadlineMs = 2000,
        int peerDeadTimeoutMs = 3000) => new()
    {
        MicPresent = micPresent,
        DeviceLabel = "USB Microphone",
        HelloDeadline = TimeSpan.FromMilliseconds(helloDeadlineMs),
        PeerDeadTimeout = TimeSpan.FromMilliseconds(peerDeadTimeoutMs),
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
        await using var fixture = await StartAsync(token, FastOptions(helloDeadlineMs: 400));
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
        await using var fixture = await StartAsync(token, FastOptions(peerDeadTimeoutMs: 600), metrics: metrics);
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
        await using var fixture = await StartAsync(token, FastOptions(peerDeadTimeoutMs: 2500));
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.AuthenticateAsync(token, cancellation.Token);
        await fixture.Peer.ReadControlAsync(cancellation.Token);

        // Thirty 100 ms gaps span at least 3 s, comfortably past the 2.5 s
        // dead-peer timeout, so the connection surviving proves the timer is
        // reset by received traffic rather than merely not having elapsed yet.
        // The ratios are deliberately lopsided: a single gap would have to
        // stretch 25x under load to trip the timeout, while the suite running
        // slowly only pushes the total further past it.
        for (var seq = 1; seq <= 30; seq++)
        {
            await Task.Delay(100, cancellation.Token);
            await fixture.Peer.SendControlAsync(ControlMessages.Ping(seq), cancellation.Token);
            var pong = await fixture.Peer.ReadControlAsync(cancellation.Token);
            Assert.NotNull(pong);
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
        await using var fixture = await StartAsync(token, FastOptions(helloDeadlineMs: 400), limiter);
        using var cancellation = new CancellationTokenSource(Timeout);

        await fixture.Peer.ReadControlAsync(cancellation.Token);
        Assert.True(await fixture.Peer.WaitForCloseAsync(TimeSpan.FromSeconds(5)));

        Assert.Equal(1, limiter.ConsecutiveFailures);
    }
}
