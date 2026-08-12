using SharedMic.Agent.Session;
using Xunit;

namespace SharedMic.Agent.Tests;

public class SessionStateMachineTests
{
    private static SessionStateMachine Counting()
    {
        var next = 0;
        return new SessionStateMachine(() => $"sess-{++next:0000}");
    }

    [Fact]
    public void StartsIdle()
    {
        var machine = Counting();

        Assert.Equal(SessionState.Idle, machine.State);
        Assert.Null(machine.SessionId);
        Assert.Equal(0, machine.SessionsStarted);
    }

    [Fact]
    public void StartOpensASession()
    {
        var machine = Counting();

        var outcome = machine.HandleStart(micPresent: true);

        Assert.True(outcome.Accepted);
        Assert.True(outcome.StartedNewSession);
        Assert.Null(outcome.Reason);
        Assert.Equal("sess-0001", outcome.SessionId);
        Assert.Equal(SessionState.Active, machine.State);
        Assert.Equal(1, machine.SessionsStarted);
    }

    [Fact]
    public void DuplicateStartIsIdempotentAndDoesNotOpenASecondSession()
    {
        var machine = Counting();

        var first = machine.HandleStart(micPresent: true);
        var second = machine.HandleStart(micPresent: true);

        Assert.Equal(first.SessionId, second.SessionId);
        Assert.True(second.Accepted);
        Assert.False(second.StartedNewSession);
        Assert.Equal(1, machine.SessionsStarted);
    }

    [Fact]
    public void StartIsRejectedWithMicUnavailableWhenTheMicIsAbsent()
    {
        var machine = Counting();

        var outcome = machine.HandleStart(micPresent: false);

        Assert.False(outcome.Accepted);
        Assert.Equal("MIC_UNAVAILABLE", outcome.Reason);
        Assert.Equal(SessionState.Idle, machine.State);
        Assert.Equal(0, machine.SessionsStarted);
    }

    [Fact]
    public void MicLossDoesNotEndAnAlreadyActiveSessionThroughStart()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        var outcome = machine.HandleStart(micPresent: false);

        Assert.False(outcome.Accepted);
        Assert.Equal(SessionState.Active, machine.State);
    }

    [Fact]
    public void StopEndsTheActiveSessionAndReportsItsId()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        var outcome = machine.HandleStop("sess-0001");

        Assert.True(outcome.EndedSession);
        Assert.Equal("sess-0001", outcome.SessionId);
        Assert.Equal(SessionState.Idle, machine.State);
    }

    [Fact]
    public void StopWhileIdleSucceedsAndEchoesTheRequestedId()
    {
        var machine = Counting();

        var outcome = machine.HandleStop("");

        Assert.False(outcome.EndedSession);
        Assert.Equal("", outcome.SessionId);
        Assert.Equal(SessionState.Idle, machine.State);
    }

    [Fact]
    public void DuplicateStopSucceeds()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        var first = machine.HandleStop("sess-0001");
        var second = machine.HandleStop("sess-0001");

        Assert.True(first.EndedSession);
        Assert.False(second.EndedSession);
        Assert.Equal("sess-0001", second.SessionId);
    }

    [Fact]
    public void StopIsNotRejectedOnASessionIdMismatch()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        var outcome = machine.HandleStop("sess-from-a-previous-connection");

        Assert.True(outcome.EndedSession);
        Assert.Equal("sess-0001", outcome.SessionId);
        Assert.Equal(SessionState.Idle, machine.State);
    }

    [Fact]
    public void StartAfterStopOpensAGenuinelyNewSession()
    {
        var machine = Counting();

        var first = machine.HandleStart(micPresent: true);
        machine.HandleStop(first.SessionId);
        var second = machine.HandleStart(micPresent: true);

        Assert.NotEqual(first.SessionId, second.SessionId);
        Assert.True(second.StartedNewSession);
        Assert.Equal(2, machine.SessionsStarted);
    }

    [Fact]
    public void ResetReturnsToIdleWithoutCountingASession()
    {
        var machine = Counting();
        machine.HandleStart(micPresent: true);

        machine.Reset();

        Assert.Equal(SessionState.Idle, machine.State);
        Assert.Null(machine.SessionId);
        Assert.Equal(1, machine.SessionsStarted);
    }

    [Fact]
    public void DefaultSessionIdsAreDistinct()
    {
        var ids = new HashSet<string>();
        for (var i = 0; i < 64; i++)
        {
            Assert.True(ids.Add(SessionStateMachine.DefaultSessionId()));
        }
    }
}
