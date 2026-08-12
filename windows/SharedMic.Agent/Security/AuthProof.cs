using System.Security.Cryptography;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// The challenge-response of protocol-v1.md section 6: the server issues a
/// fresh 32-byte nonce per connection, and the client proves possession of the
/// pairing token with HMAC-SHA256 over the RAW nonce bytes, not over the hex
/// string. Verification is constant time.
///
/// Never log the token, the nonce, or an offered proof.
/// </summary>
public static class AuthProof
{
    public static byte[] GenerateNonce()
    {
        var nonce = new byte[ProtocolConstants.NonceBytes];
        RandomNumberGenerator.Fill(nonce);
        return nonce;
    }

    public static string Compute(byte[] token, byte[] nonce) =>
        Convert.ToHexString(HMACSHA256.HashData(token, nonce)).ToLowerInvariant();

    public static bool Verify(byte[] token, byte[] nonce, string? proof)
    {
        if (string.IsNullOrEmpty(proof))
        {
            return false;
        }

        byte[] offered;
        try
        {
            offered = Convert.FromHexString(proof);
        }
        catch (FormatException)
        {
            return false;
        }

        var expected = HMACSHA256.HashData(token, nonce);
        return CryptographicOperations.FixedTimeEquals(expected, offered);
    }
}
