import Foundation

public enum PairingError: Error, Equatable {
    case alreadyPairing
    case authenticationFailed(String)
    case transport(String)
    /// The attempt was abandoned by an explicit user action — `unpair()` or a
    /// quit — rather than by anything the peer did.
    case cancelled
}

extension PairingError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .alreadyPairing:
            return "A pairing attempt is already in progress."
        case .authenticationFailed(let detail):
            return "The Windows agent rejected that pairing string (\(detail)). Check it and try again."
        case .transport(let detail):
            return "Could not reach the Windows agent: \(detail)"
        case .cancelled:
            return "The pairing attempt was cancelled."
        }
    }
}

/// Wires the pure units to the network: loads the pairing record, opens a pinned
/// TLS connection, runs the handshake, performs whatever `SessionController`
/// asks for, and reconnects with backoff — except after a fingerprint mismatch,
/// which is terminal.
///
/// All mutable state is confined to `queue`; every callback out is delivered on
/// the main queue so the SwiftUI layer can consume it directly.
public final class ConnectionCoordinator: ControlClientDelegate {
    public var onStateChange: ((AgentState) -> Void)?
    public var onNotice: ((String) -> Void)?
    public var onFingerprintWarning: ((_ expected: String, _ presented: String) -> Void)?

    private let store: PairingStore
    private let clientId: String
    private let queue = DispatchQueue(label: "com.sharedmic.coordinator")

    private var controller = SessionController()
    private var backoff = ReconnectPolicy()
    private var transport: PinnedTLSTransport?
    private var client: ControlClient?
    private var record: PairingRecord?
    private var reconnectTimer: DispatchSourceTimer?
    private var startTimeoutTimer: DispatchSourceTimer?
    private var startTimeoutRequestId: String?
    private var stopTimeoutTimer: DispatchSourceTimer?
    private var stopTimeoutRequestId: String?
    /// Non-nil for exactly as long as a `pair(...)` ceremony is in flight. It is
    /// both the "already pairing" interlock and the only place that attempt's
    /// completion lives, so every way an attempt can end — success, peer
    /// failure, or explicit abandonment by `unpair()`/`shutdown()` — goes
    /// through `resolvePairing(_:)`. One field with one resolver is what makes
    /// "called exactly once, and never latched on" structural rather than a
    /// property of remembering to clear a flag at every exit.
    private var pairingCompletion: ((Result<PairingRecord, Error>) -> Void)?
    /// The candidate record for the in-flight attempt: set once its TLS
    /// connection is up and the HMAC handshake has begun, persisted only when
    /// HELLO_ACK proves the token.
    private var pendingPairingRecord: PairingRecord?
    private var shuttingDown = false
    private var requestCounter = 0
    private var totalAudioBytes = 0
    /// Bumped every time `teardownConnection()` runs. Captured by each connect
    /// attempt's completion closure so a completion that resolves on
    /// `PinnedTLSTransport`'s own queue after this coordinator has already
    /// moved on (a fresh attempt, `unpair()`, or `shutdown()`) can recognize
    /// itself as stale and do nothing, rather than mutate `self.client` out
    /// from under whatever attempt is actually current.
    private var connectionGeneration = 0

    public init(store: PairingStore, clientId: String = Host.current().localizedName ?? "mac") {
        self.store = store
        self.clientId = clientId
        if let loaded = try? store.load() {
            self.record = loaded
            self.controller = SessionController(state: .disconnected)
        }
    }

    // MARK: - Observable state

    public var state: AgentState { queue.sync { controller.state } }
    public var deviceLabel: String { queue.sync { controller.deviceLabel } }
    public var micPresent: Bool { queue.sync { controller.micPresent } }
    public var pairedHost: String? { queue.sync { record?.host } }
    public var audioBytesReceived: Int { queue.sync { totalAudioBytes + (client?.audioBytesReceived ?? 0) } }

    // MARK: - Lifecycle

    /// Temporary Phase 1 scaffolding: called once at launch to resume a stored
    /// pairing. Deliberately does NOT feed `.paired` into `SessionController` —
    /// that event is reserved for the completion of an explicit `pair(...)`
    /// ceremony. The persisted hard-stop check lives in `openConnection()`, not
    /// here, so that no future caller can reach the dialer around it.
    public func startIfPaired() {
        queue.async { [weak self] in
            guard let self, self.record != nil else { return }
            self.openConnection()
        }
    }

    /// `completion` runs on the main queue once the graceful teardown has
    /// actually happened. `quit()` sequences `NSApplication.terminate` behind it
    /// rather than racing it — today that only costs a stray TCP RST, but Phase 2
    /// wants to send a STOP on the way out, and a terminate that beats the
    /// teardown would silently drop it.
    public func shutdown(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else {
                if let completion { DispatchQueue.main.async(execute: completion) }
                return
            }
            self.shuttingDown = true
            self.cancelReconnect()
            self.cancelSessionTimers()
            // Nothing below will ever call an in-flight pairing's completion:
            // the transport's connect completion is dropped by the generation
            // guard, and `client.stop()` makes `ControlClient` suppress its own
            // close callback. Resolve it here or it strands forever.
            self.resolvePairing(.failure(PairingError.cancelled))
            self.teardownConnection()
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    // MARK: - Pairing

    /// protocol-v1 §11: the pairing string carries only the token. The certificate
    /// fingerprint is taken trust-on-first-use from this one connection and is
    /// persisted **only after HELLO_ACK proves the token** — a peer that cannot
    /// answer the challenge never gets pinned.
    public func pair(host: String,
                     port: UInt16,
                     pairingString: String,
                     completion: @escaping (Result<PairingRecord, Error>) -> Void) {
        let token: Data
        do {
            token = try PairingString.decode(pairingString)
        } catch {
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            guard self.pairingCompletion == nil else {
                DispatchQueue.main.async { completion(.failure(PairingError.alreadyPairing)) }
                return
            }
            self.pairingCompletion = completion
            // A re-pair tears down whatever connection is live, so the state
            // machine has to hear about it — otherwise a re-pair that then fails
            // leaves `state` reading `.idle`/`.streaming` with no client and no
            // transport behind it. Only when there is something to lose: pairing
            // for the first time must stay `.unpaired` rather than announce a
            // disconnection that never happened.
            if self.client != nil || self.transport != nil {
                self.apply(self.controller.handle(.connectionLost(reason: "re-pairing")))
                self.publishState()
            }
            // After the `.connectionLost` above, which asks for a reconnect: this
            // pairing attempt *is* the reconnect, and the old record's backoff
            // timer must not race it.
            self.cancelReconnect()
            self.cancelSessionTimers()
            self.teardownConnection()
            let generation = self.connectionGeneration

            // Fresh transport per attempt: `PinnedTLSTransport.connect` resets
            // per-connection state, so reusing an instance across attempts would
            // race that reset. Every connection attempt in this class — pairing
            // and reconnect alike — constructs its own instance.
            let transport = PinnedTLSTransport()
            self.transport = transport
            // `weak transport`: the transport stores this closure in its own
            // `connectCompletion`, so a strong capture is a cycle. `finishConnect`
            // normally clears it microseconds later, but on an abandoned attempt
            // nothing clears it until the 10 s connect timeout — which would leak
            // the transport and its NWConnection for that whole window.
            transport.connect(host: host, port: port, mode: .trustOnFirstUse) { [weak self, weak transport] result in
                guard let self else { return }
                self.queue.async {
                    // A newer attempt (or unpair()/shutdown()) already tore this
                    // one down — this completion belongs to a dead attempt.
                    guard self.connectionGeneration == generation, let transport else { return }
                    switch result {
                    case .failure(let error):
                        self.teardownConnection()
                        self.resolvePairing(.failure(PairingError.transport(String(describing: error))))
                    case .success(let presentedFingerprint):
                        let candidate = PairingRecord(host: host,
                                                      port: port,
                                                      token: token,
                                                      certificateFingerprint: presentedFingerprint)
                        self.beginPairingHandshake(transport: transport, candidate: candidate)
                    }
                }
            }
        }
    }

    private func beginPairingHandshake(transport: PinnedTLSTransport, candidate: PairingRecord) {
        let client = ControlClient(transport: transport, token: candidate.token, clientId: clientId)
        self.client = client
        self.pendingPairingRecord = candidate
        client.delegate = self
        client.begin()
    }

    /// The single exit for an in-flight `pair(...)`. Both fields are cleared
    /// before the completion is called out to, so whichever path arrives first
    /// wins and no later path can double-fire it.
    @discardableResult
    private func resolvePairing(_ result: Result<PairingRecord, Error>) -> Bool {
        guard let completion = pairingCompletion else { return false }
        pairingCompletion = nil
        pendingPairingRecord = nil
        DispatchQueue.main.async { completion(result) }
        return true
    }

    public func unpair() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelReconnect()
            self.cancelSessionTimers()
            // An in-flight pair(...) is abandoned by this unpair. Nothing
            // downstream will ever complete it — a connect completion that
            // resolves later fails the generation guard, and `client.stop()`
            // inside `teardownConnection()` makes `ControlClient` suppress its
            // close callback — so resolve it here, before the teardown.
            self.resolvePairing(.failure(PairingError.cancelled))
            try? self.store.clear()
            self.record = nil
            self.apply(self.controller.handle(.unpairedByUser))
            self.publishState()
        }
    }

    // MARK: - Manual session control
    //
    // TEMPORARY PHASE 1 SCAFFOLDING. Phase 3 replaces both of these with
    // AudioDemandObserver-driven activation; nothing else should ever call them.

    public func requestStart() {
        queue.async { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.userRequestedStart(requestId: self.nextRequestId())))
            self.publishState()
        }
    }

    public func requestStop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.userRequestedStop(requestId: self.nextRequestId())))
            self.publishState()
        }
    }

    // MARK: - Connection

    /// The only place in this class that dials out, and therefore the only place
    /// the hard stop has to be enforced. Both halves of it live here:
    ///
    /// - the in-memory `.hardStop` state, for a mismatch this process already saw;
    /// - the persisted `hardStopPresentedFingerprint` marker, for one an earlier
    ///   run saw. `AgentState` does not survive a relaunch but the record does,
    ///   so rather than dialing the mismatching peer again to rediscover what is
    ///   already known, this replays the same `.fingerprintMismatch` event
    ///   `SessionController` already understands and opens nothing. Only a
    ///   successful `pair(...)` (which always writes a record with the marker
    ///   unset) or `unpair()` (which clears the record) gets past it.
    ///
    /// Keeping the marker check here rather than in `startIfPaired()` makes the
    /// invariant local to the dialer instead of a property of the call graph —
    /// a future "reconnect now" entry point cannot route around it.
    private func openConnection() {
        guard !shuttingDown, let record else { return }
        if case .hardStop = controller.state { return }
        if let presented = record.hardStopPresentedFingerprint {
            applyFingerprintMismatch(expected: record.certificateFingerprint, presented: presented)
            return
        }
        teardownConnection()
        let generation = self.connectionGeneration

        apply(controller.handle(.connectAttemptStarted))
        publishState()

        // Fresh transport per attempt — see the note in `pair(...)`.
        let transport = PinnedTLSTransport()
        self.transport = transport
        // `weak transport`: see the note in `pair(...)` — a strong capture here
        // is a retain cycle through the transport's own `connectCompletion`.
        transport.connect(host: record.host,
                          port: record.port,
                          mode: .pinned(fingerprint: record.certificateFingerprint)) { [weak self, weak transport] result in
            guard let self else { return }
            self.queue.async {
                // See the matching guard in `pair(...)`: a stale completion from
                // an attempt this coordinator has already abandoned must not
                // mutate `self.client` or drive the state machine.
                guard self.connectionGeneration == generation, let transport else { return }
                switch result {
                case .success:
                    let client = ControlClient(transport: transport,
                                               token: record.token,
                                               clientId: self.clientId)
                    self.client = client
                    client.delegate = self
                    client.begin()
                case .failure(let error):
                    if case .fingerprintMismatch(let expected, let presented) = (error as? TransportError) {
                        self.applyFingerprintMismatch(expected: expected, presented: presented)
                    } else {
                        self.apply(self.controller.handle(
                            .connectionLost(reason: String(describing: error))))
                        self.publishState()
                    }
                }
            }
        }
    }

    private func teardownConnection() {
        // Invalidates every in-flight connect completion and delegate callback
        // captured against the attempt being torn down here.
        connectionGeneration += 1
        if let client { totalAudioBytes += client.audioBytesReceived }
        client?.stop()
        client = nil
        transport?.close()
        transport = nil
    }

    /// The single place that both records a fingerprint mismatch (so a relaunch
    /// can reconstruct `.hardStop` from the store instead of reconnecting to
    /// find out again — see `openConnection()`) and drives it through the normal
    /// `SessionController`/`apply(...)` pipeline.
    private func applyFingerprintMismatch(expected: String, presented: String) {
        // Only when it actually changes: replaying a persisted marker at launch
        // would otherwise rewrite a byte-identical record to the Keychain on
        // every hard-stopped launch.
        if let current = record, current.hardStopPresentedFingerprint != presented {
            let updated = PairingRecord(host: current.host,
                                        port: current.port,
                                        token: current.token,
                                        certificateFingerprint: current.certificateFingerprint,
                                        hardStopPresentedFingerprint: presented)
            record = updated
            try? store.save(updated)
        }
        apply(controller.handle(.fingerprintMismatch(expected: expected, presented: presented)))
        publishState()
    }

    // MARK: - Actions

    private func apply(_ actions: [SessionAction]) {
        for action in actions {
            switch action {
            case .sendStart(let requestId):
                client?.send(.start(requestId: requestId, preferredFormat: .v1))
            case .sendStop(let requestId, let sessionId):
                client?.send(.stop(requestId: requestId, sessionId: sessionId))
            case .armStartTimeout(let requestId, let seconds):
                armStartTimeout(requestId: requestId, seconds: seconds)
            case .armStopTimeout(let requestId, let seconds):
                armStopTimeout(requestId: requestId, seconds: seconds)
            case .cancelStartTimeout(let requestId):
                cancelStartTimeout(requestId: requestId)
            case .cancelStopTimeout(let requestId):
                cancelStopTimeout(requestId: requestId)
            case .scheduleReconnect:
                scheduleReconnect()
            case .closeConnection:
                teardownConnection()
            case .warnFingerprintMismatch(let expected, let presented):
                DispatchQueue.main.async { [weak self] in
                    self?.onFingerprintWarning?(expected, presented)
                }
            case .notify(let message):
                DispatchQueue.main.async { [weak self] in
                    self?.onNotice?(message)
                }
            }
        }
    }

    private func nextRequestId() -> String {
        requestCounter += 1
        return "req-\(requestCounter)-\(UUID().uuidString.prefix(8))"
    }

    private func armStartTimeout(requestId: String, seconds: TimeInterval) {
        startTimeoutTimer?.cancel()
        startTimeoutRequestId = requestId
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.startTimedOut(requestId: requestId)))
            self.publishState()
        }
        timer.resume()
        startTimeoutTimer = timer
    }

    private func armStopTimeout(requestId: String, seconds: TimeInterval) {
        stopTimeoutTimer?.cancel()
        stopTimeoutRequestId = requestId
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.stopTimedOut(requestId: requestId)))
            self.publishState()
        }
        timer.resume()
        stopTimeoutTimer = timer
    }

    /// Only ever reached from `SessionAction.cancelStartTimeout`, which
    /// `SessionController` emits solely from the branch that matched its pending
    /// `requestId`. The id is re-checked here so the coordinator's own timer
    /// cannot be cancelled by a reply that answers some other request.
    private func cancelStartTimeout(requestId: String) {
        guard startTimeoutRequestId == requestId else { return }
        startTimeoutTimer?.cancel(); startTimeoutTimer = nil
        startTimeoutRequestId = nil
    }

    private func cancelStopTimeout(requestId: String) {
        guard stopTimeoutRequestId == requestId else { return }
        stopTimeoutTimer?.cancel(); stopTimeoutTimer = nil
        stopTimeoutRequestId = nil
    }

    private func cancelSessionTimers() {
        startTimeoutTimer?.cancel(); startTimeoutTimer = nil
        startTimeoutRequestId = nil
        stopTimeoutTimer?.cancel(); stopTimeoutTimer = nil
        stopTimeoutRequestId = nil
    }

    private func scheduleReconnect() {
        guard !shuttingDown, record != nil else { return }
        if case .hardStop = controller.state { return }
        cancelReconnect()
        let delay = backoff.nextDelay()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.openConnection()
        }
        timer.resume()
        reconnectTimer = timer
    }

    private func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    private func publishState() {
        let current = controller.state
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(current)
        }
    }

    // MARK: - ControlClientDelegate

    public func controlClientDidAuthenticate(_ client: ControlClient,
                                             micPresent: Bool,
                                             deviceLabel: String) {
        queue.async { [weak self] in
            // Identity, not just non-nil: a stale delegate callback from an
            // attempt this coordinator has already abandoned (torn down by a
            // newer attempt, unpair(), or shutdown()) must not resurrect it.
            guard let self, client === self.client else { return }
            if let candidate = self.pendingPairingRecord {
                // The token proved out on this connection, so the certificate it
                // presented is now trustworthy enough to pin.
                do {
                    try self.store.save(candidate)
                } catch {
                    self.resolvePairing(.failure(error))
                    return
                }
                self.record = candidate
                // Sanctioned escape from `.hardStop`: only this path, the
                // completion of an explicit user pairing action, ever feeds
                // `.paired` into `SessionController`. `startIfPaired()` and the
                // reconnect loop never do.
                self.apply(self.controller.handle(.paired))
                self.resolvePairing(.success(candidate))
            }
            self.backoff.reset()
            self.apply(self.controller.handle(.authenticated(micPresent: micPresent,
                                                             deviceLabel: deviceLabel)))
            self.publishState()
        }
    }

    public func controlClient(_ client: ControlClient, didReceive message: ControlMessage) {
        queue.async { [weak self] in
            guard let self, client === self.client else { return }
            switch message {
            // No unconditional timer cancel here: whether a reply answers the
            // request actually in flight is `SessionController`'s decision, and
            // it emits `.cancelStartTimeout`/`.cancelStopTimeout` only from the
            // branches where the `requestId` matched. Cancelling first would let
            // a reply carrying somebody else's `requestId` disarm the timeout and
            // strand this agent in `.starting`/`.stopping` with no way out.
            case .startAck(let requestId, let sessionId, _):
                self.apply(self.controller.handle(.startAcked(requestId: requestId, sessionId: sessionId)))
            case .startNack(let requestId, let reason):
                self.apply(self.controller.handle(.startNacked(requestId: requestId, reason: reason)))
            case .stopAck(let requestId, _):
                self.apply(self.controller.handle(.stopAcked(requestId: requestId)))
            case .status(let micPresent, let active, let deviceLabel):
                self.apply(self.controller.handle(.statusReceived(micPresent: micPresent,
                                                                  active: active,
                                                                  deviceLabel: deviceLabel)))
            default:
                // GREETING/HELLO/HELLO_ACK are consumed by ControlClient; PING/PONG
                // never reach here. Anything else is a server-side message this
                // phase has no use for.
                break
            }
            self.publishState()
        }
    }

    public func controlClient(_ client: ControlClient, didCloseWith error: Error?) {
        queue.async { [weak self] in
            guard let self, client === self.client else { return }
            self.cancelSessionTimers()
            if self.pendingPairingRecord != nil {
                // Closed before HELLO_ACK: the token was wrong, or the peer hung up.
                self.teardownConnection()
                self.resolvePairing(.failure(
                    PairingError.authenticationFailed(error.map { String(describing: $0) } ?? "connection closed")))
                return
            }
            self.teardownConnection()
            self.apply(self.controller.handle(
                .connectionLost(reason: error.map { String(describing: $0) } ?? "connection closed")))
            self.publishState()
        }
    }
}
