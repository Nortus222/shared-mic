using SharedMic.Agent.Audio;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;

namespace SharedMic.Agent;

/// <summary>
/// Runtime configuration. The timer values are init-only properties rather than
/// constants precisely so tests can inject short deadlines: protocol-v1.md's
/// harness does the same for the 5 s pre-auth deadline so the suite does not
/// pay it in wall time.
///
/// MicPresent is a configuration override, not a device query: the live
/// presence comes from DeviceManager, and the effective microphone state is
/// this flag ANDed with the hardware reading. --no-mic forces absence for the
/// harness nack mode.
/// </summary>
public sealed class AgentOptions
{
    public int Port { get; init; } = ProtocolConstants.DefaultPort;

    public bool MicPresent { get; init; } = true;

    public ChannelMode ChannelMode { get; init; } = ChannelMode.Mix;

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

