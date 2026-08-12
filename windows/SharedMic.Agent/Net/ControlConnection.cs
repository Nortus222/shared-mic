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
///
/// Boundary typing: ControlCodec.Validate proves a field is PRESENT, never that
/// it holds the right JSON type. {"type":"PING","v":1,"seq":"abc"} decodes
/// clean, and a seq outside the Int64 range decodes as a double. Every field
/// read below therefore goes through a pattern match rather than a cast; a cast
/// would raise InvalidCastException and replace the protocol's defined
/// behaviour with an unhandled exception.
/// </summary>
public sealed class ControlConnection : IAsyncDisposable
{
    /// <summary>How long teardown waits for the writer and liveness loops before abandoning them.</summary>
    private static readonly TimeSpan LoopDrainTimeout = TimeSpan.FromSeconds(5);

    private readonly Stream _stream;
    private readonly AgentIdentity _identity;
    private readonly AgentOptions _options;
    private readonly AuthRateLimiter _rateLimiter;
    private readonly AgentMetrics _metrics;
    private readonly SessionStateMachine _session = new();
    private readonly PrioritySendQueue _queue = new();
    private readonly CancellationTokenSource _closing = new();
    private readonly byte[] _nonce = AuthProof.GenerateNonce();

    // Monotonic milliseconds, never wall-clock. DateTime.UtcNow moves when NTP
    // steps the clock or an operator changes it, and a backwards-to-forwards
    // jump larger than PeerDeadTimeout would disconnect a perfectly healthy
    // idle peer. Environment.TickCount64 only ever counts forward.
    private long _lastPeerActivityMs;

    // Written on the read loop, read on the liveness loop. Volatile so the
    // cross-thread read is an explicit decision rather than an accident; the
    // worst case without it is one poll interval of staleness, which is benign
    // but not something a reader should have to derive.
    private volatile bool _isAuthenticated;

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

    public bool IsAuthenticated => _isAuthenticated;

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

            // The stream is disposed BEFORE the loops are awaited, and the
            // ordering is the whole point. Cancelling a token does not reliably
            // abort a write already in flight — neither Socket nor SslStream
            // guarantees it — and disposing the stream does. A peer that stops
            // reading fills the TCP send window, parks the writer inside
            // WriteAsync, and then goes silent; the liveness loop calls Close()
            // and the read loop returns, but awaiting the writer first would
            // then block forever on a write only this dispose can unstick, and
            // RunAsync would never complete. That would leave the socket held
            // and make section 6's supersession of an older connection
            // impossible. Disposing first turns the stalled write into an
            // ObjectDisposedException the writer already handles.
            //
            // It also satisfies protocol-v1.md section 3 on every exit path:
            // a violation requires CLOSING the connection, not merely ceasing
            // to read it, and doing that here means it does not depend on the
            // owner remembering to dispose this object.
            try
            {
                await _stream.DisposeAsync().ConfigureAwait(false);
            }
            catch (Exception)
            {
                // Disposing an already-faulted stream is not interesting.
            }

            // Bounded even so. These awaits exist to make teardown orderly, not
            // to make it a place RunAsync can be trapped: any future stream
            // implementation whose Dispose does not unblock a pending write
            // should cost a few seconds and a warning, not the connection
            // object.
            await DrainAsync(writer, "writer").ConfigureAwait(false);
            await DrainAsync(liveness, "liveness").ConfigureAwait(false);
        }
    }

    private async Task DrainAsync(Task loop, string name)
    {
        try
        {
            await loop.WaitAsync(LoopDrainTimeout).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            AgentLog.Warn($"the {name} loop for {RemoteDescription} did not finish within " +
                          $"{LoopDrainTimeout.TotalSeconds:F0} s; abandoning it");
        }
        catch (Exception)
        {
            // Cancellation, or an error the loop has already handled and logged.
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
                    FailAuthentication("the pre-auth deadline expired");
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
                    FailAuthentication("the pre-auth deadline expired");
                }

                return;
            }
            catch (ProtocolException exception)
            {
                // Sanitised even though ControlCodec already sanitises the
                // untrusted fragments it interpolates: this message is the one
                // place a pre-authentication peer's bytes reach a log line, and
                // one layer of defence at each end costs nothing.
                var detail = AgentLog.SanitizeMessage(exception.Message);
                AgentLog.Warn($"closing {RemoteDescription}: protocol violation: {detail}");
                if (!IsAuthenticated)
                {
                    FailAuthentication(detail);
                }

                return;
            }
            catch (Exception exception) when (exception is IOException or ObjectDisposedException)
            {
                // An abortive close is still a connection that reached section 6
                // without a verified HELLO, so section 11.4 counts it exactly as
                // the clean-EOF path below does. Not counted when the agent is
                // the one shutting down: that is our decision, not a peer
                // failure, and counting it would let a normal restart eat into
                // the lockout budget.
                if (!IsAuthenticated && !cancellationToken.IsCancellationRequested)
                {
                    FailAuthentication($"the connection faulted before authenticating ({exception.GetType().Name})");
                }

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
                var detail = AgentLog.SanitizeMessage(exception.Message);
                AgentLog.Warn($"closing {RemoteDescription}: {detail}");
                if (!IsAuthenticated)
                {
                    FailAuthentication(detail);
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

        // ControlCodec.Validate guarantees "type" is one of the eleven known
        // strings, so this pattern match cannot fail for a decoded message; it
        // is written as a match rather than a cast so a future codec change
        // cannot turn a malformed message into an InvalidCastException.
        var type = message["type"] as string;
        if (type != "HELLO")
        {
            FailAuthentication($"expected HELLO before authentication, got {type}");
            return false;
        }

        // protocol-v1.md section 5: mac is a string of 64 lowercase hex
        // characters. Nothing else in the stack enforces that shape, and
        // Convert.FromHexString would happily accept uppercase or a short
        // string, so the check is made here before the proof is used.
        if (message["mac"] is not string mac || !IsLowercaseSha256Hex(mac))
        {
            FailAuthentication("the HELLO mac is not 64 lowercase hex characters");
            return false;
        }

        if (!AuthProof.Verify(_identity.Token, _nonce, mac))
        {
            FailAuthentication("the HMAC proof did not verify");
            return false;
        }

        _rateLimiter.RecordSuccess();
        _isAuthenticated = true;
        _metrics.IncrementConnectionsAuthenticated();

        // Queue HELLO_ACK before flipping any observable state, so nothing can
        // slip ahead of it on the control queue.
        SendControl(ControlMessages.HelloAck(_identity.ServerId, _options.MicPresent, _options.DeviceLabel));
        AgentLog.Info(
            $"authenticated client '{AgentLog.Sanitize(message.GetValueOrDefault("clientId"))}' from {RemoteDescription}");
        Authenticated?.Invoke(this);
        return true;
    }

    /// <summary>Exactly 64 characters, each of 0-9 or a-f. Never logs its argument.</summary>
    private static bool IsLowercaseSha256Hex(string value)
    {
        if (value.Length != 64)
        {
            return false;
        }

        foreach (var character in value)
        {
            if (!(character is >= '0' and <= '9' or >= 'a' and <= 'f'))
            {
                return false;
            }
        }

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
                    // Present but not an integer. protocol-v1.md section 5
                    // requires fields to be present, and section 9's forgiving
                    // rule says a well-formed message the receiver cannot act
                    // on is ignored rather than fatal; a PING the agent cannot
                    // echo costs the peer one heartbeat, not the connection.
                    _metrics.IncrementUnexpectedControlMessages();
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
                    _metrics.IncrementUnexpectedControlMessages();
                    AgentLog.Warn($"ignoring a START from {RemoteDescription} whose requestId is not a string");
                    break;
                }

                var outcome = _session.HandleStart(_options.MicPresent);
                if (!outcome.Accepted)
                {
                    AgentLog.Info($"START {AgentLog.Sanitize(requestId)} rejected: {outcome.Reason}");
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
                    AgentLog.Info(
                        $"duplicate START {AgentLog.Sanitize(requestId)} returned the existing session {outcome.SessionId}");
                }

                SendControl(ControlMessages.StartAck(requestId, outcome.SessionId));
                break;
            }

            case "STOP":
            {
                if (message["requestId"] is not string requestId)
                {
                    _metrics.IncrementUnexpectedControlMessages();
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

                var idle = TimeSpan.FromMilliseconds(Environment.TickCount64 - Interlocked.Read(ref _lastPeerActivityMs));
                if (idle > _options.PeerDeadTimeout)
                {
                    _metrics.IncrementDeadPeerDisconnects();
                    AgentLog.Warn(
                        $"{RemoteDescription} sent nothing for {idle.TotalSeconds:F1} s " +
                        $"(limit {_options.PeerDeadTimeout.TotalSeconds:F1} s) — declaring the peer dead");
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

    private void Touch() => Interlocked.Exchange(ref _lastPeerActivityMs, Environment.TickCount64);
}
