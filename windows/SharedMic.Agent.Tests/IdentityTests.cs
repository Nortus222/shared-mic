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

        // Fix round 1, finding 4: the two assertions above pass for both the plan's
        // resolution (now-5min to now+3650d) and the rejected reading (a 3650-day span
        // simply shifted back 5 minutes), and for any backdate at all, respectively.
        // Pin the actual reading: NotBefore must be ~5 minutes before (NotAfter minus
        // exactly 3650 days), i.e. before "now" as CreateSelfSigned computed it.
        var impliedNow = certificate.NotAfter.ToUniversalTime().AddDays(-ProtocolConstants.CertificateValidityDays);
        var backdate = impliedNow - certificate.NotBefore.ToUniversalTime();
        Assert.InRange(
            backdate,
            ProtocolConstants.CertificateBackdate - TimeSpan.FromSeconds(5),
            ProtocolConstants.CertificateBackdate + TimeSpan.FromSeconds(5));
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

    // Fix round 1, finding 1: the token, certificate and server id are now persisted
    // as ONE blob (identity.dpapi) rather than three independent files, so both of
    // the plaintext checks below read that single file.
    [Fact]
    public void TokenIsNotStoredInPlaintextOnDisk()
    {
        var store = new IdentityStore(_directory);
        var identity = store.LoadOrCreate();

        var onDisk = File.ReadAllBytes(Path.Combine(_directory, "identity.dpapi"));

        Assert.True(onDisk.Length > identity.Token.Length);
        Assert.False(ContainsSubsequence(onDisk, identity.Token), "the raw token is present in the protected file");
    }

    [Fact]
    public void PrivateKeyIsNotStoredInPlaintextOnDisk()
    {
        var store = new IdentityStore(_directory);
        var identity = store.LoadOrCreate();

        var onDisk = File.ReadAllBytes(Path.Combine(_directory, "identity.dpapi"));

        // A PKCS#12 blob always starts with a DER SEQUENCE tag (0x30). A DPAPI
        // blob starts with its own provider GUID, so a plaintext export would
        // be visible immediately.
        Assert.NotEqual(0x30, onDisk[0]);
        Assert.False(ContainsSubsequence(onDisk, identity.Certificate.RawData));
    }

    [Fact]
    public void NoTemporaryFileIsLeftBehindAfterASuccessfulWrite()
    {
        var store = new IdentityStore(_directory);
        store.LoadOrCreate();

        var leftoverTempFiles = Directory.GetFiles(_directory, "identity.dpapi.*.tmp");

        Assert.Empty(leftoverTempFiles);
    }

    [Fact]
    public void AStoreWrittenAtomicallySurvivesBeingReadBackInAFreshStoreInstance()
    {
        var writer = new IdentityStore(_directory);
        var written = writer.LoadOrCreate();

        // A distinct IdentityStore instance, as a fresh process start would use,
        // reading the same directory must reconstruct byte-identical state.
        var reader = new IdentityStore(_directory);
        var read = reader.LoadOrCreate();

        Assert.Equal(written.Token, read.Token);
        Assert.Equal(written.ServerId, read.ServerId);
        Assert.Equal(written.Fingerprint, read.Fingerprint);
        Assert.Equal(written.PairingString, read.PairingString);
    }

    [Fact]
    public void ALeftoverTemporaryFileDoesNotConfuseLoadOrCreate()
    {
        Directory.CreateDirectory(_directory);
        var stray = Path.Combine(_directory, "identity.dpapi." + Guid.NewGuid().ToString("N") + ".tmp");
        File.WriteAllBytes(stray, new byte[] { 1, 2, 3 });

        var store = new IdentityStore(_directory);

        // The stray temp file must not be mistaken for a real (or partial) identity;
        // this must still behave as a genuine first run.
        var first = store.LoadOrCreate();
        var second = store.LoadOrCreate();

        Assert.Equal(first.Token, second.Token);
        Assert.True(File.Exists(stray), "the unrelated stray file should not have been touched");
    }

    [Fact]
    public void ACorruptStoreFileFailsLoudlyRatherThanMintingANewIdentity()
    {
        var store = new IdentityStore(_directory);
        store.LoadOrCreate();

        // Simulate an interrupted or damaged write: truncate the persisted,
        // DPAPI-protected blob so it can no longer be unprotected. This is the
        // single-file analogue of finding 1's "missing component" scenario - with
        // one atomic blob there is no way to have SOME but not ALL of the identity
        // on disk, only a whole file or a broken one, and a broken one must never
        // be treated as "nothing here yet, generate a fresh identity."
        var path = Path.Combine(_directory, "identity.dpapi");
        var onDisk = File.ReadAllBytes(path);
        File.WriteAllBytes(path, onDisk.AsSpan(0, onDisk.Length / 2).ToArray());

        Assert.ThrowsAny<CryptographicException>(() => store.LoadOrCreate());
    }

    [Fact]
    public void ResetDisposesTheSupersededPrivateKeyContainer()
    {
        var store = new IdentityStore(_directory);
        var first = store.LoadOrCreate();

        using var ecdsa = first.Certificate.GetECDsaPrivateKey() as ECDsaCng;
        Assert.NotNull(ecdsa);
        var keyName = ecdsa!.Key.UniqueName;
        Assert.NotNull(keyName);

        store.Reset();

        // The CNG container backing the superseded private key must actually be
        // gone, not merely unreferenced - Reset() must dispose the certificate it
        // is superseding so the container is deleted, not orphaned.
        Assert.Throws<CryptographicException>(
            () => CngKey.Open(keyName!, CngProvider.MicrosoftSoftwareKeyStorageProvider).Dispose());
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
