using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;

namespace SharedMic.Agent;

/// <summary>
/// Runtime configuration. The timer values are init-only properties rather than
/// constants precisely so tests can inject short deadlines: protocol-v1.md's
/// harness does the same for the 5 s pre-auth deadline so the suite does not
/// pay it in wall time.
///
/// MicPresent is a configuration flag in Phase 1, not a device query. There is
/// no DeviceManager yet; the flag exists so the START_NACK and micPresent paths
/// are exercisable before Phase 2 wires a real WASAPI device.
/// </summary>
public sealed class AgentOptions
{
    public int Port { get; init; } = ProtocolConstants.DefaultPort;

    public bool MicPresent { get; init; } = true;

    public string DeviceLabel { get; init; } = "(no device selected)";

    public string DataDirectory { get; init; } = IdentityStore.DefaultDirectory;

    public bool Headless { get; init; }

    /// <summary>Bind only 127.0.0.1 instead of every private interface. Used by tests.</summary>
    public bool LoopbackOnly { get; init; }

    public TimeSpan HelloDeadline { get; init; } = ProtocolConstants.HelloDeadline;

    public TimeSpan PeerDeadTimeout { get; init; } = ProtocolConstants.PeerDeadTimeout;

    public TimeSpan LivenessPollInterval { get; init; } = TimeSpan.FromSeconds(1);

    public TimeSpan TlsHandshakeTimeout { get; init; } = TimeSpan.FromSeconds(5);
}
