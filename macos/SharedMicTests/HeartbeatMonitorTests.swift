import XCTest
@testable import SharedMic

final class HeartbeatMonitorTests: XCTestCase {
    func testPingSequenceStartsAtOneAndIncrements() {
        var monitor = HeartbeatMonitor(now: 0)
        XCTAssertEqual(monitor.makePing(now: 0), .ping(seq: 1))
        XCTAssertEqual(monitor.makePing(now: 15), .ping(seq: 2))
        XCTAssertEqual(monitor.makePing(now: 30), .ping(seq: 3))
    }

    func testMatchingPongClearsTheOutstandingPing() throws {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        XCTAssertEqual(monitor.outstandingCount, 1)
        try monitor.handlePong(seq: 1, now: 15.2)
        XCTAssertEqual(monitor.outstandingCount, 0)
        XCTAssertEqual(monitor.lastPongAt, 15.2)
    }

    /// protocol-v1 §5: a PONG's seq MUST equal the seq of the PING it answers.
    func testUnknownPongSequenceIsAProtocolViolation() {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        XCTAssertThrowsError(try monitor.handlePong(seq: 99, now: 15.1)) { error in
            XCTAssertEqual(error as? HeartbeatError, .unexpectedPongSequence(99))
        }
    }

    func testDuplicatePongIsAlsoRejected() throws {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        try monitor.handlePong(seq: 1, now: 15.1)
        XCTAssertThrowsError(try monitor.handlePong(seq: 1, now: 15.2)) { error in
            XCTAssertEqual(error as? HeartbeatError, .unexpectedPongSequence(1))
        }
    }

    func testALatePongClearsEveryOlderOutstandingPing() throws {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        _ = monitor.makePing(now: 30)
        _ = monitor.makePing(now: 45)
        XCTAssertEqual(monitor.outstandingCount, 3)
        try monitor.handlePong(seq: 3, now: 45.1)
        XCTAssertEqual(monitor.outstandingCount, 0)
    }

    func testShouldSendPingEveryFifteenSeconds() {
        var monitor = HeartbeatMonitor(now: 0)
        XCTAssertFalse(monitor.shouldSendPing(now: 14.9, interval: SharedMicProtocol.pingInterval))
        XCTAssertTrue(monitor.shouldSendPing(now: 15.0, interval: SharedMicProtocol.pingInterval))
        _ = monitor.makePing(now: 15.0)
        XCTAssertFalse(monitor.shouldSendPing(now: 29.9, interval: SharedMicProtocol.pingInterval))
        XCTAssertTrue(monitor.shouldSendPing(now: 30.0, interval: SharedMicProtocol.pingInterval))
    }

    func testPeerIsDeclaredDeadAfterFortyFiveSecondsWithoutAPong() throws {
        var monitor = HeartbeatMonitor(now: 0)
        XCTAssertFalse(monitor.isPeerDead(now: 44.9, timeout: SharedMicProtocol.peerDeadTimeout))
        XCTAssertTrue(monitor.isPeerDead(now: 45.0, timeout: SharedMicProtocol.peerDeadTimeout))

        _ = monitor.makePing(now: 15)
        try monitor.handlePong(seq: 1, now: 15.1)
        XCTAssertFalse(monitor.isPeerDead(now: 60.0, timeout: SharedMicProtocol.peerDeadTimeout))
        XCTAssertTrue(monitor.isPeerDead(now: 60.2, timeout: SharedMicProtocol.peerDeadTimeout))
    }

    func testThreeMissedHeartbeatsIsExactlyWhatFortyFiveSecondsMeans() {
        var monitor = HeartbeatMonitor(now: 0)
        _ = monitor.makePing(now: 15)
        _ = monitor.makePing(now: 30)
        _ = monitor.makePing(now: 45)
        XCTAssertEqual(monitor.outstandingCount, 3)
        XCTAssertTrue(monitor.isPeerDead(now: 45.0, timeout: SharedMicProtocol.peerDeadTimeout))
    }
}
