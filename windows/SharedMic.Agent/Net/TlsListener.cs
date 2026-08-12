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
///
/// Binding is not the same as reachability: a Windows Firewall inbound rule for
/// the port on private profiles is a manual, elevated step and is deliberately
/// out of scope here — the agent never asks for elevation.
/// </summary>
public sealed class TlsListener : IAsyncDisposable
{
    /// <summary>How long teardown waits for the accept loops and in-flight connections.</summary>
    private static readonly TimeSpan DrainTimeout = TimeSpan.FromSeconds(5);

    private readonly AgentIdentity _identity;
    private readonly AgentOptions _options;
    private readonly AuthRateLimiter _rateLimiter;
    private readonly AgentMetrics _metrics;
    private readonly Action<AgentStatus, string?> _onStatus;
    private readonly List<TcpListener> _listeners = new();
    private readonly List<Task> _acceptLoops = new();
    private readonly List<Task> _serveTasks = new();
    private readonly CancellationTokenSource _stopping = new();
    private readonly object _gate = new();

    private ControlConnection? _current;
    private bool _disposed;

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
        }

        if (_listeners.Count == 0)
        {
            throw new InvalidOperationException(
                $"no private interface accepted a bind on port {_options.Port}");
        }

        // Endpoints is published before any accept loop runs, so a caller that
        // reads it after Start() cannot observe a half-filled list.
        Endpoints = endpoints;

        foreach (var listener in _listeners)
        {
            _acceptLoops.Add(Task.Run(() => AcceptLoopAsync(listener, _stopping.Token), CancellationToken.None));
        }

        _onStatus(AgentStatus.Disconnected, null);
    }

    public async ValueTask DisposeAsync()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
        }

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

        // Accept loops first: once they have returned, no further connection can
        // be added to _serveTasks, so the snapshot below is complete.
        await DrainAsync(_acceptLoops).ConfigureAwait(false);

        Task[] serving;
        lock (_gate)
        {
            serving = _serveTasks.ToArray();
        }

        await DrainAsync(serving).ConfigureAwait(false);

        // Disposed only after every task that holds _stopping.Token has finished
        // with it. Disposing a CancellationTokenSource whose token is still being
        // linked from turns an orderly shutdown into an ObjectDisposedException
        // on a background thread.
        _stopping.Dispose();
    }

    private static async Task DrainAsync(IEnumerable<Task> tasks)
    {
        foreach (var task in tasks)
        {
            try
            {
                await task.WaitAsync(DrainTimeout).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                AgentLog.Warn("a listener task did not finish within the shutdown drain window; abandoning it");
            }
            catch (Exception)
            {
                // Shutting down; a cancelled or faulted task is expected and has
                // already been logged where it happened.
            }
        }
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

            var serving = Task.Run(() => ServeAsync(client, cancellationToken), CancellationToken.None);
            lock (_gate)
            {
                // Pruned as we go: this list is the shutdown drain set, not a
                // history, and an agent that runs for weeks must not accumulate
                // one completed Task per connection it has ever served.
                _serveTasks.RemoveAll(task => task.IsCompleted);
                _serveTasks.Add(serving);
            }
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

            using (var handshake = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
            {
                handshake.CancelAfter(_options.TlsHandshakeTimeout);

                await ssl.AuthenticateAsServerAsync(
                    new SslServerAuthenticationOptions
                    {
                        ServerCertificate = _identity.Certificate,

                        // No client certificate and no chain building anywhere:
                        // trust in this design is a pinned SHA-256 of the DER
                        // encoding, held by the Mac. There is no CA to consult.
                        ClientCertificateRequired = false,
                        EnabledSslProtocols = SslProtocols.Tls13,
                        CertificateRevocationCheckMode = X509RevocationMode.NoCheck,
                    },
                    handshake.Token).ConfigureAwait(false);
            }

            // Logged after every handshake: TLS 1.3 is part of the contract, so
            // a negotiated version other than Tls13 has to be visible.
            AgentLog.Info($"TLS handshake with {remote} negotiated {ssl.SslProtocol}");

            connection = new ControlConnection(ssl, _identity, _options, _rateLimiter, _metrics)
            {
                RemoteDescription = remote,
            };
            connection.Authenticated += Adopt;

            // Immediately after the handshake, with no work in between: the
            // section 6 pre-auth deadline is measured from RunAsync entry, so
            // anything done here would eat into the Mac's five seconds.
            await connection.RunAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (Exception exception)
            when (exception is AuthenticationException or IOException or OperationCanceledException
                      or SocketException or ObjectDisposedException)
        {
            AgentLog.Warn($"connection from {remote} ended: {exception.GetType().Name}: {exception.Message}");
        }
        catch (Exception exception)
        {
            // ControlConnection.RunAsync does not swallow exceptions from message
            // handling, and this task is only ever observed here. Without this
            // clause an unexpected fault would become an unobserved task
            // exception: silent, and invisible in the log.
            AgentLog.Error($"connection from {remote} faulted: {exception}");
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

                // Only after RunAsync has returned: DisposeAsync disposes the
                // connection's own cancellation source, and doing that while
                // RunAsync is in flight would leave it uncancellable.
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
    /// Runs synchronously on the new connection's read loop, so it does only the
    /// swap and the status publish. Tearing the superseded connection down means
    /// cancelling its token, which runs its registered callbacks — and therefore
    /// possibly other continuations — on the calling thread; doing that here
    /// would stall the new connection's read loop behind the old one's teardown.
    /// </summary>
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
            _ = Task.Run(previous.Close, CancellationToken.None);
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
