import CoreAudio
import XCTest
@testable import SharedMic

final class FakeCoreAudioQuery: CoreAudioQuery {
    struct Proc { var pid: Int32; var bundle: String; var devices: [AudioObjectID] }

    var ownPID: Int32 = 1000
    var blackHoleID: AudioObjectID? = 99
    var procs: [AudioObjectID: Proc] = [:]
    var unlistenable: Set<AudioObjectID> = []
    var processListListenerOK = true
    var targetedPollCalls: [Int32] = []
    var fullEnumerations = 0
    var processListBlocks: [() -> Void] = []
    var deviceBlocks: [AudioObjectID: () -> Void] = [:]
    var removedDevices: [AudioObjectID] = []

    func resolveBlackHole() -> AudioObjectID? { blackHoleID }
    func processObjectIDs() -> [AudioObjectID] {
        fullEnumerations += 1
        return Array(procs.keys)
    }
    func pid(for object: AudioObjectID) -> Int32? { procs[object]?.pid }
    func bundleID(for object: AudioObjectID) -> String { procs[object]?.bundle ?? "<none>" }
    func inputDeviceIDs(for object: AudioObjectID) -> [AudioObjectID] { procs[object]?.devices ?? [] }
    func processObject(forPID pid: Int32) -> AudioObjectID? {
        targetedPollCalls.append(pid)
        return procs.first(where: { $0.value.pid == pid })?.key
    }
    func addProcessListListener(_ block: @escaping () -> Void) -> Bool {
        guard processListListenerOK else { return false }
        processListBlocks.append(block)
        return true
    }
    func addDeviceListener(processObject: AudioObjectID, block: @escaping () -> Void) -> Bool {
        guard !unlistenable.contains(processObject) else { return false }
        deviceBlocks[processObject] = block
        return true
    }
    func removeDeviceListener(processObject: AudioObjectID) {
        removedDevices.append(processObject)
        deviceBlocks.removeValue(forKey: processObject)
    }
    func removeAllListeners() {
        processListBlocks.removeAll()
        deviceBlocks.removeAll()
    }

    func fireProcessList() { processListBlocks.forEach { $0() } }
    func fireDevice(_ object: AudioObjectID) { deviceBlocks[object]?() }
}

final class AudioDemandObserverTests: XCTestCase {
    let blackHole: AudioObjectID = 99
    let other: AudioObjectID = 139

    private func makeQuery() -> FakeCoreAudioQuery {
        let q = FakeCoreAudioQuery()
        q.procs = [
            10: FakeCoreAudioQuery.Proc(pid: 501, bundle: "com.example.app", devices: []),
            11: FakeCoreAudioQuery.Proc(pid: 1000, bundle: "com.sharedmic.SharedMic", devices: [99]),
        ]
        return q
    }

    private func startObserver(_ q: FakeCoreAudioQuery, poll: TimeInterval = 0.02) -> (AudioDemandObserver, Locked<[DemandSnapshot]>) {
        let seen = Locked<[DemandSnapshot]>([])
        let observer = AudioDemandObserver(query: q, pollInterval: poll, fullRescanInterval: 0.05) { snap in
            seen.withLock { $0.append(snap) }
        }
        observer.start()
        return (observer, seen)
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 2.0, _ check: @escaping () -> Bool) {
        let exp = expectation(description: description)
        let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { t in
            if check() { exp.fulfill(); t.invalidate() }
        }
        wait(for: [exp], timeout: timeout)
        timer.invalidate()
    }

    func testStartsIdleWithOnlySelfHolding() {
        let q = makeQuery()
        let (observer, _) = startObserver(q)
        waitFor("idle") { observer.current == DemandSnapshot() }
        XCTAssertFalse(observer.current.hasDemand)
        observer.stop()
    }

    func testEmitsDemandWhenBlackHoleAppears() {
        let q = makeQuery()
        let (observer, seen) = startObserver(q)
        waitFor("idle") { observer.current == DemandSnapshot() }
        q.procs[10]?.devices = [blackHole]
        q.fireDevice(10)
        waitFor("demand") { observer.current.hasDemand }
        XCTAssertEqual(observer.current.processes, [DemandingProcess(pid: 501, bundleID: "com.example.app")])
        XCTAssertTrue(seen.withLock { $0.last?.hasDemand == true })
        observer.stop()
    }

    func testSkipsOwnPID() {
        let q = makeQuery()
        q.procs[12] = FakeCoreAudioQuery.Proc(pid: 1000, bundle: "com.sharedmic.SharedMic", devices: [blackHole])
        let (observer, _) = startObserver(q)
        waitFor("settled") { q.fullEnumerations >= 1 }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertFalse(observer.current.hasDemand)
        observer.stop()
    }

    func testUnlistenableProcessFallsBackToTargetedPollOnly() {
        let q = makeQuery()
        q.unlistenable = [10]
        let (observer, _) = startObserver(q, poll: 0.02)
        waitFor("idle") { observer.current == DemandSnapshot() }
        let sweepsBefore = q.fullEnumerations
        q.procs[10]?.devices = [blackHole]
        waitFor("demand via fallback") { observer.current.hasDemand }
        XCTAssertEqual(observer.current.processes, [DemandingProcess(pid: 501, bundleID: "com.example.app")])
        XCTAssertTrue(q.targetedPollCalls.contains(501), "fallback must use the targeted TranslatePID path")
        XCTAssertFalse(q.targetedPollCalls.contains(1000), "fallback must poll only the refused process")
        XCTAssertEqual(q.fullEnumerations, sweepsBefore, "fallback must not trigger full sweeps")
        observer.stop()
    }

    func testHandlesMultiDeviceLists() {
        let q = makeQuery()
        q.procs[10]?.devices = [other, blackHole]
        let (observer, _) = startObserver(q)
        waitFor("demand") { observer.current.hasDemand }
        XCTAssertEqual(observer.current.demandCount, 1)
        observer.stop()
    }

    func testReResolvesBlackHoleIDOnDeviceChange() {
        let q = makeQuery()
        q.procs[10]?.devices = [blackHole]
        let (observer, _) = startObserver(q)
        waitFor("demand") { observer.current.hasDemand }
        q.blackHoleID = 104
        q.procs[10]?.devices = [104]
        q.fireProcessList()
        waitFor("re-resolved") { observer.current.processes == [DemandingProcess(pid: 501, bundleID: "com.example.app")] }
        q.procs[10]?.devices = [blackHole]
        q.fireDevice(10)
        waitFor("old ID stops counting") { !observer.current.hasDemand }
        observer.stop()
    }

    func testEmitsOnlyOnChange() {
        let q = makeQuery()
        let (observer, seen) = startObserver(q)
        waitFor("settled") { q.fullEnumerations >= 1 }
        q.fireProcessList()
        q.fireProcessList()
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertEqual(seen.withLock { $0.count }, 0, "identical rescans must not re-emit")
        observer.stop()
    }

    func testRemovesListenersForDepartedProcesses() {
        let q = makeQuery()
        let (observer, _) = startObserver(q)
        waitFor("settled") { q.fullEnumerations >= 1 }
        q.procs.removeValue(forKey: 10)
        q.fireProcessList()
        waitFor("removed") { q.removedDevices.contains(10) }
        observer.stop()
    }
}

private final class Locked<T> {
    private var value: T
    private let lock = NSLock()
    init(_ value: T) { self.value = value }
    func withLock<U>(_ body: (inout T) -> U) -> U {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
