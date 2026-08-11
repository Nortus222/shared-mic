import XCTest
@testable import SharedMic

final class AudioFrameCodecTests: XCTestCase {
    private func silentPCM() -> Data {
        Data(repeating: 0, count: SharedMicProtocol.audioPCMBytes)
    }

    func testHeaderIsTwelveBigEndianBytes() throws {
        let payload = try AudioFrameCodec.encodePayload(
            sequence: 0x0102_0304,
            captureTimestampUs: 0x0102_0304_0506_0708,
            pcm: silentPCM()
        )
        XCTAssertEqual(payload.count, SharedMicProtocol.audioPayloadSize)
        XCTAssertEqual(
            Array(payload.prefix(12)),
            [0x01, 0x02, 0x03, 0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        )
    }

    func testEnvelopeIs1937Bytes() throws {
        let frame = try AudioFrameCodec.encodeFrame(sequence: 0, captureTimestampUs: 0, pcm: silentPCM())
        XCTAssertEqual(frame.count, SharedMicProtocol.audioEnvelopeSize)
        XCTAssertEqual(Array(frame.prefix(5)), [0x02, 0x00, 0x00, 0x07, 0x8c]) // 1932 = 0x078c
    }

    func testRoundTrip() throws {
        var pcm = silentPCM()
        pcm[0] = 0x11
        pcm[SharedMicProtocol.audioPCMBytes - 1] = 0x22
        let payload = try AudioFrameCodec.encodePayload(sequence: 49, captureTimestampUs: 980_000, pcm: pcm)
        let frame = try AudioFrameCodec.decodePayload(payload)
        XCTAssertEqual(frame.sequence, 49)
        XCTAssertEqual(frame.captureTimestampUs, 980_000)
        XCTAssertEqual(frame.pcm, pcm)
    }

    func testEncodeRejectsShortPCM() {
        let pcm = Data(repeating: 0, count: 1_918)
        XCTAssertThrowsError(try AudioFrameCodec.encodePayload(sequence: 0, captureTimestampUs: 0, pcm: pcm)) { error in
            XCTAssertEqual(error as? ProtocolError, .badAudioPayloadLength(1_930))
        }
    }

    func testDecodeRejectsAnythingOtherThanExactly1932Bytes() {
        // protocol-v1 §4: "Short audio payloads are not legal. There is no partial
        // frame in this protocol." The reference Python decoder is deliberately more
        // permissive; this receiver must not be.
        for count in [0, 11, 12, 1_931, 1_933] {
            let payload = Data(repeating: 0, count: count)
            XCTAssertThrowsError(try AudioFrameCodec.decodePayload(payload)) { error in
                XCTAssertEqual(error as? ProtocolError, .badAudioPayloadLength(count))
            }
        }
    }

    func testPCMSamplesAreLittleEndian() {
        // The envelope and the audio header are big-endian; the s16 samples are not.
        let bytes = AudioFrameCodec.pcmBytes(from: [1, -2, 256, Int16.min, Int16.max])
        XCTAssertEqual(
            Array(bytes),
            [0x01, 0x00, 0xfe, 0xff, 0x00, 0x01, 0x00, 0x80, 0xff, 0x7f]
        )
        XCTAssertEqual(AudioFrameCodec.samples(from: bytes), [1, -2, 256, Int16.min, Int16.max])
    }

    func testSampleCountForAFullFrame() {
        XCTAssertEqual(AudioFrameCodec.samples(from: silentPCM()).count, SharedMicProtocol.samplesPerFrame)
    }
}
