namespace SharedMic.Agent.Audio;

public interface IAudioEndpointProvider : IDisposable
{
    bool IsPresent(string endpointId);

    string GetFriendlyName(string endpointId);

    event Action? DevicesChanged;
}
