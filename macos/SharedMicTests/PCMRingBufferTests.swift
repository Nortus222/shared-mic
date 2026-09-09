import XCTest
@testable import SharedMic

final class PCMRingBufferTests: XCTestCase {
    private func framePCM(startingAt start: Int16) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(SharedMicProtocol.samplesPerFrame)
        for offset in 0..<SharedMicProtocol.samplesPerFrame {
            samples.append(start &+ Int16(offset))
        }
        return AudioFrameCodec.pcmBytes(from: samples)
    }

    private func readAll(_ buffer: inout PCMRingBuffer, count: Int) -> [Int16] {
        buffer.readSamples(count: count)
    }

    func testWriteThenReadRoundTripsExactSamples() {
        var buffer = PCMRingBuffer(capacityFrames: 4)
        let pcm = framePCM(startingAt: 1000)
        XCTAssertEqual(buffer.writeFrame(pcm: pcm), .wrote)
        XCTAssertEqual(buffer.availableSamples, SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(readAll(&buffer, count: SharedMicProtocol.samplesPerFrame),
                       AudioFrameCodec.samples(from: pcm))
        XCTAssertEqual(buffer.availableSamples, 0)
    }

    func testDepthMsMatchesBufferedAudio() {
        var buffer = PCMRingBuffer(capacityFrames: 10)
        XCTAssertEqual(buffer.depthMs, 0.0)
        buffer.writeFrame(pcm: framePCM(startingAt: 0))
        XCTAssertEqual(buffer.depthMs, 20.0, accuracy: 1e-9)
        buffer.writeFrame(pcm: framePCM(startingAt: 0))
        buffer.writeFrame(pcm: framePCM(startingAt: 0))
        XCTAssertEqual(buffer.depthMs, 60.0, accuracy: 1e-9)
    }

    func testWraparoundPreservesOrder() {
        var buffer = PCMRingBuffer(capacityFrames: 2)
        let first = framePCM(startingAt: 1)
        let second = framePCM(startingAt: 2001)
        let third = framePCM(startingAt: 4001)
        buffer.writeFrame(pcm: first)
        XCTAssertEqual(readAll(&buffer, count: SharedMicProtocol.samplesPerFrame),
                       AudioFrameCodec.samples(from: first))
        buffer.writeFrame(pcm: second)
        buffer.writeFrame(pcm: third)
        XCTAssertEqual(readAll(&buffer, count: SharedMicProtocol.samplesPerFrame),
                       AudioFrameCodec.samples(from: second))
        XCTAssertEqual(readAll(&buffer, count: SharedMicProtocol.samplesPerFrame),
                       AudioFrameCodec.samples(from: third))
        XCTAssertEqual(buffer.availableSamples, 0)
    }

    func testUnderrunZeroFillsAndCounts() {
        var buffer = PCMRingBuffer(capacityFrames: 2)
        let read = readAll(&buffer, count: SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(read, [Int16](repeating: 0, count: SharedMicProtocol.samplesPerFrame))
        XCTAssertEqual(buffer.totalUnderrunSamples, SharedMicProtocol.samplesPerFrame)

        buffer.writeFrame(pcm: framePCM(startingAt: 7))
        let partial = readAll(&buffer, count: 2 * SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(Array(partial.prefix(SharedMicProtocol.samplesPerFrame)),
                       AudioFrameCodec.samples(from: framePCM(startingAt: 7)))
        XCTAssertEqual(Array(partial.suffix(SharedMicProtocol.samplesPerFrame)),
                       [Int16](repeating: 0, count: SharedMicProtocol.samplesPerFrame))
        XCTAssertEqual(buffer.totalUnderrunSamples, 2 * SharedMicProtocol.samplesPerFrame)
    }

    func testOverflowDropsOldestWholeFrames() {
        var buffer = PCMRingBuffer(capacityFrames: 2)
        buffer.writeFrame(pcm: framePCM(startingAt: 1))
        buffer.writeFrame(pcm: framePCM(startingAt: 2001))
        XCTAssertEqual(buffer.writeFrame(pcm: framePCM(startingAt: 4001)),
                       .wroteDroppingOldest(droppedFrames: 1))
        XCTAssertEqual(buffer.totalFramesDropped, 1)
        XCTAssertEqual(buffer.availableSamples, 2 * SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(readAll(&buffer, count: SharedMicProtocol.samplesPerFrame),
                       AudioFrameCodec.samples(from: framePCM(startingAt: 2001)))
        XCTAssertEqual(readAll(&buffer, count: SharedMicProtocol.samplesPerFrame),
                       AudioFrameCodec.samples(from: framePCM(startingAt: 4001)))
    }

    func testDropOneFrameNeedsAFullFrame() {
        var buffer = PCMRingBuffer(capacityFrames: 4)
        XCTAssertFalse(buffer.dropOneFrame())
        buffer.writeFrame(pcm: framePCM(startingAt: 0))
        XCTAssertTrue(buffer.dropOneFrame())
        XCTAssertEqual(buffer.availableSamples, 0)
        XCTAssertEqual(buffer.totalFramesDropped, 1)
        XCTAssertFalse(buffer.dropOneFrame())
    }

    func testInsertSilenceFrameAppendsZeros() {
        var buffer = PCMRingBuffer(capacityFrames: 4)
        XCTAssertTrue(buffer.insertSilenceFrame())
        XCTAssertEqual(buffer.availableSamples, SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(readAll(&buffer, count: SharedMicProtocol.samplesPerFrame),
                       [Int16](repeating: 0, count: SharedMicProtocol.samplesPerFrame))
    }

    func testInsertSilenceFailsWhenFull() {
        var buffer = PCMRingBuffer(capacityFrames: 1)
        buffer.writeFrame(pcm: framePCM(startingAt: 0))
        XCTAssertFalse(buffer.insertSilenceFrame())
        XCTAssertEqual(buffer.availableSamples, SharedMicProtocol.samplesPerFrame)
    }

    func testUnsafeBufferReadMatchesAllocatingRead() {
        var viaUnsafe = PCMRingBuffer(capacityFrames: 4)
        var viaAllocating = PCMRingBuffer(capacityFrames: 4)
        let pcm = framePCM(startingAt: -500)
        viaUnsafe.writeFrame(pcm: pcm)
        viaAllocating.writeFrame(pcm: pcm)

        var scratch = [Int16](repeating: 0, count: SharedMicProtocol.samplesPerFrame)
        let underrun = scratch.withUnsafeMutableBufferPointer { pointer in
            viaUnsafe.read(into: pointer)
        }
        XCTAssertEqual(underrun, 0)
        XCTAssertEqual(scratch, viaAllocating.readSamples(count: SharedMicProtocol.samplesPerFrame))
    }

    func testUnsafeBufferReadZeroFillsTailOnUnderrun() {
        var buffer = PCMRingBuffer(capacityFrames: 4)
        var scratch = [Int16](repeating: 42, count: SharedMicProtocol.samplesPerFrame)
        let underrun = scratch.withUnsafeMutableBufferPointer { pointer in
            buffer.read(into: pointer)
        }
        XCTAssertEqual(underrun, SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(scratch, [Int16](repeating: 0, count: SharedMicProtocol.samplesPerFrame))
    }

    func testProducerConsumerInterleaveAtStreamingRate() {
        var buffer = PCMRingBuffer(capacityFrames: 6)
        let frames = 50
        for index in 0..<frames {
            XCTAssertEqual(buffer.writeFrame(pcm: framePCM(startingAt: Int16(index))), .wrote)
            if index >= 3 {
                let expected = AudioFrameCodec.samples(from: framePCM(startingAt: Int16(index - 3)))
                XCTAssertEqual(readAll(&buffer, count: SharedMicProtocol.samplesPerFrame), expected)
            }
        }
        XCTAssertEqual(buffer.totalFramesWritten, frames)
        XCTAssertEqual(buffer.totalFramesDropped, 0)
        XCTAssertEqual(buffer.availableSamples, 3 * SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(buffer.depthMs, 60.0, accuracy: 1e-9)
    }

    func testClearDropsBufferedAudioButKeepsCounters() {
        var buffer = PCMRingBuffer(capacityFrames: 4)
        buffer.writeFrame(pcm: framePCM(startingAt: 0))
        buffer.clear()
        XCTAssertEqual(buffer.availableSamples, 0)
        XCTAssertEqual(buffer.depthMs, 0.0)
        XCTAssertEqual(buffer.totalFramesWritten, 1)
        let read = readAll(&buffer, count: SharedMicProtocol.samplesPerFrame)
        XCTAssertEqual(read, [Int16](repeating: 0, count: SharedMicProtocol.samplesPerFrame))
    }
}
