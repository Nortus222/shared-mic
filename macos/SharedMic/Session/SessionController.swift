import Foundation

/// Observability spec §11 names the states the UI must show. Phase 3 adds
/// `stopPending` (the 1000 ms stop-debounce transient) and `disabled` (the
/// kill switch). `Held` is a UI indication, not a machine node: spec §5.2
/// routes force-on through STARTING/ACTIVE while §11 requires a Held display,
/// so the coordinator exposes `holdRemaining` and the menu renders Held
/// whenever a hold is active (see `holdActive` below).
public enum AgentState: Equatable {
    case unpaired
    case disconnected
    case connecting
    case idle
    case starting(requestId: String)
    case streaming(sessionId: String)
    /// Stop-debounce window (spec §5.2): demand went away but the STOP has
    /// not been sent yet. Still ACTIVE for audio purposes — the renderer
    /// stays open. Demand (or hold) returning cancels back to `streaming`;
    /// expiry moves to `stopping`. Transient; never persisted.
    case stopPending(sessionId: String)
    case stopping(requestId: String, sessionId: String)
    case degraded(reason: String)
    /// Kill switch (spec §5.3). Persists across restarts via DemandSettings.
    /// No START is ever emitted from here; only `userEnabled` (or an
    /// explicit unpair/re-pair ceremony) leaves it.
    case disabled
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
        case .stopPending: return "Stop pending"
        case .stopping: return "Stopping"
        case .degraded: return "Degraded"
        case .disabled: return "Disabled"
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
    // Retained for compat: nothing drives these by hand anymore (Phase 3
    // deleted the menu's Start/Stop and `requestStart/requestStop`), but the
    // machine still honors them so earlier tests keep passing unmodified.
    case userRequestedStart(requestId: String)
    case startAcked(requestId: String, sessionId: String)
    case startNacked(requestId: String, reason: String)
    case startTimedOut(requestId: String)
    // Retained for compat, same as above.
    case userRequestedStop(requestId: String)
    case stopAcked(requestId: String)
    case stopTimedOut(requestId: String)
    case statusReceived(micPresent: Bool, active: Bool, deviceLabel: String)
    case connectionLost(reason: String)
    case fingerprintMismatch(expected: String, presented: String)
    case unpairedByUser
    /// Phase 3 demand trigger. `requestId` is consumed only on branches that
    /// must send START or STOP; level-only branches just record the flag.
    case demandChanged(hasDemand: Bool, requestId: String)
    case holdBegan(requestId: String)
    case holdExpired(requestId: String)
    /// Fires when the coordinator's stop-debounce timer fires. `sessionId`
    /// must match the pending session or the event is stale and ignored.
    case stopDebounceExpired(requestId: String, sessionId: String)
    case userDisabled(requestId: String)
    case userEnabled
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
    /// Phase 3 stop debounce. Arming carries the session so a stale expiry
    /// for an older session cannot stop a newer one; cancelling is
    /// idempotent and needs no identity.
    case armStopDebounce(sessionId: String, seconds: TimeInterval)
    case cancelStopDebounce
    case scheduleReconnect
    case closeConnection
    /// Phase 2 render lifecycle. `.openRenderer` fires on entry to
    /// `.starting` (the writer opens, never held open at idle);
    /// `.closeRendererAfterDrain` on entry to `.stopping` (queued audio
    /// still plays; the close lands on STOP_ACK); `.closeRenderer` ends a
    /// session that never drains — refused/timed-out START, timed-out STOP,
    /// mic loss — so no abnormal exit leaks an open output unit. The
    /// remaining exits (connection loss, unpair, shutdown) tear the whole
    /// connection down, and `ConnectionCoordinator.teardownConnection()`
    /// closes the renderer there, so the machine does not repeat it.
    case openRenderer
    case closeRendererAfterDrain
    case closeRenderer
    case warnFingerprintMismatch(expected: String, presented: String)
    case notify(String)
}

/// Pure transition function. No sockets, no timers, no UI — the coordinator
/// performs the returned actions and feeds the results back in as events.
public struct SessionController {
    public static let minStopDebounceSeconds: TimeInterval = 0.5
    public static let defaultStopDebounceSeconds: TimeInterval = 1.0
    public static let maxStopDebounceSeconds: TimeInterval = 2.0

    public private(set) var state: AgentState
    public private(set) var micPresent: Bool = false
    public private(set) var deviceLabel: String = ""
    public private(set) var hasDemand: Bool = false
    public private(set) var holdActive: Bool = false
    public private(set) var stopDebounceSeconds: TimeInterval
    private var pendingDisabled = false

    private static let micUnavailableMessage = "The Windows microphone is unavailable."
    private static let micDisconnectedMessage = "The Windows microphone was disconnected."
    private static let startTimeoutMessage = "The Windows agent did not answer START within 2 s."
    private static let stopTimeoutMessage = "STOP went unanswered; the session is treated as ended."
    private static let connectionLostMessage = "The connection to the Windows agent was lost while the microphone was in use."
    private static let hardStopMessage = "The Windows agent presented a different certificate than the one paired. Re-pair explicitly to continue."

    public init(state: AgentState = .unpaired,
                stopDebounceSeconds: TimeInterval = SessionController.defaultStopDebounceSeconds) {
        self.state = state
        self.stopDebounceSeconds = Self.clampDebounce(stopDebounceSeconds)
    }

    public mutating func setStopDebounceSeconds(_ seconds: TimeInterval) {
        stopDebounceSeconds = Self.clampDebounce(seconds)
    }

    public static func clampDebounce(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, minStopDebounceSeconds), maxStopDebounceSeconds)
    }

    public var activeSessionId: String? {
        switch state {
        case .streaming(let sessionId):
            return sessionId
        case .stopPending(let sessionId):
            return sessionId
        case .stopping(_, let sessionId):
            return sessionId.isEmpty ? nil : sessionId
        default:
            return nil
        }
    }

    private var shouldNotify: Bool { hasDemand || holdActive }

    private mutating func enterStopping(requestId: String, sessionId: String) -> [SessionAction] {
        state = .stopping(requestId: requestId, sessionId: sessionId)
        return [
            .sendStop(requestId: requestId, sessionId: sessionId),
            .armStopTimeout(requestId: requestId, seconds: SharedMicProtocol.stopTimeout),
            .closeRendererAfterDrain
        ]
    }

    private mutating func enterStarting(requestId: String) -> [SessionAction] {
        guard micPresent else {
            return [.notify(Self.micUnavailableMessage)]
        }
        state = .starting(requestId: requestId)
        return [
            .sendStart(requestId: requestId),
            .armStartTimeout(requestId: requestId, seconds: SharedMicProtocol.startTimeout),
            .openRenderer
        ]
    }

    public mutating func handle(_ event: SessionEvent) -> [SessionAction] {
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

        if case .disabled = state {
            switch event {
            case .userEnabled:
                state = .idle
                return []
            case .unpairedByUser:
                state = .unpaired
                return [.closeConnection]
            case .fingerprintMismatch(let expected, let presented):
                state = .hardStop(reason: Self.hardStopMessage)
                return [.closeConnection, .warnFingerprintMismatch(expected: expected, presented: presented)]
            default:
                return []
            }
        }

        switch event {
        case .paired:
            state = .disconnected
            return []

        case .unpairedByUser:
            pendingDisabled = false
            state = .unpaired
            return [.closeConnection]

        case .fingerprintMismatch(let expected, let presented):
            pendingDisabled = false
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

        case .connectionLost(let reason):
            switch state {
            case .starting, .streaming, .stopPending, .stopping:
                pendingDisabled = false
                state = .degraded(reason: reason)
                var actions: [SessionAction] = [.cancelStopDebounce, .scheduleReconnect]
                if shouldNotify {
                    actions.append(.notify(Self.connectionLostMessage))
                }
                return actions
            default:
                state = .disconnected
                return [.scheduleReconnect]
            }

        case .userRequestedStart(let requestId):
            switch state {
            case .idle:
                return enterStarting(requestId: requestId)
            case .stopPending(let sessionId):
                state = .streaming(sessionId: sessionId)
                return [.cancelStopDebounce]
            default:
                return []
            }

        case .startAcked(let requestId, let sessionId):
            guard case .starting(let pending) = state, pending == requestId else { return [] }
            state = .streaming(sessionId: sessionId)
            return [.cancelStartTimeout(requestId: requestId)]

        case .startNacked(let requestId, let reason):
            guard case .starting(let pending) = state, pending == requestId else { return [] }
            state = .idle
            return [.cancelStartTimeout(requestId: requestId), .notify("Start refused: \(reason)"),
                    .closeRenderer]

        case .startTimedOut(let requestId):
            guard case .starting(let pending) = state, pending == requestId else { return [] }
            state = .degraded(reason: Self.startTimeoutMessage)
            var actions: [SessionAction] = [.closeConnection, .scheduleReconnect, .closeRenderer]
            if shouldNotify {
                actions.append(.notify(Self.startTimeoutMessage))
            }
            return actions

        case .userRequestedStop(let requestId):
            switch state {
            case .streaming(let sessionId):
                return enterStopping(requestId: requestId, sessionId: sessionId)
            case .stopPending(let sessionId):
                return enterStopping(requestId: requestId, sessionId: sessionId)
            case .starting, .idle:
                return enterStopping(requestId: requestId, sessionId: "")
            default:
                return []
            }

        case .stopAcked(let requestId):
            guard case .stopping(let pending, _) = state, pending == requestId else { return [] }
            let wasDisabled = pendingDisabled
            pendingDisabled = false
            state = wasDisabled ? .disabled : .idle
            return [.cancelStopTimeout(requestId: requestId), .closeRenderer]

        case .stopTimedOut(let requestId):
            guard case .stopping(let pending, _) = state, pending == requestId else { return [] }
            let wasDisabled = pendingDisabled
            pendingDisabled = false
            state = wasDisabled ? .disabled : .idle
            return [.notify(Self.stopTimeoutMessage), .closeRenderer]

        case .statusReceived(let mic, _, let label):
            micPresent = mic
            deviceLabel = label
            if !mic {
                switch state {
                case .starting, .streaming, .stopPending, .stopping:
                    pendingDisabled = false
                    state = .degraded(reason: Self.micDisconnectedMessage)
                    var actions: [SessionAction] = [.cancelStopDebounce, .closeRenderer]
                    if shouldNotify {
                        actions.append(.notify(Self.micDisconnectedMessage))
                    }
                    return actions
                default:
                    return []
                }
            }
            if case .degraded = state {
                state = .idle
            }
            return []

        case .demandChanged(let has, let requestId):
            hasDemand = has
            if has {
                switch state {
                case .idle:
                    return enterStarting(requestId: requestId)
                case .stopPending(let sessionId):
                    state = .streaming(sessionId: sessionId)
                    return [.cancelStopDebounce]
                default:
                    return []
                }
            } else {
                switch state {
                case .streaming(let sessionId):
                    guard !holdActive else { return [] }
                    state = .stopPending(sessionId: sessionId)
                    return [.armStopDebounce(sessionId: sessionId, seconds: stopDebounceSeconds)]
                case .starting:
                    guard !holdActive else { return [] }
                    return enterStopping(requestId: requestId, sessionId: "")
                default:
                    return []
                }
            }

        case .holdBegan(let requestId):
            holdActive = true
            switch state {
            case .idle:
                return enterStarting(requestId: requestId)
            case .stopPending(let sessionId):
                state = .streaming(sessionId: sessionId)
                return [.cancelStopDebounce]
            default:
                return []
            }

        case .holdExpired(let requestId):
            holdActive = false
            switch state {
            case .streaming(let sessionId):
                guard !hasDemand else { return [] }
                state = .stopPending(sessionId: sessionId)
                return [.armStopDebounce(sessionId: sessionId, seconds: stopDebounceSeconds)]
            case .starting:
                guard !hasDemand else { return [] }
                return enterStopping(requestId: requestId, sessionId: "")
            default:
                return []
            }

        case .stopDebounceExpired(let requestId, let sessionId):
            guard case .stopPending(let pending) = state, pending == sessionId else { return [] }
            return enterStopping(requestId: requestId, sessionId: sessionId)

        case .userDisabled(let requestId):
            holdActive = false
            switch state {
            case .idle, .disconnected, .connecting, .degraded, .unpaired:
                state = .disabled
                return [.cancelStopDebounce]
            case .streaming(let sessionId):
                pendingDisabled = true
                return enterStopping(requestId: requestId, sessionId: sessionId)
            case .stopPending(let sessionId):
                pendingDisabled = true
                return enterStopping(requestId: requestId, sessionId: sessionId)
            case .starting:
                pendingDisabled = true
                return enterStopping(requestId: requestId, sessionId: "")
            case .stopping:
                pendingDisabled = true
                return []
            case .disabled, .hardStop:
                return []
            }

        case .userEnabled:
            return []
        }
    }
}
