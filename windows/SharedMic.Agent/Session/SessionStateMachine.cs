using System.Security.Cryptography;

namespace SharedMic.Agent.Session;

public enum SessionState
{
    Idle,
    Active,
}

/// <summary>Result of handling a START (protocol-v1.md section 7).</summary>
public readonly record struct StartOutcome(bool Accepted, string SessionId, string? Reason, bool StartedNewSession);

/// <summary>Result of handling a STOP (protocol-v1.md section 7).</summary>
public readonly record struct StopOutcome(string SessionId, bool EndedSession);

/// <summary>
/// Session lifecycle as a pure transition function, per design spec section
/// 3.1. No I/O, no sockets, no timers.
///
/// Both START and STOP are idempotent (protocol-v1.md section 7). A duplicate
/// START while active returns the EXISTING sessionId and does not restart
/// anything, which is what makes it safe for the Mac to retry START after a
/// reconnect without knowing whether the previous one landed. A STOP while
/// idle still succeeds, and STOP is never rejected on a sessionId mismatch:
/// STOP means "make sure no session is active on this connection".
///
/// Not thread-safe by design. ControlConnection dispatches every control
/// message from its single read loop.
///
/// Phase 1 note: an active session streams nothing. There is no capture path
/// yet, so State == Active means only that a session identifier is allocated.
///
/// <see cref="StartOutcome.StartedNewSession"/> is the hook the future audio
/// layer resets its sequence counter on: sequence resets to 0 if and only if
/// StartedNewSession is true (protocol-v1.md section 7). A duplicate START
/// leaves the sequence counter untouched. Phase 1 emits no audio, so nothing
/// here can prove that end to end &#8212; this class only guarantees the signal
/// StartedNewSession is correct.
///
/// <see cref="StartOutcome.SessionId"/> on a rejected (NACK) outcome is
/// diagnostic only: START_NACK on the wire carries just requestId and reason
/// (protocol-v1.md section 7), so this value is never wire-visible. It is
/// populated when a session is already active (so logs can show which
/// session the NACK applied to) and empty when idle (there is no session to
/// report).
/// </summary>
public sealed class SessionStateMachine
{
    private readonly Func<string> _sessionIdFactory;
    private string? _sessionId;

    public SessionStateMachine(Func<string>? sessionIdFactory = null) =>
        _sessionIdFactory = sessionIdFactory ?? DefaultSessionId;

    public static string DefaultSessionId() =>
        "sess-" + Convert.ToHexString(RandomNumberGenerator.GetBytes(8)).ToLowerInvariant();

    public SessionState State => _sessionId is null ? SessionState.Idle : SessionState.Active;

    public string? SessionId => _sessionId;

    public long SessionsStarted { get; private set; }

    public StartOutcome HandleStart(bool micPresent)
    {
        if (_sessionId is not null)
        {
            // An already-active session's state is not disturbed by a later
            // mic loss report on a duplicate START; that path is a STATUS in
            // Phase 2, not a session teardown. The outcome itself still
            // reflects the current mic reading so the caller knows not to
            // treat this as a healthy re-ack.
            return micPresent
                ? new StartOutcome(true, _sessionId, null, false)
                : new StartOutcome(false, _sessionId, "MIC_UNAVAILABLE", false);
        }

        if (!micPresent)
        {
            return new StartOutcome(false, string.Empty, "MIC_UNAVAILABLE", false);
        }

        _sessionId = _sessionIdFactory();
        SessionsStarted++;
        return new StartOutcome(true, _sessionId, null, true);
    }

    public StopOutcome HandleStop(string requestedSessionId)
    {
        var ended = _sessionId;
        _sessionId = null;
        return ended is null
            ? new StopOutcome(requestedSessionId, false)
            : new StopOutcome(ended, true);
    }

    public void Reset() => _sessionId = null;
}
