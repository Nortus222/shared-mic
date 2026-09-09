import CoreAudio
import XCTest
@testable import SharedMic

/// Owner-gated end-to-end validation for plan Tasks 6 (prefill matrix) and 7
/// (Mac-side validation rows): real HAL output to the installed BlackHole,
/// driven by the mock Windows server over loopback.
///
/// This is what this machine can prove without the real Windows agent:
/// the full render chain starts, consumes real frames with counted
/// underruns, survives minutes of streaming, and never touches the default
/// output device. Wi-Fi-condition cells, the 30-minute soak, Raycast timing,
/// simultaneous capture, and the real-Windows sequence proof stay owner-run.
///
/// Enable: `touch /tmp/sharedmic-audio-validation` (or export
/// `SHAREDMIC_AUDIO_VALIDATION=1` on runners that propagate it — plain
/// `xcodebuild test` scrubs the test host's environment, so the file is the
/// local switch), then run this suite. Without BlackHole installed the tests
/// skip instead of failing.
private final class ValidationDelegate: ControlClientDelegate {
    var onAuthenticate: (() -> Void)?
    var onMessage: ((ControlMessage) -> Void)?
    var onClose: ((Error?) -> Void)?
    var didClose = false

    func controlClientDidAuthenticate(_ client: ControlClient, micPresent: Bool, deviceLabel: String) {
        onAuthenticate?()
    }

    func controlClient(_ client: ControlClient, didReceive message: ControlMessage) {
        onMessage?(message)
    }

    func controlClient(_ client: ControlClient, didCloseWith error: Error?) {
        didClose = true
        onClose?(error)
    }
}

/// Counts enqueues while delegating everything to a real `AudioRenderer`
/// (real HAL unit, real BlackHole). Not thread-safe by itself: the test
/// drives START/STOP synchronously and only reads counts after queue hops.
private final class SpyRenderer: RendererControl {
    let inner: AudioRenderer
    private let lock = NSLock()
    private var _enqueued = 0

    var enqueued: Int {
        lock.lock(); defer { lock.unlock() }
        return _enqueued
    }

    var isOpen: Bool { inner.isOpen }

    init(prefillFrames: Int) {
        inner = AudioRenderer(lister: CoreAudioDeviceLister(),
                              unitFactory: { HALOutputUnit() },
                              prefillFrames: prefillFrames)
    }

    func open() throws { try inner.open() }

    func enqueue(pcm: Data) {
        lock.lock(); _enqueued += 1; lock.unlock()
        inner.enqueue(pcm: pcm)
    }

    func closeAfterDrain() { inner.closeAfterDrain() }
    func finalizeClose() { inner.finalizeClose() }
}

private func liveDefaultOutputUID() -> String? {
    var deviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioObjectID(0)
    var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &deviceAddress, 0, nil, &deviceSize, &deviceID) == noErr else {
        return nil
    }
    var uidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var uid: CFString?
    var uidSize = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else {
        return nil
    }
    return uid as String?
}

final class AudioValidationTests: XCTestCase {

    /// Gate + live BlackHole resolution. Returns the resolved device ID so
    /// the run log records which device actually rendered.
    private var validationEnabled: Bool {
        if ProcessInfo.processInfo.environment["SHAREDMIC_AUDIO_VALIDATION"] == "1" { return true }
        return FileManager.default.fileExists(atPath: "/tmp/sharedmic-audio-validation")
    }

    private func requireValidation() throws -> AudioObjectID {
        try XCTSkipUnless(validationEnabled,
                          "owner-gated: touch /tmp/sharedmic-audio-validation, then re-run this suite")
        do {
            let deviceID = try BlackHoleDevice.resolve(with: CoreAudioDeviceLister())
            print("VALIDATION BlackHole deviceID=\(deviceID)")
            return deviceID
        } catch {
            throw XCTSkip("BlackHole 2ch is not installed on this Mac")
        }
    }

    private func makeLiveClient(spy: SpyRenderer,
                                delegate: ValidationDelegate) throws -> (ControlClient, MockWindowsServerProcess) {
        let server = try MockWindowsServerProcess()
        let transport = PinnedTLSTransport()
        let connected = expectation(description: "tls connected")
        transport.connect(host: "127.0.0.1", port: server.port,
                          mode: .pinned(fingerprint: server.fingerprint)) { result in
            if case .failure(let error) = result { XCTFail("handshake failed: \(error)") }
            connected.fulfill()
        }
        wait(for: [connected], timeout: 15.0)

        let client = ControlClient(transport: transport, token: server.token, clientId: "mac-validation")
        client.delegate = delegate
        let rendererQueue = DispatchQueue(label: "validation.renderer")
        client.audioSink = { pcm in rendererQueue.async { spy.enqueue(pcm: pcm) } }
        let authenticated = expectation(description: "authenticated")
        delegate.onAuthenticate = { authenticated.fulfill() }
        client.begin()
        wait(for: [authenticated], timeout: 15.0)
        return (client, server)
    }

    private func startSession(_ client: ControlClient,
                              delegate: ValidationDelegate,
                              requestId: String) throws -> String {
        var sessionId = ""
        let started = expectation(description: "START_ACK \(requestId)")
        delegate.onMessage = { message in
            if case .startAck(_, let id, _) = message {
                sessionId = id
                started.fulfill()
            }
        }
        client.send(.start(requestId: requestId, preferredFormat: .v1))
        wait(for: [started], timeout: 10.0)
        return sessionId
    }

    private func stopSession(_ client: ControlClient,
                             delegate: ValidationDelegate,
                             requestId: String,
                             sessionId: String) {
        let stopped = expectation(description: "STOP_ACK \(requestId)")
        delegate.onMessage = { message in
            if case .stopAck = message { stopped.fulfill() }
        }
        client.send(.stop(requestId: requestId, sessionId: sessionId))
        wait(for: [stopped], timeout: 10.0)
    }

    private func sleepSeconds(_ seconds: TimeInterval, description: String) {
        let done = expectation(description: description)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 10.0)
    }

    /// Task 4 step 4 / Task 7 smoke: sine frames from the mock render through
    /// a real HAL unit into BlackHole, and the default output device is
    /// byte-identical before and after.
    func testRendersSineToBlackHoleThroughHAL() throws {
        let blackHoleID = try requireValidation()
        let defaultBefore = liveDefaultOutputUID()
        print("VALIDATION defaultOutputBefore=\(defaultBefore ?? "unknown")")

        let spy = SpyRenderer(prefillFrames: 3)
        let delegate = ValidationDelegate()
        let (client, server) = try makeLiveClient(spy: spy, delegate: delegate)
        defer { server.terminate() }
        defer { client.stop() }

        try spy.open()
        XCTAssertEqual(spy.inner.startedUnit, false, "prefill gates the start")
        let sessionId = try startSession(client, delegate: delegate, requestId: "val-1")
        sleepSeconds(3.0, description: "render sine")
        XCTAssertTrue(spy.inner.startedUnit, "prefill reached: the HAL unit started")
        XCTAssertGreaterThan(spy.enqueued, 100, "expected ~150 frames in 3 s of loopback sine")
        print("VALIDATION smoke enqueued=\(spy.enqueued) underruns=\(spy.inner.underrunSamples) " +
              "depthMs=\(spy.inner.depthMs) blackHoleID=\(blackHoleID)")
        stopSession(client, delegate: delegate, requestId: "val-2", sessionId: sessionId)
        spy.finalizeClose()

        XCTAssertEqual(liveDefaultOutputUID(), defaultBefore, "the default output device must not move")
    }

    /// Task 6, quiet-loopback column: prefill {40, 60, 120} ms × 5 reps,
    /// reporting START-to-first-playable latency and first-2-s underruns.
    /// Measurement only — the figure stays at 60 ms until the Wi-Fi cells
    /// land.
    func testPrefillMatrixQuietLoopback() throws {
        _ = try requireValidation()

        let delegate = ValidationDelegate()
        let rendererQueue = DispatchQueue(label: "validation.matrix")
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }

        let transport = PinnedTLSTransport()
        let connected = expectation(description: "tls connected")
        transport.connect(host: "127.0.0.1", port: server.port,
                          mode: .pinned(fingerprint: server.fingerprint)) { _ in connected.fulfill() }
        wait(for: [connected], timeout: 15.0)
        let client = ControlClient(transport: transport, token: server.token, clientId: "mac-validation")
        client.delegate = delegate
        let authenticated = expectation(description: "authenticated")
        delegate.onAuthenticate = { authenticated.fulfill() }
        client.begin()
        wait(for: [authenticated], timeout: 15.0)
        defer { client.stop() }

        for prefillFrames in [2, 3, 6] {
            for rep in 1...5 {
                let spy = SpyRenderer(prefillFrames: prefillFrames)
                client.audioSink = { pcm in rendererQueue.async { spy.enqueue(pcm: pcm) } }
                try spy.open()
                let sendTime = Date()
                let sessionId = try startSession(client, delegate: delegate,
                                                 requestId: "mx-\(prefillFrames)-\(rep)")
                var startLatencyMs: Double = -1
                let deadline = Date().addingTimeInterval(5.0)
                while !spy.inner.startedUnit && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if spy.inner.startedUnit {
                    startLatencyMs = Date().timeIntervalSince(sendTime) * 1_000.0
                }
                XCTAssertGreaterThan(startLatencyMs, 0, "prefill \(prefillFrames): unit never started")
                sleepSeconds(2.0, description: "matrix stream")
                let flushed = expectation(description: "renderer queue drained")
                rendererQueue.async { flushed.fulfill() }
                wait(for: [flushed], timeout: 5.0)
                stopSession(client, delegate: delegate,
                            requestId: "mx-stop-\(prefillFrames)-\(rep)", sessionId: sessionId)
                spy.finalizeClose()
                print(String(format: "VALIDATION prefill=%dms rep=%d startLatencyMs=%.0f underruns2s=%d enqueued=%d",
                             prefillFrames * 20, rep, startLatencyMs,
                             spy.inner.underrunSamples, spy.enqueued))
            }
        }
    }

    /// Task 7 soak, short edition: 3 minutes of continuous rendering with a
    /// depth trace. Proves the tick/dwell/counter machinery end to end; the
    /// 30-minute verdict stays owner-run.
    func testShortDriftSoak() throws {
        _ = try requireValidation()

        let spy = SpyRenderer(prefillFrames: 3)
        let delegate = ValidationDelegate()
        let (client, server) = try makeLiveClient(spy: spy, delegate: delegate)
        defer { server.terminate() }
        defer { client.stop() }

        try spy.open()
        let sessionId = try startSession(client, delegate: delegate, requestId: "soak-1")
        var trace: [String] = []
        for sample in 0..<36 {
            sleepSeconds(5.0, description: "soak sample \(sample)")
            trace.append(String(format: "%.0f", spy.inner.depthMs))
            if delegate.didClose { break }
        }
        stopSession(client, delegate: delegate, requestId: "soak-2", sessionId: sessionId)
        spy.finalizeClose()
        print("VALIDATION soak enqueued=\(spy.enqueued) underruns=\(spy.inner.underrunSamples) " +
              "driftDrops=\(spy.inner.driftDropsApplied) driftInserts=\(spy.inner.driftInsertsApplied)")
        print("VALIDATION depthTraceMs=[\(trace.joined(separator: " "))]")
        XCTAssertFalse(delegate.didClose, "the session must survive 3 minutes of loopback streaming")
        XCTAssertGreaterThan(spy.enqueued, 8000, "expected ~9000 frames in 3 minutes")
    }
}
