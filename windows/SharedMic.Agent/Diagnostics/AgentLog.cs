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

    private static void Write(string level, string message)
    {
        lock (Gate)
        {
            Console.WriteLine($"{DateTimeOffset.UtcNow:yyyy-MM-ddTHH:mm:ss.fffZ} {level} {message}");
        }
    }
}
