import Foundation

public enum HeartbeatError: Error, Equatable {
    case unexpectedPongSequence(Int)
}

/// protocol-v1 §8: the Mac sends PING every 15 s and declares the connection dead
/// after 45 s without a PONG (three missed heartbeats).
///
/// Pure, with an injected monotonic clock in seconds. The owning connection calls
/// `shouldSendPing`/`isPeerDead` on a timer tick and feeds PONGs back in.
public struct HeartbeatMonitor {
    private var nextSequence: Int = 1
    private var outstanding: [Int] = []
    private var lastPingSentAt: TimeInterval
    private(set) public var lastPongAt: TimeInterval

    public init(now: TimeInterval) {
        lastPingSentAt = now
        lastPongAt = now
    }

    public var outstandingCount: Int { outstanding.count }

    public mutating func makePing(now: TimeInterval) -> ControlMessage {
        let sequence = nextSequence
        nextSequence += 1
        outstanding.append(sequence)
        lastPingSentAt = now
        return .ping(seq: sequence)
    }

    /// A PONG whose `seq` matches no outstanding PING is a protocol violation
    /// (protocol-v1 §5) — including a repeat of one already answered.
    public mutating func handlePong(seq: Int, now: TimeInterval) throws {
        guard outstanding.contains(seq) else {
            throw HeartbeatError.unexpectedPongSequence(seq)
        }
        // A PONG implicitly acknowledges every earlier PING: the peer answered a
        // later one, so the earlier ones can never usefully arrive.
        outstanding.removeAll { $0 <= seq }
        lastPongAt = now
    }

    public func shouldSendPing(now: TimeInterval,
                               interval: TimeInterval = SharedMicProtocol.pingInterval) -> Bool {
        now - lastPingSentAt >= interval
    }

    public func isPeerDead(now: TimeInterval,
                           timeout: TimeInterval = SharedMicProtocol.peerDeadTimeout) -> Bool {
        now - lastPongAt >= timeout
    }
}
