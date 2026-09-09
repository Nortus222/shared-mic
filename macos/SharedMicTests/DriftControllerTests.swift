import XCTest
@testable import SharedMic

final class DriftControllerTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        epoch.addingTimeInterval(seconds)
    }

    /// Ticks every second with the same depth, returning all verdicts.
    private func tickSeries(controller: inout DriftController,
                            depthMs: Double,
                            seconds: Range<Int>) -> [DriftController.Action] {
        seconds.map { second in controller.tick(depthMs: depthMs, now: at(TimeInterval(second))) }
    }

    func testDefaultsMatchTheSpec() {
        XCTAssertEqual(DriftController.highWatermarkMs, 120.0)
        XCTAssertEqual(DriftController.lowWatermarkMs, 40.0)
        XCTAssertEqual(DriftController.dwellSeconds, 5.0)
    }

    /// Spec §6.5: depth above the 120 ms high watermark for 5 consecutive
    /// seconds drops one frame, then the dwell re-arms for the next one.
    func testSustainedHighDepthDropsOneFrameAfterFiveSeconds() {
        var controller = DriftController()
        let verdicts = tickSeries(controller: &controller, depthMs: 130.0, seconds: 0..<10)
        XCTAssertEqual(verdicts,
                       [.none, .none, .none, .none, .none,
                        .dropOneFrame,
                        .none, .none, .none, .none])
    }

    func testRearmsAndDropsAgainAfterAnotherFiveSeconds() {
        var controller = DriftController()
        let verdicts = tickSeries(controller: &controller, depthMs: 130.0, seconds: 0..<12)
        XCTAssertEqual(verdicts[5], .dropOneFrame)
        XCTAssertEqual(verdicts[10], .dropOneFrame,
                       "a persistently high buffer must keep correcting, one frame per dwell")
    }

    /// Mirror image at the 40 ms low watermark: sustained lowness inserts
    /// one silence frame per dwell.
    func testSustainedLowDepthInsertsSilenceAfterFiveSeconds() {
        var controller = DriftController()
        let verdicts = tickSeries(controller: &controller, depthMs: 30.0, seconds: 0..<10)
        XCTAssertEqual(verdicts,
                       [.none, .none, .none, .none, .none,
                        .insertSilenceFrame,
                        .none, .none, .none, .none])
    }

    /// The 5-second dwell is what distinguishes drift from jitter: a transient
    /// spike that clears within a second must never correct.
    func testTransientSpikeIsJitterNotDrift() {
        var controller = DriftController()
        XCTAssertEqual(controller.tick(depthMs: 130.0, now: at(0)), .none)
        let verdicts = tickSeries(controller: &controller, depthMs: 60.0, seconds: 1..<10)
        XCTAssertTrue(verdicts.allSatisfy { $0 == .none },
                      "a 1 s excursion must not correct once depth returns in-band")
    }

    /// An in-band sample resets the dwell: 4 s high, 1 s in-band, 4 s high
    /// is two aborted dwells, not one completed one.
    func testInBandDepthResetsTheDwell() {
        var controller = DriftController()
        var verdicts = tickSeries(controller: &controller, depthMs: 130.0, seconds: 0..<4)
        verdicts += tickSeries(controller: &controller, depthMs: 60.0, seconds: 4..<5)
        verdicts += tickSeries(controller: &controller, depthMs: 130.0, seconds: 5..<9)
        XCTAssertTrue(verdicts.allSatisfy { $0 == .none })
    }

    /// Watermark edges are strict: exactly 120 ms or 40 ms is in-band.
    func testWatermarkEdgesAreStrict() {
        var controller = DriftController()
        for second in 0..<10 {
            XCTAssertEqual(controller.tick(depthMs: 120.0, now: at(TimeInterval(second))), .none)
            XCTAssertEqual(controller.tick(depthMs: 40.0, now: at(TimeInterval(second))), .none)
        }
    }

    /// Dwell is tracked per side: a high excursion does not consume the low
    /// side's dwell, it resets it — and vice versa.
    func testSidesDwellIndependently() {
        var controller = DriftController()
        var verdicts = tickSeries(controller: &controller, depthMs: 30.0, seconds: 0..<4)
        verdicts += tickSeries(controller: &controller, depthMs: 130.0, seconds: 4..<5)
        verdicts += tickSeries(controller: &controller, depthMs: 30.0, seconds: 5..<9)
        XCTAssertTrue(verdicts.allSatisfy { $0 == .none },
                      "the 1 s high excursion must reset the low side's 4 s dwell")
    }

    /// At a plausible 100 ppm the clocks diverge 0.1 ms per second. From a
    /// 60 ms mid-band start the buffer reaches the high watermark after
    /// ~10 minutes, so corrections must arrive at most about once per few
    /// minutes — never in a chattering burst.
    func testPlausibleDriftCorrectsAboutOncePerFewMinutes() {
        var controller = DriftController()
        var depthMs = 60.0
        var verdicts: [DriftController.Action] = []
        for second in 0..<1200 {
            let verdict = controller.tick(depthMs: depthMs, now: at(TimeInterval(second)))
            verdicts.append(verdict)
            // The renderer applies each verdict as a single 20 ms frame step.
            if verdict == .dropOneFrame { depthMs -= 20.0 }
            if verdict == .insertSilenceFrame { depthMs += 20.0 }
            depthMs += 0.1
        }
        let corrections = verdicts.filter { $0 != .none }.count
        XCTAssertGreaterThan(corrections, 0, "100 ppm over 20 minutes must correct at least once")
        XCTAssertLessThanOrEqual(corrections, 5,
                                 "100 ppm must not correct more than ~once per few minutes")
        // No two corrections closer than one dwell apart.
        var lastCorrection: Int?
        for (second, verdict) in verdicts.enumerated() where verdict != .none {
            if let previous = lastCorrection {
                XCTAssertGreaterThanOrEqual(second - previous, 5)
            }
            lastCorrection = second
        }
    }
}
