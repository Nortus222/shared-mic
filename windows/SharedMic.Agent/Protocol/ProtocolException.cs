namespace SharedMic.Agent.Protocol;

/// <summary>
/// Thrown when bytes on the wire violate protocol/protocol-v1.md. Every catch
/// site for this exception must close the connection rather than skip the
/// offending frame and resynchronize (protocol-v1.md section 3).
/// </summary>
public sealed class ProtocolException : Exception
{
    public ProtocolException(string message)
        : base(message)
    {
    }
}
