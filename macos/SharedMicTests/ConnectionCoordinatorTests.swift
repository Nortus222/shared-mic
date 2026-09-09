import XCTest
@testable import SharedMic

/// A loopback socket that listens and then says nothing at all. The kernel
/// completes the TCP handshake from the backlog, so `connect` succeeds, but
/// nothing ever answers the ClientHello — a TLS client hangs there until its own
/// timeout.
///
/// That is what makes "abandon a pairing while its connect is still in flight" a
/// deterministic test rather than a race: nothing can resolve that connect while
/// the test runs. Deliberately a raw BSD socket rather than an `NWListener` —
/// `NWListener` fails outright (EINVAL at `start`) in this test environment,
/// while `bind`/`listen` work, and the connection is never accepted or read from
/// so nothing more than a listening socket is needed.
private final class SilentTCPListener {
    struct StartupFailure: Error { let detail: String }

    private let descriptor: Int32
    let port: UInt16

    init() throws {
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw StartupFailure(detail: "socket() failed: \(errno)") }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                       // let the kernel choose
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fileDescriptor, 4) == 0 else {
            close(fileDescriptor)
            throw StartupFailure(detail: "bind/listen failed: \(errno)")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fileDescriptor, $0, &length)
            }
        }
        guard named == 0 else {
            close(fileDescriptor)
            throw StartupFailure(detail: "getsockname failed: \(errno)")
        }
        descriptor = fileDescriptor
        port = UInt16(bigEndian: assigned.sin_port)
    }

    func stop() {
        close(descriptor)
    }
}

final class ConnectionCoordinatorTests: XCTestCase {

    private func waitForState(_ coordinator: ConnectionCoordinator,
                              timeout: TimeInterval = 20.0,
                              description: String,
                              _ matches: @escaping (AgentState) -> Bool) {
        let reached = expectation(description: description)
        var fulfilled = false
        coordinator.onStateChange = { state in
            if !fulfilled && matches(state) {
                fulfilled = true
                reached.fulfill()
            }
        }
        if !fulfilled && matches(coordinator.state) {
            fulfilled = true
            reached.fulfill()
        }
        wait(for: [reached], timeout: timeout)
    }

    /// Renderer actions execute async on the renderer's serial queue while
    /// state publishes on the main queue, with no ordering between them: after
    /// `waitForState` returns, the renderer effect may still be queued. Poll
    /// the recording instead of asserting immediately.
    private func waitForRecording(_ description: String,
                                  timeout: TimeInterval = 5.0,
                                  _ check: @escaping () -> Bool) {
        let met = expectation(description: description)
        func poll() {
            if check() {
                met.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        poll()
        wait(for: [met], timeout: timeout)
    }

    private func pair(_ coordinator: ConnectionCoordinator,
                      with server: MockWindowsServerProcess) throws -> PairingRecord {
        let paired = expectation(description: "paired")
        var outcome: Result<PairingRecord, Error>!
        coordinator.pair(host: "127.0.0.1", port: server.port, pairingString: server.pairingString) { result in
            outcome = result
            paired.fulfill()
        }
        wait(for: [paired], timeout: 30.0)
        switch outcome! {
        case .success(let record):
            return record
        case .failure(let error):
            throw error
        }
    }

    /// Design spec §7.1: pairing pins the fingerprint and stores token +
    /// fingerprint in the store. The fingerprint is captured trust-on-first-use
    /// and persisted only after the token proves out on that same connection.
    func testPairingPinsTheFingerprintAndStoresTheToken() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let record = try pair(coordinator, with: server)
        XCTAssertEqual(record.certificateFingerprint, server.fingerprint)
        XCTAssertEqual(record.token, server.token)
        XCTAssertEqual(record.host, "127.0.0.1")
        XCTAssertEqual(record.port, server.port)
        XCTAssertEqual(try store.load(), record)
    }

    func testPairingReachesIdle() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle after pairing") { $0 == .idle }
        XCTAssertEqual(coordinator.deviceLabel, "Mock USB Mic")
        XCTAssertTrue(coordinator.micPresent)
    }

    /// A wrong token must not leave a pinned certificate behind — otherwise a
    /// mistyped pairing string would silently pin whatever answered the port.
    func testFailedPairingStoresNothing() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let finished = expectation(description: "pairing finished")
        var outcome: Result<PairingRecord, Error>!
        // A syntactically valid pairing string for a different 32-byte token.
        let wrongString = PairingString.encode(token: Data(repeating: 0x5a, count: 32))
        coordinator.pair(host: "127.0.0.1", port: server.port, pairingString: wrongString) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30.0)

        guard case .failure = outcome! else {
            return XCTFail("pairing with the wrong token must fail")
        }
        XCTAssertNil(try store.load(), "a failed pairing must not persist anything")
    }

    func testMalformedPairingStringIsRejectedBeforeAnyConnection() throws {
        let store = InMemoryPairingStore()
        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let finished = expectation(description: "rejected")
        var outcome: Result<PairingRecord, Error>!
        coordinator.pair(host: "127.0.0.1", port: 47_800, pairingString: "TOOSHORT") { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10.0)
        guard case .failure(let error) = outcome! else {
            return XCTFail("a short pairing string must be rejected")
        }
        XCTAssertEqual(error as? PairingStringError, .wrongDecodedLength(5))
        XCTAssertNil(try store.load())
    }

    func testStartIfPairedReconnectsFromAStoredRecord() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: server.fingerprint))

        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }
        coordinator.startIfPaired()
        waitForState(coordinator, description: "idle from stored pairing") { $0 == .idle }
    }

    // MARK: - Phase 3 demand-driven sessions

    private func demandFake() -> FakeCoreAudioQuery {
        let fake = FakeCoreAudioQuery()
        fake.procs = [
            10: FakeCoreAudioQuery.Proc(pid: 501, bundle: "com.example.voice", devices: []),
            11: FakeCoreAudioQuery.Proc(pid: 1000, bundle: "com.sharedmic.SharedMic", devices: [99]),
        ]
        return fake
    }

    private func demandCoordinator(fake: FakeCoreAudioQuery,
                                   makeRenderer: (() -> RendererControl)? = nil) -> ConnectionCoordinator {
        ConnectionCoordinator(
            store: InMemoryPairingStore(), clientId: "mac-tests",
            makeRenderer: makeRenderer,
            demandSettings: InMemoryDemandSettingsStore(DemandSettings(stopDebounceMs: 500)),
            makeObserver: { onChange in
                AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
            })
    }

    private func waitForObserverReady(_ fake: FakeCoreAudioQuery) {
        let ready = expectation(description: "observer registered listeners")
        func poll() {
            if !fake.deviceBlocks.isEmpty {
                ready.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        poll()
        wait(for: [ready], timeout: 10.0)
    }

    private func setDemand(_ fake: FakeCoreAudioQuery, _ hasDemand: Bool) {
        waitForObserverReady(fake)
        guard let object = fake.procs.first(where: { $0.value.pid == 501 })?.key else {
            XCTFail("demand fixture process missing")
            return
        }
        fake.procs[object]?.devices = hasDemand ? [99] : []
        fake.fireDevice(object)
    }

    private func waitForStreaming(_ coordinator: ConnectionCoordinator) {
        waitForState(coordinator, description: "streaming") { state in
            if case .streaming = state { return true }
            return false
        }
    }

    /// Phase 3 replaces the manual Start/Stop scaffolding: demand appearing
    /// starts a session with no button press, demand clearing stops it after
    /// the debounce.
    func testDemandStartsAndStopsASession() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        // Recording renderer: a live session must not open real audio
        // hardware as a test side effect on Macs with BlackHole installed.
        let fake = demandFake()
        let coordinator = demandCoordinator(fake: fake, makeRenderer: { RecordingRenderer() })
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        setDemand(fake, true)
        waitForStreaming(coordinator)
        XCTAssertGreaterThan(coordinator.audioBytesReceived, 0)

        setDemand(fake, false)
        waitForState(coordinator, description: "idle again") { $0 == .idle }
    }

    /// Plan Task 5: the one control-plane touch, end to end. START opens the
    /// renderer, validated PCM lands in it as whole 1,920-byte frames off the
    /// control queue, STOP drains and STOP_ACK closes, byte counts reconcile.
    /// Phase 3 drives both ends from demand instead of by hand.
    func testDemandDrivenSessionRendersAudioThroughTheRenderer() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let recording = RecordingRenderer()
        let fake = demandFake()
        let coordinator = demandCoordinator(fake: fake, makeRenderer: { recording })
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }
        XCTAssertEqual(recording.opened, 0, "idle holds no output unit")

        setDemand(fake, true)
        waitForStreaming(coordinator)
        let rendering = expectation(description: "audio rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { rendering.fulfill() }
        wait(for: [rendering], timeout: 5.0)

        XCTAssertEqual(recording.opened, 1, "entry to STARTING opens the renderer")
        XCTAssertGreaterThan(recording.enqueuedPCM.count, 10, "expected ~50 frames/second")
        XCTAssertTrue(recording.enqueuedPCM.allSatisfy { $0.count == SharedMicProtocol.audioPCMBytes })
        XCTAssertEqual(coordinator.audioBytesReceived,
                       recording.enqueuedPCM.count * SharedMicProtocol.audioPCMBytes)

        let drainedBefore = recording.drained
        let finalizedBefore = recording.finalized
        setDemand(fake, false)
        waitForState(coordinator, description: "idle again") { $0 == .idle }
        waitForRecording("STOP drains before close") { recording.drained == drainedBefore + 1 }
        waitForRecording("STOP_ACK closes the renderer") { recording.finalized == finalizedBefore + 1 }
    }

    /// Mic loss mid-session takes the abnormal exit: no drain window, the
    /// renderer closes immediately with the session.
    func testMicLossMidSessionClosesTheRenderer() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let recording = RecordingRenderer()
        let fake = demandFake()
        let coordinator = demandCoordinator(fake: fake, makeRenderer: { recording })
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }
        setDemand(fake, true)
        waitForStreaming(coordinator)
        let rendering = expectation(description: "audio rendered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { rendering.fulfill() }
        wait(for: [rendering], timeout: 5.0)
        XCTAssertGreaterThan(recording.enqueuedPCM.count, 0)

        let finalizedBefore = recording.finalized
        server.setMicPresent(false)
        waitForState(coordinator, description: "degraded") { state in
            if case .degraded = state { return true }
            return false
        }
        waitForRecording("mic loss closes the renderer") { recording.finalized == finalizedBefore + 1 }
    }

    /// A renderer that cannot open (BlackHole missing) must surface guidance,
    /// not silence: the session still proceeds, but the user is told why no
    /// audio arrives.
    func testRendererOpenFailureSurfacesGuidance() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let recording = RecordingRenderer()
        recording.openError = AudioRendererError.deviceUnavailable(message: BlackHoleDevice.unavailableMessage)
        let fake = demandFake()
        let coordinator = demandCoordinator(fake: fake, makeRenderer: { recording })
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        let guided = expectation(description: "guidance notice")
        var notice: String?
        coordinator.onNotice = { message in
            notice = message
            guided.fulfill()
        }
        setDemand(fake, true)
        wait(for: [guided], timeout: 10.0)
        XCTAssertTrue(notice?.contains("BlackHole") ?? false,
                      "expected setup guidance")
    }

    /// Design spec §8: network drops mid-session — the Mac reconnects with backoff.
    ///
    /// This is the end-to-end proof that the reconnect path actually reconnects,
    /// not merely that `dropConnections()` returned: it asserts the coordinator
    /// first observes `.disconnected` (the drop was noticed) and then transitions
    /// all the way back to `.idle` (a fresh transport was opened, the pinned TLS
    /// handshake succeeded again, and HELLO_ACK re-authenticated).
    func testReconnectsAfterTheConnectionDrops() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        let disconnected = expectation(description: "disconnected")
        var sawDisconnected = false
        coordinator.onStateChange = { state in
            if !sawDisconnected && state == .disconnected {
                sawDisconnected = true
                disconnected.fulfill()
            }
        }
        server.dropConnections()
        wait(for: [disconnected], timeout: 20.0)

        // First backoff step is 0.5 s +/- 20%, so this must recover quickly.
        waitForState(coordinator, timeout: 30.0, description: "idle again after reconnect") { $0 == .idle }
    }

    /// The hard stop, end to end: a stored pin that does not match the presented
    /// certificate must stop dead, warn, and never retry.
    func testFingerprintMismatchStopsDeadAndDoesNotRetry() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: String(repeating: "00", count: 32)))

        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let warned = expectation(description: "user warned")
        var warning: (expected: String, presented: String)?
        coordinator.onFingerprintWarning = { expected, presented in
            warning = (expected, presented)
            warned.fulfill()
        }
        coordinator.startIfPaired()
        wait(for: [warned], timeout: 30.0)

        XCTAssertEqual(warning?.expected, String(repeating: "00", count: 32))
        XCTAssertEqual(warning?.presented, server.fingerprint)
        guard case .hardStop = coordinator.state else {
            return XCTFail("expected .hardStop, got \(coordinator.state)")
        }

        // No automatic retry, ever: the state must still be .hardStop after long
        // enough for several backoff steps to have fired.
        let settled = expectation(description: "no retry")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { settled.fulfill() }
        wait(for: [settled], timeout: 10.0)
        guard case .hardStop = coordinator.state else {
            return XCTFail("the agent recovered from a fingerprint mismatch on its own")
        }
    }

    // MARK: - Task 13 review, item 1: hard stop persists across a relaunch

    /// A fingerprint mismatch must leave a marker in the store, not just the
    /// in-memory `AgentState` — that marker is what lets a relaunch reconstruct
    /// `.hardStop` without dialing the mismatching peer again.
    func testFingerprintMismatchPersistsTheHardStopMarker() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: String(repeating: "00", count: 32)))

        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let warned = expectation(description: "user warned")
        coordinator.onFingerprintWarning = { _, _ in warned.fulfill() }
        coordinator.startIfPaired()
        wait(for: [warned], timeout: 30.0)

        let stored = try store.load()
        XCTAssertEqual(stored?.certificateFingerprint, String(repeating: "00", count: 32),
                       "the pinned (expected) fingerprint must be untouched")
        XCTAssertEqual(stored?.hardStopPresentedFingerprint, server.fingerprint,
                       "the presented fingerprint must be recorded as the hard-stop marker")
    }

    /// The other half of item 1: a coordinator constructed fresh over a store
    /// that already carries the hard-stop marker must reconstruct `.hardStop`
    /// **without ever opening a connection** — even when the stored pin would
    /// authenticate fine, proving the marker wins over dialing out to check.
    func testStartIfPairedWithPersistedHardStopNeverConnects() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        // Pinned to the mock's real fingerprint — a connection attempt would
        // succeed and authenticate fine — but carrying a hard-stop marker from
        // a supposed earlier mismatch. The marker must win.
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: server.fingerprint,
                                     hardStopPresentedFingerprint: String(repeating: "11", count: 32)))

        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let warned = expectation(description: "user warned")
        var warning: (expected: String, presented: String)?
        coordinator.onFingerprintWarning = { expected, presented in
            warning = (expected, presented)
            warned.fulfill()
        }
        coordinator.startIfPaired()
        wait(for: [warned], timeout: 10.0)

        XCTAssertEqual(warning?.expected, server.fingerprint)
        XCTAssertEqual(warning?.presented, String(repeating: "11", count: 32))
        guard case .hardStop = coordinator.state else {
            return XCTFail("expected .hardStop, got \(coordinator.state)")
        }
        // No authentication occurred: mic presence, device label, and audio
        // byte count are all still the never-connected defaults.
        XCTAssertFalse(coordinator.micPresent)
        XCTAssertEqual(coordinator.deviceLabel, "")
        XCTAssertEqual(coordinator.audioBytesReceived, 0)

        // Settle briefly and confirm it really never dials out on its own.
        let settled = expectation(description: "stayed put")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)
        guard case .hardStop = coordinator.state else {
            return XCTFail("coordinator connected despite a persisted hard stop")
        }
    }

    /// A successful `pair(...)` — the explicit user pairing action the spec
    /// sanctions — must clear a prior hard-stop marker, and a later
    /// `startIfPaired()` (standing in for the next relaunch) must then connect
    /// normally instead of re-entering `.hardStop`.
    func testSuccessfulPairClearsAPriorHardStopMarker() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        // Simulate a stored hard stop left over from an earlier mismatch.
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: String(repeating: "00", count: 32),
                                     hardStopPresentedFingerprint: server.fingerprint))

        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        let stored = try store.load()
        XCTAssertNil(stored?.hardStopPresentedFingerprint,
                     "a successful pair(...) must clear the hard-stop marker")

        // A later relaunch-equivalent start now connects normally instead of
        // re-entering .hardStop.
        let coordinator2 = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator2.shutdown() }
        coordinator2.startIfPaired()
        waitForState(coordinator2, description: "idle after re-pair clears hard stop") { $0 == .idle }
    }

    // MARK: - Task 13 review, item 2: stale-attempt guarding

    /// A `ControlClientDelegate` callback whose `client` argument is not the
    /// coordinator's current client must be a complete no-op. This stands in,
    /// deterministically, for the race the review flagged: a completion or
    /// delegate callback resolving after `teardownConnection()` has already
    /// moved the coordinator on to a different (or no) attempt. No real
    /// network race is needed to exercise this — the coordinator's own public
    /// `ControlClientDelegate` conformance is called directly with a
    /// `ControlClient` it never adopted, standing in for a stale completion.
    ///
    /// `coordinator.state` (and the other `queue.sync`-backed accessors) is
    /// read immediately after, which — because the coordinator's internal
    /// queue is serial and FIFO — cannot return until every `queue.async`
    /// block already enqueued by the calls above (including a would-be state
    /// mutation) has finished. That makes the assertions below deterministic,
    /// not a hope that the guard "usually" wins.
    func testStaleDelegateCallbackIsIgnored() throws {
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        var observedStates: [AgentState] = []
        coordinator.onStateChange = { observedStates.append($0) }

        // A `ControlClient` the coordinator never adopted.
        let orphanTransport = PinnedTLSTransport()
        let orphanClient = ControlClient(transport: orphanTransport,
                                         token: Data(repeating: 0, count: 32),
                                         clientId: "orphan")

        coordinator.controlClientDidAuthenticate(orphanClient, micPresent: true, deviceLabel: "should be ignored")
        coordinator.controlClient(orphanClient, didReceive: .status(micPresent: true, active: true,
                                                                    deviceLabel: "should be ignored"))
        coordinator.controlClient(orphanClient, didCloseWith: nil)

        // Forces a drain of the coordinator's serial queue before asserting.
        XCTAssertEqual(coordinator.state, .unpaired,
                       "a delegate callback for a client the coordinator never adopted must be a no-op")
        XCTAssertTrue(observedStates.isEmpty, "no state publish should result from a stale delegate callback")
        XCTAssertFalse(coordinator.micPresent)
        XCTAssertEqual(coordinator.deviceLabel, "")
    }

    // MARK: - Abandoning an in-flight pairing

    /// The pairing interlock used to latch permanently. `unpair()` while a
    /// `pair(...)` was still connecting tore the attempt down without clearing
    /// the flag — the connect completion that would have cleared it is dropped
    /// by the generation guard — so every later `pair(...)` returned
    /// `.alreadyPairing` for the lifetime of the process, with no recovery but
    /// quitting.
    ///
    /// The silent acceptor guarantees the first attempt is still mid-handshake
    /// when it is abandoned, so this exercises the abandonment path every run.
    func testUnpairDuringAnInFlightPairingDoesNotLockOutFuturePairings() throws {
        let silent = try SilentTCPListener()
        defer { silent.stop() }
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let abandoned = expectation(description: "the abandoned attempt is resolved, not stranded")
        // Optional, not implicitly unwrapped: a regression here means the
        // completion never fires at all, and this test must then fail rather
        // than trap and take the rest of the bundle with it.
        var outcome: Result<PairingRecord, Error>?
        coordinator.pair(host: "127.0.0.1", port: silent.port, pairingString: server.pairingString) { result in
            outcome = result
            abandoned.fulfill()
        }
        coordinator.unpair()
        wait(for: [abandoned], timeout: 10.0)

        guard case .failure(let error)? = outcome else {
            return XCTFail("an abandoned pairing must fail rather than succeed or strand")
        }
        XCTAssertEqual(error as? PairingError, .cancelled)

        // The interlock is clear: a fresh attempt runs normally instead of
        // bouncing off `.alreadyPairing`.
        let record = try pair(coordinator, with: server)
        XCTAssertEqual(record.certificateFingerprint, server.fingerprint)
        waitForState(coordinator, description: "idle after re-pairing") { $0 == .idle }
    }

    /// The same abandonment through `shutdown()`, which has the same two escape
    /// routes and the same consequence: a completion that never fires.
    func testShutdownResolvesAnInFlightPairing() throws {
        let silent = try SilentTCPListener()
        defer { silent.stop() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")

        let abandoned = expectation(description: "pairing resolved by shutdown")
        var outcome: Result<PairingRecord, Error>?
        coordinator.pair(host: "127.0.0.1",
                         port: silent.port,
                         pairingString: PairingString.encode(token: Data(repeating: 0x11, count: 32))) { result in
            outcome = result
            abandoned.fulfill()
        }

        let finished = expectation(description: "shutdown completed")
        coordinator.shutdown { finished.fulfill() }
        wait(for: [abandoned, finished], timeout: 10.0)

        guard case .failure(let error)? = outcome else {
            return XCTFail("an abandoned pairing must fail rather than succeed or strand")
        }
        XCTAssertEqual(error as? PairingError, .cancelled)
    }

    func testUnpairClearsTheStoreAndReturnsToUnpaired() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let coordinator = ConnectionCoordinator(store: store, clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        coordinator.unpair()
        waitForState(coordinator, description: "unpaired") { $0 == .unpaired }
        XCTAssertNil(try store.load())
    }

    // MARK: - Phase 4 sleep/wake

    /// The wake forces a full demand rescan (BlackHole UID re-resolve plus
    /// watcher rebuild) even when nothing else happened.
    func testWakeForcesADemandRescan() {
        let fake = demandFake()
        let coordinator = demandCoordinator(fake: fake)
        defer { coordinator.shutdown() }

        waitForObserverReady(fake)
        let before = fake.fullEnumerations
        coordinator.handleWake()
        let rescanned = expectation(description: "rescan after wake")
        func poll() {
            if fake.fullEnumerations > before {
                rescanned.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        poll()
        wait(for: [rescanned], timeout: 10.0)
    }

    /// Stale AudioObjectIDs must never survive a sleep cycle: if the
    /// BlackHole ID changed across the wake, the old ID stops counting and
    /// the new one counts after a single rescan.
    func testWakeDropsAStaleBlackHoleID() {
        let fake = demandFake()
        let coordinator = demandCoordinator(fake: fake)
        defer { coordinator.shutdown() }

        waitForObserverReady(fake)
        setDemand(fake, true)
        waitForPoll(description: "demand on old ID") { coordinator.demandSnapshot.hasDemand }

        // The ID changes while asleep; no listener fires, so the coordinator
        // still believes the stale snapshot until the wake rescan.
        fake.blackHoleID = 104
        XCTAssertTrue(coordinator.demandSnapshot.hasDemand)
        coordinator.handleWake()
        waitForPoll(description: "stale ID dropped") { !coordinator.demandSnapshot.hasDemand }

        // The new ID counts again once a holder appears on it.
        guard let object = fake.procs.first(where: { $0.value.pid == 501 })?.key else {
            return XCTFail("demand fixture process missing")
        }
        fake.procs[object]?.devices = [104]
        fake.fireDevice(object)
        waitForPoll(description: "demand on new ID") { coordinator.demandSnapshot.hasDemand }
    }

    /// A wake while connected schedules nothing: the live connection (or its
    /// already-pending reconnect) owns transport recovery.
    func testWakeWhileConnectedSchedulesNoReconnect() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }
        coordinator.handleWake()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(coordinator.reconnectCountValue, 0)
    }

    /// Wake with demand held across a dead peer: the rescan runs, the
    /// existing backoff reconnects, and the Phase 3 re-auth refire restarts
    /// the session — no new state-machine edges.
    func testWakeWithDemandHeldRecoversTheSession() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let fake = demandFake()
        let coordinator = demandCoordinator(fake: fake, makeRenderer: { RecordingRenderer() })
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }
        setDemand(fake, true)
        waitForStreaming(coordinator)

        coordinator.handleWake()
        server.dropConnections()
        // The drop must land first: without this the wait below matches the
        // still-streaming state and proves nothing.
        waitForState(coordinator, timeout: 30.0, description: "drop noticed") {
            if case .streaming = $0 { return false }
            return true
        }
        waitForState(coordinator, timeout: 30.0, description: "streaming again after wake") {
            if case .streaming = $0 { return true }
            return false
        }
        XCTAssertEqual(coordinator.sessionCountValue, 2)
    }

    private func waitForPoll(description: String,
                             timeout: TimeInterval = 10.0,
                             _ met: @escaping () -> Bool) {
        let done = expectation(description: description)
        func poll() {
            if met() {
                done.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        poll()
        wait(for: [done], timeout: timeout)
    }
}
