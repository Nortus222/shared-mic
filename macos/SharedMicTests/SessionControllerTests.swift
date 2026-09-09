import XCTest
@testable import SharedMic

final class SessionControllerTests: XCTestCase {

    /// Drives a controller to an authenticated, mic-present idle state.
    private func authenticatedController() -> SessionController {
        var controller = SessionController()
        _ = controller.handle(.paired)
        _ = controller.handle(.connectAttemptStarted)
        _ = controller.handle(.authenticated(micPresent: true, deviceLabel: "USB Microphone"))
        return controller
    }

    func testStartsUnpaired() {
        let controller = SessionController()
        XCTAssertEqual(controller.state, .unpaired)
        XCTAssertNil(controller.activeSessionId)
    }

    func testPairingMovesToDisconnected() {
        var controller = SessionController()
        XCTAssertEqual(controller.handle(.paired), [])
        XCTAssertEqual(controller.state, .disconnected)
    }

    func testAuthenticationMovesToIdleAndRecordsMicState() {
        var controller = authenticatedController()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.micPresent)
        XCTAssertEqual(controller.deviceLabel, "USB Microphone")
        _ = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        XCTAssertFalse(controller.micPresent)
    }

    func testStartSendsStartAndArmsTheTwoSecondTimeout() {
        var controller = authenticatedController()
        let actions = controller.handle(.userRequestedStart(requestId: "req-1"))
        XCTAssertEqual(actions, [
            .sendStart(requestId: "req-1"),
            .armStartTimeout(requestId: "req-1", seconds: 2.0),
            .openRenderer
        ])
        XCTAssertEqual(controller.state, .starting(requestId: "req-1"))
    }

    func testStartAckMovesToStreamingAndExposesTheSessionId() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        XCTAssertEqual(controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1")),
                       [.cancelStartTimeout(requestId: "req-1")])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
        XCTAssertEqual(controller.activeSessionId, "sess-1")
    }

    func testDuplicateStartWhileStreamingIsANoOp() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        XCTAssertEqual(controller.handle(.userRequestedStart(requestId: "req-2")), [])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
    }

    func testStartWhileMicAbsentIsRefusedLocally() {
        var controller = authenticatedController()
        _ = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        let actions = controller.handle(.userRequestedStart(requestId: "req-1"))
        XCTAssertEqual(actions, [.notify("The Windows microphone is unavailable.")])
        XCTAssertEqual(controller.state, .idle)
    }

    func testStartNackReturnsToIdleWithTheReason() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        let actions = controller.handle(.startNacked(requestId: "req-1", reason: "MIC_UNAVAILABLE"))
        XCTAssertEqual(actions, [
            .cancelStartTimeout(requestId: "req-1"),
            .notify("Start refused: MIC_UNAVAILABLE"),
            .closeRenderer
        ])
        XCTAssertEqual(controller.state, .idle)
    }

    /// protocol-v1 §8: a START that goes unanswered for 2 s means a failed or dead
    /// peer — not something to keep waiting on.
    func testStartTimeoutTearsDownAndReconnects() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        let actions = controller.handle(.startTimedOut(requestId: "req-1"))
        XCTAssertEqual(actions, [.closeConnection, .scheduleReconnect, .closeRenderer])
        XCTAssertEqual(controller.state, .degraded(reason: "The Windows agent did not answer START within 2 s."))
    }

    func testStaleStartTimeoutIsIgnored() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        XCTAssertEqual(controller.handle(.startTimedOut(requestId: "req-1")), [])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
    }

    func testStopSendsStopWithTheActiveSessionIdAndArmsTheOneSecondTimeout() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        let actions = controller.handle(.userRequestedStop(requestId: "req-2"))
        XCTAssertEqual(actions, [
            .sendStop(requestId: "req-2", sessionId: "sess-1"),
            .armStopTimeout(requestId: "req-2", seconds: 1.0),
            .closeRendererAfterDrain
        ])
        XCTAssertEqual(controller.state, .stopping(requestId: "req-2", sessionId: "sess-1"))
    }

    /// protocol-v1 §7: a STOP with no session active still succeeds, and its
    /// sessionId MAY be an empty string.
    func testStopWhileIdleSendsStopWithAnEmptySessionId() {
        var controller = authenticatedController()
        let actions = controller.handle(.userRequestedStop(requestId: "req-9"))
        XCTAssertEqual(actions, [
            .sendStop(requestId: "req-9", sessionId: ""),
            .armStopTimeout(requestId: "req-9", seconds: 1.0),
            .closeRendererAfterDrain
        ])
        XCTAssertEqual(controller.state, .stopping(requestId: "req-9", sessionId: ""))
    }

    func testStopAckReturnsToIdleAndClearsTheSession() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        _ = controller.handle(.userRequestedStop(requestId: "req-2"))
        XCTAssertEqual(controller.handle(.stopAcked(requestId: "req-2")),
                       [.cancelStopTimeout(requestId: "req-2"), .closeRenderer])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeSessionId)
    }

    // MARK: - Acks that answer some other request

    /// The coordinator used to cancel the START timeout the moment a START_ACK
    /// arrived, before this controller had decided whether the ack answered the
    /// request actually in flight. A non-conformant peer could therefore disarm
    /// the timeout with a stale `requestId` and park the agent in `.starting`
    /// forever. The cancel is now an action, emitted only from the matching
    /// branch — so a mismatch must produce no action at all, leaving the timeout
    /// armed as the way out.
    func testMismatchedStartAckLeavesTheStartTimeoutArmed() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))

        XCTAssertEqual(controller.handle(.startAcked(requestId: "req-2", sessionId: "sess-1")), [],
                       "an ack for another request must not cancel this request's timeout")
        XCTAssertEqual(controller.state, .starting(requestId: "req-1"))

        // The armed timeout is still the way out.
        XCTAssertEqual(controller.handle(.startTimedOut(requestId: "req-1")),
                       [.closeConnection, .scheduleReconnect, .closeRenderer])
    }

    func testMismatchedStartNackLeavesTheStartTimeoutArmed() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))

        XCTAssertEqual(controller.handle(.startNacked(requestId: "req-2", reason: "MIC_UNAVAILABLE")), [])
        XCTAssertEqual(controller.state, .starting(requestId: "req-1"))
        XCTAssertEqual(controller.handle(.startTimedOut(requestId: "req-1")),
                       [.closeConnection, .scheduleReconnect, .closeRenderer])
    }

    func testMismatchedStopAckLeavesTheStopTimeoutArmed() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        _ = controller.handle(.userRequestedStop(requestId: "req-2"))

        XCTAssertEqual(controller.handle(.stopAcked(requestId: "req-3")), [])
        XCTAssertEqual(controller.state, .stopping(requestId: "req-2", sessionId: "sess-1"))
        XCTAssertEqual(controller.handle(.stopTimedOut(requestId: "req-2")),
                       [.notify("STOP went unanswered; the session is treated as ended."),
                        .closeRenderer])
    }

    /// protocol-v1 §8: treat the session as ended locally regardless; do not block
    /// on a STOP_ACK that may never arrive.
    func testStopTimeoutEndsTheSessionLocallyWithoutTearingDownTheConnection() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        _ = controller.handle(.userRequestedStop(requestId: "req-2"))
        let actions = controller.handle(.stopTimedOut(requestId: "req-2"))
        XCTAssertEqual(actions, [.notify("STOP went unanswered; the session is treated as ended."),
                                   .closeRenderer])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.activeSessionId)
    }

    func testMicUnplugMidSessionEntersDegradedAndNotifies() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        let actions = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        XCTAssertEqual(actions, [.notify("The Windows microphone was disconnected."),
                                   .closeRenderer])
        XCTAssertEqual(controller.state, .degraded(reason: "The Windows microphone was disconnected."))
        XCTAssertNil(controller.activeSessionId)
    }

    func testMicUnplugWhileIdleStaysConnectedAndSilent() {
        var controller = authenticatedController()
        let actions = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.micPresent)
    }

    func testMicReplugRecoversFromDegraded() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        _ = controller.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "USB Microphone"))
        let actions = controller.handle(.statusReceived(micPresent: true, active: false, deviceLabel: "USB Microphone"))
        XCTAssertEqual(actions, [])
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.micPresent)
    }

    func testConnectionLossSchedulesAReconnectAndDropsTheSession() {
        var controller = authenticatedController()
        _ = controller.handle(.userRequestedStart(requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        let actions = controller.handle(.connectionLost(reason: "peer dead"))
        XCTAssertEqual(actions, [.scheduleReconnect])
        XCTAssertEqual(controller.state, .disconnected)
        XCTAssertNil(controller.activeSessionId)
    }

    /// The load-bearing test of this whole phase: protocol-v1 §2 and design spec
    /// §7.3 forbid any automatic recovery from a pinned-fingerprint mismatch.
    func testFingerprintMismatchIsATerminalHardStopWithNoReconnect() {
        var controller = authenticatedController()
        let actions = controller.handle(.fingerprintMismatch(expected: "aa", presented: "bb"))
        XCTAssertEqual(actions, [
            .closeConnection,
            .warnFingerprintMismatch(expected: "aa", presented: "bb")
        ])
        XCTAssertFalse(actions.contains(.scheduleReconnect))
        XCTAssertEqual(controller.state, .hardStop(reason: "The Windows agent presented a different certificate than the one paired. Re-pair explicitly to continue."))
    }

    func testHardStopSwallowsEveryEventExceptAnExplicitRePair() {
        var controller = authenticatedController()
        _ = controller.handle(.fingerprintMismatch(expected: "aa", presented: "bb"))
        let hardStop = controller.state

        for event: SessionEvent in [
            .connectAttemptStarted,
            .connectionLost(reason: "whatever"),
            .userRequestedStart(requestId: "req-1"),
            .userRequestedStop(requestId: "req-2"),
            .statusReceived(micPresent: true, active: false, deviceLabel: "USB Microphone"),
            .authenticated(micPresent: true, deviceLabel: "USB Microphone")
        ] {
            XCTAssertEqual(controller.handle(event), [], "hard stop leaked an action for \(event)")
            XCTAssertEqual(controller.state, hardStop, "hard stop left the terminal state for \(event)")
        }

        XCTAssertEqual(controller.handle(.paired), [])
        XCTAssertEqual(controller.state, .disconnected)
    }

    func testUnpairingClosesTheConnection() {
        var controller = authenticatedController()
        XCTAssertEqual(controller.handle(.unpairedByUser), [.closeConnection])
        XCTAssertEqual(controller.state, .unpaired)
    }

    /// The hard stop's second sanctioned escape: an explicit unpair, exercised
    /// from `.hardStop` itself (not from `.idle`, which `testUnpairingClosesTheConnection`
    /// already covers) — distinct from the `.paired` re-pair path covered by
    /// `testHardStopSwallowsEveryEventExceptAnExplicitRePair`.
    func testUnpairingFromHardStopClosesTheConnectionAndClearsTheHardStop() {
        var controller = authenticatedController()
        _ = controller.handle(.fingerprintMismatch(expected: "aa", presented: "bb"))
        XCTAssertEqual(controller.state, .hardStop(reason: "The Windows agent presented a different certificate than the one paired. Re-pair explicitly to continue."))

        XCTAssertEqual(controller.handle(.unpairedByUser), [.closeConnection])
        XCTAssertEqual(controller.state, .unpaired)
    }

    func testDisplayNamesCoverTheObservabilityStates() {
        XCTAssertEqual(AgentState.disconnected.displayName, "Disconnected")
        XCTAssertEqual(AgentState.idle.displayName, "Idle")
        XCTAssertEqual(AgentState.starting(requestId: "r").displayName, "Starting")
        XCTAssertEqual(AgentState.streaming(sessionId: "s").displayName, "Streaming")
        XCTAssertEqual(AgentState.degraded(reason: "x").displayName, "Degraded")
    }
}
