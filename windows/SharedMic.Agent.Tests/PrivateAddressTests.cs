using System.Net;
using SharedMic.Agent.Net;
using Xunit;

namespace SharedMic.Agent.Tests;

public class PrivateAddressTests
{
    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("10.0.0.1")]
    [InlineData("10.255.255.254")]
    [InlineData("172.16.0.1")]
    [InlineData("172.31.255.254")]
    [InlineData("192.168.1.5")]
    [InlineData("169.254.10.20")]
    [InlineData("::1")]
    [InlineData("fe80::1")]
    [InlineData("fd00::1")]
    public void PrivateAddressesAreAccepted(string address)
    {
        Assert.True(PrivateAddress.IsPrivate(IPAddress.Parse(address)));
    }

    [Theory]
    [InlineData("8.8.8.8")]
    [InlineData("1.1.1.1")]
    [InlineData("172.15.255.255")]
    [InlineData("172.32.0.1")]
    [InlineData("192.169.0.1")]
    [InlineData("11.0.0.1")]
    [InlineData("2606:4700:4700::1111")]
    public void PublicAddressesAreRejected(string address)
    {
        Assert.False(PrivateAddress.IsPrivate(IPAddress.Parse(address)));
    }

    [Fact]
    public void EnumerationAlwaysIncludesLoopbackAndOnlyPrivateAddresses()
    {
        var addresses = PrivateAddress.Enumerate();

        Assert.Contains(IPAddress.Loopback, addresses);
        Assert.All(addresses, address => Assert.True(PrivateAddress.IsPrivate(address)));
    }
}
