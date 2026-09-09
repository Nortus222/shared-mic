import AppKit
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

    private func makeFake() -> FakeCoreAudioQuery {
        let fake = FakeCoreAudioQuery()
        fake.procs = [
            10: FakeCoreAudioQuery.Proc(pid: 501, bundle: "com.example.voice", devices: []),
            11: FakeCoreAudioQuery.Proc(pid: 1000, bundle: "com.sharedmic.SharedMic", devices: [99]),
        ]
        return fake
    }


    private func quietModel(store: PairingStore = InMemoryPairingStore()) -> AppModel {
        let fake = FakeCoreAudioQuery()
        return AppModel(store: store, clientId: "mac-tests", autoStart: false,
                        demandSettings: InMemoryDemandSettingsStore(),
                        makeObserver: { onChange in
                            AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
                        },
                        readSystemInput: { nil })
    }

    private func demandModel(fake: FakeCoreAudioQuery,
                             settings: DemandSettings = DemandSettings(stopDebounceMs: 500)) -> AppModel {
        AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false,
                 makeRenderer: { RecordingRenderer() },
                 demandSettings: InMemoryDemandSettingsStore(settings),
                 makeObserver: { onChange in
                     AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
                 },
                 readSystemInput: { SystemInputInfo(name: "OWC Thunderbolt 3 Audio Device", uid: "hw-owc-1") })
    }

    private func setDemand(_ fake: FakeCoreAudioQuery, _ hasDemand: Bool) {
        guard let object = fake.procs.first(where: { $0.value.pid == 501 })?.key else { return }
        fake.procs[object]?.devices = hasDemand ? [99] : []
        fake.fireDevice(object)
    }

    private func pair(_ model: AppModel, with server: MockWindowsServerProcess) {
        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()
        waitUntil("idle after pairing") { model.state == .idle }
    }

    func testStartsUnpairedWithSensibleDefaults() {
        let model = quietModel()
        XCTAssertEqual(model.state, .unpaired)
        XCTAssertEqual(model.statusText, "Not paired")
        XCTAssertEqual(model.portField, String(SharedMicProtocol.defaultPort))
        XCTAssertNil(model.pairedHost)
        XCTAssertFalse(model.isDisabled)
        XCTAssertTrue(model.demandProcesses.isEmpty)
        XCTAssertNil(model.holdRemaining)
    }

    func testPairingFromTheFormReachesIdle() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let model = quietModel()

        model.hostField = "127.0.0.1"
        model.portField = String(server.port)
        model.pairingField = server.pairingString
        model.pair()

        waitUntil("idle after pairing") { model.state == .idle }
        XCTAssertEqual(model.statusText, "Idle")
        XCTAssertEqual(model.deviceLabel, "Mock USB Mic")
        XCTAssertEqual(model.pairedHost, "127.0.0.1")
        XCTAssertFalse(model.isDisabled)
        XCTAssertFalse(model.isPairing)
        // The pairing string is cleared from the UI once it has been consumed.
        XCTAssertEqual(model.pairingField, "")
    }

    func testAMistypedPairingStringSurfacesANotice() {
        let model = quietModel()
        model.hostField = "127.0.0.1"
        model.portField = String(SharedMicProtocol.defaultPort)
        model.pairingField = "NOPE"
        model.pair()

        waitUntil("notice shown") { model.lastNotice != nil }
        XCTAssertEqual(model.state, .unpaired)
        XCTAssertFalse(model.isPairing)
    }

    /// Phase 3 replaces the manual path: demand appearing starts a session
    /// with no button press, and demand clearing stops it after the debounce.
    func testDemandDrivesSessionsAutomatically() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let fake = makeFake()
        let model = demandModel(fake: fake)
        pair(model, with: server)

        setDemand(fake, true)
        waitUntil("streaming on demand") {
            if case .streaming = model.state { return true }
            return false
        }
        XCTAssertEqual(model.demandProcesses, [DemandingProcess(pid: 501, bundleID: "com.example.voice")])

        setDemand(fake, false)
        waitUntil("idle after debounce") { model.state == .idle }
        XCTAssertTrue(model.demandProcesses.isEmpty)
    }

    func testDisableSuppressesDemandAndEnableResumes() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let fake = makeFake()
        let model = demandModel(fake: fake)
        pair(model, with: server)

        model.disable()
        waitUntil("disabled") { model.state == .disabled }
        XCTAssertEqual(model.statusText, "Disabled — remote microphone off")

        setDemand(fake, true)
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertEqual(model.state, .disabled, "kill switch must never start on demand")

        model.enable()
        waitUntil("streaming after enable with demand held") {
            if case .streaming = model.state { return true }
            return false
        }
    }

    func testHoldStartsASessionWithNoDemandAndCancellingStopsIt() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let fake = makeFake()
        let model = demandModel(fake: fake)
        pair(model, with: server)

        model.beginHold()
        waitUntil("streaming on hold") {
            if case .streaming = model.state { return true }
            return false
        }
        XCTAssertNotNil(model.holdRemaining)
        XCTAssertNotNil(model.holdDisplay)

        model.cancelHold()
        waitUntil("idle after hold cancelled") { model.state == .idle }
        XCTAssertNil(model.holdDisplay)
    }

    func testDebounceSettingClampsTo500Through2000() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let fake = makeFake()
        let model = demandModel(fake: fake)
        pair(model, with: server)

        model.setStopDebounceMs(50)
        waitUntil("clamped to floor") { model.stopDebounceMs == 500 }
        model.setStopDebounceMs(5000)
        waitUntil("clamped to ceiling") { model.stopDebounceMs == 2000 }
    }

    func testSystemInputFlagSurfacesBlackHoleAsDefault() {
        let blackHoleDefault = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests",
                                        autoStart: false,
                                        demandSettings: InMemoryDemandSettingsStore(),
                                        readSystemInput: { SystemInputInfo(name: "BlackHole 2ch", uid: "BlackHole2ch_UID") })
        waitUntil("input read") { blackHoleDefault.systemInputName != nil }
        XCTAssertTrue(blackHoleDefault.systemInputIsBlackHole)

        let hardwareDefault = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests",
                                       autoStart: false,
                                       demandSettings: InMemoryDemandSettingsStore(),
                                       readSystemInput: { SystemInputInfo(name: "OWC", uid: "hw-owc-1") })
        waitUntil("input read") { hardwareDefault.systemInputName != nil }
        XCTAssertFalse(hardwareDefault.systemInputIsBlackHole)
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
        let fake = makeFake()
        let model = demandModel(fake: fake)
        pair(model, with: server)
        XCTAssertEqual(model.audioBytesReceived, 0, "an idle session carries no audio")

        setDemand(fake, true)
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

        setDemand(fake, false)
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
        let mismatchFake = FakeCoreAudioQuery()
        let model = AppModel(store: store, clientId: "mac-tests", autoStart: true,
                             demandSettings: InMemoryDemandSettingsStore(),
                             makeObserver: { onChange in
                                 AudioDemandObserver(query: mismatchFake, pollInterval: 0.02, onChange: onChange)
                             },
                             readSystemInput: { nil })

        waitUntil("warning surfaced") { model.fingerprintWarning != nil }
        let warning = try XCTUnwrap(model.fingerprintWarning)
        XCTAssertTrue(warning.contains(server.fingerprint), "the presented fingerprint must be shown")
        XCTAssertTrue(warning.contains("re-pair") || warning.contains("Re-pair"))
        XCTAssertEqual(model.statusText, "Certificate mismatch")
        if case .hardStop = model.state {} else {
            XCTFail("expected hard stop, got \(model.state)")
        }
    }

    func testUnpairReturnsToTheUnpairedForm() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let store = InMemoryPairingStore()
        let model = quietModel(store: store)
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

    /// Phase 4 Task 2: the menu's diagnostics snapshot is published from the
    /// same 1 Hz refresh as the menu rows, so the numbers reconcile by
    /// construction rather than by parallel bookkeeping.
    func testDiagnosticsSnapshotReconcilesWithMenuRows() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let fake = makeFake()
        let model = demandModel(fake: fake)
        pair(model, with: server)

        setDemand(fake, true)
        waitUntil("streaming") {
            if case .streaming = model.state { return true }
            return false
        }
        setDemand(fake, false)
        waitUntil("idle again") { model.state == .idle }
        waitUntil("diagnostics catch up") { model.diagnostics.sessionCount == 1 }

        XCTAssertEqual(model.diagnostics.sessionCount, model.sessionCount)
        XCTAssertEqual(model.diagnostics.audioBytesReceived, model.audioBytesReceived)
        XCTAssertEqual(model.diagnostics.debounceFireCount, model.debounceFireCount)
        XCTAssertEqual(model.diagnostics.activationLatency?.count, 1)
    }

    /// Phase 4 Task 3: the 1 Hz refresh surfaces the rendered peak as the
    /// menu meter level.
    func testInputLevelPollSurfacesRendererPeak() {
        let recording = RecordingRenderer()
        recording.stubPeak = 0.5
        let fake = makeFake()
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false,
                             makeRenderer: { recording },
                             demandSettings: InMemoryDemandSettingsStore(),
                             makeObserver: { onChange in
                                 AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
                             },
                             readSystemInput: { nil })
        waitUntil("level poll") { model.inputLevel == 0.5 }
    }

    /// Phase 4 Task 4: the system wake notification reaches the demand
    /// observer as a forced rescan.
    func testWakeNotificationTriggersDemandRescan() {
        let fake = makeFake()
        // Held for the whole test: the wake is delivered to the model.
        let model = AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false,
                             demandSettings: InMemoryDemandSettingsStore(),
                             makeObserver: { onChange in
                                 AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
                             },
                             readSystemInput: { nil })
        _ = model
        waitUntil("observer ready") { !fake.deviceBlocks.isEmpty }
        let before = fake.fullEnumerations
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        waitUntil("rescan after wake") { fake.fullEnumerations > before }
    }

    func testDiagnosticsStartEmpty() {
        let model = quietModel()
        XCTAssertEqual(model.diagnostics.sessionCount, 0)
        XCTAssertNil(model.diagnostics.activationLatency)
        XCTAssertEqual(model.diagnostics.reconnectCount, 0)
        XCTAssertEqual(model.diagnostics.authFailureCount, 0)
    }
}
