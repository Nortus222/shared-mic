namespace SharedMic.Agent;

/// <summary>
/// The tray states Phase 1 can actually reach. Design spec section 11 lists
/// Starting, Streaming, Degraded, Disabled and Held as well; those depend on
/// audio capture and automatic demand, so they arrive in Phase 2 and Phase 3.
/// </summary>
public enum AgentStatus
{
    Disconnected,
    Idle,
    Error,
}
