using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Audio;

public sealed class MicCaptureService : IDisposable
{
    private readonly string _endpointId;
    private readonly ICaptureSink _sink;
    private readonly IAudioCaptureFactory _factory;
    private readonly object _gate = new();
    private readonly List<float> _pending = new();

    private IAudioCapture? _capture;
    private object? _owner;
    private int _inputFramesPerGroup;
    private int _inputChannels;
    private int _inputSampleRate;
    private uint _sequence;
    private float _sessionPeakLeft;
    private float _sessionPeakRight;
    private bool _running;
    private bool _disposed;

    public MicCaptureService(
        string endpointId, ChannelMode mode, ICaptureSink sink, IAudioCaptureFactory factory)
    {
        _endpointId = endpointId;
        Mode = mode;
        _sink = sink;
        _factory = factory;
    }

    public event Action? CaptureLost;

    public ChannelMode Mode { get; set; }

    public bool IsRunning
    {
        get { lock (_gate) { return _running; } }
    }

    public float LastPeak { get; private set; }

    public float SessionPeakLeft { get { lock (_gate) { return _sessionPeakLeft; } } }

    public float SessionPeakRight { get { lock (_gate) { return _sessionPeakRight; } } }

    public bool TryStart(out string? failureReason)
    {
        lock (_gate)
        {
            if (_running)
            {
                failureReason = null;
                return true;
            }

            return StartLocked(null, out failureReason);
        }
    }

    public bool TryStart(object owner, out string? failureReason)
    {
        lock (_gate)
        {
            if (_running && ReferenceEquals(_owner, owner))
            {
                failureReason = null;
                return true;
            }

            if (_running)
            {
                StopLocked();
            }

            return StartLocked(owner, out failureReason);
        }
    }

    public void Stop()
    {
        IAudioCapture? capture;
        lock (_gate)
        {
            capture = DetachLocked();
        }

        Teardown(capture);
    }

    public void Stop(object owner)
    {
        IAudioCapture? capture;
        lock (_gate)
        {
            if (!_running)
            {
                return;
            }

            if (_owner is not null && !ReferenceEquals(_owner, owner))
            {
                return;
            }

            capture = DetachLocked();
        }

        Teardown(capture);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
        }

        Stop();
    }

    private bool StartLocked(object? owner, out string? failureReason)
    {
        ThrowIfDisposed();

        IAudioCapture capture;
        try
        {
            capture = _factory.Open(_endpointId);
        }
        catch (Exception)
        {
            failureReason = "MIC_UNAVAILABLE";
            return false;
        }

        try
        {
            capture.Start();
        }
        catch (Exception)
        {
            capture.Dispose();
            failureReason = "MIC_UNAVAILABLE";
            return false;
        }

        _capture = capture;
        _owner = owner;
        _inputSampleRate = capture.SampleRate;
        _inputChannels = capture.Channels;
        _inputFramesPerGroup = checked((int)((long)capture.SampleRate * ProtocolConstants.FrameDurationMs / 1000));
        _pending.Clear();
        _sequence = 0;
        LastPeak = 0f;
        _sessionPeakLeft = 0f;
        _sessionPeakRight = 0f;
        _running = true;
        capture.DataAvailable += OnDataAvailable;
        capture.CaptureLost += OnCaptureLost;
        failureReason = null;
        return true;
    }

    private void StopLocked() => Teardown(DetachLocked());

    private IAudioCapture? DetachLocked()
    {
        IAudioCapture? capture = _capture;
        _capture = null;
        _owner = null;
        _running = false;
        _pending.Clear();
        if (capture is not null)
        {
            capture.DataAvailable -= OnDataAvailable;
            capture.CaptureLost -= OnCaptureLost;
        }

        return capture;
    }

    private static void Teardown(IAudioCapture? capture)
    {
        if (capture is null)
        {
            return;
        }

        try
        {
            capture.Stop();
        }
        catch (Exception)
        {
        }

        capture.Dispose();
    }

    private void OnDataAvailable(float[] interleaved)
    {
        List<(byte[] Pcm, uint Sequence, ulong TimestampUs)> ready = new();
        lock (_gate)
        {
            if (!_running || _disposed)
            {
                return;
            }

            _pending.AddRange(interleaved);
            int groupFloats = checked(_inputFramesPerGroup * _inputChannels);
            while (_pending.Count >= groupFloats)
            {
                float[] group = _pending.GetRange(0, groupFloats).ToArray();
                _pending.RemoveRange(0, groupFloats);
                UpdateChannelPeaksLocked(group);
                short[] samples = PcmNormalizer.NormalizeInterleavedToMono48k(
                    group, _inputSampleRate, _inputChannels, Mode);
                UpdatePeakLocked(samples);
                ulong timestampUs = (ulong)_sequence * (ulong)ProtocolConstants.FrameDurationUs;
                ready.Add((PcmNormalizer.ToS16LeBytes(samples), _sequence, timestampUs));
                _sequence++;
            }
        }

        foreach (var frame in ready)
        {
            _sink.OnCaptureFrame(frame.Pcm, frame.Sequence, frame.TimestampUs);
        }
    }

    private void OnCaptureLost()
    {
        Stop();
        CaptureLost?.Invoke();
    }

    private void UpdateChannelPeaksLocked(float[] interleaved)
    {
        if (_inputChannels == 1)
        {
            foreach (float sample in interleaved)
            {
                float magnitude = Math.Abs(sample);
                if (magnitude > _sessionPeakLeft)
                {
                    _sessionPeakLeft = magnitude;
                }

                _sessionPeakRight = _sessionPeakLeft;
            }

            return;
        }

        for (int index = 0; index < interleaved.Length; index += 2)
        {
            float left = Math.Abs(interleaved[index]);
            float right = Math.Abs(interleaved[index + 1]);
            if (left > _sessionPeakLeft)
            {
                _sessionPeakLeft = left;
            }

            if (right > _sessionPeakRight)
            {
                _sessionPeakRight = right;
            }
        }
    }

    private void UpdatePeakLocked(short[] samples)
    {
        float peak = 0f;
        foreach (short sample in samples)
        {
            float magnitude = Math.Abs(sample / 32768f);
            if (magnitude > peak)
            {
                peak = magnitude;
            }
        }

        LastPeak = peak;
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(MicCaptureService));
        }
    }
}




