using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class AuthRateLimiterTests
{
    private sealed class TestClock
    {
        public DateTimeOffset Now { get; set; } = new(2026, 8, 10, 12, 0, 0, TimeSpan.Zero);

        public DateTimeOffset Read() => Now;

        public void Advance(TimeSpan amount) => Now += amount;
    }

    [Fact]
    public void DefaultsMatchTheContract()
    {
        var limiter = new AuthRateLimiter();

        Assert.False(limiter.IsLockedOut);
        Assert.True(limiter.TryBeginAttempt());
        Assert.Equal(TimeSpan.Zero, limiter.LockoutRemaining);
        Assert.Equal(5, ProtocolConstants.MaxAuthFailures);
        Assert.Equal(TimeSpan.FromSeconds(30), ProtocolConstants.AuthLockoutDuration);
    }

    [Fact]
    public void FourFailuresDoNotLockOut()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 4; i++)
        {
            limiter.RecordFailure();
        }

        Assert.False(limiter.IsLockedOut);
        Assert.True(limiter.TryBeginAttempt());
        Assert.Equal(4, limiter.ConsecutiveFailures);
    }

    [Fact]
    public void FifthConsecutiveFailureLocksOutForThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 5; i++)
        {
            limiter.RecordFailure();
        }

        Assert.True(limiter.IsLockedOut);
        Assert.False(limiter.TryBeginAttempt());
        Assert.Equal(TimeSpan.FromSeconds(30), limiter.LockoutRemaining);
        Assert.Equal(1, limiter.LockoutCount);
    }

    [Fact]
    public void LockoutExpiresAfterThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 5; i++)
        {
            limiter.RecordFailure();
        }

        clock.Advance(TimeSpan.FromSeconds(29));
        Assert.True(limiter.IsLockedOut);

        clock.Advance(TimeSpan.FromSeconds(1.5));
        Assert.False(limiter.IsLockedOut);
        Assert.True(limiter.TryBeginAttempt());
        Assert.Equal(TimeSpan.Zero, limiter.LockoutRemaining);
    }

    [Fact]
    public void CounterResetsAfterALockoutSoTheNextFiveFailuresLockAgain()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 5; i++)
        {
            limiter.RecordFailure();
        }

        clock.Advance(TimeSpan.FromSeconds(31));
        Assert.Equal(0, limiter.ConsecutiveFailures);

        for (var i = 0; i < 4; i++)
        {
            limiter.RecordFailure();
        }

        Assert.False(limiter.IsLockedOut);

        limiter.RecordFailure();
        Assert.True(limiter.IsLockedOut);
        Assert.Equal(2, limiter.LockoutCount);
    }

    [Fact]
    public void SuccessClearsTheConsecutiveCount()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        limiter.RecordFailure();
        limiter.RecordFailure();
        limiter.RecordFailure();
        limiter.RecordFailure();
        limiter.RecordSuccess();
        limiter.RecordFailure();

        Assert.Equal(1, limiter.ConsecutiveFailures);
        Assert.False(limiter.IsLockedOut);
    }

    [Fact]
    public void ACorrectTokenIsAlsoRefusedWhileLockedOut()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(clock: clock.Read);

        for (var i = 0; i < 5; i++)
        {
            limiter.RecordFailure();
        }

        // The caller must consult TryBeginAttempt before verifying anything, so
        // the lockout is not a per-credential check but a per-agent one.
        Assert.False(limiter.TryBeginAttempt());
    }

    [Fact]
    public void ShortLockoutsAreConfigurableSoIntegrationTestsDoNotWaitThirtySeconds()
    {
        var clock = new TestClock();
        var limiter = new AuthRateLimiter(maxFailures: 2, lockoutDuration: TimeSpan.FromMilliseconds(200), clock: clock.Read);

        limiter.RecordFailure();
        limiter.RecordFailure();

        Assert.True(limiter.IsLockedOut);
        clock.Advance(TimeSpan.FromMilliseconds(250));
        Assert.False(limiter.IsLockedOut);
    }
}
