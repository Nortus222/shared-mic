import Foundation

/// Accumulates bytes off the wire and yields whole envelopes.
///
/// protocol-v1 §3: a receiver reads bytes into a buffer and repeatedly attempts
/// to decode one envelope from the front; a short buffer means "wait", never a
/// wrong answer. A throw here is a protocol violation and the caller must close
/// the connection rather than resynchronize.
public struct FrameBuffer {
    private var storage = Data()

    public init() {}

    public var byteCount: Int { storage.count }

    public mutating func append(_ data: Data) {
        storage.append(data)
    }

    public mutating func nextFrame() throws -> DecodedFrame? {
        guard let frame = try FrameCodec.decode(storage) else { return nil }
        let end = storage.index(storage.startIndex, offsetBy: frame.bytesConsumed)
        storage.removeSubrange(storage.startIndex..<end)
        return frame
    }
}
