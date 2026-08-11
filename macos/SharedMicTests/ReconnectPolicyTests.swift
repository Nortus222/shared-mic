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
        var low = ReconnectPolicy()
        XCTAssertEqual(low.nextDelay(randomFraction: 0.0), 0.4, accuracy: 1e-9)
        var high = ReconnectPolicy()
        XCTAssertEqual(high.nextDelay(randomFraction: 1.0), 0.6, accuracy: 1e-9)
    }

    func testJitteredDelaysAreNeverNegativeAndNeverExceedTheCapWindow() {
        var policy = ReconnectPolicy()
        for _ in 0..<40 {
            let delay = policy.nextDelay()
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 30.0 * 1.2)
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

    func testLongRunOfFailuresDoesNotOverflow() {
        var policy = ReconnectPolicy()
        for _ in 0..<10_000 {
            _ = policy.nextDelay(randomFraction: 0.5)
        }
        XCTAssertEqual(policy.nextDelay(randomFraction: 0.5), 30.0)
    }
}
