import XCTest
@testable import SharedMic

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

    /// Temporary Phase 1 scaffolding: the manual Start/Stop that Phase 3's demand
    /// detection replaces.
    func testManualStartAndStopDriveASession() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        _ = try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        coordinator.requestStart()
        waitForState(coordinator, description: "streaming") { state in
            if case .streaming = state { return true }
            return false
        }
        XCTAssertGreaterThan(coordinator.audioBytesReceived, 0)

        coordinator.requestStop()
        waitForState(coordinator, description: "idle again") { $0 == .idle }
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
}
