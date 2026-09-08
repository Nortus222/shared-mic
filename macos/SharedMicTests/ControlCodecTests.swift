import XCTest
@testable import SharedMic

final class ControlCodecTests: XCTestCase {
    func testEncodesWithSortedKeysAndNoWhitespace() throws {
        let message = ControlMessage.ping(seq: 1)
        let payload = try ControlCodec.encode(message)
        XCTAssertEqual(String(data: payload, encoding: .utf8), #"{"seq":1,"type":"PING","v":1}"#)
    }

    func testNestedObjectKeysAreAlsoSorted() throws {
        let message = ControlMessage.start(requestId: "req-0001", preferredFormat: .v1)
        let payload = try ControlCodec.encode(message)
        XCTAssertEqual(
            String(data: payload, encoding: .utf8),
            #"{"preferredFormat":{"channels":1,"sampleFormat":"s16le","sampleRate":48000},"requestId":"req-0001","type":"START","v":1}"#
        )
    }

    func testCanonicalAudioFormatMatchesSpec() {
        XCTAssertEqual(AudioFormat.v1.sampleRate, 48_000)
        XCTAssertEqual(AudioFormat.v1.channels, 1)
        XCTAssertEqual(AudioFormat.v1.sampleFormat, "s16le")
    }

    func testEncodeFrameProducesACompleteControlEnvelope() throws {
        let frame = try ControlCodec.encodeFrame(.pong(seq: 7))
        let decoded = try XCTUnwrap(FrameCodec.decode(frame))
        XCTAssertEqual(decoded.type, .control)
        XCTAssertEqual(try ControlCodec.decode(decoded.payload), .pong(seq: 7))
    }

    func testRoundTripsEveryMessageType() throws {
        let messages: [ControlMessage] = [
            .greeting(serverId: "win-desktop", nonce: String(repeating: "0", count: 64)),
            .hello(clientId: "mac-studio", mac: String(repeating: "ab", count: 32)),
            .helloAck(serverId: "win-desktop", micPresent: true, deviceLabel: "USB Microphone"),
            .start(requestId: "req-0001", preferredFormat: .v1),
            .startAck(requestId: "req-0001", sessionId: "sess-0001", format: .v1),
            .startNack(requestId: "req-0002", reason: "MIC_UNAVAILABLE"),
            .stop(requestId: "req-0003", sessionId: "sess-0001"),
            .stopAck(requestId: "req-0003", sessionId: "sess-0001"),
            .status(micPresent: false, active: false, deviceLabel: "USB Microphone"),
            .ping(seq: 1),
            .pong(seq: 1)
        ]
        XCTAssertEqual(messages.count, 11)
        for message in messages {
            let payload = try ControlCodec.encode(message)
            XCTAssertEqual(try ControlCodec.decode(payload), message, "round trip failed for \(message.typeName)")
        }
    }

    func testRejectsWrongProtocolVersion() {
        let payload = Data(#"{"seq":1,"type":"PING","v":2}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .unsupportedVersion(2))
        }
    }

    func testRejectsMissingRequiredField() {
        let payload = Data(#"{"type":"HELLO","v":1,"clientId":"mac"}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .missingField(type: "HELLO", field: "mac"))
        }
    }

    func testRejectsWrongFieldType() {
        let payload = Data(#"{"seq":"one","type":"PING","v":1}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .wrongFieldType(type: "PING", field: "seq"))
        }
    }

    func testRejectsUnknownMessageType() {
        let payload = Data(#"{"type":"BOOM","v":1}"#.utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownControlType("BOOM"))
        }
    }

    func testRejectsNonObjectJSON() {
        let payload = Data("[1,2,3]".utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            XCTAssertEqual(error as? ProtocolError, .notAnObject)
        }
    }

    func testRejectsMalformedJSON() {
        let payload = Data("{not json".utf8)
        XCTAssertThrowsError(try ControlCodec.decode(payload)) { error in
            guard case .malformedJSON = (error as? ProtocolError) else {
                return XCTFail("expected .malformedJSON, got \(error)")
            }
        }
    }

    func testStatusHasExactlyThreeFieldsBeyondVersionAndType() throws {
        let payload = try ControlCodec.encode(.status(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["v", "type", "micPresent", "active", "deviceLabel"])
        XCTAssertNil(object["errors"])
    }

    func testEncodesAsUTF8WithoutASCIIEscaping() throws {
        let payload = try ControlCodec.encode(.helloAck(serverId: "win", micPresent: true, deviceLabel: "Mikrofón ✓"))
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertTrue(text.contains("Mikrofón ✓"))
        XCTAssertFalse(text.contains("\\u"))
    }
}
