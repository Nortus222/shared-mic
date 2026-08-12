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

    // Fix round 1, finding I-2: the previous "race" test never actually ran
    // concurrently. This one drives real producer/consumer/discarder threads
    // for a bounded duration, then quiesces and checks both the accounting
    // identity and that no phantom wake-up signals are left outstanding
    // (finding I-1 shows up here as PendingSignalCountForTests != 0).
    //
    // The race that finding I-1 describes lives at the start/stop boundary
    // of a run (a producer mid-way through Enqueue*, past the lock but not
    // yet at Release/signal, exactly when a consumer or discarder empties
    // the queue out from under it), so this runs many short bounded trials
    // rather than one long one: more boundary crossings, more chances to
    // observe it, each trial still fixed-duration and deterministic to stop.
    [Fact]
    public async Task ConcurrentProducersConsumerAndDiscarderReconcileWithNoPhantomSignals()
    {
        const int trials = 25;

        for (var trial = 0; trial < trials; trial++)
        {
            var queue = new PrioritySendQueue();
            var producerCount = Math.Max(4, Environment.ProcessorCount);
            using var runFor = new CancellationTokenSource(TimeSpan.FromMilliseconds(60));

            var producers = Enumerable.Range(0, producerCount).Select(p => Task.Run(() =>
            {
                var i = 0;
                while (!runFor.IsCancellationRequested)
                {
                    if (i % 17 == 0)
                    {
                        queue.EnqueueControl(Marker(FrameType.Control, (byte)(i % 256)));
                    }
                    else
                    {
                        queue.EnqueueAudio(Marker(FrameType.Audio, (byte)(i % 256)));
                    }

                    i++;
                }
            })).ToArray();

            var discarder = Task.Run(() =>
            {
                while (!runFor.IsCancellationRequested)
                {
                    queue.DiscardAudio();
                }
            });

            long received = 0;
            using var consumerCts = CancellationTokenSource.CreateLinkedTokenSource(runFor.Token);
            var consumer = Task.Run(async () =>
            {
                try
                {
                    while (true)
                    {
                        await queue.DequeueAsync(consumerCts.Token);
                        Interlocked.Increment(ref received);
                    }
                }
                catch (OperationCanceledException)
                {
                    // Expected once the run window closes.
                }
            });

            await Task.WhenAll(producers);
            await discarder;

            // Stop the consumer in the same instant the run window closes (no
            // grace period) so a wake-up signal still in flight from a
            // producer's delayed Release/signal is not silently absorbed as a
            // spurious wake before we inspect it. The remaining real items
            // are mopped up synchronously below, which reconciles
            // item-backed signals but not phantom (item-less) ones.
            consumerCts.Cancel();
            try
            {
                await consumer;
            }
            catch (OperationCanceledException)
            {
                // Expected: cancellation races the consumer's own loop exit.
            }

            while (queue.TryDequeue(out _))
            {
                received++;
            }

            var offered = queue.ControlFramesQueued + queue.AudioFramesOffered;
            var accountedFor = received + queue.AudioFramesEvicted + queue.AudioFramesDiscarded;

            Assert.Equal(offered, accountedFor);
            Assert.Equal(0, queue.ControlDepth + queue.AudioDepth);
            Assert.Equal(0, queue.PendingSignalCountForTests);
        }
    }
}
