using System.Security.Cryptography;
using System.Text;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// The 256-bit pairing secret of protocol-v1.md section 11.1 and the pairing
/// string of section 11.2. The token is the HMAC key in the section 6
/// handshake; it never crosses the wire in any form.
///
/// The pairing string is RFC 4648 base32, uppercase, unpadded, hyphen-grouped
/// in runs of 8. Decoding is deliberately tolerant because a human is retyping
/// 52 characters off a screen: uppercase, delete everything outside [A-Z2-7],
/// then require exactly 32 bytes back.
///
/// Do not add confusable-character mapping (0 to O, 1 to I or L). A typed '0'
/// is deleted rather than corrected, and the length check then rejects the
/// result. An implementation that maps confusables would accept strings the
/// macOS side rejects; that would be a protocol version change.
/// </summary>
public static class PairingToken
{
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    private const int GroupSize = 8;

    public static byte[] Generate()
    {
        var token = new byte[ProtocolConstants.TokenBytes];
        RandomNumberGenerator.Fill(token);
        return token;
    }

    public static string Encode(ReadOnlySpan<byte> token)
    {
        var raw = new StringBuilder();
        var buffer = 0;
        var bitsInBuffer = 0;

        foreach (var value in token)
        {
            buffer = (buffer << 8) | value;
            bitsInBuffer += 8;
            while (bitsInBuffer >= 5)
            {
                bitsInBuffer -= 5;
                raw.Append(Alphabet[(buffer >> bitsInBuffer) & 0x1F]);
            }
        }

        if (bitsInBuffer > 0)
        {
            raw.Append(Alphabet[(buffer << (5 - bitsInBuffer)) & 0x1F]);
        }

        var text = raw.ToString();
        var grouped = new StringBuilder(text.Length + ((text.Length - 1) / GroupSize));
        for (var offset = 0; offset < text.Length; offset += GroupSize)
        {
            if (offset > 0)
            {
                grouped.Append('-');
            }

            grouped.Append(text, offset, Math.Min(GroupSize, text.Length - offset));
        }

        return grouped.ToString();
    }

    public static byte[] Decode(string text)
    {
        ArgumentNullException.ThrowIfNull(text);

        var cleaned = new StringBuilder(text.Length);
        foreach (var character in text.ToUpperInvariant())
        {
            if (Alphabet.IndexOf(character) >= 0)
            {
                cleaned.Append(character);
            }
        }

        var symbols = cleaned.ToString();
        var remainder = symbols.Length % 8;
        if (remainder is 1 or 3 or 6)
        {
            throw new FormatException(
                $"pairing string has an invalid base32 length ({symbols.Length} usable characters)");
        }

        var bytes = new List<byte>((symbols.Length * 5) / 8);
        var buffer = 0;
        var bitsInBuffer = 0;
        foreach (var character in symbols)
        {
            buffer = (buffer << 5) | Alphabet.IndexOf(character);
            bitsInBuffer += 5;
            if (bitsInBuffer >= 8)
            {
                bitsInBuffer -= 8;
                bytes.Add((byte)((buffer >> bitsInBuffer) & 0xFF));
            }
        }

        if (bytes.Count != ProtocolConstants.TokenBytes)
        {
            throw new FormatException(
                $"pairing string decodes to {bytes.Count} bytes, expected {ProtocolConstants.TokenBytes}");
        }

        return bytes.ToArray();
    }
}
