import XCTest
@testable import SharedMic

final class AuthProofTests: XCTestCase {
    /// Known answers computed with the reference implementation:
    ///   harness/.venv/bin/python -c \
    ///     "import hmac,hashlib; print(hmac.new(bytes(range(32)), bytes(range(32)), hashlib.sha256).hexdigest())"
    func testProofMatchesReferenceHMACSHA256() {
        let sequentialToken = Data((0..<32).map { UInt8($0) })
        let sequentialNonce = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(
            AuthProof.proof(token: sequentialToken, nonce: sequentialNonce),
            "e8499be4f1980d68f13222a418df5cbd97d53fddf590c2108e22d40005b70713"
        )

        let zeros = Data(repeating: 0, count: 32)
        XCTAssertEqual(
            AuthProof.proof(token: zeros, nonce: zeros),
            "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a"
        )

        let abNonce = Data(repeating: 0xab, count: 32)
        XCTAssertEqual(
            AuthProof.proof(token: sequentialToken, nonce: abNonce),
            "de295e728712be63b6352907b1f77cbb4437e815c00c17a7fcf86670b2141af1"
        )
    }

    func testProofIsLowercaseHex64Characters() {
        let proof = AuthProof.proof(token: Data(repeating: 7, count: 32), nonce: Data(repeating: 9, count: 32))
        XCTAssertEqual(proof.count, 64)
        XCTAssertEqual(proof, proof.lowercased())
        XCTAssertNotNil(Hex.decode(proof))
    }

    /// protocol-v1 §6: the HMAC is over the raw 32 nonce bytes, not over the
    /// 64-character hex string. Getting this wrong authenticates against nothing.
    func testProofIsOverRawNonceBytesNotTheHexString() {
        let token = Data(repeating: 0x5a, count: 32)
        let nonce = Data(repeating: 0xab, count: 32)
        let overRawBytes = AuthProof.proof(token: token, nonce: nonce)
        let overHexString = AuthProof.proof(token: token, nonce: Data(Hex.encode(nonce).utf8))
        XCTAssertNotEqual(overRawBytes, overHexString)
    }

    func testFingerprintIsLowercaseHexSHA256OfTheGivenBytes() {
        // SHA-256 of the empty input, the standard known answer.
        XCTAssertEqual(
            AuthProof.fingerprint(ofDER: Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        let fingerprint = AuthProof.fingerprint(ofDER: Data([0x30, 0x82, 0x01]))
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertEqual(fingerprint, fingerprint.lowercased())
    }
}
