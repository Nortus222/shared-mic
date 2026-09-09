namespace SharedMic.Agent.Audio;

public interface IAudioCapture : IDisposable
{
    int SampleRate { get; }

    int Channels { get; }

    event Action<float[]>? DataAvailable;

    event Action? CaptureLost;

    void Start();

    void Stop();
}

public interface IAudioCaptureFactory
{
    IAudioCapture Open(string endpointId);
}
