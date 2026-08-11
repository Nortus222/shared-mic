import XCTest
@testable import SharedMic

final class ReconnectPolicyTests: XCTestCase {
    func testDefaultsMatchTheSpec() {
        let policy = ReconnectPolicy()
        XCTAssertEqual(policy.initialDelay, 0.5)
        XCTAssertEqual(policy.maxDelay, 30.0)
        XCTAssertEqual(policy.attemptCount, 0)
    }

    /// randomFraction 0.5 is the centre of the jitter window, so the sequence is
    /// the undisturbed exponential curve: 0.5, 1, 2, 4, 8, 16, then the 30 s cap.
    func testDoublesFromHalfASecondAndCapsAtThirty() {
        var policy = ReconnectPolicy()
        var delays: [TimeInterval] = []
        for _ in 0..<9 {
            delays.append(policy.nextDelay(randomFraction: 0.5))
        }
        XCTAssertEqual(delays, [0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0])
        XCTAssertEqual(policy.attemptCount, 9)
    }

    func testJitterStaysWithinTwentyPercentOfTheBase() {
        // At attempt 0, the base is 0.5, but jitter on randomFraction 0.0 would be 0.4,
        // which is below the spec's 0.5 s floor. The floor clamp raises it to 0.5.
        var floorClamp = ReconnectPolicy()
        XCTAssertEqual(floorClamp.nextDelay(randomFraction: 0.0), 0.5, accuracy: 1e-9)

        // At attempt 1, the base is 1.0, and jitter is genuinely ±20%: 0.8 to 1.2.
        var low = ReconnectPolicy()
        _ = low.nextDelay(randomFraction: 0.5)  // advance to attempt 1
        XCTAssertEqual(low.nextDelay(randomFraction: 0.0), 0.8, accuracy: 1e-9)

        var high = ReconnectPolicy()
        _ = high.nextDelay(randomFraction: 0.5)  // advance to attempt 1
        XCTAssertEqual(high.nextDelay(randomFraction: 1.0), 1.2, accuracy: 1e-9)
    }

    func testJitteredDelaysStayWithinTheSpecifiedRange() {
        var policy = ReconnectPolicy()
        for _ in 0..<40 {
            let delay = policy.nextDelay()
            XCTAssertGreaterThanOrEqual(delay, 0.5)
            XCTAssertLessThanOrEqual(delay, 30.0)
        }
    }

    func testResetReturnsToTheInitialDelay() {
        var policy = ReconnectPolicy()
        _ = policy.nextDelay(randomFraction: 0.5)
        _ = policy.nextDelay(randomFraction: 0.5)
        policy.reset()
        XCTAssertEqual(policy.attemptCount, 0)
        XCTAssertEqual(policy.nextDelay(randomFraction: 0.5), 0.5)
    }

    func testSaturatedMaximumRespectTheHardCeiling() {
        var policy = ReconnectPolicy()
        // Advance to saturation: after attempt 6, the base caps at 30.0.
        for _ in 0..<7 {
            _ = policy.nextDelay(randomFraction: 0.5)
        }
        // At saturation, even with maximum jitter (randomFraction 1.0), the result
        // is clamped to maxDelay (30.0 s), not allowed to exceed it.
        XCTAssertEqual(policy.nextDelay(randomFraction: 1.0), 30.0)
    }

    func testLongRunOfFailuresDoesNotOverflow() {
        var policy = ReconnectPolicy()
        for _ in 0..<10_000 {
            _ = policy.nextDelay(randomFraction: 0.5)
        }
        XCTAssertEqual(policy.nextDelay(randomFraction: 0.5), 30.0)
    }
}
