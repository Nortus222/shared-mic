import Foundation
import XCTest
@testable import SharedMic

/// Headless Phase 3 measurements (plan Task 6).
///
/// Hermetic by default: demand comes from scriptable sources and audio from
/// the Python mock, so plain `xcodebuild test` needs no hardware, no Windows
/// host, and no human. Two env knobs escalate toward reality:
///
/// - `SHAREDMIC_MEASURE_HOST` / `SHAREDMIC_MEASURE_PORT` /
///   `SHAREDMIC_MEASURE_PAIRING`, or `/tmp/sharedmic-measure.json` with the
///   same keys (lowercase): pair with the real Windows agent instead of
///   the mock. Numbers from such a run are end-to-end; mock runs are labeled
///   Mac-side-only in the report.
/// - `SHAREDMIC_MEASURE_ROUNDS`: activation-loop repetitions (default 5 for
///   suite speed; 100 for the §9 verdict).
///
/// The live-observer latency leg spawns `probes/macos-measure/DemandDriver`
/// (compiled with swiftc on first use; skipped with a message when the
/// toolchain is absent). It asserts on the driver's PID specifically, so
/// stray demand from other processes on the machine cannot flake it.
final class MeasurementTests: XCTestCase {

    // MARK: - configuration

    private struct RealHost {
        let host: String
        let port: UInt16
        let pairing: String
    }

    /// Measurement config: env first, then an ephemeral JSON file. The file
    /// path exists because `xcodebuild test` does not propagate the parent
    /// shell's environment to the test host in this setup (verified
    /// empirically: a bogus-host probe still ran against the mock). The file
    /// carries a bearer pairing secret, so it lives in /tmp, is never
    /// committed, and should be deleted after the run:
    /// `{"host":"192.168.x.x","port":47800,"pairing":"...","rounds":100}`.
    private struct FileConfig: Decodable {
        var host: String?
        var port: UInt16?
        var pairing: String?
        var rounds: Int?
    }

    private func fileConfig() -> FileConfig? {
        let url = URL(fileURLWithPath: "/tmp/sharedmic-measure.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FileConfig.self, from: data) else { return nil }
        return decoded
    }

    private func realHost() -> RealHost? {
        let env = ProcessInfo.processInfo.environment
        if let host = env["SHAREDMIC_MEASURE_HOST"],
           let portString = env["SHAREDMIC_MEASURE_PORT"],
           let port = UInt16(portString),
           let pairing = env["SHAREDMIC_MEASURE_PAIRING"] {
            return RealHost(host: host, port: port, pairing: pairing)
        }
        if let file = fileConfig(),
           let host = file.host, let port = file.port, let pairing = file.pairing {
            return RealHost(host: host, port: port, pairing: pairing)
        }
        return nil
    }

    private func rounds() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["SHAREDMIC_MEASURE_ROUNDS"], let value = Int(raw), value > 0 { return value }
        if let file = fileConfig(), let value = file.rounds, value > 0 { return value }
        return 5
    }

    // MARK: - small waits

    private func waitFor(_ description: String,
                         timeout: TimeInterval = 30.0,
                         _ condition: @escaping () -> Bool) {
        let met = expectation(description: description)
        func poll() {
            if condition() {
                met.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { poll() }
            }
        }
        poll()
        wait(for: [met], timeout: timeout)
    }

    private func waitForState(_ coordinator: ConnectionCoordinator,
                              timeout: TimeInterval = 30.0,
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

    // MARK: - fake-demand coordinator (hermetic session legs)

    private func measureCoordinator() -> (ConnectionCoordinator, FakeCoreAudioQuery, RecordingRenderer) {
        let fake = FakeCoreAudioQuery()
        fake.procs = [
            10: FakeCoreAudioQuery.Proc(pid: 501, bundle: "com.example.voice", devices: []),
            11: FakeCoreAudioQuery.Proc(pid: 1000, bundle: "com.sharedmic.SharedMic", devices: [99]),
        ]
        let recording = RecordingRenderer()
        let coordinator = ConnectionCoordinator(
            store: InMemoryPairingStore(), clientId: "mac-measure",
            makeRenderer: { recording },
            demandSettings: InMemoryDemandSettingsStore(DemandSettings(stopDebounceMs: 500)),
            makeObserver: { onChange in
                AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
            })
        return (coordinator, fake, recording)
    }

    private func waitForObserverReady(_ fake: FakeCoreAudioQuery) {
        waitFor("observer registered listeners", timeout: 10.0) { !fake.deviceBlocks.isEmpty }
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

    private func pairForMeasurement(_ coordinator: ConnectionCoordinator,
                                    server: MockWindowsServerProcess?) {
        if let server {
            let paired = expectation(description: "paired with mock")
            var outcome: Result<PairingRecord, Error>!
            coordinator.pair(host: "127.0.0.1", port: server.port,
                             pairingString: server.pairingString) { result in
                outcome = result
                paired.fulfill()
            }
            wait(for: [paired], timeout: 30.0)
            if case .failure(let error) = outcome! { XCTFail("mock pairing failed: \(error)") }
        } else if let real = realHost() {
            let paired = expectation(description: "paired with Windows agent")
            var outcome: Result<PairingRecord, Error>!
            coordinator.pair(host: real.host, port: real.port,
                             pairingString: real.pairing) { result in
                outcome = result
                paired.fulfill()
            }
            wait(for: [paired], timeout: 60.0)
            if case .failure(let error) = outcome! { XCTFail("Windows pairing failed: \(error)") }
        }
        waitForState(coordinator, description: "idle") { $0 == .idle }
    }

    private func waitForStreaming(_ coordinator: ConnectionCoordinator) {
        waitForState(coordinator, description: "streaming") { state in
            if case .streaming = state { return true }
            return false
        }
    }

    // MARK: - debounce legs

    func testDebounceCancelsOnQuickReturn() throws {
        let server = realHost() == nil ? try MockWindowsServerProcess() : nil
        defer { server?.terminate() }
        let (coordinator, fake, _) = measureCoordinator()
        defer { coordinator.shutdown() }
        pairForMeasurement(coordinator, server: server)

        setDemand(fake, true)
        waitForStreaming(coordinator)
        setDemand(fake, false)
        Thread.sleep(forTimeInterval: 0.2)
        setDemand(fake, true)
        waitForStreaming(coordinator)
        XCTAssertEqual(coordinator.sessionCountValue, 1, "a gap inside the debounce must not start a second session")
        XCTAssertEqual(coordinator.debounceFireCount, 0, "a cancelled debounce must not count as fired")
    }

    func testDebounceFiresAfterAGap() throws {
        let server = realHost() == nil ? try MockWindowsServerProcess() : nil
        defer { server?.terminate() }
        let (coordinator, fake, _) = measureCoordinator()
        defer { coordinator.shutdown() }
        pairForMeasurement(coordinator, server: server)

        setDemand(fake, true)
        waitForStreaming(coordinator)
        setDemand(fake, false)
        waitForState(coordinator, description: "idle after debounce") { $0 == .idle }
        XCTAssertEqual(coordinator.debounceFireCount, 1, "the spec asks whether the debounce fires at all: it did")
        setDemand(fake, true)
        waitForStreaming(coordinator)
        XCTAssertEqual(coordinator.sessionCountValue, 2)
    }

    // MARK: - activation latency distribution (§9 headless proxy)

    func testActivationLatencyDistribution() throws {
        let server = realHost() == nil ? try MockWindowsServerProcess() : nil
        defer { server?.terminate() }
        let (coordinator, fake, recording) = measureCoordinator()
        defer { coordinator.shutdown() }
        pairForMeasurement(coordinator, server: server)

        let total = rounds()
        var samples: [Double] = []
        for _ in 0..<total {
            let framesBefore = recording.enqueuedPCM.count
            setDemand(fake, true)
            waitForStreaming(coordinator)
            waitFor("first frame measured", timeout: 30.0) {
                coordinator.lastActivationLatencyMs != nil
                    && recording.enqueuedPCM.count > framesBefore
            }
            samples.append(coordinator.lastActivationLatencyMs ?? -1)
            setDemand(fake, false)
            waitForState(coordinator, description: "idle") { $0 == .idle }
        }

        let sorted = samples.sorted()
        let p50 = sorted[max(0, Int(Double(sorted.count) * 0.5) - 1)]
        let p95 = sorted[max(0, Int(Double(sorted.count) * 0.95) - 1)]
        let label = realHost() == nil ? "mock (Mac-side only)" : "real Windows agent (end-to-end)"
        print("MEASURE activation_ms [\(label)] n=\(sorted.count) " +
              sorted.map { String(format: "%.1f", $0) }.joined(separator: ","))
        print("MEASURE activation_ms [\(label)] min=\(String(format: "%.1f", sorted.first ?? -1)) " +
              "p50=\(String(format: "%.1f", p50)) p95=\(String(format: "%.1f", p95)) " +
              "max=\(String(format: "%.1f", sorted.last ?? -1)) budget=300")
        XCTAssertGreaterThan(sorted.count, 0)
        XCTAssertTrue(sorted.allSatisfy { $0 >= 0 }, "every round must produce a latency sample")
        if total >= 20 {
            XCTAssertLessThan(p95, 300, "p95 activation latency must fit the 300 ms budget")
        } else {
            XCTAssertLessThan(sorted.last ?? .infinity, 300, "max activation latency must fit the 300 ms budget")
        }
    }

    // MARK: - first-frame onset proxy (no human ears)

    /// The mock restarts its 440 Hz sine at phase 0 on every session, so the
    /// first rendered frames have exactly known content. A clipped onset —
    /// zero-filled or shifted frames — differs hugely; per-sample ±1 LSB
    /// absorbs only cross-language float rounding.
    func testFirstFrameCarriesSessionStart() throws {
        guard realHost() == nil else {
            throw XCTSkip("onset-marker content is a mock property; real-agent onset is covered by the latency distribution")
        }
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let (coordinator, fake, recording) = measureCoordinator()
        defer { coordinator.shutdown() }
        pairForMeasurement(coordinator, server: server)

        setDemand(fake, true)
        waitFor("two frames rendered", timeout: 30.0) { recording.enqueuedPCM.count >= 2 }
        let frames = recording.enqueuedPCM
        XCTAssertEqual(frames[0].count, SharedMicProtocol.audioPCMBytes)
        assertFrame(frames[0], equalsSineFromSample: 0)
        assertFrame(frames[1], equalsSineFromSample: 960)
    }

    private func expectedSineSample(_ globalIndex: Int) -> Int16 {
        Int16((0.5 * 32767.0 * sin(2.0 * .pi * 440.0 * Double(globalIndex) / 48000.0)).rounded(.towardZero))
    }

    private func assertFrame(_ frame: Data, equalsSineFromSample start: Int) {
        XCTAssertEqual(frame.count, 960 * 2)
        var worst: Int = 0
        for i in 0..<960 {
            let raw = frame.withUnsafeBytes { $0.load(fromByteOffset: i * 2, as: Int16.self) }
            let got = Int16(littleEndian: raw)
            let want = expectedSineSample(start + i)
            worst = max(worst, abs(Int(got) - Int(want)))
        }
        XCTAssertLessThanOrEqual(worst, 1, "first rendered frames must carry the session-start sine within rounding")
    }

    // MARK: - live demand-detection latency (real observer + real process)

    func testDemandDetectionLatencyLive() throws {
        let driver = try buildDriver()
        let observer = AudioDemandObserver(query: LiveCoreAudioQuery(), pollInterval: 0.02)
        observer.start()
        defer { observer.stop() }

        let session = try DriverSession(binary: driver, holdMs: 2500)
        session.launch()
        defer { session.waitUntilExit() }
        waitFor("driver OPEN", timeout: 15.0) { session.openMs != nil }
        guard let pid = session.pid, let openMs = session.openMs else {
            XCTFail("driver did not report PID/OPEN")
            return
        }
        var sightedMs: Int64?
        waitFor("observer reports driver pid", timeout: 15.0) {
            if observer.current.processes.contains(where: { $0.pid == pid }) {
                sightedMs = Int64(Date().timeIntervalSince1970 * 1000.0)
                return true
            }
            return false
        }
        if let sighted = sightedMs {
            let latency = sighted - openMs
            print("MEASURE demand_latency_ms open_to_snapshot=\(latency)")
            XCTAssertLessThan(latency, 2000, "demand should surface far inside the debounce window")
        }
        session.waitUntilExit()
        waitFor("observer clears driver pid", timeout: 15.0) {
            !observer.current.processes.contains(where: { $0.pid == pid })
        }
    }

    // MARK: - driver build + launch helpers

    private func buildDriver() throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: "/usr/bin/swiftc") else {
            throw XCTSkip("swiftc unavailable; demand driver cannot be built here")
        }
        let binary = fileManager.temporaryDirectory.appendingPathComponent("DemandDriver")
        let source = RepositoryPaths.root.appendingPathComponent("probes/macos-measure/DemandDriver.swift")
        var needsBuild = true
        if fileManager.fileExists(atPath: binary.path),
           let binDate = try? fileManager.attributesOfItem(atPath: binary.path)[.modificationDate] as? Date,
           let srcDate = try? fileManager.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
           binDate >= srcDate {
            needsBuild = false
        }
        if needsBuild {
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            build.arguments = ["-O", "-o", binary.path, source.path]
            try build.run()
            build.waitUntilExit()
            guard build.terminationStatus == 0,
                  fileManager.isExecutableFile(atPath: binary.path) else {
                throw XCTSkip("demand driver failed to compile")
            }
        }
        return binary
    }

    private final class DriverSession {
        private let lock = NSLock()
        private var _lines: [String] = []
        private var pending = Data()
        let process = Process()
        var pid: Int32?
        var openMs: Int64?

        var lines: [String] {
            lock.lock(); defer { lock.unlock() }
            return _lines
        }

        init(binary: URL, holdMs: Int) throws {
            process.executableURL = binary
            process.arguments = ["--hold-ms", String(holdMs)]
            let pipe = Pipe()
            process.standardOutput = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard let self else { return }
                if data.isEmpty {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    return
                }
                self.lock.lock()
                self.pending.append(data)
                while let range = self.pending.range(of: Data([0x0A])) {
                    let lineData = self.pending.subdata(in: 0..<range.lowerBound)
                    self.pending.removeSubrange(0..<range.upperBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        self._lines.append(line)
                    }
                }
                self.lock.unlock()
                self.parse()
            }
        }

        private func parse() {
            lock.lock()
            let snapshot = _lines
            lock.unlock()
            for line in snapshot {
                let parts = line.split(separator: " ")
                guard parts.count == 2 else { continue }
                if parts[0] == "PID" { pid = Int32(parts[1]) }
                if parts[0] == "OPEN" { openMs = Int64(parts[1]) }
            }
        }

        func launch() { try? process.run() }

        func waitUntilExit() {
            if process.isRunning { process.waitUntilExit() }
        }
    }
}
