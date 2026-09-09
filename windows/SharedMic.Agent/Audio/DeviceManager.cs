namespace SharedMic.Agent.Audio;

public sealed class DeviceManager : IDisposable
{
    public const string PinnedEndpointId = "{0.0.1.00000000}.{dcea823c-c06f-40bf-8f35-9de9fb96acfd}";

    public const string AbsentLabel = "(device not present)";

    private readonly IAudioEndpointProvider _provider;
    private readonly string _endpointId;
    private bool _isPresent;
    private string _deviceLabel;
    private bool _disposed;

    public DeviceManager(IAudioEndpointProvider provider, string endpointId = PinnedEndpointId)
    {
        _provider = provider;
        _endpointId = endpointId;
        _isPresent = _provider.IsPresent(_endpointId);
        _deviceLabel = _isPresent ? _provider.GetFriendlyName(_endpointId) : AbsentLabel;
        _provider.DevicesChanged += OnDevicesChanged;
    }

    public event Action<bool>? PresenceChanged;

    public string EndpointId => _endpointId;

    public bool IsMicPresent
    {
        get
        {
            ThrowIfDisposed();
            return _isPresent;
        }
    }

    public string DeviceLabel
    {
        get
        {
            ThrowIfDisposed();
            return _deviceLabel;
        }
    }

    public bool Refresh()
    {
        ThrowIfDisposed();
        bool present = _provider.IsPresent(_endpointId);
        string label = present ? _provider.GetFriendlyName(_endpointId) : AbsentLabel;
        if (present == _isPresent && label == _deviceLabel)
        {
            return _isPresent;
        }

        _isPresent = present;
        _deviceLabel = label;
        PresenceChanged?.Invoke(present);
        return present;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _provider.DevicesChanged -= OnDevicesChanged;
        _provider.Dispose();
    }

    private void OnDevicesChanged()
    {
        Refresh();
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(DeviceManager));
        }
    }
}
