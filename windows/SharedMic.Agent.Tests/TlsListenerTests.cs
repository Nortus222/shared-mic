using System.Collections.Concurrent;
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

    /// <summary>
    /// The status callback fires on the agent's threads, not the test's. A plain
    /// List would be mutated from a thread other than the asserting one, and the
    /// listener adopts a connection immediately AFTER HELLO_ACK is queued — so a
    /// read of HELLO_ACK does not order-guarantee that Idle has been recorded
    /// yet. Collect concurrently and wait for the status with a bound.
    /// </summary>
    private sealed class StatusLog
    {
        private readonly ConcurrentQueue<AgentStatus> _statuses = new();

        public void Record(AgentStatus status, string? _) => _statuses.Enqueue(status);

        public async Task AssertEventuallyContainsAsync(AgentStatus expected, CancellationToken cancellationToken)
        {
            var deadline = DateTimeOffset.UtcNow + TimeSpan.FromSeconds(5);
            while (DateTimeOffset.UtcNow < deadline)
            {
                if (_statuses.Contains(expected))
                {
                    return;
                }

                await Task.Delay(20, cancellationToken);
            }

            Assert.Contains(expected, _statuses.ToArray());
        }
    }

    [Fact]
    public async Task AcceptsAPinnedTls13ConnectionAndCompletesTheHandshake()
    {
        var identity = new IdentityStore(_directory).LoadOrCreate();
        var options = LoopbackOptions(port: 0);
        var statuses = new StatusLog();
        await using var listener = new TlsListener(
            identity,
            options,
            new AuthRateLimiter(),
            new AgentMetrics(),
            statuses.Record);

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
        await statuses.AssertEventuallyContainsAsync(AgentStatus.Idle, cancellation.Token);
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
