import CoreAudio
import XCTest
@testable import SharedMic

private struct FakeRendererLister: AudioDeviceLister {
    var devices: [OutputAudioDevice]
    func outputDevices() -> [OutputAudioDevice] { devices }
}

private func blackHoleLister(id: AudioObjectID = 99) -> FakeRendererLister {
    FakeRendererLister(devices: [
        OutputAudioDevice(id: 42, uid: "AppleUSBAudioEngine:Vendor:Device:1234:2", name: "USB Audio"),
        OutputAudioDevice(id: id, uid: "BlackHole2ch_UID", name: "BlackHole 2ch"),
    ])
}

/// Native-endian fill: Apple platforms are little-endian, matching the wire.
private func patternedFrame(fill: Int16) -> Data {
    var samples = [Int16](repeating: fill, count: SharedMicProtocol.samplesPerFrame)
    return samples.withUnsafeBytes { Data($0) }
}

private func expectedFloat(_ fill: Int16) -> Float {
    Float(fill) / 32768.0
}

final class AudioRendererTests: XCTestCase {
    private var testNow = Date(timeIntervalSince1970: 2_000_000)

    private func makeRenderer(lister: AudioDeviceLister? = nil,
                              null: NullOutputUnit? = nil,
                              prefillFrames: Int = 3) -> (AudioRenderer, NullOutputUnit) {
        let unit = null ?? NullOutputUnit()
        let renderer = AudioRenderer(lister: lister ?? blackHoleLister(),
                                     unitFactory: { unit },
                                     prefillFrames: prefillFrames,
                                     now: { [weak self] in self?.testNow ?? Date() })
        return (renderer, unit)
    }

    private func advanceTestClock(frames: Int) {
        testNow = testNow.addingTimeInterval(Double(frames) / 48_000.0)
    }

    private func fire(_ unit: NullOutputUnit, frames: Int = 960) -> ([Float], [Float]) {
        advanceTestClock(frames: frames)
        return unit.fire(frameCount: frames)
    }

    func testOpenBindsTheBlackHoleUIDAndStartsAfterPrefill() throws {
        let (renderer, unit) = makeRenderer()
        try renderer.open()
        XCTAssertTrue(renderer.isOpen)
        XCTAssertEqual(unit.deviceID, 99)
        XCTAssertFalse(unit.isStarted, "the unit starts after prefill, not at open")

        try renderer.open()
        XCTAssertEqual(unit.initializeCount, 1, "re-open is idempotent")

        renderer.enqueue(pcm: patternedFrame(fill: 1))
        renderer.enqueue(pcm: patternedFrame(fill: 2))
        XCTAssertFalse(unit.isStarted, "2 of 3 prefill frames must not start the unit")
        renderer.enqueue(pcm: patternedFrame(fill: 3))
        XCTAssertTrue(unit.isStarted, "the 3rd prefill frame starts the unit")
        renderer.finalizeClose()
    }

    func testOpenWithoutBlackHoleThrowsGuidance() {
        let (renderer, _) = makeRenderer(
            lister: FakeRendererLister(devices: []))
        XCTAssertThrowsError(try renderer.open()) { error in
            guard let rendererError = error as? AudioRendererError,
                  case .deviceUnavailable(let message) = rendererError else {
                return XCTFail("wrong error type: \(error)")
            }
            XCTAssertTrue(message.contains("BlackHole"))
        }
    }

    func testEmptyCallbackOutputsZerosAndCountsAnUnderrun() throws {
        let (renderer, unit) = makeRenderer(prefillFrames: 0)
        try renderer.open()
        XCTAssertTrue(unit.isStarted)
        let (left, right) = fire(unit)
        XCTAssertTrue(left.allSatisfy { $0 == 0 })
        XCTAssertTrue(right.allSatisfy { $0 == 0 })
        XCTAssertEqual(renderer.underrunSamples, 960)
        renderer.finalizeClose()
    }

    func testMonoInputIsDuplicatedToBothChannels() throws {
        let (renderer, unit) = makeRenderer(prefillFrames: 0)
        try renderer.open()
        renderer.enqueue(pcm: patternedFrame(fill: 1000))
        let (left, right) = fire(unit)
        XCTAssertEqual(left.count, 960)
        XCTAssertTrue(left.allSatisfy { abs($0 - expectedFloat(1000)) < 1e-6 })
        XCTAssertEqual(left, right, "mono must be duplicated, not panned")
        renderer.finalizeClose()
    }

    func testCloseAfterDrainPlaysQueuedFramesThenCloses() throws {
        let (renderer, unit) = makeRenderer(prefillFrames: 0)
        try renderer.open()
        renderer.enqueue(pcm: patternedFrame(fill: 1))
        renderer.enqueue(pcm: patternedFrame(fill: 2))
        renderer.closeAfterDrain()
        XCTAssertTrue(renderer.isOpen, "draining still plays; close is not immediate")

        let (firstLeft, _) = fire(unit)
        XCTAssertTrue(firstLeft.allSatisfy { abs($0 - expectedFloat(1)) < 1e-6 })
        let (secondLeft, _) = fire(unit)
        XCTAssertTrue(secondLeft.allSatisfy { abs($0 - expectedFloat(2)) < 1e-6 })

        renderer.finalizeClose()
        XCTAssertFalse(renderer.isOpen)
        XCTAssertFalse(unit.isStarted)
        XCTAssertEqual(unit.disposeCount, 1)
    }

    func testIdleCloseIsANoOp() {
        let (renderer, unit) = makeRenderer()
        renderer.finalizeClose()
        renderer.closeAfterDrain()
        XCTAssertFalse(renderer.isOpen)
        XCTAssertEqual(unit.initializeCount, 0, "idle close must leave no open device")
    }

    func testStragglerFramesAfterCloseAreCountedNotCrashed() throws {
        let (renderer, _) = makeRenderer(prefillFrames: 0)
        try renderer.open()
        renderer.finalizeClose()
        renderer.enqueue(pcm: patternedFrame(fill: 7))
        XCTAssertEqual(renderer.droppedStragglerFrames, 1)
    }

    func testFullBridgeDropsNewestAndCounts() throws {
        let (renderer, _) = makeRenderer(prefillFrames: 0)
        try renderer.open()
        for index in 0..<60 {
            renderer.enqueue(pcm: patternedFrame(fill: Int16(index)))
        }
        XCTAssertEqual(renderer.enqueuedFrames, 50)
        XCTAssertEqual(renderer.droppedNewestFrames, 10,
                       "a 50-frame bridge keeps the first 50 and drops the 10 newest")
        XCTAssertEqual(renderer.depthMs, 1000.0, accuracy: 0.001)
        renderer.finalizeClose()
    }

    func testConsumerSideEvictionDropsOldest() throws {
        let (renderer, unit) = makeRenderer(prefillFrames: 0)
        try renderer.open()
        for index in 1...50 {
            renderer.enqueue(pcm: patternedFrame(fill: Int16(index)))
        }
        let (left, _) = fire(unit)
        XCTAssertTrue(left.allSatisfy { abs($0 - expectedFloat(11)) < 1e-6 },
                      "an over-full bridge evicts the 10 oldest frames first")
        XCTAssertEqual(renderer.droppedOldestFrames, 10)
        renderer.finalizeClose()
    }

    /// Drift correction end to end: hold the buffer high and the render
    /// callback applies one drop per 5 s dwell, then re-arms.
    func testSustainedHighDepthDropsOneFramePerDwell() throws {
        let (renderer, unit) = makeRenderer(prefillFrames: 0)
        try renderer.open()
        for _ in 0..<8 {
            renderer.enqueue(pcm: patternedFrame(fill: 5))
        }
        // 360 fires = 7 drift ticks; the 5 s dwell fires once with margin to
        // spare for floating-point accumulation in the test clock.
        for _ in 0..<360 {
            _ = fire(unit)
            renderer.enqueue(pcm: patternedFrame(fill: 5))
        }
        XCTAssertEqual(renderer.driftDropsApplied, 1)
        XCTAssertEqual(renderer.driftInsertsApplied, 0)
        renderer.finalizeClose()
    }

    func testOpenClearsStaleAudioFromThePreviousSession() throws {
        let (renderer, unit) = makeRenderer(prefillFrames: 0)
        try renderer.open()
        renderer.enqueue(pcm: patternedFrame(fill: 9))
        renderer.finalizeClose()
        try renderer.open()
        let (left, _) = fire(unit)
        XCTAssertTrue(left.allSatisfy { $0 == 0 },
                      "a reopened renderer must not replay the previous session")
        renderer.finalizeClose()
    }
}
