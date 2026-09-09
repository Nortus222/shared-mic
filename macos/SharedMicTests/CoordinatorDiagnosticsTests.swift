import XCTest
@testable import SharedMic

/// Phase 4 Task 1: the four coordinator counters the diagnostics view needs
/// beyond Phase 3 (reconnects, auth failures, session durations, latency
/// history) plus the reconcile-by-construction snapshot.
final class CoordinatorDiagnosticsTests: XCTestCase {
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

    private func waitForPoll(_ description: String,
                             timeout: TimeInterval = 20.0,
                             _ met: @escaping () -> Bool) {
        let done = expectation(description: description)
        func poll() {
            if met() {
                done.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { poll() }
            }
        }
        poll()
        wait(for: [done], timeout: timeout)
    }

    private func pair(_ coordinator: ConnectionCoordinator,
                      with server: MockWindowsServerProcess) throws {
        let paired = expectation(description: "paired")
        var outcome: Result<PairingRecord, Error>!
        coordinator.pair(host: "127.0.0.1", port: server.port, pairingString: server.pairingString) { result in
            outcome = result
            paired.fulfill()
        }
        wait(for: [paired], timeout: 30.0)
        guard case .success = outcome! else {
            throw outcome!.failureValue ?? PairingError.cancelled
        }
    }

    private func demandFake() -> FakeCoreAudioQuery {
        let fake = FakeCoreAudioQuery()
        fake.procs = [
            10: FakeCoreAudioQuery.Proc(pid: 501, bundle: "com.example.voice", devices: []),
            11: FakeCoreAudioQuery.Proc(pid: 1000, bundle: "com.sharedmic.SharedMic", devices: [99]),
        ]
        return fake
    }

    private func demandCoordinator(fake: FakeCoreAudioQuery,
                                   recording: RecordingRenderer) -> ConnectionCoordinator {
        ConnectionCoordinator(
            store: InMemoryPairingStore(), clientId: "mac-tests",
            makeRenderer: { recording },
            demandSettings: InMemoryDemandSettingsStore(DemandSettings(stopDebounceMs: 500)),
            makeObserver: { onChange in
                AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
            })
    }

    private func setDemand(_ fake: FakeCoreAudioQuery, _ hasDemand: Bool) {
        guard let object = fake.procs.first(where: { $0.value.pid == 501 })?.key else {
            XCTFail("demand fixture process missing")
            return
        }
        fake.procs[object]?.devices = hasDemand ? [99] : []
        fake.fireDevice(object)
    }

    func testFreshCoordinatorCountsZero() {
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }
        XCTAssertEqual(coordinator.reconnectCountValue, 0)
        XCTAssertEqual(coordinator.authFailureCountValue, 0)
        XCTAssertEqual(coordinator.totalSessionSecondsValue, 0)
        let snapshot = coordinator.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.sessionCount, 0)
        XCTAssertNil(snapshot.activationLatency)
        XCTAssertEqual(snapshot.renderer, RendererCounters())
    }

    /// A wrong token fails exactly as today — and now it counts.
    func testWrongTokenPairingCountsOneAuthFailure() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        let finished = expectation(description: "pairing finished")
        var outcome: Result<PairingRecord, Error>!
        let wrongString = PairingString.encode(token: Data(repeating: 0x5a, count: 32))
        coordinator.pair(host: "127.0.0.1", port: server.port, pairingString: wrongString) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30.0)
        guard case .failure = outcome! else {
            return XCTFail("pairing with the wrong token must fail")
        }
        XCTAssertEqual(coordinator.authFailureCountValue, 1)
    }

    /// Killing the peer fires the existing backoff reconnect — and now it counts.
    func testTransportLossCountsReconnect() throws {
        let server = try MockWindowsServerProcess()
        let coordinator = ConnectionCoordinator(store: InMemoryPairingStore(), clientId: "mac-tests")
        defer { coordinator.shutdown() }

        try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle after pairing") { $0 == .idle }
        XCTAssertEqual(coordinator.reconnectCountValue, 0)

        server.terminate()
        waitForPoll("reconnect attempt fires") { coordinator.reconnectCountValue >= 1 }
    }

    /// One demand-driven session accumulates a positive duration, one latency
    /// sample, and a snapshot that matches the menu-row accessors exactly.
    func testSessionDurationAndSnapshotReconcile() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let fake = demandFake()
        let recording = RecordingRenderer()
        let coordinator = demandCoordinator(fake: fake, recording: recording)
        defer { coordinator.shutdown() }

        try pair(coordinator, with: server)
        waitForState(coordinator, description: "idle") { $0 == .idle }

        setDemand(fake, true)
        waitForState(coordinator, description: "streaming") {
            if case .streaming = $0 { return true }
            return false
        }
        setDemand(fake, false)
        waitForState(coordinator, description: "idle again") { $0 == .idle }

        XCTAssertGreaterThan(coordinator.totalSessionSecondsValue, 0)
        let snapshot = coordinator.diagnosticsSnapshot()
        XCTAssertEqual(snapshot.sessionCount, coordinator.sessionCountValue)
        XCTAssertEqual(snapshot.sessionCount, 1)
        XCTAssertEqual(snapshot.audioBytesReceived, coordinator.audioBytesReceived)
        XCTAssertGreaterThan(snapshot.audioBytesReceived, 0)
        XCTAssertEqual(snapshot.debounceFireCount, coordinator.debounceFireCount)
        XCTAssertEqual(snapshot.activationLatency?.count, 1)
        XCTAssertEqual(snapshot.activationLatency?.latestMs,
                        coordinator.lastActivationLatencyMs)
    }
}

private extension Result {
    var failureValue: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
