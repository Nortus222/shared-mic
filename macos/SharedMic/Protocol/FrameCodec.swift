import Foundation

/// protocol-v1 §3: `uint8 type` + `uint32 length` (BIG-ENDIAN) + payload.
public enum FrameType: UInt8 {
    case control = 1
    case audio = 2
}

public struct DecodedFrame: Equatable {
    public let type: FrameType
    public let payload: Data
    /// Total bytes the frame occupied, i.e. 5 + length. The caller drops this
    /// many bytes off the front of its buffer and tries again.
    public let bytesConsumed: Int

    public init(type: FrameType, payload: Data, bytesConsumed: Int) {
        self.type = type
        self.payload = payload
        self.bytesConsumed = bytesConsumed
    }
}

public enum FrameCodec {
    public static func encode(type: FrameType, payload: Data) throws -> Data {
        guard payload.count <= SharedMicProtocol.maxPayloadBytes else {
            throw ProtocolError.payloadTooLarge(payload.count)
        }
        var output = Data(capacity: SharedMicProtocol.envelopeHeaderSize + payload.count)
        output.append(type.rawValue)
        var lengthBigEndian = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lengthBigEndian) { output.append(contentsOf: $0) }
        output.append(payload)
        return output
    }

    /// Decodes one frame from the front of `buffer`.
    ///
    /// Returns nil when `buffer` does not yet hold a complete frame — "not yet",
    /// never a wrong answer. Throws on a protocol violation, which the caller
    /// must treat as "close the connection".
    ///
    /// Written against `buffer.startIndex` rather than 0 so it is correct on a
    /// `Data` slice, which keeps the parent's indices.
    public static func decode(_ buffer: Data) throws -> DecodedFrame? {
        let start = buffer.startIndex
        guard buffer.count >= SharedMicProtocol.envelopeHeaderSize else { return nil }

        let rawType = buffer[start]
        guard let type = FrameType(rawValue: rawType) else {
            throw ProtocolError.unknownFrameType(rawType)
        }

        let length = Int(buffer[start + 1]) << 24
            | Int(buffer[start + 2]) << 16
            | Int(buffer[start + 3]) << 8
            | Int(buffer[start + 4])
        guard length <= SharedMicProtocol.maxPayloadBytes else {
            throw ProtocolError.payloadTooLarge(length)
        }

        let total = SharedMicProtocol.envelopeHeaderSize + length
        guard buffer.count >= total else { return nil }

        let payloadStart = start + SharedMicProtocol.envelopeHeaderSize
        let payload = Data(buffer[payloadStart ..< (start + total)])
        return DecodedFrame(type: type, payload: payload, bytesConsumed: total)
    }
}
