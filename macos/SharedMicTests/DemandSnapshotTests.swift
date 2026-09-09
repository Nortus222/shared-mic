import CoreAudio
import XCTest
@testable import SharedMic

final class DemandSnapshotTests: XCTestCase {
    let blackHole: AudioObjectID = 99
    let other: AudioObjectID = 139

    func testEmptyRowsHaveNoDemand() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [], ownPID: 1000)
        XCTAssertFalse(snap.hasDemand)
        XCTAssertTrue(snap.processes.isEmpty)
    }

    func testContainsPredicateCountsMultiDeviceLists() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [
            (pid: 501, bundleID: "com.apple.WebKit.GPU", inputDevices: [other, blackHole])
        ], ownPID: 1000)
        XCTAssertTrue(snap.hasDemand)
        XCTAssertEqual(snap.processes, [DemandingProcess(pid: 501, bundleID: "com.apple.WebKit.GPU")])
    }

    func testOwnPIDIsAlwaysSkipped() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [
            (pid: 1000, bundleID: "com.sharedmic.SharedMic", inputDevices: [blackHole])
        ], ownPID: 1000)
        XCTAssertFalse(snap.hasDemand)
    }

    func testNonBlackHoleDevicesDoNotCount() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [
            (pid: 502, bundleID: "com.apple.WebKit.GPU", inputDevices: [other])
        ], ownPID: 1000)
        XCTAssertFalse(snap.hasDemand)
    }

    func testMixedRowsReportOnlyHolders() {
        let snap = DemandGate.snapshot(blackHoleID: blackHole, rows: [
            (pid: 501, bundleID: "a", inputDevices: [other]),
            (pid: 502, bundleID: "b", inputDevices: [blackHole]),
            (pid: 1000, bundleID: "self", inputDevices: [blackHole])
        ], ownPID: 1000)
        XCTAssertTrue(snap.hasDemand)
        XCTAssertEqual(snap.processes, [DemandingProcess(pid: 502, bundleID: "b")])
    }
}
