import AudioToolbox
import CoreAudio
import Darwin
import Foundation

// MARK: - Seams

/// The control surface `ConnectionCoordinator` needs. `AudioRenderer` is the
/// production implementation; tests substitute a recording double.
///
/// All methods must be called from a single serial context — the
/// coordinator's renderer queue at runtime, the test thread in tests.
/// (`PCMRingBuffer` precedent: this type guarantees correct behavior for any
/// serialized call sequence; the lock-free handoff to the render thread is
/// inside `AudioRenderer`.)
public protocol RendererControl: AnyObject {
    func open() throws
    func enqueue(pcm: Data)
    func closeAfterDrain()
    func finalizeClose()
    var isOpen: Bool { get }
    /// Per-session accounting snapshot for the diagnostics view (spec §11).
    /// Lag-tolerant like every other bridge counter: the coordinator folds
    /// these into its cumulative totals at teardown and adds the live reading
    /// at snapshot time.
    func readCounters() -> RendererCounters
    /// Read-and-clear rendered-PCM peak (0–1) for the menu level meter. The
    /// 1 Hz poller takes whatever rendered since the last take, so each
    /// reading is that second's peak.
    func takeRenderedPeak() -> Float
}

extension RendererControl {
    public func readCounters() -> RendererCounters { RendererCounters() }
    public func takeRenderedPeak() -> Float { 0 }
}

/// The output-unit contract behind `AudioRenderer`. The only production
/// implementation drives a HAL unit bound to BlackHole; `NullOutputUnit` is
/// the test double. Never used by the shipping app.
public protocol OutputUnit: AnyObject {
    var deviceID: AudioObjectID? { get }
    var isStarted: Bool { get }
    func setDevice(_ id: AudioObjectID) throws
    func setRenderBlock(_ block: @escaping (UnsafeMutableBufferPointer<Float>,
                                            UnsafeMutableBufferPointer<Float>,
                                            Int) -> Void)
    func initialize() throws
    func start() throws
    func stop()
    func dispose()
}

public enum AudioRendererError: Error {
    case unitCreationFailed(OSStatus)
    case deviceFailed(OSStatus)
    case formatFailed(OSStatus)
    case callbackFailed(OSStatus)
    case startFailed(OSStatus)
    /// BlackHole is missing. Carries the setup guidance verbatim so layers
    /// above the `Audio/` boundary never name the device themselves.
    case deviceUnavailable(message: String)
}

extension AudioRendererError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unitCreationFailed(let status):
            return "could not create the BlackHole output unit (\(status))"
        case .deviceFailed(let status):
            return "could not bind the output unit to BlackHole (\(status))"
        case .formatFailed(let status):
            return "could not set the 48 kHz stereo render format (\(status))"
        case .callbackFailed(let status):
            return "could not install the render callback (\(status))"
        case .startFailed(let status):
            return "could not start BlackHole playback (\(status))"
        case .deviceUnavailable(let message):
            return message
        }
    }
}

// MARK: - Lock-free bridge

/// Single-producer / single-consumer sample ring between the network writer
/// (`AudioRenderer.enqueue`, on the renderer's serial queue) and the
/// real-time render thread (`AudioRenderer.renderFrames`, on HAL's IO
/// thread). Stores mono Float32: the Int16→Float conversion happens
/// writer-side so the callback is a plain copy.
///
/// Ordering discipline (the whole of the thread safety here):
///
/// - `tail` has one writer (producer) and one reader (consumer); `head` has
///   one writer (consumer) and one reader (producer). Aligned word
///   loads/stores are single-copy atomic on arm64/x86_64, so no value ever
///   tears; `OSMemoryBarrier()` at each publish point orders the slot data
///   before the index that advertises it. (`atomic_thread_fence` is not
///   importable from Swift, and the `Synchronization` module needs macOS 15;
///   the deployment floor is 14.4, so the Darwin barrier is the only
///   importable full fence. It exceeds what SPSC strictly needs on arm64,
///   where same-address load/store ordering plus cache coherency does most
///   of the work — documented here so a reader does not "simplify" it away.)
/// - A stale `head` read underestimates free space (safe direction: the
///   producer may drop-newest spuriously, it can never overwrite unread
///   data). A stale `tail` read is impossible beyond cache-coherency delay,
///   which the publish barrier already orders against.
/// - `insertRequested` is advisory and lossy: if a set races a clear, drift
///   re-requests within one dwell. Counters are per-session (reset by `clear()` in `open()`); cross-thread
///   reads may lag, which is fine for metrics and exact in single-threaded
///   tests.
///
/// Full policy is deliberately split: the producer drops NEWEST (it cannot
/// advance consumer-owned `head`), while the consumer evicts OLDEST whenever
/// depth exceeds the pathological threshold — so every sustained-full event
/// still ends with the freshest audio surviving, matching the drop-oldest
/// intent without a head race.
final class RenderBridge {
    static let capacitySamples = 50 * SharedMicProtocol.samplesPerFrame
    static let evictThresholdSamples = 45 * SharedMicProtocol.samplesPerFrame
    static let evictTargetSamples = 40 * SharedMicProtocol.samplesPerFrame

    private var storage: [Float]
    private var head = 0
    private var tail = 0
    /// Explicit depth authority. `head == tail` is ambiguous (empty vs.
    /// full), so depth is never derived from the cursors: the producer only
    /// ever increments `count` and the consumer only ever decrements it,
    /// each barrier-ordered with its cursor move. A stale cross-thread read
    /// is always in the safe direction (producer underestimates free space
    /// and may drop-newest; the consumer never over-reads published data).
    private var count = 0

    private(set) var underrunSamples = 0
    private(set) var droppedNewestFrames = 0
    private(set) var droppedOldestFrames = 0
    /// Loudest absolute sample rendered since the last take. Written on the
    /// render thread, taken from the coordinator's renderer queue: a plain
    /// Float is single-copy atomic on arm64, and a torn-or-stale read only
    /// wiggles a meter, so no fence is warranted on the hot path.
    private(set) var peakSinceRead: Float = 0

    /// Set by the consumer (drift verdict), applied and cleared by the
    /// producer on the next enqueue. See the lossiness note above.
    var insertRequested = false

    init() {
        storage = [Float](repeating: 0, count: Self.capacitySamples)
    }

    var depthSamples: Int { count }

    var freeSamples: Int {
        Self.capacitySamples - depthSamples
    }

    /// Producer-side. Converts s16le mono to Float32 and appends one frame.
    /// Returns false without writing when full (caller counts drop-newest).
    func writeFrame(samples: [Int16]) -> Bool {
        guard freeSamples >= SharedMicProtocol.samplesPerFrame else { return false }
        for index in 0..<SharedMicProtocol.samplesPerFrame {
            storage[tail] = Float(samples[index]) * (1.0 / 32768.0)
            tail = (tail + 1) % Self.capacitySamples
        }
        OSMemoryBarrier()
        count += SharedMicProtocol.samplesPerFrame
        return true
    }

    /// Producer-side. Appends one 20 ms silence frame for drift correction.
    /// Returns false without writing when full.
    func writeSilenceFrame() -> Bool {
        guard freeSamples >= SharedMicProtocol.samplesPerFrame else { return false }
        for _ in 0..<SharedMicProtocol.samplesPerFrame {
            storage[tail] = 0
            tail = (tail + 1) % Self.capacitySamples
        }
        OSMemoryBarrier()
        count += SharedMicProtocol.samplesPerFrame
        return true
    }

    /// Consumer-side. Copies up to one quantum of mono into both stereo
    /// channels, zero-filling past available data. Returns underrun samples.
    /// No allocation: straight-line copy over preallocated storage.
    func readStereo(left: UnsafeMutableBufferPointer<Float>,
                    right: UnsafeMutableBufferPointer<Float>,
                    frameCount: Int) -> Int {
        let have = min(frameCount, count)
        for index in 0..<have {
            let sample = storage[head]
            head = (head + 1) % Self.capacitySamples
            left[index] = sample
            right[index] = sample
            let magnitude = abs(sample)
            if magnitude > peakSinceRead { peakSinceRead = magnitude }
        }
        OSMemoryBarrier()
        count -= have
        let underrun = frameCount - have
        if underrun > 0 {
            for index in have..<frameCount {
                left[index] = 0
                right[index] = 0
            }
            underrunSamples += underrun
        }
        return underrun
    }

    /// Consumer-side. Reads and clears the rendered peak (see
    /// `peakSinceRead`). Single-threaded callers only for the clear half;
    /// the coordinator is the only taker and it serializes on the renderer
    /// queue.
    func takePeak() -> Float {
        let peak = peakSinceRead
        peakSinceRead = 0
        return peak
    }

    /// Consumer-side. Drops whole oldest frames down toward the target;
    /// returns the dropped frame count.
    @discardableResult
    func dropOldestFrames(_ frames: Int) -> Int {
        var dropped = 0
        for _ in 0..<frames {
            guard count >= SharedMicProtocol.samplesPerFrame else { break }
            head = (head + SharedMicProtocol.samplesPerFrame) % Self.capacitySamples
            count -= SharedMicProtocol.samplesPerFrame
            dropped += 1
        }
        if dropped > 0 {
            OSMemoryBarrier()
            droppedOldestFrames += dropped
        }
        return dropped
    }

    /// Writer-side only, and only when no callback is in flight
    /// (before start / after stop) — it resets both cursors at once.
    func clear() {
        head = 0
        tail = 0
        count = 0
        underrunSamples = 0
        droppedNewestFrames = 0
        droppedOldestFrames = 0
        peakSinceRead = 0
    }
}

// MARK: - Render block box

/// Carries the Swift fill block across the C callback boundary for
/// `HALOutputUnit`. Owned by the unit; the callback holds it unretained and
/// the unit guarantees no callback is in flight after `stop()` returns.
final class RenderBlockBox {
    var block: ((UnsafeMutableBufferPointer<Float>,
                 UnsafeMutableBufferPointer<Float>,
                 Int) -> Void)?
}

private func halRenderCallback(inRefCon: UnsafeMutableRawPointer,
                               _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                               _ stamp: UnsafePointer<AudioTimeStamp>,
                               _ bus: UInt32,
                               _ frames: UInt32,
                               _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let ioData else { return noErr }
    let box = Unmanaged<RenderBlockBox>.fromOpaque(inRefCon).takeUnretainedValue()
    guard let block = box.block else { return noErr }
    let buffers = UnsafeMutableAudioBufferListPointer(ioData)
    guard buffers.count == 2 else { return noErr }
    let wanted = Int(frames)
    for index in 0..<2 {
        guard let raw = buffers[index].mData else { return noErr }
        let capacity = Int(buffers[index].mDataByteSize) / MemoryLayout<Float>.size
        guard capacity >= wanted else { return noErr }
    }
    let left = UnsafeMutableBufferPointer(
        start: buffers[0].mData!.assumingMemoryBound(to: Float.self), count: wanted)
    let right = UnsafeMutableBufferPointer(
        start: buffers[1].mData!.assumingMemoryBound(to: Float.self), count: wanted)
    block(left, right, wanted)
    return noErr
}

// MARK: - Output units

/// Test double. Never used by the shipping app.
public final class NullOutputUnit: OutputUnit {
    public private(set) var deviceID: AudioObjectID?
    public private(set) var isStarted = false
    public private(set) var initializeCount = 0
    public private(set) var disposeCount = 0
    public var shouldFailStart = false
    private var block: ((UnsafeMutableBufferPointer<Float>,
                         UnsafeMutableBufferPointer<Float>,
                         Int) -> Void)?

    public init() {}

    public func setDevice(_ id: AudioObjectID) throws {
        deviceID = id
    }

    public func setRenderBlock(_ block: @escaping (UnsafeMutableBufferPointer<Float>,
                                                   UnsafeMutableBufferPointer<Float>,
                                                   Int) -> Void) {
        self.block = block
    }

    public func initialize() throws {
        initializeCount += 1
        isStarted = false
    }

    public func start() throws {
        if shouldFailStart { throw AudioRendererError.startFailed(-1) }
        isStarted = true
    }

    public func stop() {
        isStarted = false
    }

    public func dispose() {
        disposeCount += 1
        isStarted = false
    }

    /// Test-thread only: drives the production fill routine into fresh
    /// buffers and returns them. Allocates — never called on a real-time
    /// thread.
    public func fire(frameCount: Int) -> ([Float], [Float]) {
        var left = [Float](repeating: 0, count: frameCount)
        var right = [Float](repeating: 0, count: frameCount)
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                block?(leftBuffer, rightBuffer, frameCount)
            }
        }
        return (left, right)
    }
}

/// HAL output unit bound to an explicit device — never the default.
/// Created fresh per `initialize()` so every `open()` starts clean.
public final class HALOutputUnit: OutputUnit {
    public private(set) var deviceID: AudioObjectID?
    public private(set) var isStarted = false
    private var audioUnit: AudioUnit?
    private let blockBox = RenderBlockBox()

    public init() {}

    public func setDevice(_ id: AudioObjectID) throws {
        deviceID = id
    }

    public func setRenderBlock(_ block: @escaping (UnsafeMutableBufferPointer<Float>,
                                                   UnsafeMutableBufferPointer<Float>,
                                                   Int) -> Void) {
        blockBox.block = block
    }

    public func initialize() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioRendererError.unitCreationFailed(-1)
        }
        var unit: AudioUnit?
        let creation = AudioComponentInstanceNew(component, &unit)
        guard creation == noErr, let created = unit else {
            throw AudioRendererError.unitCreationFailed(creation)
        }
        guard let bound = deviceID else {
            AudioComponentInstanceDispose(created)
            throw AudioRendererError.deviceFailed(-1)
        }
        var boundID = bound
        let deviceStatus = AudioUnitSetProperty(created,
                                                kAudioOutputUnitProperty_CurrentDevice,
                                                kAudioUnitScope_Global, 0,
                                                &boundID,
                                                UInt32(MemoryLayout<AudioObjectID>.size))
        guard deviceStatus == noErr else {
            AudioComponentInstanceDispose(created)
            throw AudioRendererError.deviceFailed(deviceStatus)
        }
        var format = AudioStreamBasicDescription(
            mSampleRate: Double(SharedMicProtocol.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 2,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0)
        let formatStatus = AudioUnitSetProperty(created,
                                                kAudioUnitProperty_StreamFormat,
                                                kAudioUnitScope_Input, 0,
                                                &format,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard formatStatus == noErr else {
            AudioComponentInstanceDispose(created)
            throw AudioRendererError.formatFailed(formatStatus)
        }
        var callback = AURenderCallbackStruct(
            inputProc: halRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(blockBox).toOpaque())
        let callbackStatus = AudioUnitSetProperty(created,
                                                  kAudioUnitProperty_SetRenderCallback,
                                                  kAudioUnitScope_Input, 0,
                                                  &callback,
                                                  UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard callbackStatus == noErr else {
            AudioComponentInstanceDispose(created)
            throw AudioRendererError.callbackFailed(callbackStatus)
        }
        guard AudioUnitInitialize(created) == noErr else {
            AudioComponentInstanceDispose(created)
            throw AudioRendererError.formatFailed(-1)
        }
        audioUnit = created
        isStarted = false
    }

    public func start() throws {
        guard let unit = audioUnit else { throw AudioRendererError.startFailed(-1) }
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw AudioRendererError.startFailed(status) }
        isStarted = true
    }

    public func stop() {
        if let unit = audioUnit { _ = AudioOutputUnitStop(unit) }
        isStarted = false
    }

    public func dispose() {
        stop()
        if let unit = audioUnit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
    }

    deinit {
        dispose()
    }
}

// MARK: - Renderer

/// Renders wire audio to BlackHole (spec §6.4): mono→stereo duplication,
/// prefill-gated start, per-second drift correction (spec §6.5), drain on
/// stop. The only type allowed on the render thread.
///
/// Lifecycle: `open()` (on entry to STARTING) resolves BlackHole by UID and
/// prepares the unit; the unit *starts* once `prefillFrames` are buffered
/// (spec §6.4: 60 ms / 3 frames; Task 6 owns the figure). `closeAfterDrain()`
/// (on STOPPING) keeps playing queued audio; `finalizeClose()` (on STOP_ACK
/// or stop timeout) stops and disposes unconditionally — the drain is
/// best-effort, the close is not. `open()` clears stale audio and resets
/// per-session counters, so a reopened renderer never replays the old
/// session.
public final class AudioRenderer: RendererControl {
    private let lister: AudioDeviceLister
    private let unitFactory: () -> any OutputUnit
    private let prefillFrames: Int
    private let now: () -> Date

    private let bridge = RenderBridge()
    private var drift = DriftController()
    private var unit: (any OutputUnit)?
    private var draining = false
    private var consumedSamples = 0
    private var lastDriftTickSamples = 0

    public private(set) var enqueuedFrames = 0
    public private(set) var droppedNewestFrames = 0
    public private(set) var droppedStragglerFrames = 0
    public private(set) var driftDropsApplied = 0
    public private(set) var driftInsertsApplied = 0
    public private(set) var driftInsertsSkipped = 0
    public private(set) var unitStartFailures = 0

    public init(lister: AudioDeviceLister = CoreAudioDeviceLister(),
                unitFactory: @escaping () -> any OutputUnit = { HALOutputUnit() },
                prefillFrames: Int = 3,
                now: @escaping () -> Date = Date.init) {
        self.lister = lister
        self.unitFactory = unitFactory
        self.prefillFrames = prefillFrames
        self.now = now
    }

    public var isOpen: Bool { unit != nil }
    public var startedUnit: Bool { unit?.isStarted ?? false }
    public var underrunSamples: Int { bridge.underrunSamples }
    public var droppedOldestFrames: Int { bridge.droppedOldestFrames }

    public func readCounters() -> RendererCounters {
        RendererCounters(enqueuedFrames: enqueuedFrames,
                         droppedNewestFrames: droppedNewestFrames,
                         droppedStragglerFrames: droppedStragglerFrames,
                         droppedOldestFrames: bridge.droppedOldestFrames,
                         underrunSamples: bridge.underrunSamples,
                         driftDropsApplied: driftDropsApplied,
                         driftInsertsApplied: driftInsertsApplied,
                         driftInsertsSkipped: driftInsertsSkipped,
                         unitStartFailures: unitStartFailures,
                         jitterDepthMs: depthMs)
    }

    public func takeRenderedPeak() -> Float { bridge.takePeak() }
    public var depthMs: Double {
        Double(bridge.depthSamples) / Double(SharedMicProtocol.sampleRate) * 1_000.0
    }

    public func open() throws {
        if unit != nil { return }
        let deviceID: AudioObjectID
        do {
            deviceID = try BlackHoleDevice.resolve(with: lister)
        } catch let error as BlackHoleDeviceError {
            throw AudioRendererError.deviceUnavailable(message: error.message)
        }
        let created = unitFactory()
        try created.setDevice(deviceID)
        created.setRenderBlock { [weak self] left, right, frameCount in
            self?.renderFrames(left: left, right: right, frameCount: frameCount)
        }
        try created.initialize()
        bridge.clear()
        drift = DriftController()
        consumedSamples = 0
        lastDriftTickSamples = 0
        enqueuedFrames = 0
        droppedNewestFrames = 0
        droppedStragglerFrames = 0
        driftDropsApplied = 0
        driftInsertsApplied = 0
        driftInsertsSkipped = 0
        unitStartFailures = 0
        draining = false
        unit = created
        maybeStart()
    }

    /// Writer-side. Copies one 20 ms frame into the bridge; never blocks.
    /// Requires exactly 1,920 bytes — `ControlClient` already validated the
    /// 1,932-byte envelope, so anything else is a programmer error and traps.
    public func enqueue(pcm: Data) {
        precondition(pcm.count == SharedMicProtocol.audioPCMBytes,
                     "one frame is exactly 1920 bytes of s16le PCM")
        guard unit != nil else {
            droppedStragglerFrames += 1
            return
        }
        if bridge.insertRequested {
            bridge.insertRequested = false
            if bridge.writeSilenceFrame() {
                driftInsertsApplied += 1
            } else {
                driftInsertsSkipped += 1
            }
        }
        let samples = AudioFrameCodec.samples(from: pcm)
        if bridge.writeFrame(samples: samples) {
            enqueuedFrames += 1
        } else {
            droppedNewestFrames += 1
        }
        maybeStart()
    }

    public func closeAfterDrain() {
        if unit != nil { draining = true }
    }

    public func finalizeClose() {
        guard let created = unit else { return }
        created.stop()
        created.dispose()
        unit = nil
        draining = false
    }

    private func maybeStart() {
        guard let created = unit, !created.isStarted else { return }
        guard bridge.depthSamples >= prefillFrames * SharedMicProtocol.samplesPerFrame else { return }
        do {
            try created.start()
        } catch {
            unitStartFailures += 1
        }
    }

    // MARK: - Render thread

    /// Real-time safety review, line by line:
    ///
    /// - Depth/evict/read/drop calls touch only preallocated `[Float]`
    ///   storage plus integer indices — subscript access bounds-checks but
    ///   never allocates.
    /// - `OSMemoryBarrier()` inside the bridge is a CPU fence, not a lock:
    ///   it never blocks, sleeps, or syscalls.
    /// - `drift.tick` is pure struct arithmetic; `now()` (once per rendered
    ///   second) is a vDSO clock read — no allocation, no lock, no I/O.
    /// - No logging, no optionals unwrapped across heap objects, no Swift
    ///   reference counting on the hot path (`self` is already unretained
    ///   via the render block; value types only).
    /// - The `for` loops are bounded by `frameCount` (the HAL quantum).
    func renderFrames(left: UnsafeMutableBufferPointer<Float>,
                      right: UnsafeMutableBufferPointer<Float>,
                      frameCount: Int) {
        let depth = bridge.depthSamples
        if depth > RenderBridge.evictThresholdSamples {
            let excessFrames = (depth - RenderBridge.evictTargetSamples +
                SharedMicProtocol.samplesPerFrame - 1) / SharedMicProtocol.samplesPerFrame
            _ = bridge.dropOldestFrames(excessFrames)
        }
        _ = bridge.readStereo(left: left, right: right, frameCount: frameCount)
        consumedSamples += frameCount
        while consumedSamples - lastDriftTickSamples >= SharedMicProtocol.sampleRate {
            lastDriftTickSamples += SharedMicProtocol.sampleRate
            switch drift.tick(depthMs: depthMs, now: now()) {
            case .none:
                break
            case .dropOneFrame:
                if bridge.dropOldestFrames(1) > 0 { driftDropsApplied += 1 }
            case .insertSilenceFrame:
                bridge.insertRequested = true
            }
        }
    }
}
