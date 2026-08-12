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
