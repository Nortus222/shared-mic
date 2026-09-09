import XCTest
@testable import SharedMic

final class SessionDemandTests: XCTestCase {
    private func idleController(micPresent: Bool = true) -> SessionController {
        var controller = SessionController()
        _ = controller.handle(.paired)
        _ = controller.handle(.connectAttemptStarted)
        _ = controller.handle(.authenticated(micPresent: micPresent, deviceLabel: "USB Microphone"))
        return controller
    }

    private func streamingController() -> SessionController {
        var controller = idleController()
        _ = controller.handle(.demandChanged(hasDemand: true, requestId: "req-1"))
        _ = controller.handle(.startAcked(requestId: "req-1", sessionId: "sess-1"))
        return controller
    }

    func testDemandStartsSessionImmediately() {
        var controller = idleController()
        let actions = controller.handle(.demandChanged(hasDemand: true, requestId: "req-1"))
        XCTAssertEqual(actions, [
            .sendStart(requestId: "req-1"),
            .armStartTimeout(requestId: "req-1", seconds: 2.0),
            .openRenderer
        ])
        XCTAssertEqual(controller.state, .starting(requestId: "req-1"))
        XCTAssertTrue(controller.hasDemand)
    }

    func testDemandLossArmsDebounceInsteadOfStopping() {
        var controller = streamingController()
        let actions = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        XCTAssertEqual(actions, [.armStopDebounce(sessionId: "sess-1", seconds: 1.0)])
        XCTAssertEqual(controller.state, .stopPending(sessionId: "sess-1"))
        XCTAssertFalse(controller.hasDemand)
    }

    func testDemandReturnCancelsDebounce() {
        var controller = streamingController()
        _ = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        let actions = controller.handle(.demandChanged(hasDemand: true, requestId: "req-3"))
        XCTAssertEqual(actions, [.cancelStopDebounce])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
    }

    func testDebounceExpirySendsStop() {
        var controller = streamingController()
        _ = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        let actions = controller.handle(.stopDebounceExpired(requestId: "req-3", sessionId: "sess-1"))
        XCTAssertEqual(actions, [
            .sendStop(requestId: "req-3", sessionId: "sess-1"),
            .armStopTimeout(requestId: "req-3", seconds: 1.0),
            .closeRendererAfterDrain
        ])
        XCTAssertEqual(controller.state, .stopping(requestId: "req-3", sessionId: "sess-1"))
    }

    func testStaleDebounceForOldSessionIsIgnored() {
        var controller = streamingController()
        _ = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        XCTAssertEqual(controller.handle(.stopDebounceExpired(requestId: "req-9", sessionId: "sess-old")), [])
        XCTAssertEqual(controller.state, .stopPending(sessionId: "sess-1"))
    }

    func testDebounceIsClampedTo500Through2000ms() {
        var low = SessionController(stopDebounceSeconds: 0.1)
        XCTAssertEqual(low.stopDebounceSeconds, 0.5)
        var high = SessionController(stopDebounceSeconds: 5.0)
        XCTAssertEqual(high.stopDebounceSeconds, 2.0)
        var controller = streamingController()
        controller.setStopDebounceSeconds(0.05)
        XCTAssertEqual(controller.stopDebounceSeconds, 0.5)
        let actions = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        XCTAssertEqual(actions, [.armStopDebounce(sessionId: "sess-1", seconds: 0.5)])
    }

    func testRepeatedDemandLossDoesNotRearm() {
        var controller = streamingController()
        _ = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        XCTAssertEqual(controller.handle(.demandChanged(hasDemand: false, requestId: "req-3")), [])
        XCTAssertEqual(controller.state, .stopPending(sessionId: "sess-1"))
    }

    func testDemandLossWhileStartingAbandonsImmediately() {
        var controller = idleController()
        _ = controller.handle(.demandChanged(hasDemand: true, requestId: "req-1"))
        let actions = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        if case .stopping = controller.state {} else {
            XCTFail("expected stopping, got \(controller.state)")
        }
        XCTAssertTrue(actions.contains(.sendStop(requestId: "req-2", sessionId: "")))
    }

    func testDisableFromStreamingStopsAndLandsDisabled() {
        var controller = streamingController()
        let actions = controller.handle(.userDisabled(requestId: "req-2"))
        XCTAssertTrue(actions.contains(.sendStop(requestId: "req-2", sessionId: "sess-1")))
        _ = controller.handle(.stopAcked(requestId: "req-2"))
        XCTAssertEqual(controller.state, .disabled)
    }

    func testDisableFromIdleLandsDisabledDirectly() {
        var controller = idleController()
        XCTAssertEqual(controller.handle(.userDisabled(requestId: "req-1")), [.cancelStopDebounce])
        XCTAssertEqual(controller.state, .disabled)
    }

    func testDisabledNeverStartsOnDemand() {
        var controller = idleController()
        _ = controller.handle(.userDisabled(requestId: "req-1"))
        XCTAssertEqual(controller.handle(.demandChanged(hasDemand: true, requestId: "req-2")), [])
        XCTAssertEqual(controller.handle(.holdBegan(requestId: "req-3")), [])
        XCTAssertEqual(controller.state, .disabled)
    }

    func testEnableReturnsToIdle() {
        var controller = idleController()
        _ = controller.handle(.userDisabled(requestId: "req-1"))
        XCTAssertEqual(controller.handle(.userEnabled), [])
        XCTAssertEqual(controller.state, .idle)
    }

    func testHoldForcesStartWithNoDemand() {
        var controller = idleController()
        let actions = controller.handle(.holdBegan(requestId: "req-1"))
        XCTAssertTrue(controller.holdActive)
        XCTAssertEqual(actions, [
            .sendStart(requestId: "req-1"),
            .armStartTimeout(requestId: "req-1", seconds: 2.0),
            .openRenderer
        ])
    }

    func testHoldSuppressesDebounce() {
        var controller = streamingController()
        _ = controller.handle(.holdBegan(requestId: "req-9"))
        XCTAssertEqual(controller.handle(.demandChanged(hasDemand: false, requestId: "req-2")), [])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
    }

    func testHoldExpiryWithoutDemandDebounces() {
        var controller = streamingController()
        _ = controller.handle(.holdBegan(requestId: "req-9"))
        _ = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        let actions = controller.handle(.holdExpired(requestId: "req-3"))
        XCTAssertFalse(controller.holdActive)
        XCTAssertEqual(actions, [.armStopDebounce(sessionId: "sess-1", seconds: 1.0)])
        XCTAssertEqual(controller.state, .stopPending(sessionId: "sess-1"))
    }

    func testHoldReturnFromStopPendingCancels() {
        var controller = streamingController()
        _ = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        XCTAssertEqual(controller.handle(.holdBegan(requestId: "req-3")), [.cancelStopDebounce])
        XCTAssertEqual(controller.state, .streaming(sessionId: "sess-1"))
    }

    func testDegradedNotifiesWithDemandAndStaysSilentAtIdle() {
        var idle = idleController()
        _ = idle.handle(.connectionLost(reason: "peer dead"))
        XCTAssertEqual(idle.state, .disconnected)

        var active = streamingController()
        let actions = active.handle(.connectionLost(reason: "peer dead"))
        XCTAssertTrue(actions.contains(.scheduleReconnect))
        XCTAssertTrue(actions.contains(where: {
            if case .notify = $0 { return true }
            return false
        }), "losing the transport mid-session with demand must notify")
        if case .degraded = active.state {} else {
            XCTFail("expected degraded, got \(active.state)")
        }
    }

    func testStartTimeoutNotifiesWithDemandOnly() {
        var idle = idleController()
        _ = idle.handle(.demandChanged(hasDemand: false, requestId: "req-0"))
        _ = idle.handle(.holdBegan(requestId: "req-1"))
        let withHold = idle.handle(.startTimedOut(requestId: "req-1"))
        XCTAssertTrue(withHold.contains(where: {
            if case .notify = $0 { return true }
            return false
        }))

        var idle2 = idleController()
        _ = idle2.handle(.demandChanged(hasDemand: true, requestId: "req-1"))
        _ = idle2.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        _ = idle2.handle(.holdExpired(requestId: "req-3"))
        XCTAssertFalse(idle2.hasDemand)
    }

    func testMicLossNotifiesWithDemandAndStaysSilentAtIdle() {
        var idle = idleController()
        XCTAssertEqual(idle.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "x")), [])

        var active = streamingController()
        let actions = active.handle(.statusReceived(micPresent: false, active: false, deviceLabel: "x"))
        XCTAssertTrue(actions.contains(where: {
            if case .notify = $0 { return true }
            return false
        }))
        if case .degraded = active.state {} else {
            XCTFail("expected degraded, got \(active.state)")
        }
    }

    func testStopPendingExposesSessionId() {
        var controller = streamingController()
        _ = controller.handle(.demandChanged(hasDemand: false, requestId: "req-2"))
        XCTAssertEqual(controller.activeSessionId, "sess-1")
    }

    func testDisplayNamesCoverNewStates() {
        XCTAssertEqual(AgentState.disabled.displayName, "Disabled")
        XCTAssertEqual(AgentState.stopPending(sessionId: "s").displayName, "Stop pending")
    }
}
