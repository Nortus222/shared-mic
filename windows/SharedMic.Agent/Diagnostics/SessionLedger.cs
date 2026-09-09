namespace SharedMic.Agent.Diagnostics;

/// <summary>
/// Point-in-time session accounting for the diagnostics view.
/// </summary>
public sealed record SessionLedgerSnapshot(
    long SessionsStarted,
    double TotalSessionSeconds,
    int ActiveSessions,
    long SendQueueDrops);

/// <summary>
/// Cross-connection session durations and send-queue drops (spec section 11,
/// Phase 4 Task 10). Fed from `TlsListener.OnConnectionSessionState`, which
/// is the single funnel every session transition passes through — START,
/// STOP, mic loss, and disconnect alike.
///
/// Threading: `NoteSessionState` runs on connection read loops while the
/// listener holds its own lock, so this takes only its own short lock and
/// never waits on anything else. `Snapshot` is safe from any thread.
/// </summary>
public sealed class SessionLedger
{
    private readonly object _gate = new();
    private readonly Func<DateTime> _clock;
    private DateTime? _activeSince;
    private long _dropsBaseline;
    private long _sessionsStarted;
    private double _totalSessionSeconds;
    private long _sendQueueDrops;

    public SessionLedger(Func<DateTime>? clock = null)
    {
        _clock = clock ?? (() => DateTime.UtcNow);
    }

    /// <param name="active">Whether a session is open after this transition.</param>
    /// <param name="sendQueueDropsCumulative">
    /// The connection's cumulative evicted + discarded audio frames. The
    /// ledger diffs against the session-start baseline, so per-connection
    /// counters fold into a cross-connection total with no double count.
    /// </param>
    public void NoteSessionState(bool active, long sendQueueDropsCumulative)
    {
        lock (_gate)
        {
            if (active)
            {
                if (_activeSince is null)
                {
                    _activeSince = _clock();
                    _dropsBaseline = sendQueueDropsCumulative;
                    _sessionsStarted++;
                }

                return;
            }

            if (_activeSince is not null)
            {
                _totalSessionSeconds += (_clock() - _activeSince.Value).TotalSeconds;
                _activeSince = null;
            }

            _sendQueueDrops += Math.Max(0, sendQueueDropsCumulative - _dropsBaseline);
            _dropsBaseline = sendQueueDropsCumulative;
        }
    }

    public SessionLedgerSnapshot Snapshot()
    {
        lock (_gate)
        {
            var open = _activeSince is { } began ? (_clock() - began).TotalSeconds : 0;
            return new SessionLedgerSnapshot(
                _sessionsStarted,
                _totalSessionSeconds + open,
                _activeSince is null ? 0 : 1,
                _sendQueueDrops);
        }
    }
}

/// <summary>
/// The full spec section 11 counter set the tray diagnostics section
/// displays, Windows-owned half: connection/auth history from
/// `AgentMetrics`, session history from `SessionLedger`.
/// </summary>
public sealed record WindowsDiagnosticsSnapshot(
    long SessionsStarted,
    double TotalSessionSeconds,
    int ActiveSessions,
    long SendQueueDrops,
    long ConnectionsAccepted,
    long ConnectionsAuthenticated,
    long AuthFailures,
    long ControlMessagesSent,
    long ControlMessagesReceived,
    long AudioFramesSent)
{
    public static WindowsDiagnosticsSnapshot From(
        AgentMetricsSnapshot metrics, SessionLedgerSnapshot sessions) => new(
        sessions.SessionsStarted,
        sessions.TotalSessionSeconds,
        sessions.ActiveSessions,
        sessions.SendQueueDrops,
        metrics.ConnectionsAccepted,
        metrics.ConnectionsAuthenticated,
        metrics.AuthFailures,
        metrics.ControlMessagesSent,
        metrics.ControlMessagesReceived,
        metrics.AudioFramesSent);

    public IReadOnlyList<string> ToMenuLines() => new[]
    {
        $"Sessions: {SessionsStarted} ({TotalSessionSeconds:N0}s total)",
        $"Send-queue drops: {SendQueueDrops}",
        $"Connections: {ConnectionsAccepted} accepted, {ConnectionsAuthenticated} authed",
        $"Auth failures: {AuthFailures}",
        $"Audio frames sent: {AudioFramesSent}",
    };
}
