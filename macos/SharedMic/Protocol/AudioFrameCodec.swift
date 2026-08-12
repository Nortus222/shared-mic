import Foundation

/// protocol-v1 §4.
///
/// ```
/// uint32  sequence             // BIG-ENDIAN
/// uint64  captureTimestampUs   // BIG-ENDIAN
/// bytes   pcm                  // exactly 1920 bytes of s16 LITTLE-ENDIAN PCM
/// ```
///
/// **The single most likely implementation mistake** (protocol-v1 §4): the
/// envelope and this header are big-endian, and the PCM samples inside are
/// little-endian. Applying the header's byte order to the PCM compiles, raises
/// nothing, and produces heavy static rather than a crash.
///
/// Phase 1 never carries PCM. This codec exists so the golden audio vectors can
/// be byte-matched now and so Phase 2's renderer inherits a tested codec.
public struct AudioFrame: Equatable {
    public let sequence: UInt32
    public let captureTimestampUs: UInt64
    public let pcm: Data

    public init(sequence: UInt32, captureTimestampUs: UInt64, pcm: Data) {
        self.sequence = sequence
        self.captureTimestampUs = captureTimestampUs
        self.pcm = pcm
    }
}

public enum AudioFrameCodec {
    public static func encodePayload(sequence: UInt32,
                                     captureTimestampUs: UInt64,
                                     pcm: Data) throws -> Data {
        guard pcm.count == SharedMicProtocol.audioPCMBytes else {
            throw ProtocolError.badAudioPayloadLength(SharedMicProtocol.audioHeaderSize + pcm.count)
        }
        var output = Data(capacity: SharedMicProtocol.audioPayloadSize)
        var sequenceBigEndian = sequence.bigEndian
        withUnsafeBytes(of: &sequenceBigEndian) { output.append(contentsOf: $0) }
        var timestampBigEndian = captureTimestampUs.bigEndian
        withUnsafeBytes(of: &timestampBigEndian) { output.append(contentsOf: $0) }
        output.append(pcm)
        return output
    }

    /// Strict on purpose: protocol-v1 §4 requires a receiver to treat any length
    /// other than 1932 as a protocol violation and close the connection.
    public static func decodePayload(_ payload: Data) throws -> AudioFrame {
        guard payload.count == SharedMicProtocol.audioPayloadSize else {
            throw ProtocolError.badAudioPayloadLength(payload.count)
        }
        let start = payload.startIndex
        var sequence: UInt32 = 0
        for offset in 0..<4 {
            sequence = (sequence << 8) | UInt32(payload[start + offset])
        }
        var timestamp: UInt64 = 0
        for offset in 4..<12 {
            timestamp = (timestamp << 8) | UInt64(payload[start + offset])
        }
        let pcm = Data(payload[(start + SharedMicProtocol.audioHeaderSize)...])
        return AudioFrame(sequence: sequence, captureTimestampUs: timestamp, pcm: pcm)
    }

    public static func encodeFrame(sequence: UInt32,
                                   captureTimestampUs: UInt64,
                                   pcm: Data) throws -> Data {
        let payload = try encodePayload(sequence: sequence,
                                        captureTimestampUs: captureTimestampUs,
                                        pcm: pcm)
        return try FrameCodec.encode(type: .audio, payload: payload)
    }

    /// s16 **little-endian** — low byte first.
    ///
    /// An odd-length input has its trailing byte dropped: half a sample is not a
    /// sample. Unreachable through the protocol (protocol-v1 §4 fixes the PCM at
    /// 1920 bytes and `decodePayload` rejects anything else), but stated because
    /// Phase 2's renderer calls this directly.
    public static func samples(from pcm: Data) -> [Int16] {
        var output: [Int16] = []
        output.reserveCapacity(pcm.count / 2)
        var index = pcm.startIndex
        while index + 1 < pcm.endIndex {
            let low = UInt16(pcm[index])
            let high = UInt16(pcm[index + 1])
            output.append(Int16(bitPattern: low | (high << 8)))
            index += 2
        }
        return output
    }

    /// s16 **little-endian** — low byte first.
    public static func pcmBytes(from samples: [Int16]) -> Data {
        var output = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            output.append(UInt8(bits & 0x00ff))
            output.append(UInt8((bits >> 8) & 0x00ff))
        }
        return output
    }
}
