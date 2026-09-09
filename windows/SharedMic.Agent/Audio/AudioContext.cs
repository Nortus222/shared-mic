namespace SharedMic.Agent.Audio;

public sealed class AudioContext : IDisposable
{
    private bool _disposed;

    public AudioContext(DeviceManager? devices, IAudioCaptureFactory? captureFactory, ChannelMode channelMode = ChannelMode.Mix)
    {
        Devices = devices;
        Router = new CaptureRouter();
        if (captureFactory is not null)
        {
            Capture = new MicCaptureService(
                devices?.EndpointId ?? DeviceManager.PinnedEndpointId,
                channelMode,
                Router,
                captureFactory);
            Capture.CaptureLost += () => CaptureLost?.Invoke();
        }

        if (Devices is not null)
        {
            Devices.PresenceChanged += present => PresenceChanged?.Invoke(present);
        }
    }

    public event Action<bool>? PresenceChanged;

    public event Action? CaptureLost;

    public DeviceManager? Devices { get; }

    public MicCaptureService? Capture { get; }

    public CaptureRouter Router { get; }

    public bool HasCapture => Capture is not null;

    public bool RefreshPresence() => Devices?.Refresh() ?? true;

    public bool CachedPresence => Devices?.IsMicPresent ?? true;

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Capture?.Dispose();
        Devices?.Dispose();
    }
}

