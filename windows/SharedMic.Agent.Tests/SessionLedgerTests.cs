using SharedMic.Agent.Diagnostics;
using Xunit;

namespace SharedMic.Agent.Tests;

public class SessionLedgerTests
{
    [Fact]
    public void FreshLedgerCountsZero()
    {
        var snapshot = new SessionLedger().Snapshot();

        Assert.Equal(0, snapshot.SessionsStarted);
        Assert.Equal(0, snapshot.TotalSessionSeconds);
        Assert.Equal(0, snapshot.ActiveSessions);
        Assert.Equal(0, snapshot.SendQueueDrops);
    }

    [Fact]
    public void SessionStartAndStopAccumulateOneSessionAndItsDuration()
    {
        var now = new DateTime(2026, 9, 8, 12, 0, 0, DateTimeKind.Utc);
        var ledger = new SessionLedger(() => now);

        ledger.NoteSessionState(active: true, sendQueueDropsCumulative: 0);
        now = now.AddSeconds(30);
        ledger.NoteSessionState(active: false, sendQueueDropsCumulative: 4);

        var snapshot = ledger.Snapshot();
        Assert.Equal(1, snapshot.SessionsStarted);
        Assert.Equal(30, snapshot.TotalSessionSeconds);
        Assert.Equal(0, snapshot.ActiveSessions);
        Assert.Equal(4, snapshot.SendQueueDrops);
    }

    [Fact]
    public void DuplicateActiveNotesDoNotRestartTheClockOrDoubleCount()
    {
        var now = new DateTime(2026, 9, 8, 12, 0, 0, DateTimeKind.Utc);
        var ledger = new SessionLedger(() => now);

        ledger.NoteSessionState(active: true, sendQueueDropsCumulative: 0);
        now = now.AddSeconds(10);
        ledger.NoteSessionState(active: true, sendQueueDropsCumulative: 0);
        now = now.AddSeconds(10);
        ledger.NoteSessionState(active: false, sendQueueDropsCumulative: 0);

        var snapshot = ledger.Snapshot();
        Assert.Equal(1, snapshot.SessionsStarted);
        Assert.Equal(20, snapshot.TotalSessionSeconds);
    }

    [Fact]
    public void OpenSessionContributesItsLiveAge()
    {
        var now = new DateTime(2026, 9, 8, 12, 0, 0, DateTimeKind.Utc);
        var ledger = new SessionLedger(() => now);

        ledger.NoteSessionState(active: true, sendQueueDropsCumulative: 0);
        now = now.AddSeconds(7);

        var snapshot = ledger.Snapshot();
        Assert.Equal(1, snapshot.ActiveSessions);
        Assert.Equal(7, snapshot.TotalSessionSeconds);
    }

    [Fact]
    public void DropsFoldAcrossConnectionsWithoutDoubleCount()
    {
        var now = new DateTime(2026, 9, 8, 12, 0, 0, DateTimeKind.Utc);
        var ledger = new SessionLedger(() => now);

        // First connection's queue already dropped 100 frames before this
        // session; only the 5 during the session count.
        ledger.NoteSessionState(active: true, sendQueueDropsCumulative: 100);
        ledger.NoteSessionState(active: false, sendQueueDropsCumulative: 105);

        // A fresh connection restarts its queue at zero: the baseline
        // re-arms on the next session start instead of going negative.
        ledger.NoteSessionState(active: true, sendQueueDropsCumulative: 0);
        ledger.NoteSessionState(active: false, sendQueueDropsCumulative: 2);

        Assert.Equal(7, ledger.Snapshot().SendQueueDrops);
    }

    [Fact]
    public void SnapshotComposesMetricsAndLedger()
    {
        var metrics = new AgentMetrics();
        metrics.IncrementConnectionsAccepted();
        metrics.IncrementConnectionsAuthenticated();
        metrics.IncrementAuthFailures();
        metrics.IncrementAudioFramesSent();

        var ledger = new SessionLedger();
        ledger.NoteSessionState(active: true, sendQueueDropsCumulative: 0);
        ledger.NoteSessionState(active: false, sendQueueDropsCumulative: 1);

        var snapshot = WindowsDiagnosticsSnapshot.From(metrics.Snapshot(), ledger.Snapshot());

        Assert.Equal(1, snapshot.SessionsStarted);
        Assert.Equal(1, snapshot.SendQueueDrops);
        Assert.Equal(1, snapshot.ConnectionsAccepted);
        Assert.Equal(1, snapshot.ConnectionsAuthenticated);
        Assert.Equal(1, snapshot.AuthFailures);
        Assert.Equal(1, snapshot.AudioFramesSent);
        Assert.Equal(5, snapshot.ToMenuLines().Count);
    }
}
