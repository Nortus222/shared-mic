import Foundation

/// Pure single-producer / single-consumer sample ring for the Phase 2 render path.
///
/// Spec §6.4: the macOS render callback reads buffered PCM and zero-fills on
/// underrun. This type owns the *accounting semantics* of that buffer —
/// wraparound, underrun zero-fill, drop-oldest overflow, drift-correction
/// insert/drop primitives, depth reporting, counters — as a single-threaded
/// value type, the same precedent as `FrameBuffer` and `SessionStateMachine`.
///
/// Threading: the lock-free handoff between the network writer thread and the
/// real-time render thread is `AudioRenderer`'s job, not this type's. `mutating`
/// methods are not synchronized; the renderer must guarantee at most one
/// writer and at most one reader and publish visibility across them. What this
/// type guarantees is that any serialized call sequence behaves correctly.
///
/// Overrun policy is drop-oldest whole frames: stale audio is worse than lost
/// audio for dictation latency, matching the Windows send queue's 25-frame
/// drop-oldest ring (protocol peer behavior, not a second copy of it).
public struct PCMRingBuffer {
    public static let defaultCapacityFrames = 50

    public let capacitySamples: Int

    private var storage: [Int16]
    private var head = 0
    private var tail = 0
    private var count = 0

    public private(set) var totalFramesWritten = 0
    public private(set) var totalFramesDropped = 0
    public private(set) var totalUnderrunSamples = 0

    public init(capacityFrames: Int = defaultCapacityFrames) {
        precondition(capacityFrames > 0, "capacity must hold at least one frame")
        self.capacitySamples = capacityFrames * SharedMicProtocol.samplesPerFrame
        self.storage = [Int16](repeating: 0, count: capacitySamples)
    }

    public var availableSamples: Int { count }

    public var freeSamples: Int { capacitySamples - count }

    /// Buffered audio depth in milliseconds at the fixed 48 kHz wire rate.
    public var depthMs: Double {
        Double(count) / Double(SharedMicProtocol.sampleRate) * 1_000.0
    }

    public enum WriteResult: Equatable {
        case wrote
        case wroteDroppingOldest(droppedFrames: Int)
    }

    /// Appends exactly one 20 ms frame. Requires 1,920 bytes: `ControlClient`
    /// already validated the 1,932-byte envelope, so anything else here is a
    /// programmer error and traps rather than corrupting the stream.
    @discardableResult
    public mutating func writeFrame(pcm: Data) -> WriteResult {
        precondition(pcm.count == SharedMicProtocol.audioPCMBytes,
                     "one frame is exactly 1920 bytes of s16le PCM")
        var dropped = 0
        while freeSamples < SharedMicProtocol.samplesPerFrame {
            dropOneFrame()
            dropped += 1
        }
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            precondition(samples.count == SharedMicProtocol.samplesPerFrame)
            for index in 0..<samples.count {
                storage[tail] = Int16(littleEndian: samples[index])
                tail = (tail + 1) % capacitySamples
            }
        }
        count += SharedMicProtocol.samplesPerFrame
        totalFramesWritten += 1
        if dropped == 0 { return .wrote }
        return .wroteDroppingOldest(droppedFrames: dropped)
    }

    /// Reads up to `buffer.count` samples into a caller-provided buffer and
    /// returns the underrun sample count. The remainder of `buffer` is
    /// zero-filled when fewer samples are available. Performs no allocation,
    /// so this is the only read the render callback may use.
    @discardableResult
    public mutating func read(into buffer: UnsafeMutableBufferPointer<Int16>) -> Int {
        let wanted = buffer.count
        let have = min(wanted, count)
        for index in 0..<have {
            buffer[index] = storage[head]
            head = (head + 1) % capacitySamples
        }
        count -= have
        let underrun = wanted - have
        if underrun > 0 {
            for index in have..<wanted {
                buffer[index] = 0
            }
            totalUnderrunSamples += underrun
        }
        return underrun
    }

    /// Allocating convenience read for the network-side drain path and tests.
    /// The render callback must use `read(into:)` instead.
    public mutating func readSamples(count wanted: Int) -> [Int16] {
        var output = [Int16](repeating: 0, count: wanted)
        output.withUnsafeMutableBufferPointer { buffer in
            _ = read(into: buffer)
        }
        return output
    }

    /// Drops the oldest whole frame, counting it. Used both for drift
    /// correction (spec §6.5) and for drop-oldest overflow eviction in
    /// `writeFrame`, so `totalFramesDropped` covers both paths.
    @discardableResult
    public mutating func dropOneFrame() -> Bool {
        guard count >= SharedMicProtocol.samplesPerFrame else { return false }
        head = (head + SharedMicProtocol.samplesPerFrame) % capacitySamples
        count -= SharedMicProtocol.samplesPerFrame
        totalFramesDropped += 1
        return true
    }

    /// Inserts one 20 ms silence frame at the newest end (spec §6.5).
    /// Returns false when no room; the caller then drops oldest first.
    @discardableResult
    public mutating func insertSilenceFrame() -> Bool {
        guard freeSamples >= SharedMicProtocol.samplesPerFrame else { return false }
        for _ in 0..<SharedMicProtocol.samplesPerFrame {
            storage[tail] = 0
            tail = (tail + 1) % capacitySamples
        }
        count += SharedMicProtocol.samplesPerFrame
        return true
    }

    public mutating func clear() {
        head = 0
        tail = 0
        count = 0
    }
}
