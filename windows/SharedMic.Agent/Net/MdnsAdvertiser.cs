using System.Runtime.InteropServices;
using SharedMic.Agent.Diagnostics;

namespace SharedMic.Agent.Net;

/// <summary>
/// mDNS backend seam: the advertiser lifecycle is unit-testable without
/// touching the network.
/// </summary>
public interface IMdnsBackend
{
    void Register(string instanceName, ushort port, IReadOnlyDictionary<string, string> txt);
    void Deregister();
}

/// <summary>
/// Advertise `_sharedmic._tcp` on the LAN (spec section 12, Phase 4 Task 9)
/// so the Mac pairing form can offer this agent. The TXT record carries a
/// fingerprint prefix as a diagnostic aid only: pinning still happens over
/// the pairing ceremony, never from TXT.
/// </summary>
public sealed class MdnsAdvertiser : IDisposable
{
    public const string ServiceType = "_sharedmic._tcp";
    public const int FingerprintPrefixLength = 16;

    private readonly IMdnsBackend _backend;
    private readonly string _instanceName;
    private bool _started;
    private bool _disposed;

    public MdnsAdvertiser(IMdnsBackend backend, string instanceName)
    {
        _backend = backend;
        _instanceName = instanceName;
    }

    public void Start(ushort port, string fingerprint)
    {
        ThrowIfDisposed();
        if (_started)
        {
            Stop();
        }

        var prefix = fingerprint.Length > FingerprintPrefixLength
            ? fingerprint.Substring(0, FingerprintPrefixLength)
            : fingerprint;
        _backend.Register(_instanceName, port, new Dictionary<string, string> { ["fp"] = prefix });
        _started = true;
        AgentLog.Info($"advertising {ServiceType} as '{_instanceName}' on port {port}");
    }

    public void Stop()
    {
        ThrowIfDisposed();
        if (!_started)
        {
            return;
        }

        _started = false;
        _backend.Deregister();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        if (_started)
        {
            _started = false;
            try
            {
                _backend.Deregister();
            }
            catch (Exception exception)
            {
                AgentLog.Warn($"mDNS deregister on dispose failed ({exception.GetType().Name})");
            }
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(MdnsAdvertiser));
        }
    }
}

/// <summary>
/// Live backend over dnsapi.dll (`DnsServiceRegister` / `DnsServiceDeRegister`).
/// All unmanaged allocations live exactly from Register to Deregister and are
/// freed there: leaking them would pin a stale announcement past shutdown.
/// A registration failure throws and never half-registers; the caller
/// (Program) treats advertise as best-effort and keeps serving without it.
/// </summary>
public sealed class DnsApiMdnsBackend : IMdnsBackend, IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceInstance
    {
        public IntPtr InstanceName;
        public IntPtr HostName;
        public IntPtr Ip4Address;
        public IntPtr Ip6Address;
        public ushort Port;
        public ushort Priority;
        public ushort Weight;
        public uint PropertyCount;
        public IntPtr Keys;
        public IntPtr Values;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceRegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        public IntPtr RegisterCompletionCallback;
        public IntPtr QueryContext;
        public IntPtr Credentials;
        public int UseUnicode;
    }

    private const uint RequestVersion1 = 1;

    [DllImport("dnsapi.dll", SetLastError = true)]
    private static extern int DnsServiceRegister(ref DnsServiceRegisterRequest request, IntPtr cancel);

    [DllImport("dnsapi.dll", SetLastError = true)]
    private static extern int DnsServiceDeRegister(ref DnsServiceRegisterRequest request);

    private readonly List<IntPtr> _allocations = new();
    private IntPtr _requestPtr = IntPtr.Zero;
    private bool _disposed;

    public void Register(string instanceName, ushort port, IReadOnlyDictionary<string, string> txt)
    {
        ThrowIfDisposed();
        Deregister();

        // Full instance name: "HOST._sharedmic._tcp.local". HostName stays
        // NULL so the system advertises its own hostname. wPort is host byte
        // order (dnsapi converts for the SRV record) — Task 11 verifies the
        // Mac form shows the right port on a fresh LAN join.
        var fullName = $"{instanceName}.{MdnsAdvertiser.ServiceType}.local";
        var keys = new List<IntPtr>();
        var values = new List<IntPtr>();
        foreach (var entry in txt)
        {
            keys.Add(Track(Marshal.StringToHGlobalUni(entry.Key)));
            values.Add(Track(Marshal.StringToHGlobalUni(entry.Value)));
        }

        var instance = new DnsServiceInstance
        {
            InstanceName = Track(Marshal.StringToHGlobalUni(fullName)),
            HostName = IntPtr.Zero,
            Ip4Address = IntPtr.Zero,
            Ip6Address = IntPtr.Zero,
            // wPort is host byte order (dnsapi converts for the SRV record).
            Port = port,
            Priority = 0,
            Weight = 0,
            PropertyCount = (uint)txt.Count,
            Keys = Track(CopyPointers(keys)),
            Values = Track(CopyPointers(values)),
        };

        var request = new DnsServiceRegisterRequest
        {
            Version = RequestVersion1,
            InterfaceIndex = 0,
            ServiceInstance = Track(Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceInstance>())),
            RegisterCompletionCallback = IntPtr.Zero,
            QueryContext = IntPtr.Zero,
            Credentials = IntPtr.Zero,
            UseUnicode = 1,
        };
        Marshal.StructureToPtr(instance, request.ServiceInstance, fDeleteOld: false);

        var result = DnsServiceRegister(ref request, IntPtr.Zero);
        if (result != 0)
        {
            FreeAll();
            throw new InvalidOperationException($"DnsServiceRegister failed with code {result}");
        }

        _requestPtr = Track(Marshal.AllocHGlobal(Marshal.SizeOf<DnsServiceRegisterRequest>()));
        Marshal.StructureToPtr(request, _requestPtr, fDeleteOld: false);
    }

    public void Deregister()
    {
        if (_requestPtr == IntPtr.Zero)
        {
            return;
        }

        try
        {
            var request = Marshal.PtrToStructure<DnsServiceRegisterRequest>(_requestPtr);
            DnsServiceDeRegister(ref request);
        }
        finally
        {
            FreeAll();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        Deregister();
    }

    private IntPtr Track(IntPtr allocation)
    {
        _allocations.Add(allocation);
        return allocation;
    }

    private static IntPtr CopyPointers(List<IntPtr> pointers)
    {
        if (pointers.Count == 0)
        {
            return IntPtr.Zero;
        }

        var array = Marshal.AllocHGlobal(IntPtr.Size * pointers.Count);
        for (var i = 0; i < pointers.Count; i++)
        {
            Marshal.WriteIntPtr(array, i * IntPtr.Size, pointers[i]);
        }

        return array;
    }

    private void FreeAll()
    {
        _requestPtr = IntPtr.Zero;
        foreach (var allocation in _allocations)
        {
            if (allocation != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(allocation);
            }
        }

        _allocations.Clear();
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
        {
            throw new ObjectDisposedException(nameof(DnsApiMdnsBackend));
        }
    }
}
