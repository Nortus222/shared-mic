import Foundation

/// Design spec §4.3: the Mac reconnects with exponential backoff from 0.5 s to a
/// 30 s cap, jittered.
///
/// Randomness is injected rather than sampled internally so the curve is testable
/// exactly. `nextDelay()` is the convenience that samples for real callers.
public struct ReconnectPolicy {
    public let initialDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterFraction: Double

    private var attempt: Int = 0

    public init(initialDelay: TimeInterval = SharedMicProtocol.reconnectInitialDelay,
                maxDelay: TimeInterval = SharedMicProtocol.reconnectMaxDelay,
                jitterFraction: Double = SharedMicProtocol.reconnectJitterFraction) {
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
    }

    public var attemptCount: Int { attempt }

    /// - Parameter randomFraction: uniform in `0...1`. 0.5 yields the undisturbed
    ///   base delay; 0 and 1 yield the edges of the jitter window.
    public mutating func nextDelay(randomFraction: Double) -> TimeInterval {
        // Clamp the exponent before shifting: 2^62 already exceeds any cap, and
        // an unclamped exponent overflows after ~1000 failed attempts.
        let exponent = min(attempt, 32)
        let base = min(initialDelay * pow(2.0, Double(exponent)), maxDelay)
        attempt += 1
        let clamped = min(max(randomFraction, 0.0), 1.0)
        let multiplier = (1.0 - jitterFraction) + (2.0 * jitterFraction * clamped)
        return base * multiplier
    }

    public mutating func nextDelay() -> TimeInterval {
        nextDelay(randomFraction: Double.random(in: 0...1))
    }

    /// Called after a connection reaches HELLO_ACK, not merely after TCP connects —
    /// a peer that accepts the socket and then fails authentication is not a
    /// success and must not reset the curve.
    public mutating func reset() {
        attempt = 0
    }
}
