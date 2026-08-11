import XCTest
@testable import SharedMic

final class FrameCodecTests: XCTestCase {
    func testEncodesTheWorkedExampleFromTheSpec() throws {
        // protocol-v1 §3 worked example: CONTROL frame carrying {"type":"PING"}
        let payload = Data(#"{"type":"PING"}"#.utf8)
        XCTAssertEqual(payload.count, 15)
        let frame = try FrameCodec.encode(type: .control, payload: payload)
        XCTAssertEqual(
            Hex.encode(frame),
            "010000000f7b2274797065223a2250494e47227d"
        )
    }

    func testLengthIsBigEndian() throws {
        let payload = Data(repeating: 0x41, count: 258) // 0x0102
        let frame = try FrameCodec.encode(type: .audio, payload: payload)
        XCTAssertEqual(Array(frame.prefix(5)), [0x02, 0x00, 0x00, 0x01, 0x02])
    }

    func testRoundTrip() throws {
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let frame = try FrameCodec.encode(type: .audio, payload: payload)
        let decoded = try XCTUnwrap(FrameCodec.decode(frame))
        XCTAssertEqual(decoded.type, .audio)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.bytesConsumed, 9)
    }

    func testDecodeReturnsNilWhenHeaderIncomplete() throws {
        XCTAssertNil(try FrameCodec.decode(Data()))
        XCTAssertNil(try FrameCodec.decode(Data([0x01, 0x00, 0x00, 0x00])))
    }

    func testDecodeReturnsNilWhenPayloadIncomplete() throws {
        var partial = try FrameCodec.encode(type: .control, payload: Data([0x7b, 0x7d]))
        partial.removeLast()
        XCTAssertNil(try FrameCodec.decode(partial))
    }

    func testDecodeReportsConsumedSoStreamCanHoldTwoFrames() throws {
        var stream = try FrameCodec.encode(type: .control, payload: Data([0x61]))
        stream.append(try FrameCodec.encode(type: .audio, payload: Data([0x62, 0x63])))

        let first = try XCTUnwrap(FrameCodec.decode(stream))
        XCTAssertEqual(first.type, .control)
        XCTAssertEqual(first.payload, Data([0x61]))
        XCTAssertEqual(first.bytesConsumed, 6)

        let rest = stream.dropFirst(first.bytesConsumed)
        let second = try XCTUnwrap(FrameCodec.decode(Data(rest)))
        XCTAssertEqual(second.type, .audio)
        XCTAssertEqual(second.payload, Data([0x62, 0x63]))
        XCTAssertEqual(second.bytesConsumed, 7)
    }

    func testDecodeRejectsUnknownFrameType() {
        let bytes = Data([0x03, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownFrameType(3))
        }
    }

    func testDecodeRejectsOversizedPayloadWithoutAllocating() {
        // 1 MiB + 1, big-endian: 00 10 00 01
        let bytes = Data([0x01, 0x00, 0x10, 0x00, 0x01])
        XCTAssertThrowsError(try FrameCodec.decode(bytes)) { error in
            XCTAssertEqual(error as? ProtocolError, .payloadTooLarge(1_048_577))
        }
    }

    func testEncodeRefusesOversizedPayload() {
        let payload = Data(repeating: 0, count: SharedMicProtocol.maxPayloadBytes + 1)
        XCTAssertThrowsError(try FrameCodec.encode(type: .audio, payload: payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .payloadTooLarge(1_048_577))
        }
    }

    func testDecodeWorksOnASliceWithNonZeroStartIndex() throws {
        var stream = Data([0xff, 0xff, 0xff])
        stream.append(try FrameCodec.encode(type: .control, payload: Data([0x7a])))
        let slice = stream.dropFirst(3)
        let decoded = try XCTUnwrap(FrameCodec.decode(slice))
        XCTAssertEqual(decoded.payload, Data([0x7a]))
        XCTAssertEqual(decoded.bytesConsumed, 6)
    }
}
