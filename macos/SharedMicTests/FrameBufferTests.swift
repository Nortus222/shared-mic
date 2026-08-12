import XCTest
@testable import SharedMic

final class FrameBufferTests: XCTestCase {
    func testEmptyBufferYieldsNothing() throws {
        var buffer = FrameBuffer()
        XCTAssertNil(try buffer.nextFrame())
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testFrameSplitAcrossManyChunksIsReassembled() throws {
        let frame = try ControlCodec.encodeFrame(.ping(seq: 5))
        var buffer = FrameBuffer()
        for byte in frame.dropLast() {
            buffer.append(Data([byte]))
            XCTAssertNil(try buffer.nextFrame(), "a partial frame must never decode")
        }
        buffer.append(Data([frame.last!]))
        let decoded = try XCTUnwrap(buffer.nextFrame())
        XCTAssertEqual(try ControlCodec.decode(decoded.payload), .ping(seq: 5))
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testTwoConcatenatedFramesInOneChunk() throws {
        var chunk = try ControlCodec.encodeFrame(.ping(seq: 1))
        chunk.append(try ControlCodec.encodeFrame(.pong(seq: 1)))
        var buffer = FrameBuffer()
        buffer.append(chunk)

        let first = try XCTUnwrap(buffer.nextFrame())
        XCTAssertEqual(try ControlCodec.decode(first.payload), .ping(seq: 1))
        let second = try XCTUnwrap(buffer.nextFrame())
        XCTAssertEqual(try ControlCodec.decode(second.payload), .pong(seq: 1))
        XCTAssertNil(try buffer.nextFrame())
        XCTAssertEqual(buffer.byteCount, 0)
    }

    func testTrailingPartialFrameIsRetained() throws {
        var chunk = try ControlCodec.encodeFrame(.ping(seq: 1))
        chunk.append(try ControlCodec.encodeFrame(.pong(seq: 1)).prefix(4))
        var buffer = FrameBuffer()
        buffer.append(chunk)
        _ = try buffer.nextFrame()
        XCTAssertNil(try buffer.nextFrame())
        XCTAssertEqual(buffer.byteCount, 4)
    }

    func testBadFrameTypeThrows() {
        var buffer = FrameBuffer()
        buffer.append(Data([0x09, 0x00, 0x00, 0x00, 0x00]))
        XCTAssertThrowsError(try buffer.nextFrame()) { error in
            XCTAssertEqual(error as? ProtocolError, .unknownFrameType(9))
        }
    }

    func testOversizedLengthThrowsBeforeWaitingForTheBytes() {
        var buffer = FrameBuffer()
        buffer.append(Data([0x01, 0xff, 0xff, 0xff, 0xff]))
        XCTAssertThrowsError(try buffer.nextFrame()) { error in
            XCTAssertEqual(error as? ProtocolError, .payloadTooLarge(4_294_967_295))
        }
    }

    func testCarriesAFullAudioEnvelope() throws {
        let pcm = Data(repeating: 0x11, count: SharedMicProtocol.audioPCMBytes)
        let frame = try AudioFrameCodec.encodeFrame(sequence: 7, captureTimestampUs: 140_000, pcm: pcm)
        var buffer = FrameBuffer()
        buffer.append(frame.prefix(1_000))
        XCTAssertNil(try buffer.nextFrame())
        buffer.append(frame.dropFirst(1_000))
        let decoded = try XCTUnwrap(buffer.nextFrame())
        XCTAssertEqual(decoded.type, .audio)
        let audio = try AudioFrameCodec.decodePayload(decoded.payload)
        XCTAssertEqual(audio.sequence, 7)
        XCTAssertEqual(audio.captureTimestampUs, 140_000)
    }
}
