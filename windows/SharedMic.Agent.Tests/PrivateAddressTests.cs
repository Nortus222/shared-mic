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
    [InlineData("192.167.0.1")]
    [InlineData("11.0.0.1")]
    [InlineData("9.255.255.255")]
    [InlineData("2606:4700:4700::1111")]
    public void PublicAddressesAreRejected(string address)
    {
        Assert.False(PrivateAddress.IsPrivate(IPAddress.Parse(address)));
    }

    /// <summary>
    /// protocol-v1.md section 2 names the wildcards explicitly as addresses the
    /// listener must never bind. They are not "private" in any reading, and the
    /// classifier is the only thing standing between them and a bind.
    /// </summary>
    [Theory]
    [InlineData("0.0.0.0")]
    [InlineData("::")]
    public void WildcardAddressesAreRejected(string address)
    {
        Assert.False(PrivateAddress.IsPrivate(IPAddress.Parse(address)));
    }

    /// <summary>
    /// protocol-v1.md section 2 names CGNAT explicitly. 100.64.0.0/10 is shared
    /// address space, not a private network under this design's reading, so it
    /// is rejected on purpose rather than by omission.
    /// </summary>
    [Theory]
    [InlineData("100.64.0.1")]
    [InlineData("100.127.255.255")]
    public void CarrierGradeNatAddressesAreRejected(string address)
    {
        Assert.False(PrivateAddress.IsPrivate(IPAddress.Parse(address)));
    }

    /// <summary>
    /// IPv4-mapped IPv6 fails closed: the classifier's IPv6 branch asks only
    /// about loopback, link-local and unique-local, so a mapped address is never
    /// private — INCLUDING a mapped RFC 1918 address. Both cases are pinned so
    /// the fail-closed behaviour is a decision, not an accident of ordering. A
    /// future change that unwrapped mapped addresses would have to change this
    /// test, which is the point.
    /// </summary>
    [Theory]
    [InlineData("::ffff:8.8.8.8")]
    [InlineData("::ffff:192.168.1.5")]
    [InlineData("::ffff:10.0.0.1")]
    public void IPv4MappedAddressesAreRejected(string address)
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
