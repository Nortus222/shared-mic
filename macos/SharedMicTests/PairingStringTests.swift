import XCTest
@testable import SharedMic

final class PairingStringTests: XCTestCase {
    private let specToken = Data((0..<32).map { UInt8($0) })
    private let specString = "AAAQEAYE-AUDAOCAJ-BIFQYDIO-B4IBCEQT-CQKRMFYY-DENBWHA5-DYPQ"

    func testEncodesTheSpecWorkedExample() {
        XCTAssertEqual(PairingString.encode(token: specToken), specString)
    }

    func testShapeIs58CharactersWithSixHyphens() {
        let encoded = PairingString.encode(token: specToken)
        XCTAssertEqual(encoded.count, SharedMicProtocol.pairingStringLength)
        XCTAssertEqual(encoded.filter { $0 == "-" }.count, 6)
        let groups = encoded.split(separator: "-").map(String.init)
        XCTAssertEqual(groups.map(\.count), [8, 8, 8, 8, 8, 8, 4])
    }

    func testEncodingIsUppercaseUnpaddedRFC4648() {
        let encoded = PairingString.encode(token: specToken)
        XCTAssertFalse(encoded.contains("="))
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567-")
        XCTAssertTrue(encoded.allSatisfy { allowed.contains($0) })
    }

    func testRoundTripsARandomToken() throws {
        var token = Data(count: 32)
        for index in 0..<32 { token[index] = UInt8.random(in: 0...255) }
        XCTAssertEqual(try PairingString.decode(PairingString.encode(token: token)), token)
    }

    func testDecodesTheSpecWorkedExample() throws {
        XCTAssertEqual(try PairingString.decode(specString), specToken)
    }

    func testToleratesHumanTranscription() throws {
        XCTAssertEqual(try PairingString.decode(specString.lowercased()), specToken)
        XCTAssertEqual(try PairingString.decode(specString.replacingOccurrences(of: "-", with: " ")), specToken)
        XCTAssertEqual(try PairingString.decode(specString.replacingOccurrences(of: "-", with: "")), specToken)
        XCTAssertEqual(try PairingString.decode("  \(specString)\n\t"), specToken)
        XCTAssertEqual(try PairingString.decode("AAAQ EAYE-aud aocaj/BIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYPQ"), specToken)
    }

    func testRejectsWrongLength() {
        XCTAssertThrowsError(try PairingString.decode("AAAQEAYE")) { error in
            XCTAssertEqual(error as? PairingStringError, .wrongDecodedLength(5))
        }
        XCTAssertThrowsError(try PairingString.decode(specString + "AAAAAAAA")) { error in
            XCTAssertEqual(error as? PairingStringError, .wrongDecodedLength(37))
        }
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try PairingString.decode("!!!!"))
        XCTAssertThrowsError(try PairingString.decode(""))
    }

    func testDoesNotMapConfusableCharacters() {
        // protocol-v1 §11.2: a typed `0` or `1` is DELETED, not corrected to O/I/L.
        // Deleting four characters from a valid string must therefore fail the
        // 32-byte length check rather than silently decode to a different token.
        let withConfusables = specString.replacingOccurrences(of: "A", with: "0")
        XCTAssertThrowsError(try PairingString.decode(withConfusables))
    }
}
