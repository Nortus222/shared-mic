import XCTest
@testable import SharedMic

final class HexTests: XCTestCase {
    func testEncodeIsLowercaseAndZeroPadded() {
        XCTAssertEqual(Hex.encode(Data([0x00, 0x0f, 0xab, 0xff])), "000fabff")
        XCTAssertEqual(Hex.encode(Data()), "")
    }

    func testEncodeMatchesTheSpecWorkedExampleToken() {
        let token = Data((0..<32).map { UInt8($0) })
        XCTAssertEqual(
            Hex.encode(token),
            "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        )
    }

    func testDecodeRoundTrips() {
        let data = Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0x01])
        XCTAssertEqual(Hex.decode(Hex.encode(data)), data)
    }

    func testDecodeAcceptsUppercase() {
        XCTAssertEqual(Hex.decode("DEADBEEF"), Data([0xde, 0xad, 0xbe, 0xef]))
    }

    func testDecodeRejectsOddLengthAndNonHex() {
        XCTAssertNil(Hex.decode("abc"))
        XCTAssertNil(Hex.decode("zz"))
        XCTAssertNil(Hex.decode("00 11"))
    }
}
