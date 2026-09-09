using SharedMic.Agent.Net;
using Xunit;

namespace SharedMic.Agent.Tests;

public class MdnsAdvertiserTests
{
    private sealed class FakeMdnsBackend : IMdnsBackend
    {
        public List<(string InstanceName, ushort Port, Dictionary<string, string> Txt)> Registrations { get; } = new();
        public int Deregistrations { get; private set; }
        public bool FailNextRegister { get; set; }

        public void Register(string instanceName, ushort port, IReadOnlyDictionary<string, string> txt)
        {
            if (FailNextRegister)
            {
                FailNextRegister = false;
                throw new InvalidOperationException("no network");
            }

            Registrations.Add((instanceName, port, new Dictionary<string, string>(txt)));
        }

        public void Deregister() => Deregistrations++;
    }

    [Fact]
    public void StartRegistersInstancePortAndFingerprintPrefix()
    {
        var backend = new FakeMdnsBackend();
        using var advertiser = new MdnsAdvertiser(backend, "DESKTOP-1");

        advertiser.Start(47899, new string('a', 64));

        var registration = Assert.Single(backend.Registrations);
        Assert.Equal("DESKTOP-1", registration.InstanceName);
        Assert.Equal(47899, registration.Port);
        Assert.Equal(new string('a', 16), registration.Txt["fp"]);
    }

    [Fact]
    public void ServiceTypeMatchesTheMacBrowser()
    {
        Assert.Equal("_sharedmic._tcp", MdnsAdvertiser.ServiceType);
    }

    [Fact]
    public void StartTwiceReRegistersInsteadOfStacking()
    {
        var backend = new FakeMdnsBackend();
        using var advertiser = new MdnsAdvertiser(backend, "DESKTOP-1");

        advertiser.Start(47899, new string('a', 64));
        advertiser.Start(47900, new string('b', 64));

        Assert.Equal(2, backend.Registrations.Count);
        Assert.Equal(1, backend.Deregistrations);
        Assert.Equal(47900, backend.Registrations[1].Port);
    }

    [Fact]
    public void StopDeregistersAndIsIdempotent()
    {
        var backend = new FakeMdnsBackend();
        using var advertiser = new MdnsAdvertiser(backend, "DESKTOP-1");

        advertiser.Stop();
        Assert.Equal(0, backend.Deregistrations);

        advertiser.Start(47899, new string('a', 64));
        advertiser.Stop();
        advertiser.Stop();
        Assert.Equal(1, backend.Deregistrations);
    }

    [Fact]
    public void DisposeDeregistersAnActiveAnnouncement()
    {
        var backend = new FakeMdnsBackend();
        var advertiser = new MdnsAdvertiser(backend, "DESKTOP-1");
        advertiser.Start(47899, new string('a', 64));

        advertiser.Dispose();

        Assert.Equal(1, backend.Deregistrations);
    }

    [Fact]
    public void RegisterFailurePropagatesAndLeavesNothingStarted()
    {
        var backend = new FakeMdnsBackend { FailNextRegister = true };
        using var advertiser = new MdnsAdvertiser(backend, "DESKTOP-1");

        Assert.Throws<InvalidOperationException>(() => advertiser.Start(47899, new string('a', 64)));

        advertiser.Stop();
        Assert.Equal(0, backend.Deregistrations);
    }
}
