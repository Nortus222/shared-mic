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
    /// Phase 2 render path (plan Task 5). All renderer calls happen on this
    /// queue — never on the control queue, which also services the heartbeat
    /// and handshake deadlines. `renderer` itself is immutable after init so
    /// the audio sink can capture it from any queue safely.
    private let rendererQueue = DispatchQueue(label: "com.sharedmic.renderer")
    private let renderer: RendererControl

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
    private let demandSettings: DemandSettingsStore
    private var stopDebounceTimer: DispatchSourceTimer?
    private var stopDebounceSessionId: String?
    private var holdTimer: DispatchSourceTimer?
    private var holdEnd: Date?
    private var demandObserver: AudioDemandObserver?
    private var lastSnapshot = DemandSnapshot()
    public var onDemandChange: ((DemandSnapshot) -> Void)?
    private var startedSessions = 0
    private var debounceFires = 0
    private var lastActivationLatency: Double?
    private var startSentAt: Date?
    private var awaitingFirstFrame = false
    /// Phase 4 diagnostics (spec §11). All confined to `queue`.
    private var reconnectCount = 0
    private var authFailureCount = 0
    private var latencySamplesMs: [Double] = []
    private var sessionBeganAt: Date?
    private var totalSessionSeconds = 0.0
    private var accumulatedRenderer = RendererCounters()
    private static let maxLatencySamples = 50
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

    public init(store: PairingStore,
                clientId: String = Host.current().localizedName ?? "mac",
                makeRenderer: (() -> RendererControl)? = nil,
                demandSettings: DemandSettingsStore = UserDefaultsDemandSettingsStore(),
                makeObserver: ((@escaping (DemandSnapshot) -> Void) -> AudioDemandObserver)? = nil) {
        self.store = store
        self.clientId = clientId
        self.renderer = makeRenderer?() ?? AudioRenderer()
        self.demandSettings = demandSettings
        let settings = demandSettings.load()
        let debounceSeconds = Double(settings.stopDebounceMs) / 1000.0
        if let loaded = try? store.load() {
            self.record = loaded
            self.controller = SessionController(
                state: settings.disabled ? .disabled : .disconnected,
                stopDebounceSeconds: debounceSeconds)
        } else if settings.disabled {
            self.controller = SessionController(state: .disabled,
                                                stopDebounceSeconds: debounceSeconds)
        } else {
            self.controller = SessionController(stopDebounceSeconds: debounceSeconds)
        }
        if let makeObserver {
            let observer = makeObserver({ [weak self] snapshot in
                self?.noteSnapshot(snapshot)
            })
            self.demandObserver = observer
            observer.start()
        }
    }

    // MARK: - Observable state

    public var state: AgentState { queue.sync { controller.state } }
    public var deviceLabel: String { queue.sync { controller.deviceLabel } }
    public var micPresent: Bool { queue.sync { controller.micPresent } }
    public var pairedHost: String? { queue.sync { record?.host } }
    public var audioBytesReceived: Int { queue.sync { totalAudioBytes + (client?.audioBytesReceived ?? 0) } }
    public var demandSnapshot: DemandSnapshot { queue.sync { lastSnapshot } }
    public var holdRemaining: TimeInterval? {
        queue.sync {
            guard let end = holdEnd else { return nil }
            return max(0, end.timeIntervalSinceNow)
        }
    }
    public var stopDebounceMs: Int { queue.sync { demandSettings.load().stopDebounceMs } }
    public var holdSeconds: TimeInterval { queue.sync { demandSettings.load().holdSeconds } }
    public var sessionCountValue: Int { queue.sync { startedSessions } }
    public var debounceFireCount: Int { queue.sync { debounceFires } }
    public var lastActivationLatencyMs: Double? { queue.sync { lastActivationLatency } }
    /// This second's rendered-PCM peak for the menu meter. Read-and-clear:
    /// each call takes what rendered since the previous one, which is exactly
    /// the 1 Hz menu poll's cadence. Main-thread callers only (see
    /// `diagnosticsSnapshot()` for why the renderer-queue hop is safe).
    public var renderedPeak: Float { rendererQueue.sync { renderer.takeRenderedPeak() } }
    public var reconnectCountValue: Int { queue.sync { reconnectCount } }
    public var authFailureCountValue: Int { queue.sync { authFailureCount } }
    public var totalSessionSecondsValue: Double {
        queue.sync { totalSessionSeconds + openSessionElapsedLocked() }
    }

    /// One consistent read of every §11 row the diagnostics view displays.
    /// The renderer read hops to `rendererQueue` synchronously: safe from any
    /// thread except `rendererQueue` itself (the renderer never calls back
    /// into this queue synchronously, so no cycle). Main-thread callers only.
    public func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        queue.sync {
            let live = rendererQueue.sync { renderer.readCounters() }
            return DiagnosticsSnapshot(
                sessionCount: startedSessions,
                totalSessionSeconds: totalSessionSeconds + openSessionElapsedLocked(),
                activationLatency: ActivationLatencyStats.compute(samples: latencySamplesMs),
                renderer: accumulatedRenderer.adding(live),
                reconnectCount: reconnectCount,
                authFailureCount: authFailureCount,
                debounceFireCount: debounceFires,
                audioBytesReceived: totalAudioBytes + (client?.audioBytesReceived ?? 0))
        }
    }

    /// In-progress session age for the snapshot. Must be called on `queue`.
    private func openSessionElapsedLocked() -> Double {
        guard let began = sessionBeganAt else { return 0 }
        return Date().timeIntervalSince(began)
    }
    public var isDisabled: Bool {
        queue.sync { if case .disabled = controller.state { return true }; return false }
    }

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

    /// Sleep/wake recovery (spec §12 Phase 4). Stale AudioObjectIDs must never
    /// survive a sleep cycle, so every wake forces the BlackHole UID
    /// re-resolve plus a full demand rescan — `rescanNow()` already does
    /// exactly that. Transport recovery rides the existing backoff: a live
    /// connection (or its already-pending reconnect) owns it, and demand
    /// re-fires on re-auth through the normal `refireIfIdleWithDemand` path.
    /// Repeated wakes cannot stack reconnects: a pending attempt suppresses
    /// a new one, and the backoff sequence is never reset here.
    public func handleWake() {
        queue.async { [weak self] in
            guard let self, !self.shuttingDown else { return }
            self.demandObserver?.rescanNow()
            guard self.record != nil,
                  self.client == nil,
                  self.reconnectTimer == nil else { return }
            if case .hardStop = self.controller.state { return }
            self.scheduleReconnect()
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
            self.cancelHoldTimer()
            self.demandObserver?.stop()
            self.demandObserver = nil
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
        self.wireAudioSink(client)
        client.begin()
    }

    /// The single exit for an in-flight `pair(...)`. Both fields are cleared
    /// before the completion is called out to, so whichever path arrives first
    /// wins and no later path can double-fire it.
    @discardableResult
    private func resolvePairing(_ result: Result<PairingRecord, Error>) -> Bool {
        if case .failure(let error) = result,
           case .authenticationFailed = (error as? PairingError) {
            // On `queue` in every caller: pair-flow failures resolve here.
            authFailureCount += 1
        }
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
            self.cancelHoldTimer()
            self.apply(self.controller.handle(.unpairedByUser))
            // Unpair is an explicit reset: clear the kill switch, the hold,
            // and the demand flags (all silent no-ops in `.unpaired`) so a
            // later pairing starts from clean state rather than stale flags.
            var settings = self.demandSettings.load()
            settings.disabled = false
            self.demandSettings.save(settings)
            self.apply(self.controller.handle(.holdExpired(requestId: self.nextRequestId())))
            self.apply(self.controller.handle(.demandChanged(hasDemand: false, requestId: self.nextRequestId())))
            self.lastSnapshot = DemandSnapshot()
            self.publishState()
        }
    }

    // MARK: - Demand-driven session control (Phase 3)
    //
    // Sessions start and stop from `AudioDemandObserver` snapshots arriving
    // via `noteSnapshot(_:)`. The kill switch and force-on hold are the only
    // manual session controls; the Phase 1 Start/Stop scaffolding is gone.

    /// Kill switch (spec §5.3): sends STOP immediately, persists DISABLED,
    /// cancels any hold. Only `enable()` leaves it.
    public func disable() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelHoldTimer()
            self.apply(self.controller.handle(.userDisabled(requestId: self.nextRequestId())))
            var settings = self.demandSettings.load()
            settings.disabled = true
            self.demandSettings.save(settings)
            self.publishState()
        }
    }

    public func enable() {
        queue.async { [weak self] in
            guard let self else { return }
            self.apply(self.controller.handle(.userEnabled))
            // Enabling with no pairing must not strand the machine in `.idle`
            // (which implies a live connection): fall back to `.unpaired`.
            if self.record == nil {
                self.apply(self.controller.handle(.unpairedByUser))
            }
            var settings = self.demandSettings.load()
            settings.disabled = false
            self.demandSettings.save(settings)
            // The machine records no demand while disabled; re-drive from the
            // last observer snapshot so enable-with-demand starts promptly.
            if self.lastSnapshot.hasDemand {
                self.apply(self.controller.handle(
                    .demandChanged(hasDemand: true, requestId: self.nextRequestId())))
            }
            self.publishState()
        }
    }

    /// Force-on hold (spec §5.4) for apps Core Audio cannot see. Ignored
    /// while disabled or hard-stopped. Pressing again restarts the hold from
    /// now — each press is fresh explicit consent, and expiry still applies.
    public func beginHold() {
        queue.async { [weak self] in
            guard let self else { return }
            if case .disabled = self.controller.state { return }
            if case .hardStop = self.controller.state { return }
            let seconds = self.demandSettings.load().holdSeconds
            self.holdEnd = Date().addingTimeInterval(seconds)
            self.armHoldTimer()
            self.apply(self.controller.handle(.holdBegan(requestId: self.nextRequestId())))
            self.publishState()
        }
    }

    public func cancelHold() {
        queue.async { [weak self] in
            guard let self, self.holdEnd != nil else { return }
            self.cancelHoldTimer()
            self.apply(self.controller.handle(.holdExpired(requestId: self.nextRequestId())))
            self.publishState()
        }
    }

    public func setStopDebounceMs(_ ms: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            var settings = self.demandSettings.load()
            settings.stopDebounceMs = DemandSettings.clampDebounceMs(ms)
            self.demandSettings.save(settings)
            self.controller.setStopDebounceSeconds(Double(settings.stopDebounceMs) / 1000.0)
        }
    }

    private func noteSnapshot(_ snapshot: DemandSnapshot) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastSnapshot = snapshot
            self.apply(self.controller.handle(
                .demandChanged(hasDemand: snapshot.hasDemand, requestId: self.nextRequestId())))
            self.publishState()
            DispatchQueue.main.async { [weak self] in
                self?.onDemandChange?(snapshot)
            }
        }
    }

    /// After landing in `.idle`, a session the observer still wants must be
    /// (re)started: reconnect recovery, replug recovery, and STOP-race
    /// recovery (demand returned while stopping) all funnel through here.
    /// Deliberately NOT called after `startNacked` — a refused START must
    /// never auto-retry into a START storm — and guarded on mic presence so
    /// an absent mic can never notify-loop.
    private func refireIfIdleWithDemand() {
        guard case .idle = controller.state,
              controller.micPresent,
              record != nil,
              client != nil,
              controller.hasDemand || controller.holdActive else { return }
        if controller.hasDemand {
            apply(controller.handle(.demandChanged(hasDemand: true, requestId: nextRequestId())))
        } else {
            apply(controller.handle(.holdBegan(requestId: nextRequestId())))
        }
    }

    private func armStopDebounceTimer(sessionId: String, seconds: TimeInterval) {
        cancelStopDebounceTimer()
        stopDebounceSessionId = sessionId
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let pending = self.stopDebounceSessionId
            self.stopDebounceTimer = nil
            self.stopDebounceSessionId = nil
            guard case .stopPending(let current) = self.controller.state,
                  current == pending else { return }
            // The spec's debounce-firing check: this increments only when the
            // debounce actually fires a STOP, never on arm or cancel.
            self.debounceFires += 1
            self.apply(self.controller.handle(
                .stopDebounceExpired(requestId: self.nextRequestId(), sessionId: pending ?? "")))
            self.publishState()
        }
        timer.resume()
        stopDebounceTimer = timer
    }

    private func cancelStopDebounceTimer() {
        stopDebounceTimer?.cancel()
        stopDebounceTimer = nil
        stopDebounceSessionId = nil
    }

    private func armHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
        guard let end = holdEnd else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, end.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.holdEnd = nil
            self.holdTimer = nil
            self.apply(self.controller.handle(.holdExpired(requestId: self.nextRequestId())))
            self.publishState()
        }
        timer.resume()
        holdTimer = timer
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
        holdEnd = nil
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
                    self.wireAudioSink(client)
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
        // The renderer is connection-scoped like the client: every teardown —
        // connection loss, unpair, shutdown, re-pair — closes it. Async on
        // the renderer queue, ordered after the client stop, so sink blocks
        // already queued run first (FIFO); the next `open()` clears the
        // bridge, so nothing stale survives into the next session.
        let renderer = self.renderer
        noteSessionEnded()
        accumulatedRenderer = accumulatedRenderer.adding(rendererQueue.sync { renderer.readCounters() })
        rendererQueue.async { renderer.finalizeClose() }
    }

    /// Phase 2 render handoff (plan Task 5): validated PCM crosses from the
    /// control queue to the renderer queue async — the renderer's bridge
    /// drops oldest with a counter when full, so audio bursts never
    /// back-pressure the heartbeat.
    private func wireAudioSink(_ client: ControlClient) {
        client.audioSink = { [weak self] pcm in
            guard let self else { return }
            let renderer = self.renderer
            self.rendererQueue.async { renderer.enqueue(pcm: pcm) }
            self.queue.async { self.noteFirstFrame() }
        }
    }

    /// Phase 3 measurement: START sent to first playable frame. Recorded once
    /// per session; cleared when the session ends before any frame arrives.
    private func noteFirstFrame() {
        guard awaitingFirstFrame, let sent = startSentAt else { return }
        awaitingFirstFrame = false
        let latencyMs = Date().timeIntervalSince(sent) * 1000.0
        lastActivationLatency = latencyMs
        latencySamplesMs.append(latencyMs)
        if latencySamplesMs.count > Self.maxLatencySamples {
            latencySamplesMs.removeFirst(latencySamplesMs.count - Self.maxLatencySamples)
        }
    }

    /// A START_ACK opens the billable session: durations measure ACKed
    /// sessions only, never unanswered STARTs. Duplicate ACKs for an already
    /// open session must not restart the clock.
    private func noteSessionBegan() {
        if sessionBeganAt == nil { sessionBeganAt = Date() }
    }

    /// Idempotent: every session-end path (STOP_ACK, stop timeout, teardown)
    /// funnels through here, and only the first one per session collects.
    private func noteSessionEnded() {
        guard let began = sessionBeganAt else { return }
        sessionBeganAt = nil
        totalSessionSeconds += Date().timeIntervalSince(began)
    }

    /// Surfaces a renderer `open()` failure (missing output device above all) on
    /// the coordinator queue so it goes through the normal notice pipeline.
    private func failRendererOpen(_ error: Error) {
        queue.async { [weak self] in
            guard let self else { return }
            if let rendererError = error as? AudioRendererError,
               case .deviceUnavailable(let guidance) = rendererError {
                self.apply([.notify(guidance)])
            } else {
                self.apply([.notify("Audio output unavailable: \(String(describing: error))")])
            }
            self.publishState()
        }
    }

    /// The single place that both records a fingerprint mismatch (so a relaunch
    /// can reconstruct `.hardStop` from the store instead of reconnecting to
    /// find out again — see `openConnection()`) and drives it through the normal
    /// `SessionController`/`apply(...)` pipeline.
    private func applyFingerprintMismatch(expected: String, presented: String) {
        authFailureCount += 1
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
                startedSessions += 1
                startSentAt = Date()
                awaitingFirstFrame = true
            case .sendStop(let requestId, let sessionId):
                client?.send(.stop(requestId: requestId, sessionId: sessionId))
                awaitingFirstFrame = false
            case .armStartTimeout(let requestId, let seconds):
                armStartTimeout(requestId: requestId, seconds: seconds)
            case .armStopTimeout(let requestId, let seconds):
                armStopTimeout(requestId: requestId, seconds: seconds)
            case .cancelStartTimeout(let requestId):
                cancelStartTimeout(requestId: requestId)
            case .cancelStopTimeout(let requestId):
                cancelStopTimeout(requestId: requestId)
            case .armStopDebounce(let sessionId, let seconds):
                armStopDebounceTimer(sessionId: sessionId, seconds: seconds)
            case .cancelStopDebounce:
                cancelStopDebounceTimer()
            case .scheduleReconnect:
                scheduleReconnect()
            case .closeConnection:
                teardownConnection()
            case .openRenderer:
                let renderer = self.renderer
                rendererQueue.async { [weak self] in
                    do {
                        try renderer.open()
                    } catch {
                        self?.failRendererOpen(error)
                    }
                }
            case .closeRendererAfterDrain:
                let renderer = self.renderer
                rendererQueue.async { renderer.closeAfterDrain() }
            case .closeRenderer:
                let renderer = self.renderer
                rendererQueue.async { renderer.finalizeClose() }
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
            // A timed-out STOP is treated as ended (see the machine's
            // stopTimeoutMessage), so the duration stops here too.
            self.noteSessionEnded()
            self.apply(self.controller.handle(.stopTimedOut(requestId: requestId)))
            self.refireIfIdleWithDemand()
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
        cancelStopDebounceTimer()
    }

    private func scheduleReconnect() {
        guard !shuttingDown, record != nil else { return }
        if case .hardStop = controller.state { return }
        cancelReconnect()
        let delay = backoff.nextDelay()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconnectCount += 1
            self.openConnection()
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
            self.refireIfIdleWithDemand()
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
                self.noteSessionBegan()
                self.apply(self.controller.handle(.startAcked(requestId: requestId, sessionId: sessionId)))
            case .startNack(let requestId, let reason):
                self.apply(self.controller.handle(.startNacked(requestId: requestId, reason: reason)))
            case .stopAck(let requestId, _):
                self.noteSessionEnded()
                self.apply(self.controller.handle(.stopAcked(requestId: requestId)))
                self.refireIfIdleWithDemand()
            case .status(let micPresent, let active, let deviceLabel):
                self.apply(self.controller.handle(.statusReceived(micPresent: micPresent,
                                                                  active: active,
                                                                  deviceLabel: deviceLabel)))
                self.refireIfIdleWithDemand()
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
