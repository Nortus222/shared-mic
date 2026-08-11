import Foundation

/// protocol-v1 §5 / §10: a CONTROL payload is one UTF-8 JSON object with no line
/// breaks or padding — exactly the bytes
/// `json.dumps(msg, sort_keys=True, separators=(",", ":"))` would produce.
///
/// `JSONSerialization` with `.sortedKeys` produces separator-free output with
/// lexicographically sorted keys, recursively, and emits UTF-8 without \u
/// escaping — byte-identical to the reference encoder. `.withoutEscapingSlashes`
/// is included so a `/` inside a device label cannot diverge from Python, which
/// never escapes it.
public enum ControlCodec {
    public static func encode(_ message: ControlMessage) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: message.jsonObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public static func decode(_ payload: Data) throws -> ControlMessage {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
            throw ProtocolError.malformedJSON(error.localizedDescription)
        }
        return try ControlMessage(jsonObject: object)
    }

    /// A complete CONTROL envelope (protocol-v1 §3) ready to write to the wire.
    public static func encodeFrame(_ message: ControlMessage) throws -> Data {
        try FrameCodec.encode(type: .control, payload: try encode(message))
    }
}
