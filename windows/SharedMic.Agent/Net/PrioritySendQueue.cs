using System.Threading.Channels;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Net;

/// <summary>
/// protocol-v1.md section 9. One TCP/TLS connection carries both control and
/// audio, so the sender needs a rule for what goes on the wire first:
///
///   - Control messages are queued UNBOUNDEDLY and are ALWAYS drained before
///     any audio frame. A STOP_ACK or a STATUS must never be stuck behind a
///     backlog of audio.
///   - Audio is a bounded ring of 25 frames (500 ms at 50 fps) that drops the
///     OLDEST frame on overflow and NEVER blocks. Audio production must never
///     be slowed by a stalled connection.
///
/// The two loss counters are kept apart deliberately: evictions mean the
/// network could not keep up and are worth alarming on; teardown discards are
/// intended behavior and alarming on them would be noise. Folding them into one
/// counter makes the number that matters unreadable, and breaks the identity
/// offered = sent + evicted + discarded.
///
/// Phase 1 never calls EnqueueAudio on a live connection.
///
/// Wake-up signalling (fix round 1, finding I-1): an unbounded Channel&lt;byte&gt;
/// is used purely as a waiter/signal mechanism, not as a data path. The token
/// that signals "an item is available" is written and consumed from *inside*
/// the same `_gate` critical section that mutates the queues, so a signal can
/// never desynchronise from the item it stands for. This is safe to do inside
/// the lock — unlike SemaphoreSlim.Release, which can synchronously inline a
/// waiting consumer's continuation and would run arbitrary consumer code on
/// the producer's thread while holding `_gate` — because an unbounded
/// channel's continuations run with AllowSynchronousContinuations left at its
/// default of false, so completing a pending read is always posted to the
/// thread pool rather than executed inline.
/// </summary>
public sealed class PrioritySendQueue
{
    private readonly int _audioCapacity;
    private readonly Queue<byte[]> _control = new();
    private readonly Queue<byte[]> _audio = new();
    private readonly Channel<byte> _signal = Channel.CreateUnbounded<byte>(
        new UnboundedChannelOptions { SingleReader = false, SingleWriter = false, AllowSynchronousContinuations = false });
    private readonly object _gate = new();

    private long _controlFramesQueued;
    private long _audioFramesOffered;
    private long _audioFramesEvicted;
    private long _audioFramesDiscarded;

    public PrioritySendQueue(int audioCapacity = ProtocolConstants.AudioQueueCapacity)
    {
        if (audioCapacity < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(audioCapacity));
        }

        _audioCapacity = audioCapacity;
    }

    public long ControlFramesQueued
    {
        get { lock (_gate) { return _controlFramesQueued; } }
    }

    public long AudioFramesOffered
    {
        get { lock (_gate) { return _audioFramesOffered; } }
    }

    public long AudioFramesEvicted
    {
        get { lock (_gate) { return _audioFramesEvicted; } }
    }

    public long AudioFramesDiscarded
    {
        get { lock (_gate) { return _audioFramesDiscarded; } }
    }

    public int ControlDepth
    {
        get { lock (_gate) { return _control.Count; } }
    }

    public int AudioDepth
    {
        get { lock (_gate) { return _audio.Count; } }
    }

    /// <summary>
    /// Test-only: the number of outstanding wake-up signals not yet matched to
    /// a queued item. Should be exactly 0 at quiescence; anything else is a
    /// phantom-signal leak (see Task 9 fix round 1, finding I-1).
    /// </summary>
    internal int PendingSignalCountForTests
    {
        get { return _signal.Reader.Count; }
    }

    public void EnqueueControl(byte[] frame)
    {
        lock (_gate)
        {
            _control.Enqueue(frame);
            _controlFramesQueued++;

            // Safe under the lock: see the class remarks on AllowSynchronousContinuations.
            _signal.Writer.TryWrite(0);
        }
    }

    public void EnqueueAudio(byte[] frame)
    {
        lock (_gate)
        {
            _audioFramesOffered++;
            var evicted = _audio.Count >= _audioCapacity;
            if (evicted)
            {
                _audio.Dequeue();
                _audioFramesEvicted++;
            }

            _audio.Enqueue(frame);

            // On an eviction the depth is unchanged, so no new signal is owed.
            if (!evicted)
            {
                _signal.Writer.TryWrite(0);
            }
        }
    }

    public bool TryDequeue(out byte[] frame)
    {
        lock (_gate)
        {
            if (_control.Count > 0)
            {
                frame = _control.Dequeue();
                _signal.Reader.TryRead(out _);
                return true;
            }

            if (_audio.Count > 0)
            {
                frame = _audio.Dequeue();
                _signal.Reader.TryRead(out _);
                return true;
            }
        }

        frame = Array.Empty<byte>();
        return false;
    }

    public async ValueTask<byte[]> DequeueAsync(CancellationToken cancellationToken)
    {
        while (true)
        {
            await _signal.Reader.WaitToReadAsync(cancellationToken).ConfigureAwait(false);

            lock (_gate)
            {
                if (_control.Count > 0)
                {
                    _signal.Reader.TryRead(out _);
                    return _control.Dequeue();
                }

                if (_audio.Count > 0)
                {
                    _signal.Reader.TryRead(out _);
                    return _audio.Dequeue();
                }

                // A concurrent DiscardAudio already consumed the signal (and
                // the frame) this wake-up stood for. Nothing to read back out
                // of the channel here; loop and wait for the next one.
            }
        }
    }

    /// <summary>
    /// Drop every queued audio frame, as at session teardown. Counted as
    /// discards, never as evictions. Returns the number dropped.
    /// </summary>
    public int DiscardAudio()
    {
        lock (_gate)
        {
            var discarded = _audio.Count;
            _audio.Clear();
            _audioFramesDiscarded += discarded;

            // Give back the signals those frames owned, inside the same lock
            // that just mutated the queue, so the signal count and the queue
            // depth can never observe each other out of sync.
            for (var i = 0; i < discarded; i++)
            {
                _signal.Reader.TryRead(out _);
            }

            return discarded;
        }
    }
}
