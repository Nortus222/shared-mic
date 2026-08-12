import Foundation

public enum PairingError: Error, Equatable {
    case alreadyPairing
    case authenticationFailed(String)
    case transport(String)
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
    private var stopTimeoutTimer: DispatchSourceTimer?
    private var pairingInProgress = false
    private var pendingPairing: (record: PairingRecord, completion: (Result<PairingRecord, Error>) -> Void)?
    private var shuttingDown = false
    private var requestCounter = 0
    private var totalAudioBytes = 0

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
    /// ceremony. Loading a stored record and reconnecting from it must never be
    /// able to escape a `.hardStop` left over from a prior run (in-memory state
    /// does not survive a relaunch in the first place, so there is nothing to
    /// escape from here — see the coordinator's report for the full story).
    public func startIfPaired() {
        queue.async { [weak self] in
            guard let self, self.record != nil else { return }
            self.openConnection()
        }
    }

    public func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shuttingDown = true
            self.cancelReconnect()
            self.cancelSessionTimers()
            self.teardownConnection()
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
            guard !self.pairingInProgress else {
                DispatchQueue.main.async { completion(.failure(PairingError.alreadyPairing)) }
                return
            }
            self.pairingInProgress = true
            self.cancelReconnect()
            self.teardownConnection()

            // Fresh transport per attempt: `PinnedTLSTransport.connect` resets
            // per-connection state, so reusing an instance across attempts would
            // race that reset. Every connection attempt in this class — pairing
            // and reconnect alike — constructs its own instance.
            let transport = PinnedTLSTransport()
            self.transport = transport
            transport.connect(host: host, port: port, mode: .trustOnFirstUse) { [weak self] result in
                guard let self else { return }
                self.queue.async {
                    switch result {
                    case .failure(let error):
                        self.pairingInProgress = false
                        self.teardownConnection()
                        DispatchQueue.main.async {
                            completion(.failure(PairingError.transport(String(describing: error))))
                        }
                    case .success(let presentedFingerprint):
                        let candidate = PairingRecord(host: host,
                                                      port: port,
                                                      token: token,
                                                      certificateFingerprint: presentedFingerprint)
                        self.beginPairingHandshake(transport: transport,
                                                   candidate: candidate,
                                                   completion: completion)
                    }
                }
            }
        }
    }

    private func beginPairingHandshake(transport: PinnedTLSTransport,
                                       candidate: PairingRecord,
                                       completion: @escaping (Result<PairingRecord, Error>) -> Void) {
        let client = ControlClient(transport: transport, token: candidate.token, clientId: clientId)
        self.client = client
        self.pendingPairing = (candidate, completion)
        client.delegate = self
        client.begin()
    }

    public func unpair() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelReconnect()
            self.cancelSessionTimers()
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

    private func openConnection() {
        guard !shuttingDown, let record else { return }
        if case .hardStop = controller.state { return }
        teardownConnection()

        apply(controller.handle(.connectAttemptStarted))
        publishState()

        // Fresh transport per attempt — see the note in `pair(...)`.
        let transport = PinnedTLSTransport()
        self.transport = transport
        transport.connect(host: record.host,
                          port: record.port,
                          mode: .pinned(fingerprint: record.certificateFingerprint)) { [weak self] result in
            guard let self else { return }
            self.queue.async {
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
                        self.apply(self.controller.handle(
                            .fingerprintMismatch(expected: expected, presented: presented)))
                    } else {
                        self.apply(self.controller.handle(
                            .connectionLost(reason: String(describing: error))))
                    }
                    self.publishState()
                }
            }
        }
    }

    private func teardownConnection() {
        if let client { totalAudioBytes += client.audioBytesReceived }
        client?.stop()
        client = nil
        transport?.close()
        transport = nil
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

    private func cancelSessionTimers() {
        startTimeoutTimer?.cancel(); startTimeoutTimer = nil
        stopTimeoutTimer?.cancel(); stopTimeoutTimer = nil
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
            guard let self else { return }
            if let pending = self.pendingPairing {
                // The token proved out on this connection, so the certificate it
                // presented is now trustworthy enough to pin.
                self.pendingPairing = nil
                self.pairingInProgress = false
                do {
                    try self.store.save(pending.record)
                } catch {
                    DispatchQueue.main.async { pending.completion(.failure(error)) }
                    return
                }
                self.record = pending.record
                // Sanctioned escape from `.hardStop`: only this path, the
                // completion of an explicit user pairing action, ever feeds
                // `.paired` into `SessionController`. `startIfPaired()` and the
                // reconnect loop never do.
                self.apply(self.controller.handle(.paired))
                DispatchQueue.main.async { pending.completion(.success(pending.record)) }
            }
            self.backoff.reset()
            self.apply(self.controller.handle(.authenticated(micPresent: micPresent,
                                                             deviceLabel: deviceLabel)))
            self.publishState()
        }
    }

    public func controlClient(_ client: ControlClient, didReceive message: ControlMessage) {
        queue.async { [weak self] in
            guard let self else { return }
            switch message {
            case .startAck(let requestId, let sessionId, _):
                self.startTimeoutTimer?.cancel(); self.startTimeoutTimer = nil
                self.apply(self.controller.handle(.startAcked(requestId: requestId, sessionId: sessionId)))
            case .startNack(let requestId, let reason):
                self.startTimeoutTimer?.cancel(); self.startTimeoutTimer = nil
                self.apply(self.controller.handle(.startNacked(requestId: requestId, reason: reason)))
            case .stopAck(let requestId, _):
                self.stopTimeoutTimer?.cancel(); self.stopTimeoutTimer = nil
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
            guard let self else { return }
            self.cancelSessionTimers()
            if let pending = self.pendingPairing {
                // Closed before HELLO_ACK: the token was wrong, or the peer hung up.
                self.pendingPairing = nil
                self.pairingInProgress = false
                self.teardownConnection()
                DispatchQueue.main.async {
                    pending.completion(.failure(
                        PairingError.authenticationFailed(error.map { String(describing: $0) } ?? "connection closed")))
                }
                return
            }
            self.teardownConnection()
            self.apply(self.controller.handle(
                .connectionLost(reason: error.map { String(describing: $0) } ?? "connection closed")))
            self.publishState()
        }
    }
}
