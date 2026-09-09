using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using SharedMic.Agent.Audio;
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
    private SessionState _currentSession;
    private bool _currentMicPresent = true;
    private readonly AudioContext? _audio;
    private readonly SessionLedger? _ledger;
    private bool _started;
    private bool _disposed;

    public TlsListener(
        AgentIdentity identity,
        AgentOptions options,
        AuthRateLimiter rateLimiter,
        AgentMetrics metrics,
        Action<AgentStatus, string?> onStatus,
        AudioContext? audio = null,
        SessionLedger? ledger = null)
    {
        _identity = identity;
        _options = options;
        _rateLimiter = rateLimiter;
        _metrics = metrics;
        _onStatus = onStatus;
        _audio = audio;
        _ledger = ledger;
    }

    public IReadOnlyList<IPEndPoint> Endpoints { get; private set; } = Array.Empty<IPEndPoint>();

    /// <summary>
    /// Binds once. A second call would open a second set of listeners that the
    /// first set's teardown never sees, and a call after disposal would leave
    /// listeners running past the drain in DisposeAsync — both are programming
    /// errors, so both throw rather than quietly leaking a socket.
    /// </summary>
    public void Start()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);

            if (_started)
            {
                throw new InvalidOperationException("the listener has already been started");
            }

            _started = true;
        }

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

        // Announced BEFORE the first accept loop runs. Announcing it afterwards
        // would race a client that authenticated in the meantime, and this
        // Disconnected would overwrite its Idle with nothing to correct it.
        _onStatus(AgentStatus.Disconnected, null);

        if (_audio is not null)
        {
            _audio.PresenceChanged += OnAudioPresenceChanged;
            _audio.CaptureLost += OnAudioCaptureLost;
        }

        foreach (var listener in _listeners)
        {
            _acceptLoops.Add(Task.Run(() => AcceptLoopAsync(listener, _stopping.Token), CancellationToken.None));
        }
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

        if (_audio is not null)
        {
            _audio.PresenceChanged -= OnAudioPresenceChanged;
            _audio.CaptureLost -= OnAudioCaptureLost;
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
        // Everything, including reading the remote endpoint, happens inside the
        // try. A peer that resets between accept and this line makes
        // RemoteEndPoint throw, and outside the try that would both fault this
        // task unobserved and leak the TcpClient — the two failures the general
        // catch clause and the finally below exist to prevent.
        var remote = "unknown";

        SslStream? ssl = null;
        ControlConnection? connection = null;

        try
        {
            remote = client.Client.RemoteEndPoint?.ToString() ?? "unknown";
            _metrics.IncrementConnectionsAccepted();
            AgentLog.Info($"connection from {remote}");

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

            connection = new ControlConnection(ssl, _identity, _options, _rateLimiter, _metrics, _audio)
            {
                RemoteDescription = remote,
            };
            connection.Authenticated += Adopt;
            connection.SessionStateChanged += OnConnectionSessionState;

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
                connection.SessionStateChanged -= OnConnectionSessionState;
                lock (_gate)
                {
                    if (ReferenceEquals(_current, connection))
                    {
                        _current = null;
                    }

                    // Inside the same critical section as the read of _current,
                    // so a concurrent Adopt cannot slip between them and have
                    // its Idle overwritten by this Disconnected.
                    PublishStatus();
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

            if (connection is null)
            {
                // A connection that never got past the handshake was never
                // current, so its only status publish is this one.
                PublishStatus();
            }
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
            _currentSession = SessionState.Idle;
            _currentMicPresent = true;

            // Published inside the swap's critical section, so no other
            // publisher can interleave between installing this connection and
            // announcing it.
            PublishStatus();
        }

        if (previous is not null && !ReferenceEquals(previous, connection))
        {
            AgentLog.Info("a newer authenticated connection superseded the previous one");
            _ = Task.Run(previous.Close, CancellationToken.None);
        }
    }

    /// <summary>
    /// Reads _current and publishes it in the SAME critical section. Reading
    /// under the lock and publishing outside it lets two publishers reorder: a
    /// dying non-current connection can read "no current connection", be
    /// preempted while Adopt installs and announces a new one, and then resume
    /// to announce Disconnected. Nothing re-publishes afterwards, so the tray
    /// would latch on a wrong status for as long as that connection lives —
    /// precisely across the window supersession opens. The callback was already
    /// invoked from arbitrary threads, so serialising it changes no contract it
    /// had.
    /// </summary>
    private void PublishStatus()
    {
        lock (_gate)
        {
            PublishStatusLocked();
        }
    }

    private void PublishStatusLocked()
    {
        if (_current is null)
        {
            _onStatus(AgentStatus.Disconnected, null);
            return;
        }

        if (_currentSession == SessionState.Active)
        {
            _onStatus(AgentStatus.Streaming, null);
            return;
        }

        _onStatus(_currentMicPresent ? AgentStatus.Idle : AgentStatus.Degraded, null);
    }

    private void OnConnectionSessionState(ControlConnection connection, SessionState state, bool micPresent)
    {
        lock (_gate)
        {
            if (!ReferenceEquals(_current, connection))
            {
                return;
            }

            _currentSession = state;
            _currentMicPresent = micPresent;
            PublishStatusLocked();
            // Outside the status publish but inside the same critical section:
            // the ledger takes only its own short lock and never waits, so it
            // cannot close a lock cycle with _gate.
            _ledger?.NoteSessionState(
                state == SessionState.Active,
                connection.SendQueue.AudioFramesEvicted + connection.SendQueue.AudioFramesDiscarded);
        }
    }

    private void OnAudioPresenceChanged(bool present)
    {
        ControlConnection? current;
        lock (_gate)
        {
            current = _current;
        }

        current?.OnDevicePresenceChanged(present);
    }

    private void OnAudioCaptureLost()
    {
        ControlConnection? current;
        lock (_gate)
        {
            current = _current;
        }

        current?.OnServiceCaptureLost();
    }
}








