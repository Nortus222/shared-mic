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
/// </summary>
public sealed class PrioritySendQueue
{
    private readonly int _audioCapacity;
    private readonly Queue<byte[]> _control = new();
    private readonly Queue<byte[]> _audio = new();
    private readonly SemaphoreSlim _available = new(0);
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

    public void EnqueueControl(byte[] frame)
    {
        lock (_gate)
        {
            _control.Enqueue(frame);
            _controlFramesQueued++;
        }

        _available.Release();
    }

    public void EnqueueAudio(byte[] frame)
    {
        bool evicted;
        lock (_gate)
        {
            _audioFramesOffered++;
            evicted = _audio.Count >= _audioCapacity;
            if (evicted)
            {
                _audio.Dequeue();
                _audioFramesEvicted++;
            }

            _audio.Enqueue(frame);
        }

        // On an eviction the depth is unchanged, so no new permit is owed.
        if (!evicted)
        {
            _available.Release();
        }
    }

    public bool TryDequeue(out byte[] frame)
    {
        lock (_gate)
        {
            if (_control.Count > 0)
            {
                frame = _control.Dequeue();
                _available.Wait(0);
                return true;
            }

            if (_audio.Count > 0)
            {
                frame = _audio.Dequeue();
                _available.Wait(0);
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
            await _available.WaitAsync(cancellationToken).ConfigureAwait(false);

            lock (_gate)
            {
                if (_control.Count > 0)
                {
                    return _control.Dequeue();
                }

                if (_audio.Count > 0)
                {
                    return _audio.Dequeue();
                }
            }

            // A concurrent DiscardAudio removed the frame this permit stood
            // for. Wait again rather than dequeue from an empty queue.
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

            // Give back the permits those frames owned, inside the lock, so the
            // permit count and the queue depth stay consistent for any waiter.
            for (var i = 0; i < discarded; i++)
            {
                _available.Wait(0);
            }

            return discarded;
        }
    }
}
