using System.Text;

namespace SharedMic.Agent.Diagnostics;

/// <summary>
/// Lifecycle events and counters only. Design spec section 7.3: audio payload
/// is never logged or persisted. Never pass a pairing token, a private key, a
/// nonce or an offered HMAC proof to any method here.
/// </summary>
public static class AgentLog
{
    private const int MaxUntrustedLength = 64;
    private const int MaxMessageLength = 256;

    private static readonly object Gate = new();

    public static void Info(string message) => Write("INFO ", message);

    public static void Warn(string message) => Write("WARN ", message);

    public static void Error(string message) => Write("ERROR", message);

    /// <summary>
    /// Render a peer-supplied string safely for a log line. Everything the Mac
    /// sends before authentication is attacker-controlled, and a clientId
    /// containing newlines would otherwise let a caller forge log records.
    /// Control characters become '?' and the result is length-bounded.
    /// </summary>
    public static string Sanitize(object? value)
    {
        if (value is not string text)
        {
            return value is null ? "(none)" : $"(non-string {value.GetType().Name})";
        }

        var builder = new StringBuilder(Math.Min(text.Length, MaxUntrustedLength) + 1);
        foreach (var character in text.AsSpan(0, Math.Min(text.Length, MaxUntrustedLength)))
        {
            builder.Append(char.IsControl(character) ? '?' : character);
        }

        if (text.Length > MaxUntrustedLength)
        {
            builder.Append('…');
        }

        return builder.ToString();
    }

    /// <summary>
    /// Render an exception message safely for a log line. ProtocolException
    /// messages are our own text, but some of them interpolate a value taken
    /// off the wire. ControlCodec sanitises those at the point they are first
    /// interpolated, which is where the class is actually closed; this is the
    /// second layer, so that a throw site added later without that care cannot
    /// reopen it. The cap is larger than <see cref="Sanitize"/>'s because these
    /// strings are mostly trusted diagnostic text worth keeping.
    /// </summary>
    public static string SanitizeMessage(string? message)
    {
        if (string.IsNullOrEmpty(message))
        {
            return "(no detail)";
        }

        var kept = Math.Min(message.Length, MaxMessageLength);
        var builder = new StringBuilder(kept + 1);
        for (var index = 0; index < kept; index++)
        {
            builder.Append(char.IsControl(message[index]) ? '?' : message[index]);
        }

        if (message.Length > MaxMessageLength)
        {
            builder.Append('…');
        }

        return builder.ToString();
    }

    private static void Write(string level, string message)
    {
        lock (Gate)
        {
            Console.WriteLine($"{DateTimeOffset.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ} {level} {message}");
        }
    }
}
