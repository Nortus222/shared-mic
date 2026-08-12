using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// Everything the agent is: its server identifier, its 256-bit pairing token,
/// and its device certificate. Never log any field except ServerId and
/// Fingerprint.
/// </summary>
public sealed record AgentIdentity(string ServerId, byte[] Token, X509Certificate2 Certificate, string Fingerprint)
{
    /// <summary>The base32 string the tray shows and the user retypes on the Mac.</summary>
    public string PairingString => PairingToken.Encode(Token);
}

/// <summary>
/// First-run generation and at-rest protection of the agent identity, per
/// design spec section 7.1: the token and the certificate's private key are
/// DPAPI-protected under the current user. Regenerating them is an explicit
/// re-pair, never automatic.
/// </summary>
public sealed class IdentityStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("shared-mic/v1/identity");

    private readonly string _directory;

    public IdentityStore(string directory) => _directory = directory;

    public static string DefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SharedMic");

    private string TokenPath => Path.Combine(_directory, "token.dpapi");

    private string CertificatePath => Path.Combine(_directory, "device-cert.dpapi");

    private string ServerIdPath => Path.Combine(_directory, "server-id.txt");

    public AgentIdentity LoadOrCreate()
    {
        Directory.CreateDirectory(_directory);

        var token = LoadOrCreateToken();
        var certificate = LoadOrCreateCertificate();
        var serverId = LoadOrCreateServerId();

        return new AgentIdentity(serverId, token, certificate, DeviceCertificate.Fingerprint(certificate));
    }

    public void Reset()
    {
        foreach (var path in new[] { TokenPath, CertificatePath, ServerIdPath })
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
    }

    private byte[] LoadOrCreateToken()
    {
        byte[] token;
        if (File.Exists(TokenPath))
        {
            token = Unprotect(File.ReadAllBytes(TokenPath));
        }
        else
        {
            token = PairingToken.Generate();
            WriteProtected(TokenPath, token);
        }

        if (token.Length != ProtocolConstants.TokenBytes)
        {
            throw new InvalidOperationException(
                $"the stored pairing token is {token.Length} bytes, expected {ProtocolConstants.TokenBytes}");
        }

        return token;
    }

    private X509Certificate2 LoadOrCreateCertificate()
    {
        if (File.Exists(CertificatePath))
        {
            var stored = Unprotect(File.ReadAllBytes(CertificatePath));
            try
            {
                return X509CertificateLoader.LoadPkcs12(
                    stored,
                    password: null,
                    X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(stored);
            }
        }

        var certificate = DeviceCertificate.CreateSelfSigned();
        var pkcs12 = certificate.Export(X509ContentType.Pkcs12);
        try
        {
            WriteProtected(CertificatePath, pkcs12);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pkcs12);
        }

        return certificate;
    }

    private string LoadOrCreateServerId()
    {
        if (File.Exists(ServerIdPath))
        {
            var stored = File.ReadAllText(ServerIdPath).Trim();
            if (stored.Length > 0)
            {
                return stored;
            }
        }

        var serverId = Environment.MachineName.Trim();
        if (serverId.Length == 0)
        {
            serverId = "shared-mic-windows";
        }

        File.WriteAllText(ServerIdPath, serverId);
        return serverId;
    }

    private static void WriteProtected(string path, byte[] plaintext) =>
        File.WriteAllBytes(path, ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser));

    private static byte[] Unprotect(byte[] ciphertext) =>
        ProtectedData.Unprotect(ciphertext, Entropy, DataProtectionScope.CurrentUser);
}
