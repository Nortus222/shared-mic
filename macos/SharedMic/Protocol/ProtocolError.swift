import Foundation

/// Every wire-level violation defined by protocol-v1.
///
/// All of these mean the same thing at the connection level: **close the
/// connection**. protocol-v1 §3 is explicit that a receiver must not attempt to
/// resynchronize past a bad frame, and §1 is explicit that a version mismatch is
/// a hard protocol violation rather than something to downgrade or retry.
public enum ProtocolError: Error, Equatable {
    case unknownFrameType(UInt8)
    case payloadTooLarge(Int)
    case malformedJSON(String)
    case notAnObject
    case unknownControlType(String)
    case unsupportedVersion(Int?)
    case missingField(type: String, field: String)
    case wrongFieldType(type: String, field: String)
    case badAudioPayloadLength(Int)
}

extension ProtocolError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unknownFrameType(let value):
            return "unknown frame type \(value)"
        case .payloadTooLarge(let count):
            return "payload of \(count) bytes exceeds the 1 MiB ceiling"
        case .malformedJSON(let detail):
            return "malformed JSON control payload: \(detail)"
        case .notAnObject:
            return "control message must be a JSON object"
        case .unknownControlType(let value):
            return "unknown control type '\(value)'"
        case .unsupportedVersion(let value):
            return "unsupported protocol version \(value.map(String.init) ?? "<missing>")"
        case .missingField(let type, let field):
            return "\(type) missing required field '\(field)'"
        case .wrongFieldType(let type, let field):
            return "\(type) field '\(field)' has the wrong type"
        case .badAudioPayloadLength(let count):
            return "audio payload is \(count) bytes, must be exactly 1932"
        }
    }
}
