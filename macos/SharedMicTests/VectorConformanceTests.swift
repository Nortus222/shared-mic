import XCTest
@testable import SharedMic

/// protocol-v1 §10: an implementation is conformant only if it produces and
/// accepts the exact bytes in `protocol/vectors/*.json`.
final class VectorConformanceTests: XCTestCase {

    // MARK: - Loading

    private struct ControlVector {
        let name: String
        let message: [String: Any]
        let hex: String
    }

    private struct AudioVector {
        let name: String
        let sequence: UInt32
        let timestampUs: UInt64
        let pcmHex: String
        let hex: String
    }

    private func loadControlVectors() throws -> [ControlVector] {
        let url = RepositoryPaths.vectorsDirectory.appendingPathComponent("control-messages.json")
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try raw.map { entry in
            ControlVector(
                name: try XCTUnwrap(entry["name"] as? String),
                message: try XCTUnwrap(entry["message"] as? [String: Any]),
                hex: try XCTUnwrap(entry["hex"] as? String)
            )
        }
    }

    private func loadAudioVectors() throws -> [AudioVector] {
        let url = RepositoryPaths.vectorsDirectory.appendingPathComponent("audio-frames.json")
        let data = try Data(contentsOf: url)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return try raw.map { entry in
            AudioVector(
                name: try XCTUnwrap(entry["name"] as? String),
                sequence: try XCTUnwrap((entry["sequence"] as? NSNumber)?.uint32Value),
                timestampUs: try XCTUnwrap((entry["timestampUs"] as? NSNumber)?.uint64Value),
                pcmHex: try XCTUnwrap(entry["pcmHex"] as? String),
                hex: try XCTUnwrap(entry["hex"] as? String)
            )
        }
    }

    // MARK: - Existence

    func testVectorFilesExist() {
        let fileManager = FileManager.default
        XCTAssertTrue(fileManager.fileExists(
            atPath: RepositoryPaths.vectorsDirectory.appendingPathComponent("control-messages.json").path))
        XCTAssertTrue(fileManager.fileExists(
            atPath: RepositoryPaths.vectorsDirectory.appendingPathComponent("audio-frames.json").path))
    }

    // MARK: - Control conformance

    func testControlVectorsCoverEveryMessageType() throws {
        let vectors = try loadControlVectors()
        XCTAssertEqual(vectors.count, 11)
        XCTAssertEqual(Set(vectors.map(\.name)), ControlMessage.allTypeNames)
    }

    /// protocol-v1 §10 encode conformance: encoding a vector's `message` with the
    /// canonical (sorted-key) encoder MUST produce bytes identical to its `hex`.
    func testControlVectorsEncodeToExpectedBytes() throws {
        for vector in try loadControlVectors() {
            let message = try ControlMessage(jsonObject: vector.message)
            let frame = try ControlCodec.encodeFrame(message)
            XCTAssertEqual(Hex.encode(frame), vector.hex, "encode mismatch for \(vector.name)")
        }
    }

    /// protocol-v1 §10 decode conformance: parsing a vector's `hex` MUST yield an
    /// object equal field-for-field (ignoring key order and whitespace) to its
    /// `message`.
    func testControlVectorsDecodeToExpectedMessage() throws {
        for vector in try loadControlVectors() {
            let bytes = try XCTUnwrap(Hex.decode(vector.hex), "bad hex in vector \(vector.name)")
            let frame = try XCTUnwrap(FrameCodec.decode(bytes), "incomplete frame in vector \(vector.name)")
            XCTAssertEqual(frame.type, .control, "wrong envelope type for \(vector.name)")
            XCTAssertEqual(frame.bytesConsumed, bytes.count, "trailing bytes in vector \(vector.name)")

            let message = try ControlCodec.decode(frame.payload)
            XCTAssertEqual(message.typeName, vector.name, "wrong decoded type for \(vector.name)")
            XCTAssertEqual(
                NSDictionary(dictionary: message.jsonObject),
                NSDictionary(dictionary: vector.message),
                "decoded fields differ for \(vector.name)"
            )
        }
    }

    /// Re-encoding what we decoded must return to the same bytes. This is what
    /// catches a decoder that silently drops a field the vector carried.
    func testControlVectorsSurviveDecodeThenEncode() throws {
        for vector in try loadControlVectors() {
            let bytes = try XCTUnwrap(Hex.decode(vector.hex))
            let frame = try XCTUnwrap(FrameCodec.decode(bytes))
            let message = try ControlCodec.decode(frame.payload)
            XCTAssertEqual(Hex.encode(try ControlCodec.encodeFrame(message)), vector.hex,
                           "decode/encode is not the identity for \(vector.name)")
        }
    }

    // MARK: - Audio conformance

    /// protocol-v1 §10 audio conformance: compare bytes.
    func testAudioVectorsEncodeToExpectedBytes() throws {
        let vectors = try loadAudioVectors()
        XCTAssertEqual(vectors.count, 3)
        for vector in vectors {
            let pcm = try XCTUnwrap(Hex.decode(vector.pcmHex), "bad pcmHex in vector \(vector.name)")
            XCTAssertEqual(pcm.count, SharedMicProtocol.audioPCMBytes, "wrong PCM size in \(vector.name)")
            let frame = try AudioFrameCodec.encodeFrame(
                sequence: vector.sequence,
                captureTimestampUs: vector.timestampUs,
                pcm: pcm
            )
            XCTAssertEqual(frame.count, SharedMicProtocol.audioEnvelopeSize)
            XCTAssertEqual(Hex.encode(frame), vector.hex, "encode mismatch for \(vector.name)")
        }
    }

    func testAudioVectorsDecodeToExpectedFrame() throws {
        for vector in try loadAudioVectors() {
            let bytes = try XCTUnwrap(Hex.decode(vector.hex))
            let envelope = try XCTUnwrap(FrameCodec.decode(bytes))
            XCTAssertEqual(envelope.type, .audio, "wrong envelope type for \(vector.name)")
            XCTAssertEqual(envelope.bytesConsumed, SharedMicProtocol.audioEnvelopeSize)

            let frame = try AudioFrameCodec.decodePayload(envelope.payload)
            XCTAssertEqual(frame.sequence, vector.sequence, "sequence mismatch for \(vector.name)")
            XCTAssertEqual(frame.captureTimestampUs, vector.timestampUs, "timestamp mismatch for \(vector.name)")
            XCTAssertEqual(Hex.encode(frame.pcm), vector.pcmHex, "PCM mismatch for \(vector.name)")
        }
    }

    /// The endianness trap, asserted against real vector data rather than a
    /// hand-written example: frame-0 of the synthetic session is a rising sine, so
    /// its first samples increase monotonically when read little-endian and jump
    /// wildly when read big-endian.
    func testAudioVectorPCMIsLittleEndian() throws {
        let vectors = try loadAudioVectors()
        let frameZero = try XCTUnwrap(vectors.first { $0.name == "frame-0" })
        let pcm = try XCTUnwrap(Hex.decode(frameZero.pcmHex))
        let samples = AudioFrameCodec.samples(from: pcm)
        XCTAssertEqual(samples.count, SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(Array(samples.prefix(4)), [0, 943, 1883, 2816])
    }

    /// Timestamps advance by exactly one frame duration per sequence step
    /// (protocol-v1 §4), which is what the 0/1/49 vector selection exists to pin.
    func testAudioVectorTimestampsMatchSequenceTimes20ms() throws {
        for vector in try loadAudioVectors() {
            XCTAssertEqual(vector.timestampUs,
                           UInt64(vector.sequence) * SharedMicProtocol.frameDurationUs,
                           "timestamp/sequence relationship broken in \(vector.name)")
        }
    }
}
