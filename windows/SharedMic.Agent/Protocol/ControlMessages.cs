namespace SharedMic.Agent.Protocol;

/// <summary>
/// Typed factories for all eleven control messages of protocol-v1.md section 5.
/// Windows only ever sends GREETING, HELLO_ACK, START_ACK, START_NACK,
/// STOP_ACK, STATUS and PONG; the client-side factories exist so tests can
/// drive the Mac half of the conversation. Phase 1 never sends STATUS, because
/// there is no device watcher to trigger it, but the factory is here so the
/// conformance test covers every type.
/// </summary>
public static class ControlMessages
{
    public static readonly IReadOnlyDictionary<string, object?> AudioFormat =
        new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["sampleRate"] = (long)ProtocolConstants.SampleRate,
            ["channels"] = (long)ProtocolConstants.Channels,
            ["sampleFormat"] = ProtocolConstants.SampleFormat,
        };

    public static Dictionary<string, object?> Greeting(string serverId, string nonceHex) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "GREETING",
            ["serverId"] = serverId,
            ["nonce"] = nonceHex,
        };

    public static Dictionary<string, object?> Hello(string clientId, string mac) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "HELLO",
            ["clientId"] = clientId,
            ["mac"] = mac,
        };

    public static Dictionary<string, object?> HelloAck(string serverId, bool micPresent, string deviceLabel) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "HELLO_ACK",
            ["serverId"] = serverId,
            ["micPresent"] = micPresent,
            ["deviceLabel"] = deviceLabel,
        };

    public static Dictionary<string, object?> Start(string requestId) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "START",
            ["requestId"] = requestId,
            ["preferredFormat"] = AudioFormat,
        };

    public static Dictionary<string, object?> StartAck(string requestId, string sessionId) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "START_ACK",
            ["requestId"] = requestId,
            ["sessionId"] = sessionId,
            ["format"] = AudioFormat,
        };

    public static Dictionary<string, object?> StartNack(string requestId, string reason) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "START_NACK",
            ["requestId"] = requestId,
            ["reason"] = reason,
        };

    public static Dictionary<string, object?> Stop(string requestId, string sessionId) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "STOP",
            ["requestId"] = requestId,
            ["sessionId"] = sessionId,
        };

    public static Dictionary<string, object?> StopAck(string requestId, string sessionId) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "STOP_ACK",
            ["requestId"] = requestId,
            ["sessionId"] = sessionId,
        };

    public static Dictionary<string, object?> Status(bool micPresent, bool active, string deviceLabel) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "STATUS",
            ["micPresent"] = micPresent,
            ["active"] = active,
            ["deviceLabel"] = deviceLabel,
        };

    public static Dictionary<string, object?> Ping(long seq) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "PING",
            ["seq"] = seq,
        };

    public static Dictionary<string, object?> Pong(long seq) =>
        new(StringComparer.Ordinal)
        {
            ["v"] = (long)ProtocolConstants.ProtocolVersion,
            ["type"] = "PONG",
            ["seq"] = seq,
        };
}
