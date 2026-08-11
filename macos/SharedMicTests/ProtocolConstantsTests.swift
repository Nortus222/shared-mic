import XCTest
@testable import SharedMic

final class ProtocolConstantsTests: XCTestCase {
    func testVersionAndPort() {
        XCTAssertEqual(SharedMicProtocol.version, 1)
        XCTAssertEqual(SharedMicProtocol.defaultPort, 47800)
    }

    func testEnvelopeConstants() {
        XCTAssertEqual(SharedMicProtocol.envelopeHeaderSize, 5)
        XCTAssertEqual(SharedMicProtocol.maxPayloadBytes, 1_048_576)
    }

    func testAudioFrameArithmeticMatchesTheSpecTable() {
        XCTAssertEqual(SharedMicProtocol.audioHeaderSize, 12)
        XCTAssertEqual(SharedMicProtocol.audioPCMBytes, 1_920)
        XCTAssertEqual(SharedMicProtocol.audioPayloadSize, 1_932)
        XCTAssertEqual(SharedMicProtocol.audioEnvelopeSize, 1_937)
        XCTAssertEqual(
            SharedMicProtocol.audioPayloadSize,
            SharedMicProtocol.audioHeaderSize + SharedMicProtocol.audioPCMBytes
        )
        XCTAssertEqual(
            SharedMicProtocol.audioEnvelopeSize,
            SharedMicProtocol.envelopeHeaderSize + SharedMicProtocol.audioPayloadSize
        )
    }

    func testAudioFormatConstants() {
        XCTAssertEqual(SharedMicProtocol.sampleRate, 48_000)
        XCTAssertEqual(SharedMicProtocol.channels, 1)
        XCTAssertEqual(SharedMicProtocol.sampleFormat, "s16le")
        XCTAssertEqual(SharedMicProtocol.samplesPerFrame, 960)
        XCTAssertEqual(SharedMicProtocol.framesPerSecond, 50)
        XCTAssertEqual(SharedMicProtocol.frameDurationUs, 20_000)
        XCTAssertEqual(SharedMicProtocol.samplesPerFrame * 2, SharedMicProtocol.audioPCMBytes)
        XCTAssertEqual(SharedMicProtocol.samplesPerFrame * SharedMicProtocol.framesPerSecond,
                       SharedMicProtocol.sampleRate)
    }

    func testTimerConstants() {
        XCTAssertEqual(SharedMicProtocol.startTimeout, 2.0)
        XCTAssertEqual(SharedMicProtocol.stopTimeout, 1.0)
        XCTAssertEqual(SharedMicProtocol.pingInterval, 15.0)
        XCTAssertEqual(SharedMicProtocol.peerDeadTimeout, 45.0)
        XCTAssertEqual(SharedMicProtocol.helloDeadline, 5.0)
    }

    func testReconnectAndPairingConstants() {
        XCTAssertEqual(SharedMicProtocol.reconnectInitialDelay, 0.5)
        XCTAssertEqual(SharedMicProtocol.reconnectMaxDelay, 30.0)
        XCTAssertEqual(SharedMicProtocol.tokenBytes, 32)
        XCTAssertEqual(SharedMicProtocol.nonceBytes, 32)
        XCTAssertEqual(SharedMicProtocol.pairingGroupSize, 8)
        XCTAssertEqual(SharedMicProtocol.pairingStringLength, 58)
    }
}
