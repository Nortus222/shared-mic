import XCTest
@testable import SharedMic

final class DiagnosticsSnapshotTests: XCTestCase {
    func testEmptyLatencySamplesYieldsNilStats() {
        XCTAssertNil(ActivationLatencyStats.compute(samples: []))
    }

    func testLatencyPercentilesOnKnownSamples() {
        // 10 samples, sorted: 10..100. Nearest-rank p50 -> 50, p95 -> 100.
        let samples = [50.0, 10.0, 90.0, 30.0, 70.0, 20.0, 80.0, 40.0, 60.0, 100.0]
        guard let stats = ActivationLatencyStats.compute(samples: samples) else {
            return XCTFail("expected stats for non-empty samples")
        }
        XCTAssertEqual(stats.count, 10)
        XCTAssertEqual(stats.p50Ms, 50.0)
        XCTAssertEqual(stats.p95Ms, 100.0)
        XCTAssertEqual(stats.maxMs, 100.0)
    }

    func testLatencyHistogramBuckets() {
        let samples = [50.0, 150.0, 250.0, 350.0, 99.9, 100.0, 300.0, 300.1]
        guard let stats = ActivationLatencyStats.compute(samples: samples) else {
            return XCTFail("expected stats for non-empty samples")
        }
        XCTAssertEqual(stats.bucketUnder100Ms, 2)
        XCTAssertEqual(stats.bucket100to200Ms, 2)
        XCTAssertEqual(stats.bucket200to300Ms, 2)
        XCTAssertEqual(stats.bucketOver300Ms, 2)
    }

    func testLatencyLatestIsLastSample() {
        guard let stats = ActivationLatencyStats.compute(samples: [5.0, 7.0, 3.0]) else {
            return XCTFail("expected stats for non-empty samples")
        }
        XCTAssertEqual(stats.latestMs, 3.0)
        XCTAssertEqual(stats.maxMs, 7.0)
    }

    func testRendererCountersAddComponentWiseWithLatestDepth() {
        let first = RendererCounters(enqueuedFrames: 10, droppedNewestFrames: 1,
                                     droppedStragglerFrames: 2, droppedOldestFrames: 3,
                                     underrunSamples: 100, driftDropsApplied: 1,
                                     driftInsertsApplied: 2, driftInsertsSkipped: 3,
                                     unitStartFailures: 0, jitterDepthMs: 40.0)
        let second = RendererCounters(enqueuedFrames: 5, droppedNewestFrames: 0,
                                      droppedStragglerFrames: 1, droppedOldestFrames: 0,
                                      underrunSamples: 50, driftDropsApplied: 0,
                                      driftInsertsApplied: 1, driftInsertsSkipped: 0,
                                      unitStartFailures: 1, jitterDepthMs: 60.0)
        let combined = first.adding(second)
        XCTAssertEqual(combined.enqueuedFrames, 15)
        XCTAssertEqual(combined.droppedNewestFrames, 1)
        XCTAssertEqual(combined.droppedStragglerFrames, 3)
        XCTAssertEqual(combined.droppedOldestFrames, 3)
        XCTAssertEqual(combined.underrunSamples, 150)
        XCTAssertEqual(combined.driftDropsApplied, 1)
        XCTAssertEqual(combined.driftInsertsApplied, 3)
        XCTAssertEqual(combined.driftInsertsSkipped, 3)
        XCTAssertEqual(combined.unitStartFailures, 1)
        XCTAssertEqual(combined.jitterDepthMs, 60.0)
    }

    func testRendererCountersTotalDrops() {
        let counters = RendererCounters(enqueuedFrames: 0, droppedNewestFrames: 1,
                                        droppedStragglerFrames: 2, droppedOldestFrames: 3,
                                        underrunSamples: 0, driftDropsApplied: 0,
                                        driftInsertsApplied: 0, driftInsertsSkipped: 0,
                                        unitStartFailures: 0, jitterDepthMs: 0)
        XCTAssertEqual(counters.totalDroppedFrames, 6)
        XCTAssertEqual(counters.totalDriftCorrections, 0)
    }
}
