using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace SharedMic.Agent.Net;

/// <summary>
/// protocol-v1.md section 2 and design spec section 7.3: the listener binds to
/// private interfaces only and is never exposed to the public Internet. This is
/// a pure classifier so it can be unit tested without a network.
///
/// "Private" here means exactly: RFC 1918 (10/8, 172.16/12, 192.168/16),
/// loopback (127/8 and ::1), IPv4 link-local (169.254/16), and IPv6 link-local
/// and unique-local. PrivateAddressTests pins that reading, so widening or
/// narrowing it is a visible test change rather than a quiet edit here.
/// </summary>
public static class PrivateAddress
{
    public static bool IsPrivate(IPAddress address)
    {
        ArgumentNullException.ThrowIfNull(address);

        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            return IPAddress.IsLoopback(address) || address.IsIPv6LinkLocal || address.IsIPv6UniqueLocal;
        }

        if (address.AddressFamily != AddressFamily.InterNetwork)
        {
            return false;
        }

        var octets = address.GetAddressBytes();
        return octets[0] switch
        {
            127 => true,                                      // 127.0.0.0/8 loopback
            10 => true,                                       // 10.0.0.0/8
            172 => octets[1] >= 16 && octets[1] <= 31,         // 172.16.0.0/12
            192 => octets[1] == 168,                           // 192.168.0.0/16
            169 => octets[1] == 254,                           // 169.254.0.0/16 link-local
            _ => false,
        };
    }

    public static IReadOnlyList<IPAddress> Enumerate()
    {
        var addresses = new List<IPAddress>();

        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up)
            {
                continue;
            }

            foreach (var unicast in nic.GetIPProperties().UnicastAddresses)
            {
                if (IsPrivate(unicast.Address) && !addresses.Contains(unicast.Address))
                {
                    addresses.Add(unicast.Address);
                }
            }
        }

        if (!addresses.Contains(IPAddress.Loopback))
        {
            addresses.Add(IPAddress.Loopback);
        }

        return addresses;
    }
}
