using SharedMic.Agent.Net;
using SharedMic.Agent.Protocol;
using Xunit;

namespace SharedMic.Agent.Tests;

public class PrioritySendQueueTests
{
    private static byte[] Marker(FrameType type, byte tag) => new[] { (byte)type, tag };

    [Fact]
    public void DefaultAudioCapacityIsTwentyFiveFrames()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < ProtocolConstants.AudioQueueCapacity; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        Assert.Equal(25, queue.AudioDepth);
        Assert.Equal(0, queue.AudioFramesEvicted);
    }

    [Fact]
    public void ControlIsAlwaysDrainedBeforeAnyAudio()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 25; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        queue.EnqueueControl(Marker(FrameType.Control, 0xFF));

        Assert.True(queue.TryDequeue(out var first));
        Assert.Equal(Marker(FrameType.Control, 0xFF), first);
    }

    [Fact]
    public void OverflowDropsTheOldestFrameAndCountsExactlyOneEvictionPerFrameEvicted()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 30; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        Assert.Equal(30, queue.AudioFramesOffered);
        Assert.Equal(5, queue.AudioFramesEvicted);
        Assert.Equal(25, queue.AudioDepth);

        var survivors = new List<byte>();
        while (queue.TryDequeue(out var frame))
        {
            survivors.Add(frame[1]);
        }

        // The LAST 25 offered survive, so the oldest 5 were the ones evicted,
        // not an arbitrary 5.
        Assert.Equal(Enumerable.Range(5, 25).Select(i => (byte)i).ToArray(), survivors.ToArray());
    }

    [Fact]
    public void ControlIsUnbounded()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 5000; i++)
        {
            queue.EnqueueControl(Marker(FrameType.Control, (byte)(i % 256)));
        }

        Assert.Equal(5000, queue.ControlDepth);
        Assert.Equal(5000, queue.ControlFramesQueued);
    }

    [Fact]
    public void TeardownDiscardsAreCountedSeparatelyFromOverflowEvictions()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 30; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        var discarded = queue.DiscardAudio();

        Assert.Equal(25, discarded);
        Assert.Equal(25, queue.AudioFramesDiscarded);
        Assert.Equal(5, queue.AudioFramesEvicted);
        Assert.Equal(0, queue.AudioDepth);
    }

    [Fact]
    public void FrameCountersReconcile()
    {
        var queue = new PrioritySendQueue();

        for (var i = 0; i < 40; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)i));
        }

        var sent = 0;
        for (var i = 0; i < 10; i++)
        {
            Assert.True(queue.TryDequeue(out _));
            sent++;
        }

        var discarded = queue.DiscardAudio();

        // offered = sent + evicted + discarded
        Assert.Equal(queue.AudioFramesOffered, sent + queue.AudioFramesEvicted + discarded);
    }

    [Fact]
    public void TryDequeueReportsFalseOnAnEmptyQueue()
    {
        var queue = new PrioritySendQueue();

        Assert.False(queue.TryDequeue(out var frame));
        Assert.Empty(frame);
    }

    [Fact]
    public async Task DequeueAsyncWaitsUntilSomethingIsQueued()
    {
        var queue = new PrioritySendQueue();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));

        var pending = queue.DequeueAsync(cancellation.Token).AsTask();
        Assert.False(pending.IsCompleted);

        queue.EnqueueControl(Marker(FrameType.Control, 1));

        Assert.Equal(Marker(FrameType.Control, 1), await pending);
    }

    [Fact]
    public async Task DequeueAsyncPrefersControlOverQueuedAudio()
    {
        var queue = new PrioritySendQueue();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));

        queue.EnqueueAudio(Marker(FrameType.Audio, 1));
        queue.EnqueueControl(Marker(FrameType.Control, 2));

        Assert.Equal(Marker(FrameType.Control, 2), await queue.DequeueAsync(cancellation.Token));
        Assert.Equal(Marker(FrameType.Audio, 1), await queue.DequeueAsync(cancellation.Token));
    }

    [Fact]
    public async Task DequeueAsyncHonoursCancellation()
    {
        var queue = new PrioritySendQueue();
        using var cancellation = new CancellationTokenSource();

        var pending = queue.DequeueAsync(cancellation.Token).AsTask();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
    }

    [Fact]
    public async Task DiscardingAudioWhileAWaiterIsPendingDoesNotHandItAPhantomFrame()
    {
        var queue = new PrioritySendQueue();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));

        queue.EnqueueAudio(Marker(FrameType.Audio, 1));
        var first = await queue.DequeueAsync(cancellation.Token);
        Assert.Equal(Marker(FrameType.Audio, 1), first);

        queue.EnqueueAudio(Marker(FrameType.Audio, 2));
        queue.DiscardAudio();

        var pending = queue.DequeueAsync(cancellation.Token).AsTask();
        await Task.Delay(100, cancellation.Token);
        Assert.False(pending.IsCompleted);

        queue.EnqueueControl(Marker(FrameType.Control, 3));
        Assert.Equal(Marker(FrameType.Control, 3), await pending);
    }

    [Fact]
    public void EnqueueAudioNeverBlocksEvenWhenFull()
    {
        var queue = new PrioritySendQueue(audioCapacity: 2);
        var stopwatch = System.Diagnostics.Stopwatch.StartNew();

        for (var i = 0; i < 10000; i++)
        {
            queue.EnqueueAudio(Marker(FrameType.Audio, (byte)(i % 256)));
        }

        stopwatch.Stop();
        Assert.Equal(2, queue.AudioDepth);
        Assert.Equal(9998, queue.AudioFramesEvicted);
        Assert.True(stopwatch.Elapsed < TimeSpan.FromSeconds(5), $"enqueue took {stopwatch.Elapsed}");
    }
}
