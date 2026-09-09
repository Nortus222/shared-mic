using SharedMic.Agent.Audio;
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
/// With an AudioContext attached, an active session streams real microphone
/// audio: capture frames arrive on the WASAPI event thread through
/// ICaptureSink and are enqueued behind control traffic per section 9.
/// Without one the agent keeps its Phase 1 behavior and streams nothing.
///
/// Threading: control messages are dispatched on the single read loop, but
/// device notifications and capture loss arrive on arbitrary threads, so every
/// session-state and capture transition holds _sessionGate. The writer runs on
/// its own task and touches only the queue and the stream.
///
/// Boundary typing: ControlCodec.Validate proves a field is PRESENT, never that
/// it holds the right JSON type. {"type":"PING","v":1,"seq":"abc"} decodes
/// clean, and a seq outside the Int64 range decodes as a double. Every field
/// read below therefore goes through a pattern match rather than a cast; a cast
/// would raise InvalidCastException and replace the protocol's defined
/// behaviour with an unhandled exception.
/// </summary>
public sealed class ControlConnection : IAsyncDisposable, ICaptureSink
{
    /// <summary>How long teardown waits for the writer and liveness loops before abandoning them.</summary>
    private static readonly TimeSpan LoopDrainTimeout = TimeSpan.FromSeconds(5);

    private readonly Stream _stream;
    private readonly AgentIdentity _identity;
    private readonly AgentOptions _options;
    private readonly AuthRateLimiter _rateLimiter;
    private readonly AgentMetrics _metrics;
    private readonly SessionStateMachine _session = new();
    private readonly AudioContext? _audio;
    private readonly object _sessionGate = new();
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
        AgentMetrics metrics,
        AudioContext? audio = null)
    {
        _stream = stream;
        _identity = identity;
        _options = options;
        _rateLimiter = rateLimiter;
        _metrics = metrics;
        _audio = audio;
        if (_audio is not null)
        {
            _audio.PresenceChanged += OnDevicePresenceChanged;
            _audio.CaptureLost += OnServiceCaptureLost;
        }
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
            UnsubscribeAudio();
            lock (_sessionGate)
            {
                StopCaptureLocked();
                _session.Reset();
            }

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
        UnsubscribeAudio();

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
                // Logged, NEVER counted. See FailAuthentication's doc comment
                // for the §11.4 counting rule this implements, and the test
                // APeerThatDropsWithoutSendingAnythingIsNotAFailedAttempt that
                // pins it:
                // a connection that dropped without ever producing a decoded
                // control message never consulted the HMAC oracle, so counting
                // it buys no security and hands anyone on the LAN a lockout
                // primitive that costs five TCP connections and no token
                // knowledge.
                if (!IsAuthenticated && !cancellationToken.IsCancellationRequested)
                {
                    AgentLog.Info(
                        $"{RemoteDescription} faulted before authenticating ({exception.GetType().Name}); " +
                        "not counted as a failed attempt");
                }

                return;
            }

            if (frame is null)
            {
                // Logged, NEVER counted, for the same reason as the fault path
                // above. A Mac that roams Wi-Fi, sleeps, or has its lid closed
                // mid-handshake must not be able to spend the legitimate user's
                // lockout budget.
                AgentLog.Info($"{RemoteDescription} closed the connection");
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
        SendControl(ControlMessages.HelloAck(_identity.ServerId, CachedMicPresent(), EffectiveDeviceLabel()));
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

    /// <summary>
    /// The ONLY place a section 11.4 failed attempt is counted. Call it exactly
    /// when the peer produced something the agent had to evaluate and rejected —
    /// a wrong mac, a malformed or non-HELLO message, an AUDIO frame before
    /// authentication — or when the 5-second pre-auth deadline expired. Those
    /// are the three cases section 11.4 enumerates, and they are the same set
    /// the Python reference counts (harness server.py counts in one place, inside
    /// its wrong-type-or-bad-proof branch).
    ///
    /// Do NOT call it for a connection that simply went away: a clean EOF or an
    /// IOException before any control message was decoded. Counting those is a
    /// strictly worse trade. It buys nothing — such a peer never consulted the
    /// HMAC verification oracle this limiter exists to throttle — and it creates
    /// a pre-auth denial-of-service cheaper than the guessing attack being
    /// defended against: five open-and-drop TCP connections per 30 s, requiring
    /// no token knowledge and no cryptographic work, lock the legitimate Mac out
    /// indefinitely. It also fires on ordinary bad luck (a Wi-Fi roam, a closed
    /// lid), where a Mac that auto-retries can loop itself out forever.
    /// A connect-and-hold peer stays covered by the deadline, which IS counted.
    /// </summary>
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

                StartOutcome outcome;
                lock (_sessionGate)
                {
                    outcome = _session.HandleStart(EffectiveMicPresent());
                    if (outcome.Accepted && outcome.StartedNewSession && _audio?.Capture is not null)
                    {
                        _audio.Router.SetTarget(this);
                        if (!_audio.Capture.TryStart(this, out _))
                        {
                            _audio.Router.ClearTarget(this);
                            _session.HandleStop(outcome.SessionId);
                            outcome = new StartOutcome(false, string.Empty, "MIC_UNAVAILABLE", false);
                        }
                    }
                }

                if (!outcome.Accepted)
                {
                    AgentLog.Info($"START {AgentLog.Sanitize(requestId)} rejected: {outcome.Reason}");
                    SendControl(ControlMessages.StartNack(requestId, outcome.Reason!));
                    break;
                }

                if (outcome.StartedNewSession)
                {
                    _metrics.IncrementSessionsStarted();
                    AgentLog.Info($"session {outcome.SessionId} started");
                }
                else
                {
                    AgentLog.Info(
                        $"duplicate START {AgentLog.Sanitize(requestId)} returned the existing session {outcome.SessionId}");
                }

                SendControl(ControlMessages.StartAck(requestId, outcome.SessionId));
                RaiseSessionStateChanged();
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
                StopOutcome outcome;
                lock (_sessionGate)
                {
                    outcome = _session.HandleStop(requested);
                    StopCaptureLocked();
                }

                var discarded = _queue.DiscardAudio();
                if (outcome.EndedSession)
                {
                    AgentLog.Info($"session {outcome.SessionId} ended; discarded {discarded} queued audio frames{CapturePeaks()}");
                }

                SendControl(ControlMessages.StopAck(requestId, outcome.SessionId));
                RaiseSessionStateChanged();
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

    public void OnCaptureFrame(byte[] pcm, uint sequence, ulong timestampUs) =>
        _queue.EnqueueAudio(FrameCodec.EncodeFrame(FrameType.Audio, AudioPayloadCodec.EncodeAudioPayload(sequence, timestampUs, pcm)));

    public event Action<ControlConnection, SessionState, bool>? SessionStateChanged;

    public void OnDevicePresenceChanged(bool present)
    {
        if (present)
        {
            SendStatus();
            RaiseSessionStateChanged();
            return;
        }

        HandleMicLost();
    }

    public void OnServiceCaptureLost() => HandleMicLost();

    private void HandleMicLost()
    {
        bool hadSession;
        lock (_sessionGate)
        {
            hadSession = _session.State == SessionState.Active;
            if (hadSession)
            {
                var ended = _session.HandleStop(_session.SessionId ?? string.Empty);
                StopCaptureLocked();
                AgentLog.Warn($"session {ended.SessionId} ended by microphone loss; no STOP was asked for");
            }
        }

        if (hadSession)
        {
            _queue.DiscardAudio();
        }

        SendStatus();
        RaiseSessionStateChanged();
    }

    private void SendStatus()
    {
        SessionState state;
        bool micPresent;
        string label;
        lock (_sessionGate)
        {
            state = _session.State;
            micPresent = CachedMicPresent();
            label = EffectiveDeviceLabel();
        }

        SendControl(ControlMessages.Status(micPresent, state == SessionState.Active, label));
    }

    private void RaiseSessionStateChanged()
    {
        SessionState state;
        bool micPresent;
        lock (_sessionGate)
        {
            state = _session.State;
            micPresent = CachedMicPresent();
        }

        SessionStateChanged?.Invoke(this, state, micPresent);
    }

    private bool EffectiveMicPresent() => _options.MicPresent && (_audio?.RefreshPresence() ?? true);

    private bool CachedMicPresent() => _options.MicPresent && (_audio?.CachedPresence ?? true);

    private string EffectiveDeviceLabel() => _audio?.Devices?.DeviceLabel ?? _options.DeviceLabel;

    private string CapturePeaks()
    {
        var capture = _audio?.Capture;
        if (capture is null)
        {
            return string.Empty;
        }

        return $" (channel peaks L={capture.SessionPeakLeft:F3} R={capture.SessionPeakRight:F3})";
    }

    private void StopCaptureLocked()
    {
        var audio = _audio;
        if (audio?.Capture is null)
        {
            return;
        }

        audio.Router.ClearTarget(this);
        audio.Capture.Stop(this);
    }

    private void UnsubscribeAudio()
    {
        var audio = _audio;
        if (audio is null)
        {
            return;
        }

        audio.PresenceChanged -= OnDevicePresenceChanged;
        audio.CaptureLost -= OnServiceCaptureLost;
    }

    private void SendControl(IReadOnlyDictionary<string, object?> message) =>
        _queue.EnqueueControl(FrameCodec.EncodeFrame(FrameType.Control, ControlCodec.Encode(message)));

    private void Touch() => Interlocked.Exchange(ref _lastPeerActivityMs, Environment.TickCount64);
}







