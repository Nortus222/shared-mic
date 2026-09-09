namespace SharedMic.Agent.Audio;

public sealed class CaptureRouter : ICaptureSink
{
    private ICaptureSink? _target;
    private long _framesRouted;
    private long _framesDroppedNoTarget;

    public long FramesRouted => Interlocked.Read(ref _framesRouted);

    public long FramesDroppedNoTarget => Interlocked.Read(ref _framesDroppedNoTarget);

    public void SetTarget(ICaptureSink sink) => Interlocked.Exchange(ref _target, sink);

    public void ClearTarget(ICaptureSink sink) =>
        Interlocked.CompareExchange(ref _target, null, sink);

    public void OnCaptureFrame(byte[] pcm, uint sequence, ulong timestampUs)
    {
        ICaptureSink? target = Volatile.Read(ref _target);
        if (target is null)
        {
            Interlocked.Increment(ref _framesDroppedNoTarget);
            return;
        }

        Interlocked.Increment(ref _framesRouted);
        target.OnCaptureFrame(pcm, sequence, timestampUs);
    }
}
