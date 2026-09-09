using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace SharedMic.Agent.Audio;

public sealed class WasapiAudioCaptureFactory : IAudioCaptureFactory
{
    public IAudioCapture Open(string endpointId)
    {
        var enumerator = new MMDeviceEnumerator();
        MMDevice device;
        try
        {
            device = enumerator.GetDevice(endpointId);
        }
        catch (Exception exception) when (exception is COMException or FileNotFoundException or DirectoryNotFoundException)
        {
            enumerator.Dispose();
            throw new IOException($"capture endpoint is not present: {endpointId}", exception);
        }

        if (device.State != DeviceState.Active)
        {
            device.Dispose();
            enumerator.Dispose();
            throw new IOException($"capture endpoint is not active: {endpointId}");
        }

        return new WasapiAudioCapture(enumerator, device);
    }
}

public sealed class WasapiAudioCapture : IAudioCapture
{
    private readonly MMDeviceEnumerator _enumerator;
    private readonly MMDevice _device;
    private readonly WasapiCapture _capture;
    private int _firstBufferLogged;
    private bool _disposed;

    public WasapiAudioCapture(MMDeviceEnumerator enumerator, MMDevice device)
    {
        _enumerator = enumerator;
        _device = device;
        _capture = new WasapiCapture(device);
        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;
        Diagnostics.AgentLog.Info(
            $"capture device: {device.FriendlyName} format={_capture.WaveFormat} " +
            $"mute={device.AudioEndpointVolume.Mute} level={device.AudioEndpointVolume.MasterVolumeLevelScalar:F2}");
    }

    public event Action<float[]>? DataAvailable;

    public event Action? CaptureLost;

    public int SampleRate => _capture.WaveFormat.SampleRate;

    public int Channels => _capture.WaveFormat.Channels;

    public void Start()
    {
        ThrowIfDisposed();
        _capture.StartRecording();
    }

    public void Stop()
    {
        try
        {
            _capture.StopRecording();
        }
        catch (Exception)
        {
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _capture.DataAvailable -= OnDataAvailable;
        _capture.RecordingStopped -= OnRecordingStopped;
        _capture.Dispose();
        _device.Dispose();
        _enumerator.Dispose();
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs args)
    {
        if (args.BytesRecorded == 0)
        {
            return;
        }

        int floats = args.BytesRecorded / sizeof(float);
        var samples = new float[floats];
        Buffer.BlockCopy(args.Buffer, 0, samples, 0, args.BytesRecorded);
        if (Interlocked.CompareExchange(ref _firstBufferLogged, 1, 0) == 0)
        {
            float peak = 0f;
            foreach (float sample in samples)
            {
                float magnitude = Math.Abs(sample);
                if (float.IsFinite(magnitude) && magnitude > peak)
                {
                    peak = magnitude;
                }
            }

            int rawNonzero = 0;
            foreach (byte raw in args.Buffer.AsSpan(0, args.BytesRecorded))
            {
                if (raw != 0) rawNonzero++;
            }

            Diagnostics.AgentLog.Info(
                $"first capture buffer: {args.BytesRecorded} bytes, rawNonzero={rawNonzero}, peak={peak:F4}, " +
                $"wave={_capture.WaveFormat.SampleRate}Hz/{_capture.WaveFormat.BitsPerSample}bit/{_capture.WaveFormat.Channels}ch/{_capture.WaveFormat.Encoding}");
        }

        DataAvailable?.Invoke(samples);
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs args)
    {
        if (args.Exception is not null)
        {
            CaptureLost?.Invoke();
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(WasapiAudioCapture));
        }
    }
}
