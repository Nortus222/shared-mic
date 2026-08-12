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
