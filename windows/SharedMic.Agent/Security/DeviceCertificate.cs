using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using SharedMic.Agent.Protocol;

namespace SharedMic.Agent.Security;

/// <summary>
/// The device certificate profile of protocol-v1.md section 11.3. There is no
/// CA anywhere in this design; the certificate exists only so the Mac can pin
/// the SHA-256 of its DER encoding.
///
/// Profile, all of it load-bearing for the Swift client:
///   key type   EC P-256 (secp256r1)
///   signature  ECDSA with SHA-256, self-signed, issuer equals subject
///   subject    CN = shared-mic
///   SAN        REQUIRED, one dNSName byte-identical to the subject CN
///   validity   3,650 days, starting 5 minutes in the past
///   chain      none, one certificate long
///
/// The SAN is not decorative: Network.framework and URLSession evaluate a
/// certificate before handing it to a custom trust callback and some stacks
/// reject a SAN-less certificate at that earlier stage, producing a failure
/// that looks like a network error rather than a certificate problem.
/// </summary>
public static class DeviceCertificate
{
    public static X509Certificate2 CreateSelfSigned(string commonName = ProtocolConstants.CertificateCommonName)
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest($"CN={commonName}", key, HashAlgorithmName.SHA256);

        var san = new SubjectAlternativeNameBuilder();
        san.AddDnsName(commonName);
        request.CertificateExtensions.Add(san.Build());

        var now = DateTimeOffset.UtcNow;
        using var ephemeral = request.CreateSelfSigned(
            now - ProtocolConstants.CertificateBackdate,
            now.AddDays(ProtocolConstants.CertificateValidityDays));

        // Schannel, the TLS stack behind SslStream on Windows, cannot serve the
        // ephemeral key CreateSelfSigned() produces. Round-tripping through a
        // PKCS#12 blob gives the certificate a key handle SslStream accepts.
        var pkcs12 = ephemeral.Export(X509ContentType.Pkcs12);
        try
        {
            return X509CertificateLoader.LoadPkcs12(
                pkcs12,
                password: null,
                X509KeyStorageFlags.Exportable | X509KeyStorageFlags.UserKeySet);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pkcs12);
        }
    }

    /// <summary>Lowercase hex SHA-256 of the certificate's DER encoding. This is the entire trust model.</summary>
    public static string Fingerprint(X509Certificate2 certificate) =>
        Convert.ToHexString(SHA256.HashData(certificate.RawData)).ToLowerInvariant();
}
