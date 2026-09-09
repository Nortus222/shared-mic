using System.Runtime.InteropServices;
using NAudio.CoreAudioApi;
using NAudio.CoreAudioApi.Interfaces;

namespace SharedMic.Agent.Audio;

public sealed class NAudioEndpointProvider : IAudioEndpointProvider
{
    private readonly MMDeviceEnumerator _enumerator = new();
    private readonly NotificationForwarder _forwarder;
    private bool _disposed;

    public NAudioEndpointProvider()
    {
        _forwarder = new NotificationForwarder(OnNotified);
        _enumerator.RegisterEndpointNotificationCallback(_forwarder);
    }

    public event Action? DevicesChanged;

    public bool IsPresent(string endpointId)
    {
        ThrowIfDisposed();
        try
        {
            using var device = _enumerator.GetDevice(endpointId);
            return device.State == DeviceState.Active;
        }
        catch (Exception exception) when (exception is COMException or FileNotFoundException or DirectoryNotFoundException)
        {
            return false;
        }
    }

    public string GetFriendlyName(string endpointId)
    {
        ThrowIfDisposed();
        try
        {
            using var device = _enumerator.GetDevice(endpointId);
            return device.FriendlyName;
        }
        catch (Exception exception) when (exception is COMException or FileNotFoundException or DirectoryNotFoundException)
        {
            return DeviceManager.AbsentLabel;
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _enumerator.UnregisterEndpointNotificationCallback(_forwarder);
        _enumerator.Dispose();
    }

    private void OnNotified() => DevicesChanged?.Invoke();

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(NAudioEndpointProvider));
        }
    }

    private sealed class NotificationForwarder : IMMNotificationClient
    {
        private readonly Action _notify;

        public NotificationForwarder(Action notify) => _notify = notify;

        public void OnDefaultDeviceChanged(DataFlow flow, Role role, string defaultDeviceId)
        {
        }

        public void OnDeviceAdded(string deviceId) => _notify();

        public void OnDeviceRemoved(string deviceId) => _notify();

        public void OnDeviceStateChanged(string deviceId, DeviceState newState) => _notify();

        public void OnPropertyValueChanged(string deviceId, PropertyKey key)
        {
        }
    }
}

