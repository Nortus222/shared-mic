using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using SharedMic.Agent.Protocol;
using SharedMic.Agent.Security;
using Xunit;

namespace SharedMic.Agent.Tests;

public class IdentityTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), "sharedmic-identity-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }

    [Fact]
    public void CertificateMatchesTheRequiredProfile()
    {
        using var certificate = DeviceCertificate.CreateSelfSigned();

        Assert.Equal("CN=shared-mic", certificate.Subject);
        Assert.Equal(certificate.Subject, certificate.Issuer);
        Assert.True(certificate.HasPrivateKey);

        using var key = certificate.GetECDsaPublicKey();
        Assert.NotNull(key);
        Assert.Equal(256, key!.KeySize);

        Assert.Equal("1.2.840.10045.4.3.2", certificate.SignatureAlgorithm.Value);

        var chainLengthDays = (certificate.NotAfter - certificate.NotBefore).TotalDays;
        Assert.InRange(chainLengthDays, 3649.9, 3650.1);
        Assert.True(certificate.NotBefore.ToUniversalTime() < DateTime.UtcNow);
    }

    [Fact]
    public void CertificateCarriesASubjectAlternativeNameMatchingTheCommonName()
    {
        using var certificate = DeviceCertificate.CreateSelfSigned();

        // Look the extension up by OID and wrap it, rather than relying on
        // X509Certificate2.Extensions to hand back a strongly typed instance.
        var raw = certificate.Extensions
            .Cast<X509Extension>()
            .SingleOrDefault(extension => extension.Oid?.Value == "2.5.29.17");

        Assert.NotNull(raw);

        var san = new X509SubjectAlternativeNameExtension(raw!.RawData, raw.Critical);
        Assert.Equal(new[] { "shared-mic" }, san.EnumerateDnsNames().ToArray());
    }

    [Fact]
    public void FingerprintIsLowercaseHexSha256OfTheDerEncoding()
    {
        using var certificate = DeviceCertificate.CreateSelfSigned();

        var fingerprint = DeviceCertificate.Fingerprint(certificate);

        Assert.Equal(64, fingerprint.Length);
        Assert.Equal(fingerprint.ToLowerInvariant(), fingerprint);
        Assert.Equal(
            Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant(),
            fingerprint);
    }

    [Fact]
    public void DistinctCertificatesHaveDistinctFingerprints()
    {
        using var a = DeviceCertificate.CreateSelfSigned();
        using var b = DeviceCertificate.CreateSelfSigned();

        Assert.NotEqual(DeviceCertificate.Fingerprint(a), DeviceCertificate.Fingerprint(b));
    }

    [Fact]
    public void FirstRunGeneratesEverythingAndSecondRunReusesIt()
    {
        var store = new IdentityStore(_directory);

        var first = store.LoadOrCreate();
        var second = store.LoadOrCreate();

        Assert.Equal(ProtocolConstants.TokenBytes, first.Token.Length);
        Assert.Equal(first.Token, second.Token);
        Assert.Equal(first.Fingerprint, second.Fingerprint);
        Assert.Equal(first.ServerId, second.ServerId);
        Assert.Equal(58, first.PairingString.Length);
        Assert.True(first.Certificate.HasPrivateKey);
        Assert.True(second.Certificate.HasPrivateKey);
    }

    [Fact]
    public void TokenIsNotStoredInPlaintextOnDisk()
    {
        var store = new IdentityStore(_directory);
        var identity = store.LoadOrCreate();

        var onDisk = File.ReadAllBytes(Path.Combine(_directory, "token.dpapi"));

        Assert.True(onDisk.Length > identity.Token.Length);
        Assert.False(ContainsSubsequence(onDisk, identity.Token), "the raw token is present in the protected file");
    }

    [Fact]
    public void PrivateKeyIsNotStoredInPlaintextOnDisk()
    {
        var store = new IdentityStore(_directory);
        var identity = store.LoadOrCreate();

        var onDisk = File.ReadAllBytes(Path.Combine(_directory, "device-cert.dpapi"));

        // A PKCS#12 blob always starts with a DER SEQUENCE tag (0x30). A DPAPI
        // blob starts with its own provider GUID, so a plaintext export would
        // be visible immediately.
        Assert.NotEqual(0x30, onDisk[0]);
        Assert.False(ContainsSubsequence(onDisk, identity.Certificate.RawData));
    }

    [Fact]
    public void ResetForcesRegenerationOfANewTokenAndCertificate()
    {
        var store = new IdentityStore(_directory);
        var first = store.LoadOrCreate();

        store.Reset();
        var second = store.LoadOrCreate();

        Assert.NotEqual(Convert.ToHexString(first.Token), Convert.ToHexString(second.Token));
        Assert.NotEqual(first.Fingerprint, second.Fingerprint);
    }

    [Fact]
    public void PairingStringRoundTripsToTheStoredToken()
    {
        var store = new IdentityStore(_directory);
        var identity = store.LoadOrCreate();

        Assert.Equal(identity.Token, PairingToken.Decode(identity.PairingString));
    }

    private static bool ContainsSubsequence(byte[] haystack, byte[] needle)
    {
        if (needle.Length == 0 || needle.Length > haystack.Length)
        {
            return false;
        }

        for (var i = 0; i <= haystack.Length - needle.Length; i++)
        {
            if (haystack.AsSpan(i, needle.Length).SequenceEqual(needle))
            {
                return true;
            }
        }

        return false;
    }
}
