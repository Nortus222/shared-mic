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
///
/// The token, the certificate and the server id are persisted as ONE blob
/// (<c>identity.dpapi</c>), not three independent files. That makes the
/// identity atomic: there is no on-disk state where the token survived an
/// interrupted write, an antivirus quarantine, or a partial restore while the
/// certificate did not (or vice versa). A file that exists is a complete
/// identity or it is corrupt; either way LoadOrCreate never mints a fresh
/// certificate (and therefore a fresh pinned fingerprint) while silently
/// keeping the old token - that would strand the Mac at its hard-stop
/// fingerprint check with no explanation. Fix round 1, finding 1.
///
/// Writes go to a temp file in the same directory and are published with an
/// atomic <see cref="File.Move(string, string, bool)"/>, so a crash or power
/// loss mid-write leaves either the old identity file or nothing - never a
/// half-written one that permanently bricks the store. Fix round 1, finding 2.
/// </summary>
public sealed class IdentityStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("shared-mic/v1/identity");

    private readonly string _directory;

    private X509Certificate2? _currentCertificate;

    public IdentityStore(string directory) => _directory = directory;

    public static string DefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SharedMic");

    private string IdentityPath => Path.Combine(_directory, "identity.dpapi");

    public AgentIdentity LoadOrCreate()
    {
        Directory.CreateDirectory(_directory);

        var identity = File.Exists(IdentityPath) ? LoadExisting() : CreateNew();
        _currentCertificate = identity.Certificate;
        return identity;
    }

    /// <summary>
    /// Destroys the current identity so the next <see cref="LoadOrCreate"/>
    /// mints a new token and certificate. Disposes the certificate this store
    /// last handed out so its CNG private-key container
    /// (%APPDATA%\Microsoft\Crypto\Keys, the key the PKCS#12 round-trip in
    /// <see cref="DeviceCertificate.CreateSelfSigned"/> persists there because
    /// Schannel cannot serve an ephemeral key) is actually deleted on re-pair
    /// rather than orphaned. Fix round 1, finding 3.
    /// </summary>
    public void Reset()
    {
        _currentCertificate?.Dispose();
        _currentCertificate = null;

        if (File.Exists(IdentityPath))
        {
            File.Delete(IdentityPath);
        }
    }

    private AgentIdentity LoadExisting()
    {
        var stored = Unprotect(File.ReadAllBytes(IdentityPath));
        try
        {
            var record = Deserialize(stored);

            if (record.Token.Length != ProtocolConstants.TokenBytes)
            {
                throw new InvalidOperationException(
                    $"the stored pairing token is {record.Token.Length} bytes, expected {ProtocolConstants.TokenBytes}");
            }

            var certificate = X509CertificateLoader.LoadPkcs12(
                record.CertificatePkcs12,
                password: null,
                X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet);

            return new AgentIdentity(record.ServerId, record.Token, certificate, DeviceCertificate.Fingerprint(certificate));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(stored);
        }
    }

    private AgentIdentity CreateNew()
    {
        var token = PairingToken.Generate();
        var certificate = DeviceCertificate.CreateSelfSigned();
        var serverId = ComputeServerId();

        var pkcs12 = certificate.Export(X509ContentType.Pkcs12);
        try
        {
            var blob = Serialize(token, pkcs12, serverId);
            try
            {
                WriteProtectedAtomic(IdentityPath, blob);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(blob);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pkcs12);
        }

        return new AgentIdentity(serverId, token, certificate, DeviceCertificate.Fingerprint(certificate));
    }

    private static string ComputeServerId()
    {
        var serverId = Environment.MachineName.Trim();
        return serverId.Length == 0 ? "shared-mic-windows" : serverId;
    }

    private static byte[] Serialize(byte[] token, byte[] certificatePkcs12, string serverId)
    {
        using var stream = new MemoryStream();
        using (var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true))
        {
            WriteChunk(writer, token);
            WriteChunk(writer, certificatePkcs12);
            WriteChunk(writer, Encoding.UTF8.GetBytes(serverId));
        }

        return stream.ToArray();
    }

    private static IdentityRecord Deserialize(byte[] data)
    {
        using var stream = new MemoryStream(data);
        using var reader = new BinaryReader(stream, Encoding.UTF8, leaveOpen: true);

        var token = ReadChunk(reader);
        var certificatePkcs12 = ReadChunk(reader);
        var serverId = Encoding.UTF8.GetString(ReadChunk(reader));

        return new IdentityRecord(token, certificatePkcs12, serverId);
    }

    private static void WriteChunk(BinaryWriter writer, byte[] chunk)
    {
        writer.Write(chunk.Length);
        writer.Write(chunk);
    }

    private static byte[] ReadChunk(BinaryReader reader)
    {
        var length = reader.ReadInt32();
        if (length < 0 || length > reader.BaseStream.Length - reader.BaseStream.Position)
        {
            throw new InvalidDataException("the stored identity record is truncated or corrupt");
        }

        return reader.ReadBytes(length);
    }

    private static void WriteProtectedAtomic(string path, byte[] plaintext)
    {
        var protectedBytes = ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser);
        var tempPath = path + "." + Guid.NewGuid().ToString("N") + ".tmp";

        File.WriteAllBytes(tempPath, protectedBytes);
        File.Move(tempPath, path, overwrite: true);
    }

    private static byte[] Unprotect(byte[] ciphertext) =>
        ProtectedData.Unprotect(ciphertext, Entropy, DataProtectionScope.CurrentUser);

    private sealed record IdentityRecord(byte[] Token, byte[] CertificatePkcs12, string ServerId);
}
