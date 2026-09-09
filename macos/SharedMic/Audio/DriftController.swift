import Foundation

/// Pure clock-drift correction policy for the Phase 2 render path (spec §6.5).
///
/// The Windows capture clock and BlackHole's clock are both nominally 48 kHz
/// and are not the same clock: at 100 ppm they diverge ~60 ms over ten
/// minutes, enough to drain or overflow the jitter buffer in a long session.
/// This type decides *when* to correct; `AudioRenderer` applies the verdict.
///
/// Single-threaded pure value type — the same precedent as `PCMRingBuffer`
/// and `SessionStateMachine`. Time is injected (`now:`) so the 5-second
/// dwell is testable without sleeping. Only the render callback ticks it
/// (once per second of rendered audio), so no synchronization is needed.
///
/// Policy: depth above the 120 ms high watermark for 5 consecutive seconds
/// drops one 20 ms frame; depth below the 40 ms low watermark for 5
/// consecutive seconds inserts one 20 ms silence frame. The dwell is what
/// distinguishes real drift from ordinary network jitter. Watermark edges
/// are strict: exactly 120 ms or 40 ms is in-band. Each side dwells
/// independently, and any sample on the other side (or in-band) resets a
/// side's dwell. After firing, the dwell re-arms: a persistently high
/// buffer corrects at most once per 5 seconds.
public struct DriftController {
    public static let highWatermarkMs = 120.0
    public static let lowWatermarkMs = 40.0
    public static let dwellSeconds = 5.0

    public enum Action: Equatable {
        case none
        case dropOneFrame
        case insertSilenceFrame
    }

    private var highSince: Date?
    private var lowSince: Date?

    public init() {}

    public mutating func tick(depthMs: Double, now: Date) -> Action {
        if depthMs > Self.highWatermarkMs {
            lowSince = nil
            let start = highSince ?? now
            highSince = start
            if now.timeIntervalSince(start) >= Self.dwellSeconds {
                highSince = now
                return .dropOneFrame
            }
            return .none
        }
        if depthMs < Self.lowWatermarkMs {
            highSince = nil
            let start = lowSince ?? now
            lowSince = start
            if now.timeIntervalSince(start) >= Self.dwellSeconds {
                lowSince = now
                return .insertSilenceFrame
            }
            return .none
        }
        highSince = nil
        lowSince = nil
        return .none
    }
}
