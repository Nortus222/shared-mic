using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// protocol-v1.md section 11.4: after 5 consecutive failed authentication
/// attempts, refuse further attempts for 30 seconds. A failed attempt is any
/// connection that reaches the section 6 handshake without producing a
/// verified HELLO: a wrong mac, a malformed or non-HELLO message, or the
/// 5-second pre-auth deadline expiring.
///
/// The lockout is counted PER AGENT, not per source address. One instance is
/// shared by every connection, so an attacker choosing source ports freely
/// cannot reset it.
///
/// Without this, the handshake is an unthrottled HMAC verification oracle
/// reachable by anything that can open a TCP connection to the listener.
/// </summary>
public sealed class AuthRateLimiter
{
    private readonly int _maxFailures;
    private readonly TimeSpan _lockoutDuration;
    private readonly Func<DateTimeOffset> _clock;
    private readonly object _gate = new();

    private int _consecutiveFailures;
    private long _lockoutCount;
    private DateTimeOffset _lockedUntil = DateTimeOffset.MinValue;

    public AuthRateLimiter(
        int maxFailures = ProtocolConstants.MaxAuthFailures,
        TimeSpan? lockoutDuration = null,
        Func<DateTimeOffset>? clock = null)
    {
        if (maxFailures < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(maxFailures));
        }

        _maxFailures = maxFailures;
        _lockoutDuration = lockoutDuration ?? ProtocolConstants.AuthLockoutDuration;
        _clock = clock ?? (() => DateTimeOffset.UtcNow);
    }

    public int ConsecutiveFailures
    {
        get
        {
            lock (_gate)
            {
                ExpireLockout();
                return _consecutiveFailures;
            }
        }
    }

    public long LockoutCount
    {
        get
        {
            lock (_gate)
            {
                return _lockoutCount;
            }
        }
    }

    public bool IsLockedOut
    {
        get
        {
            lock (_gate)
            {
                ExpireLockout();
                return _clock() < _lockedUntil;
            }
        }
    }

    public TimeSpan LockoutRemaining
    {
        get
        {
            lock (_gate)
            {
                var remaining = _lockedUntil - _clock();
                return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
            }
        }
    }

    /// <summary>
    /// Call this before verifying any proof. False means the agent is locked
    /// out and the connection must be closed without evaluating the credential.
    /// </summary>
    public bool TryBeginAttempt() => !IsLockedOut;

    public void RecordFailure()
    {
        lock (_gate)
        {
            ExpireLockout();
            if (_clock() < _lockedUntil)
            {
                // Still locked out: attempts made while locked out must not be
                // counted and must not extend or renew the lockout. Callers are
                // expected to check TryBeginAttempt() first, but this guard makes
                // the guarantee structural rather than relying on caller
                // discipline alone.
                return;
            }

            _consecutiveFailures++;
            if (_consecutiveFailures >= _maxFailures)
            {
                _lockedUntil = _clock() + _lockoutDuration;
                _consecutiveFailures = 0;
                _lockoutCount++;
            }
        }
    }

    public void RecordSuccess()
    {
        lock (_gate)
        {
            _consecutiveFailures = 0;
            _lockedUntil = DateTimeOffset.MinValue;
        }
    }

    private void ExpireLockout()
    {
        if (_lockedUntil != DateTimeOffset.MinValue && _clock() >= _lockedUntil)
        {
            _lockedUntil = DateTimeOffset.MinValue;
        }
    }
}
