import Foundation

/// Observability spec §11 names the states the UI must show. Phase 1 implements
/// every one except `Disabled` and `Held`, which are the Phase 3 kill switch and
/// force-on hold.
public enum AgentState: Equatable {
    case unpaired
    case disconnected
    case connecting
    case idle
    case starting(requestId: String)
    case streaming(sessionId: String)
    case stopping(requestId: String, sessionId: String)
    case degraded(reason: String)
    /// Terminal until the user re-pairs. Reached only by a pinned-fingerprint
    /// mismatch, which protocol-v1 §2 forbids recovering from automatically.
    case hardStop(reason: String)

    public var displayName: String {
        switch self {
        case .unpaired: return "Not paired"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .idle: return "Idle"
        case .starting: return "Starting"
        case .streaming: return "Streaming"
        case .stopping: return "Stopping"
        case .degraded: return "Degraded"
        case .hardStop: return "Certificate mismatch"
        }
    }
}

public enum SessionEvent: Equatable {
    /// MUST be emitted only in response to an explicit user pairing action —
    /// never when loading a previously stored pairing from the Keychain at
    /// launch. `.paired` is one of the two sanctioned escapes from
    /// `.hardStop` (see `SessionController.handle(_:)`); firing it on a
    /// stored-credential reload would silently defeat the certificate hard
    /// stop that pinning exists to enforce. Task 13's wiring must keep this
    /// invariant: a fresh pairing ceremony fires `.paired`, a Keychain-backed
    /// reconnect at launch does not.
    case paired
    case connectAttemptStarted
    case authenticated(micPresent: Bool, deviceLabel: String)
    // Temporary Phase 1 scaffolding: `userRequestedStart`/`userRequestedStop`
    // exist only so a session can be driven by hand while there is no demand
    // detection. Phase 3's `AudioDemandObserver` replaces the manual trigger
    // and drives these same two events instead.
    case userRequestedStart(requestId: String)
    case startAcked(requestId: String, sessionId: String)
    case startNacked(requestId: String, reason: String)
    case startTimedOut(requestId: String)
    case userRequestedStop(requestId: String)
    case stopAcked(requestId: String)
    case stopTimedOut(requestId: String)
    case statusReceived(micPresent: Bool, active: Bool, deviceLabel: String)
    case connectionLost(reason: String)
    case fingerprintMismatch(expected: String, presented: String)
    case unpairedByUser
}

public enum SessionAction: Equatable {
    case sendStart(requestId: String)
    case sendStop(requestId: String, sessionId: String)
    case armStartTimeout(requestId: String, seconds: TimeInterval)
    case armStopTimeout(requestId: String, seconds: TimeInterval)
    /// Emitted only from the branches that have *matched* the pending
    /// `requestId`. Cancelling a timeout is a state decision, not a transport
    /// one: a reply carrying somebody else's `requestId` must leave the timeout
    /// armed, or a non-conformant peer could park this agent in `.starting` (or
    /// `.stopping`) forever with no armed way out.
    case cancelStartTimeout(requestId: String)
    case cancelStopTimeout(requestId: String)
    case scheduleReconnect
    case closeConnection
    case warnFingerprintMismatch(expected: String, presented: String)
    case notify(String)
}

/// Pure transition function. No sockets, no timers, no UI — the coordinator
/// performs the returned actions and feeds the results back in as events.
public struct SessionController {
    public private(set) var state: AgentState
    public private(set) var micPresent: Bool = false
    public private(set) var deviceLabel: String = ""

    private static let micUnavailableMessage = "The Windows microphone is unavailable."
    private static let micDisconnectedMessage = "The Windows microphone was disconnected."
    private static let startTimeoutMessage = "The Windows agent did not answer START within 2 s."
    private static let stopTimeoutMessage = "STOP went unanswered; the session is treated as ended."
    private static let hardStopMessage = "The Windows agent presented a different certificate than the one paired. Re-pair explicitly to continue."

    public init(state: AgentState = .unpaired) {
        self.state = state
    }

    public var activeSessionId: String? {
        switch state {
        case .streaming(let sessionId):
            return sessionId
        case .stopping(_, let sessionId):
            return sessionId.isEmpty ? nil : sessionId
        default:
            return nil
        }
    }

    public mutating func handle(_ event: SessionEvent) -> [SessionAction] {
        // A hard stop is terminal. Only an explicit re-pair (or an explicit
        // unpair) leaves it — nothing automatic, by design.
        if case .hardStop = state {
            switch event {
            case .paired:
                state = .disconnected
                return []
            case .unpairedByUser:
                state = .unpaired
                return [.closeConnection]
            default:
                return []
            }
        }

        switch event {
        case .paired:
            state = .disconnected
            return []

        case .unpairedByUser:
            state = .unpaired
            return [.closeConnection]

        case .fingerprintMismatch(let expected, let presented):
            state = .hardStop(reason: Self.hardStopMessage)
            return [.closeConnection, .warnFingerprintMismatch(expected: expected, presented: presented)]

        case .connectAttemptStarted:
            state = .connecting
            return []

        case .authenticated(let mic, let label):
            micPresent = mic
            deviceLabel = label
            state = .idle
            return []

        case .connectionLost:
            state = .disconnected
            return [.scheduleReconnect]

        // Temporary Phase 1 scaffolding: drives a session by hand while there is
        // no demand detection. Phase 3's `AudioDemandObserver` fires this same
        // event instead of a manual trigger.
        case .userRequestedStart(let requestId):
            switch state {
            case .idle:
                guard micPresent else {
                    return [.notify(Self.micUnavailableMessage)]
                }
                state = .starting(requestId: requestId)
                return [
                    .sendStart(requestId: requestId),
                    .armStartTimeout(requestId: requestId, seconds: SharedMicProtocol.startTimeout)
                ]
            default:
                // Already starting, already streaming, stopping, disconnected, or
                // degraded: a user Start is a no-op rather than a second session.
                return []
            }

        case .startAcked(let requestId, let sessionId):
            guard case .starting(let pending) = state, pending == requestId else { return [] }
            state = .streaming(sessionId: sessionId)
            return [.cancelStartTimeout(requestId: requestId)]

        case .startNacked(let requestId, let reason):
            guard case .starting(let pending) = state, pending == requestId else { return [] }
            state = .idle
            return [.cancelStartTimeout(requestId: requestId), .notify("Start refused: \(reason)")]

        case .startTimedOut(let requestId):
            guard case .starting(let pending) = state, pending == requestId else { return [] }
            state = .degraded(reason: Self.startTimeoutMessage)
            return [.closeConnection, .scheduleReconnect]

        // Temporary Phase 1 scaffolding: drives a session by hand while there is
        // no demand detection. Phase 3's `AudioDemandObserver` fires this same
        // event instead of a manual trigger.
        case .userRequestedStop(let requestId):
            switch state {
            case .streaming(let sessionId):
                state = .stopping(requestId: requestId, sessionId: sessionId)
                return [
                    .sendStop(requestId: requestId, sessionId: sessionId),
                    .armStopTimeout(requestId: requestId, seconds: SharedMicProtocol.stopTimeout)
                ]
            case .starting, .idle:
                // protocol-v1 §7: STOP always means "make sure no session is
                // active"; an empty sessionId is explicitly allowed.
                state = .stopping(requestId: requestId, sessionId: "")
                return [
                    .sendStop(requestId: requestId, sessionId: ""),
                    .armStopTimeout(requestId: requestId, seconds: SharedMicProtocol.stopTimeout)
                ]
            default:
                return []
            }

        case .stopAcked(let requestId):
            guard case .stopping(let pending, _) = state, pending == requestId else { return [] }
            state = .idle
            return [.cancelStopTimeout(requestId: requestId)]

        case .stopTimedOut(let requestId):
            guard case .stopping(let pending, _) = state, pending == requestId else { return [] }
            state = .idle
            return [.notify(Self.stopTimeoutMessage)]

        case .statusReceived(let mic, _, let label):
            micPresent = mic
            deviceLabel = label
            if !mic {
                switch state {
                case .starting, .streaming, .stopping:
                    state = .degraded(reason: Self.micDisconnectedMessage)
                    return [.notify(Self.micDisconnectedMessage)]
                default:
                    return []
                }
            }
            if case .degraded = state {
                state = .idle
            }
            return []
        }
    }
}
