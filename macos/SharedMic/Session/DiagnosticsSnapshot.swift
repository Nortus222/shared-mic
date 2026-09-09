import Foundation

/// Point-in-time renderer accounting for the diagnostics view (spec §11).
/// All fields are cumulative except `jitterDepthMs`, which is the depth at
/// the moment of the read. No audio payload, no locks, no I/O — plain data.
public struct RendererCounters: Equatable {
    public var enqueuedFrames: Int
    public var droppedNewestFrames: Int
    public var droppedStragglerFrames: Int
    public var droppedOldestFrames: Int
    public var underrunSamples: Int
    public var driftDropsApplied: Int
    public var driftInsertsApplied: Int
    public var driftInsertsSkipped: Int
    public var unitStartFailures: Int
    public var jitterDepthMs: Double

    public init(enqueuedFrames: Int = 0,
                droppedNewestFrames: Int = 0,
                droppedStragglerFrames: Int = 0,
                droppedOldestFrames: Int = 0,
                underrunSamples: Int = 0,
                driftDropsApplied: Int = 0,
                driftInsertsApplied: Int = 0,
                driftInsertsSkipped: Int = 0,
                unitStartFailures: Int = 0,
                jitterDepthMs: Double = 0) {
        self.enqueuedFrames = enqueuedFrames
        self.droppedNewestFrames = droppedNewestFrames
        self.droppedStragglerFrames = droppedStragglerFrames
        self.droppedOldestFrames = droppedOldestFrames
        self.underrunSamples = underrunSamples
        self.driftDropsApplied = driftDropsApplied
        self.driftInsertsApplied = driftInsertsApplied
        self.driftInsertsSkipped = driftInsertsSkipped
        self.unitStartFailures = unitStartFailures
        self.jitterDepthMs = jitterDepthMs
    }

    public var totalDroppedFrames: Int {
        droppedNewestFrames + droppedStragglerFrames + droppedOldestFrames
    }

    public var totalDriftCorrections: Int {
        driftDropsApplied + driftInsertsApplied
    }

    /// Component-wise sum for every cumulative field. Depth is a gauge, not
    /// a counter: the newer reading wins.
    public func adding(_ other: RendererCounters) -> RendererCounters {
        RendererCounters(enqueuedFrames: enqueuedFrames + other.enqueuedFrames,
                         droppedNewestFrames: droppedNewestFrames + other.droppedNewestFrames,
                         droppedStragglerFrames: droppedStragglerFrames + other.droppedStragglerFrames,
                         droppedOldestFrames: droppedOldestFrames + other.droppedOldestFrames,
                         underrunSamples: underrunSamples + other.underrunSamples,
                         driftDropsApplied: driftDropsApplied + other.driftDropsApplied,
                         driftInsertsApplied: driftInsertsApplied + other.driftInsertsApplied,
                         driftInsertsSkipped: driftInsertsSkipped + other.driftInsertsSkipped,
                         unitStartFailures: unitStartFailures + other.unitStartFailures,
                         jitterDepthMs: other.jitterDepthMs)
    }
}

/// Activation-latency distribution (START sent → first playable frame) over
/// one bounded sample ring. Percentiles are nearest-rank; buckets follow the
/// 300 ms activation budget in thirds so the histogram reads as budget
/// headroom at a glance.
public struct ActivationLatencyStats: Equatable {
    public var count: Int
    public var latestMs: Double
    public var p50Ms: Double
    public var p95Ms: Double
    public var maxMs: Double
    public var bucketUnder100Ms: Int
    public var bucket100to200Ms: Int
    public var bucket200to300Ms: Int
    public var bucketOver300Ms: Int

    public static func compute(samples: [Double]) -> ActivationLatencyStats? {
        guard let latest = samples.last else { return nil }
        let sorted = samples.sorted()
        let rank = { (fraction: Double) -> Double in
            let position = max(1, Int((fraction * Double(sorted.count)).rounded(.up)))
            return sorted[position - 1]
        }
        var under100 = 0, to200 = 0, to300 = 0, over300 = 0
        for sample in samples {
            if sample < 100 { under100 += 1 }
            else if sample < 200 { to200 += 1 }
            else if sample <= 300 { to300 += 1 }
            else { over300 += 1 }
        }
        return ActivationLatencyStats(count: samples.count,
                                      latestMs: latest,
                                      p50Ms: rank(0.5),
                                      p95Ms: rank(0.95),
                                      maxMs: sorted.last ?? latest,
                                      bucketUnder100Ms: under100,
                                      bucket100to200Ms: to200,
                                      bucket200to300Ms: to300,
                                      bucketOver300Ms: over300)
    }
}

/// The full spec §11 counter set the diagnostics view displays, Mac-owned
/// half. Built by `ConnectionCoordinator` from one consistent read so every
/// row reconciles with the menu rows by construction — the menu's session
/// count, byte total, and last-activation figures are projections of this
/// same snapshot, never separately maintained copies.
public struct DiagnosticsSnapshot: Equatable {
    public var sessionCount: Int
    public var totalSessionSeconds: Double
    public var activationLatency: ActivationLatencyStats?
    public var renderer: RendererCounters
    public var reconnectCount: Int
    public var authFailureCount: Int
    public var debounceFireCount: Int
    public var audioBytesReceived: Int

    public init(sessionCount: Int = 0,
                totalSessionSeconds: Double = 0,
                activationLatency: ActivationLatencyStats? = nil,
                renderer: RendererCounters = RendererCounters(),
                reconnectCount: Int = 0,
                authFailureCount: Int = 0,
                debounceFireCount: Int = 0,
                audioBytesReceived: Int = 0) {
        self.sessionCount = sessionCount
        self.totalSessionSeconds = totalSessionSeconds
        self.activationLatency = activationLatency
        self.renderer = renderer
        self.reconnectCount = reconnectCount
        self.authFailureCount = authFailureCount
        self.debounceFireCount = debounceFireCount
        self.audioBytesReceived = audioBytesReceived
    }
}
