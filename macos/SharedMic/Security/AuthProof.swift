import CryptoKit
import Foundation

/// protocol-v1 §6 step 2 and §2.
///
/// The token is the HMAC key and never crosses the wire; only the per-connection
/// proof does. The nonce passed here is the **raw 32 bytes** decoded from the
/// GREETING's hex `nonce` field — HMAC over the hex string authenticates against
/// nothing and fails on every connection with an opaque error.
public enum AuthProof {
    public static func proof(token: Data, nonce: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: nonce, using: SymmetricKey(data: token))
        return Hex.encode(Data(code))
    }

    /// The pinned value: lowercase hex SHA-256 over the certificate's DER encoding.
    public static func fingerprint(ofDER der: Data) -> String {
        Hex.encode(Data(SHA256.hash(data: der)))
    }
}
