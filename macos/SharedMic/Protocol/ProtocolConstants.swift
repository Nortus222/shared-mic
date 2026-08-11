import Foundation

/// Every fixed value in protocol-v1.md, in one place.
///
/// Changing anything here is a protocol version change (protocol-v1 §1), not an
/// implementation decision.
public enum SharedMicProtocol {
    // §1 / §2
    public static let version: Int = 1
    public static let defaultPort: UInt16 = 47_800

    // §3 — envelope, big-endian
    public static let envelopeHeaderSize: Int = 5
    public static let maxPayloadBytes: Int = 1_048_576

    // §4 — audio payload. Header is big-endian; the PCM inside is little-endian.
    public static let audioHeaderSize: Int = 12
    public static let audioPCMBytes: Int = 1_920
    public static let audioPayloadSize: Int = 1_932
    public static let audioEnvelopeSize: Int = 1_937

    public static let sampleRate: Int = 48_000
    public static let channels: Int = 1
    public static let sampleFormat: String = "s16le"
    public static let samplesPerFrame: Int = 960
    public static let frameDurationUs: UInt64 = 20_000
    public static let framesPerSecond: Int = 50

    // §8 — timers
    public static let startTimeout: TimeInterval = 2.0
    public static let stopTimeout: TimeInterval = 1.0
    public static let pingInterval: TimeInterval = 15.0
    public static let peerDeadTimeout: TimeInterval = 45.0
    public static let helloDeadline: TimeInterval = 5.0

    // design spec §4.3 — reconnect
    public static let reconnectInitialDelay: TimeInterval = 0.5
    public static let reconnectMaxDelay: TimeInterval = 30.0
    public static let reconnectJitterFraction: Double = 0.2

    // §11 — pairing
    public static let tokenBytes: Int = 32
    public static let nonceBytes: Int = 32
    public static let pairingGroupSize: Int = 8
    public static let pairingStringLength: Int = 58
}
