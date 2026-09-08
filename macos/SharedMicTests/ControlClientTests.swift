import XCTest
@testable import SharedMic

private final class RecordingDelegate: ControlClientDelegate {
    var authenticated: (micPresent: Bool, deviceLabel: String)?
    var messages: [ControlMessage] = []
    var didClose = false
    var closeError: Error?
    var onAuthenticate: (() -> Void)?
    var onMessage: ((ControlMessage) -> Void)?
    var onClose: ((Error?) -> Void)?

    func controlClientDidAuthenticate(_ client: ControlClient, micPresent: Bool, deviceLabel: String) {
        authenticated = (micPresent, deviceLabel)
        onAuthenticate?()
    }

    func controlClient(_ client: ControlClient, didReceive message: ControlMessage) {
        messages.append(message)
        onMessage?(message)
    }

    func controlClient(_ client: ControlClient, didCloseWith error: Error?) {
        didClose = true
        closeError = error
        onClose?(error)
    }
}

final class ControlClientTests: XCTestCase {

    /// Connects a pinned transport to the mock and returns the wired-up client.
    private func makeAuthenticatedClient(
        _ server: MockWindowsServerProcess,
        delegate: RecordingDelegate,
        pingInterval: TimeInterval = SharedMicProtocol.pingInterval,
        peerDeadTimeout: TimeInterval = SharedMicProtocol.peerDeadTimeout
    ) throws -> (ControlClient, PinnedTLSTransport) {
        let transport = PinnedTLSTransport()
        let connected = expectation(description: "tls connected")
        transport.connect(host: "127.0.0.1", port: server.port,
                          mode: .pinned(fingerprint: server.fingerprint)) { result in
            if case .failure(let error) = result { XCTFail("handshake failed: \(error)") }
            connected.fulfill()
        }
        wait(for: [connected], timeout: 15.0)

        let client = ControlClient(transport: transport,
                                   token: server.token,
                                   clientId: "mac-tests",
                                   pingInterval: pingInterval,
                                   peerDeadTimeout: peerDeadTimeout)
        client.delegate = delegate
        let authenticated = expectation(description: "authenticated")
        delegate.onAuthenticate = { authenticated.fulfill() }
        client.begin()
        wait(for: [authenticated], timeout: 15.0)
        return (client, transport)
    }

    /// protocol-v1 §6: GREETING -> HELLO -> HELLO_ACK over a real TLS connection.
    func testCompletesTheHandshakeAgainstTheMock() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        XCTAssertTrue(client.isAuthenticated)
        XCTAssertEqual(delegate.authenticated?.micPresent, true)
        XCTAssertEqual(delegate.authenticated?.deviceLabel, "Mock USB Mic")
    }

    func testWrongTokenFailsToAuthenticate() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }

        let transport = PinnedTLSTransport()
        defer { transport.close() }
        let connected = expectation(description: "tls connected")
        transport.connect(host: "127.0.0.1", port: server.port,
                          mode: .pinned(fingerprint: server.fingerprint)) { _ in connected.fulfill() }
        wait(for: [connected], timeout: 15.0)

        let delegate = RecordingDelegate()
        let closed = expectation(description: "closed")
        delegate.onClose = { _ in closed.fulfill() }
        delegate.onAuthenticate = { XCTFail("a wrong token must never authenticate") }

        let client = ControlClient(transport: transport,
                                   token: Data(repeating: 0xee, count: 32),
                                   clientId: "mac-tests")
        client.delegate = delegate
        client.begin()
        wait(for: [closed], timeout: 15.0)
        XCTAssertFalse(client.isAuthenticated)
    }

    func testPingGetsAMatchingPong() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        // 0.3 s heartbeat so the loop is observable inside a test.
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate,
                                                              pingInterval: 0.3, peerDeadTimeout: 30.0)
        defer { client.stop(); transport.close() }

        let stillAlive = expectation(description: "heartbeat kept running")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { stillAlive.fulfill() }
        wait(for: [stillAlive], timeout: 5.0)

        // A mismatched PONG would have been a protocol violation that closed the
        // connection, so surviving several heartbeat rounds is the assertion.
        XCTAssertFalse(delegate.didClose, "the heartbeat closed the connection: \(String(describing: delegate.closeError))")
        XCTAssertTrue(client.isAuthenticated)
    }

    func testDeadPeerIsDetected() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate,
                                                              pingInterval: 30.0, peerDeadTimeout: 1.0)
        defer { client.stop(); transport.close() }

        let closed = expectation(description: "peer declared dead")
        delegate.onClose = { error in
            XCTAssertEqual(error as? ControlClientError, .peerDead)
            closed.fulfill()
        }
        wait(for: [closed], timeout: 10.0)
    }

    /// protocol-v1 §5: STATUS is unsolicited and must not be swallowed by the
    /// reply path.
    func testUnsolicitedStatusIsDelivered() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        let gotStatus = expectation(description: "status delivered")
        delegate.onMessage = { message in
            if case .status(let micPresent, _, _) = message, micPresent == false {
                gotStatus.fulfill()
            }
        }
        server.setMicPresent(false)
        wait(for: [gotStatus], timeout: 10.0)
    }

    func testStartAndStopExchange() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        var sessionId: String?
        let started = expectation(description: "START_ACK")
        delegate.onMessage = { message in
            if case .startAck(_, let id, let format) = message {
                sessionId = id
                XCTAssertEqual(format, .v1)
                started.fulfill()
            }
        }
        client.send(.start(requestId: "req-1", preferredFormat: .v1))
        wait(for: [started], timeout: 10.0)

        let stopped = expectation(description: "STOP_ACK")
        delegate.onMessage = { message in
            if case .stopAck(let requestId, _) = message, requestId == "req-2" {
                stopped.fulfill()
            }
        }
        client.send(.stop(requestId: "req-2", sessionId: try XCTUnwrap(sessionId)))
        wait(for: [stopped], timeout: 10.0)
    }

    /// protocol-v1 §7, the project's core privacy guarantee, asserted from the
    /// Mac side: an idle authenticated connection carries zero audio bytes.
    func testIdleConnectionCarriesZeroAudioBytes() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        let settled = expectation(description: "idle period elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        XCTAssertEqual(client.audioFramesReceived, 0)
        XCTAssertEqual(client.audioBytesReceived, 0)
    }

    func testAudioFlowsOnlyBetweenStartAndStop() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        var sessionId = ""
        let started = expectation(description: "START_ACK")
        delegate.onMessage = { message in
            if case .startAck(_, let id, _) = message {
                sessionId = id
                started.fulfill()
            }
        }
        client.send(.start(requestId: "req-1", preferredFormat: .v1))
        wait(for: [started], timeout: 10.0)

        let streaming = expectation(description: "audio arrived")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { streaming.fulfill() }
        wait(for: [streaming], timeout: 5.0)
        XCTAssertGreaterThan(client.audioFramesReceived, 10, "expected ~50 frames/second")
        XCTAssertEqual(client.audioBytesReceived,
                       client.audioFramesReceived * SharedMicProtocol.audioPCMBytes)
        XCTAssertEqual(client.sequenceGaps, 0)

        let stopped = expectation(description: "STOP_ACK")
        delegate.onMessage = { message in
            if case .stopAck = message { stopped.fulfill() }
        }
        client.send(.stop(requestId: "req-2", sessionId: sessionId))
        wait(for: [stopped], timeout: 10.0)

        // Let the socket settle, then assert the count stops moving. protocol-v1 §7
        // tolerates at most one frame already inside sendall() at STOP_ACK time.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 5.0)
        let afterStop = client.audioFramesReceived

        let quiet = expectation(description: "quiet")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { quiet.fulfill() }
        wait(for: [quiet], timeout: 5.0)
        XCTAssertEqual(client.audioFramesReceived, afterStop, "audio continued after STOP_ACK")
    }

    /// protocol-v1 §4: audio `sequence` "starts at 0 per session". Regression
    /// test for a false-positive gap count: `lastSequence` used to be
    /// connection-lifetime state, so the first AUDIO frame of a restarted
    /// session (legitimately 0) was compared against the previous session's
    /// tail and miscounted as a gap. Mirrors the harness's
    /// `test_full_lifecycle_leaves_no_sequence_gaps` / `test_session_can_be_restarted`.
    func testSequenceGapsAreNotFalselyCountedAcrossASessionRestart() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        func runOneSessionCycle(index: Int) {
            var sessionId = ""
            let started = expectation(description: "START_ACK \(index)")
            delegate.onMessage = { message in
                if case .startAck(_, let id, _) = message {
                    sessionId = id
                    started.fulfill()
                }
            }
            client.send(.start(requestId: "start-\(index)", preferredFormat: .v1))
            wait(for: [started], timeout: 10.0)

            let streaming = expectation(description: "audio arrived \(index)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { streaming.fulfill() }
            wait(for: [streaming], timeout: 5.0)

            let stopped = expectation(description: "STOP_ACK \(index)")
            delegate.onMessage = { message in
                if case .stopAck = message { stopped.fulfill() }
            }
            client.send(.stop(requestId: "stop-\(index)", sessionId: sessionId))
            wait(for: [stopped], timeout: 10.0)
        }

        runOneSessionCycle(index: 1)
        runOneSessionCycle(index: 2)

        XCTAssertGreaterThan(client.audioFramesReceived, 20, "expected audio frames from both sessions")
        XCTAssertEqual(client.sequenceGaps, 0,
                       "a legitimate session restart on the same connection must not be counted as a gap")
    }

    /// protocol-v1 §5/§8: a session can also end via an unsolicited
    /// `STATUS{micPresent:false}` (mic hot-unplug), which sends no `STOP_ACK`.
    /// The reference mock's `_end_session_for_mic_loss` deliberately does not
    /// join the audio thread first, so a straggler frame from the dying
    /// session can legitimately land *after* that `STATUS` — unlike
    /// `STOP_ACK`, this path cannot be trusted as a reset anchor. This is the
    /// regression test for the `sequence == 0` rule in `handleAudio` that
    /// covers it instead: mic loss mid-session, mic returns, a second session
    /// starts and streams audio, and the restart must not be miscounted as a
    /// gap.
    func testSequenceGapsAreNotFalselyCountedAfterMicLossAndReplug() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let delegate = RecordingDelegate()
        let (client, transport) = try makeAuthenticatedClient(server, delegate: delegate)
        defer { client.stop(); transport.close() }

        let started1 = expectation(description: "START_ACK 1")
        delegate.onMessage = { message in
            if case .startAck = message { started1.fulfill() }
        }
        client.send(.start(requestId: "start-1", preferredFormat: .v1))
        wait(for: [started1], timeout: 10.0)

        let streaming1 = expectation(description: "audio arrived 1")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { streaming1.fulfill() }
        wait(for: [streaming1], timeout: 5.0)
        XCTAssertGreaterThan(client.audioFramesReceived, 10, "expected audio before mic loss")

        let lost = expectation(description: "STATUS micPresent=false")
        delegate.onMessage = { message in
            if case .status(let micPresent, _, _) = message, micPresent == false {
                lost.fulfill()
            }
        }
        server.setMicPresent(false)
        wait(for: [lost], timeout: 10.0)

        let restored = expectation(description: "STATUS micPresent=true")
        delegate.onMessage = { message in
            if case .status(let micPresent, _, _) = message, micPresent == true {
                restored.fulfill()
            }
        }
        server.setMicPresent(true)
        wait(for: [restored], timeout: 10.0)

        let started2 = expectation(description: "START_ACK 2")
        delegate.onMessage = { message in
            if case .startAck = message { started2.fulfill() }
        }
        client.send(.start(requestId: "start-2", preferredFormat: .v1))
        wait(for: [started2], timeout: 10.0)

        let streaming2 = expectation(description: "audio arrived 2")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { streaming2.fulfill() }
        wait(for: [streaming2], timeout: 5.0)

        XCTAssertGreaterThan(client.audioFramesReceived, 20, "expected audio frames from both sessions")
        XCTAssertEqual(client.sequenceGaps, 0,
                       "a session restarted after mic loss must not be counted as a gap")
    }
}
