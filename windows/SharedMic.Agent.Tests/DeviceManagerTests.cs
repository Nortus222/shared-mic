using SharedMic.Agent.Audio;
using Xunit;

namespace SharedMic.Agent.Tests;

public class DeviceManagerTests
{
    [Fact]
    public void PinnedEndpointIdMatchesProbeMeasurement()
    {
        Assert.Equal(
            "{0.0.1.00000000}.{dcea823c-c06f-40bf-8f35-9de9fb96acfd}",
            DeviceManager.PinnedEndpointId);
    }

    [Fact]
    public void ReportsPresentWithHardwareFriendlyName()
    {
        using var provider = new FakeEndpointProvider
        {
            Present = true,
            FriendlyName = "Microphone (Samson Meteorite Mic)",
        };
        using var manager = new DeviceManager(provider);

        Assert.True(manager.IsMicPresent);
        Assert.Equal("Microphone (Samson Meteorite Mic)", manager.DeviceLabel);
    }

    [Fact]
    public void ReportsAbsentWithoutQueryingFriendlyName()
    {
        using var provider = new FakeEndpointProvider { Present = false };
        using var manager = new DeviceManager(provider);

        Assert.False(manager.IsMicPresent);
        Assert.Equal(DeviceManager.AbsentLabel, manager.DeviceLabel);
        Assert.Equal(0, provider.FriendlyNameQueries);
    }

    [Fact]
    public void HotUnplugRaisesPresenceChangedAndRefreshesLabel()
    {
        using var provider = new FakeEndpointProvider
        {
            Present = true,
            FriendlyName = "Microphone (Samson Meteorite Mic)",
        };
        using var manager = new DeviceManager(provider);

        bool? observed = null;
        manager.PresenceChanged += present => observed = present;

        provider.Present = false;
        provider.RaiseDevicesChanged();

        Assert.False(manager.IsMicPresent);
        Assert.Equal(DeviceManager.AbsentLabel, manager.DeviceLabel);
        Assert.Equal(false, observed);
    }

    [Fact]
    public void HotReplugRaisesPresenceChangedWithNewLabel()
    {
        using var provider = new FakeEndpointProvider { Present = false };
        using var manager = new DeviceManager(provider);

        bool? observed = null;
        manager.PresenceChanged += present => observed = present;

        provider.Present = true;
        provider.FriendlyName = "Microphone (Samson Meteorite Mic)";
        provider.RaiseDevicesChanged();

        Assert.True(manager.IsMicPresent);
        Assert.Equal("Microphone (Samson Meteorite Mic)", manager.DeviceLabel);
        Assert.Equal(true, observed);
    }

    [Fact]
    public void RefreshWithoutChangeRaisesNoEvent()
    {
        using var provider = new FakeEndpointProvider
        {
            Present = true,
            FriendlyName = "Microphone (Samson Meteorite Mic)",
        };
        using var manager = new DeviceManager(provider);

        int events = 0;
        manager.PresenceChanged += _ => events++;

        Assert.True(manager.Refresh());
        Assert.Equal(0, events);
    }

    private sealed class FakeEndpointProvider : IAudioEndpointProvider
    {
        public bool Present { get; set; }

        public string FriendlyName { get; set; } = "Fake Microphone";

        public int FriendlyNameQueries { get; private set; }

        public event Action? DevicesChanged;

        public bool IsPresent(string endpointId) => Present;

        public string GetFriendlyName(string endpointId)
        {
            FriendlyNameQueries++;
            return FriendlyName;
        }

        public void RaiseDevicesChanged() => DevicesChanged?.Invoke();

        public void Dispose()
        {
        }
    }
}
