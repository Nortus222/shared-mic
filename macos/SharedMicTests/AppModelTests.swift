import XCTest
@testable import SharedMic

@MainActor
final class AppModelTests: XCTestCase {

    private func waitUntil(_ description: String,
                           timeout: TimeInterval = 30.0,
                           _ condition: @escaping () -> Bool) {
        let met = expectation(description: description)
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            if condition() {
                timer?.invalidate()
                met.fulfill()
            }
        }
        wait(for: [met], timeout: timeout)
        timer?.invalidate()
    }

    func testStartsUnpairedWithSensibleDefaults() {
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false)
        XCTAssertEqual(model.state, .unpaired)
        XCTAssertEqual(model.statusText, "Not paired")
        XCTAssertEqual(model.portField, String(SharedMicProtocol.defaultPort))
        XCTAssertNil(model.pairedHost)
        XCTAssertFalse(model.canStart)
        XCTAssertFalse(model.canStop)
    }

    func testPairingFromTheFormReachesIdle() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false)

        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()

        waitUntil("idle after pairing") { model.state == .idle }
        XCTAssertEqual(model.statusText, "Idle")
        XCTAssertEqual(model.deviceLabel, "Mock USB Mic")
        XCTAssertEqual(model.pairedHost, "127.0.0.1")
        XCTAssertTrue(model.canStart)
        XCTAssertFalse(model.canStop)
        XCTAssertFalse(model.isPairing)
        // The pairing string is cleared from the UI once it has been consumed.
        XCTAssertEqual(model.pairingField, "")
    }

    func testAMistypedPairingStringSurfacesANotice() {
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false)
        model.hostField = "127.0.0.1"
        model.portField = String(SharedMicProtocol.defaultPort)
        model.pairingField = "NOPE"
        model.pair()

        waitUntil("notice shown") { model.lastNotice != nil }
        XCTAssertEqual(model.state, .unpaired)
        XCTAssertFalse(model.isPairing)
    }

    /// Temporary Phase 1 scaffolding, exercised here so the manual path is known
    /// to work before it is used for hand testing.
    func testManualStartAndStopFlipTheAffordances() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false)
        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()
        waitUntil("idle") { model.state == .idle }

        model.startSession()
        waitUntil("streaming") {
            if case .streaming = model.state { return true }
            return false
        }
        XCTAssertEqual(model.statusText, "Streaming")
        XCTAssertFalse(model.canStart)
        XCTAssertTrue(model.canStop)

        model.stopSession()
        waitUntil("idle again") { model.state == .idle }
        XCTAssertTrue(model.canStart)
    }

    /// `audioBytesReceived` used to be refreshed only from `onStateChange`, and
    /// the state does not change for the length of a streaming session — so the
    /// menu showed whatever the counter read the instant streaming began ("Zero
    /// KB") for the whole session. "Zero bytes while idle" is this project's
    /// headline invariant; a readout permanently stuck at zero is worse than
    /// none. A 1 Hz refresh timer is what makes it move.
    func testAudioByteReadoutRefreshesDuringASessionWithoutAStateChange() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        // Recording renderer: this drives a live session, which must not
        // open real audio hardware as a test side effect.
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false,
                             makeRenderer: { RecordingRenderer() })
        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()
        waitUntil("idle") { model.state == .idle }
        XCTAssertEqual(model.audioBytesReceived, 0, "an idle session carries no audio")

        model.startSession()
        waitUntil("streaming") {
            if case .streaming = model.state { return true }
            return false
        }

        // Let the session settle, then take a reading. From here nothing else
        // publishes state — the coordinator only publishes on an event, and a
        // quiet streaming session has none (protocol-v1 §8 heartbeats are
        // consumed by `ControlClient`, and the mock sends STATUS only on a mic
        // change) — so nothing but the refresh timer can move this number.
        let settled = expectation(description: "session settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)
        let reading = model.audioBytesReceived

        waitUntil("byte counter advanced without a state event", timeout: 15.0) {
            model.audioBytesReceived > reading
        }

        model.stopSession()
        waitUntil("idle again") { model.state == .idle }
    }

    func testFingerprintMismatchSurfacesAProminentWarning() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        try store.save(PairingRecord(host: "127.0.0.1",
                                     port: server.port,
                                     token: server.token,
                                     certificateFingerprint: String(repeating: "00", count: 32)))
        let model = AppModel(store: store, clientId: "mac-tests", autoStart: true)

        waitUntil("warning surfaced") { model.fingerprintWarning != nil }
        let warning = try XCTUnwrap(model.fingerprintWarning)
        XCTAssertTrue(warning.contains(server.fingerprint), "the presented fingerprint must be shown")
        XCTAssertTrue(warning.contains("re-pair") || warning.contains("Re-pair"))
        XCTAssertEqual(model.statusText, "Certificate mismatch")
        XCTAssertFalse(model.canStart, "a hard stop must not offer to start a session")
    }

    func testUnpairReturnsToTheUnpairedForm() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let model = AppModel(store: store, clientId: "mac-tests", autoStart: false)
        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()
        waitUntil("idle") { model.state == .idle }

        model.unpair()
        waitUntil("unpaired") { model.state == .unpaired }
        XCTAssertNil(model.pairedHost)
        XCTAssertNil(try store.load())
    }
}
