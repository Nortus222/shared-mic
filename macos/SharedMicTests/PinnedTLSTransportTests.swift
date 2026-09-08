import XCTest
@testable import SharedMic

final class PinnedTLSTransportTests: XCTestCase {

    private func connect(_ transport: PinnedTLSTransport,
                         to server: MockWindowsServerProcess,
                         mode: PinningMode,
                         timeout: TimeInterval = 10.0) -> Result<String, Error> {
        let finished = expectation(description: "connect completed")
        var outcome: Result<String, Error>!
        transport.connect(host: "127.0.0.1", port: server.port, mode: mode, timeout: timeout) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: timeout + 10.0)
        return outcome
    }

    /// protocol-v1 §2 and §11.3: a self-signed EC P-256 certificate with no CA
    /// anywhere must complete a TLS 1.3 handshake when its fingerprint matches.
    func testConnectsWhenTheFingerprintMatches() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let result = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint))
        switch result {
        case .success(let presented):
            XCTAssertEqual(presented, server.fingerprint)
        case .failure(let error):
            XCTFail("expected a successful pinned handshake, got \(error)")
        }
    }

    func testTrustOnFirstUseReportsThePresentedFingerprint() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let result = connect(transport, to: server, mode: .trustOnFirstUse)
        switch result {
        case .success(let presented):
            XCTAssertEqual(presented, server.fingerprint)
            XCTAssertEqual(presented.count, 64)
        case .failure(let error):
            XCTFail("trust-on-first-use should not fail, got \(error)")
        }
    }

    /// The single most important test in this phase. A mismatch must surface as a
    /// mismatch — quickly, and without Network.framework quietly retrying.
    func testFingerprintMismatchIsAHardStop() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let wrong = String(repeating: "00", count: 32)
        let started = Date()
        let result = connect(transport, to: server, mode: .pinned(fingerprint: wrong), timeout: 10.0)

        switch result {
        case .success:
            XCTFail("a mismatched pin must never produce a usable connection")
        case .failure(let error):
            XCTAssertEqual(
                error as? TransportError,
                .fingerprintMismatch(expected: wrong, presented: server.fingerprint)
            )
        }
        // Must fail fast rather than sit in NWConnection's `.waiting` retry loop.
        XCTAssertLessThan(Date().timeIntervalSince(started), 9.0)
    }

    func testMismatchDoesNotRetryOnItsOwn() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        var closeCallbacks = 0
        transport.onClose = { _ in closeCallbacks += 1 }
        _ = connect(transport, to: server, mode: .pinned(fingerprint: String(repeating: "11", count: 32)))

        // Give NWConnection ample time to attempt a retry of its own accord.
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        // The transport reported the failure exactly once, through `connect`'s
        // completion, and never re-entered the handshake.
        XCTAssertEqual(closeCallbacks, 0)
    }

    func testFingerprintComparisonIsCaseInsensitiveOnTheStoredValue() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let result = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint.uppercased()))
        guard case .success = result else {
            return XCTFail("an uppercased pin of the same certificate must still match")
        }
    }

    func testReceivesTheGreetingBytesTheServerSendsImmediately() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let received = expectation(description: "greeting bytes")
        var bytes = Data()
        transport.onReceive = { chunk in
            bytes.append(chunk)
            if bytes.count >= 5 { received.fulfill() }
        }
        guard case .success = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint)) else {
            return XCTFail("handshake failed")
        }
        wait(for: [received], timeout: 10.0)

        // protocol-v1 §6 step 1: the server greets immediately after the handshake.
        XCTAssertEqual(bytes.first, FrameType.control.rawValue)
        let frame = try XCTUnwrap(FrameCodec.decode(bytes))
        let message = try ControlCodec.decode(frame.payload)
        guard case .greeting(let serverId, let nonce) = message else {
            return XCTFail("expected GREETING, got \(message.typeName)")
        }
        XCTAssertEqual(serverId, "mock-win")
        XCTAssertEqual(nonce.count, 64)
    }

    /// The sibling test above installs `onReceive` *before* `connect()`, which no
    /// real caller does: `ConnectionCoordinator` only reaches
    /// `ControlClient.begin()` — and therefore only installs a handler — from
    /// `connect`'s completion, hopped onto its own queue. protocol-v1 §6 has the
    /// server send GREETING the instant the handshake finishes, so those bytes
    /// routinely land in that window. They must be buffered, not dropped: a
    /// dropped GREETING strands the handshake until the 5 s deadline and surfaces
    /// during pairing as a bogus "wrong token" failure.
    func testGreetingSurvivesAHandlerInstalledAfterConnectCompletes() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        guard case .success = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint)) else {
            return XCTFail("handshake failed")
        }

        // Give the GREETING every chance to arrive while no handler exists — the
        // window this test is about — rather than hoping to hit it by luck.
        let settled = expectation(description: "greeting is on the wire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        let received = expectation(description: "greeting bytes")
        var bytes = Data()
        transport.onReceive = { chunk in
            bytes.append(chunk)
            if bytes.count >= 5 { received.fulfill() }
        }
        wait(for: [received], timeout: 10.0)

        let frame = try XCTUnwrap(FrameCodec.decode(bytes))
        guard case .greeting = try ControlCodec.decode(frame.payload) else {
            return XCTFail("the buffered bytes were not the GREETING")
        }
    }

    /// The same window, for the close path. A close that lands before `onClose`
    /// is installed must still be delivered — latching it as "reported" would
    /// leave the `ControlClient` unable to ever learn the connection died.
    func testCloseThatLandsBeforeTheHandlerIsInstalledIsStillDelivered() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        guard case .success = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint)) else {
            return XCTFail("handshake failed")
        }
        server.dropConnections()

        let settled = expectation(description: "drop observed with no handler installed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5.0)

        let closed = expectation(description: "close delivered late")
        var closeCount = 0
        transport.onClose = { error in
            closeCount += 1
            XCTAssertNotNil(error, "an unexpected drop must be reported as an error")
            closed.fulfill()
        }
        wait(for: [closed], timeout: 10.0)

        // Exactly once: a buffered close must not also re-fire later.
        let quiet = expectation(description: "no second close")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { quiet.fulfill() }
        wait(for: [quiet], timeout: 5.0)
        XCTAssertEqual(closeCount, 1)
    }

    func testConnectingToAClosedPortFailsRatherThanHanging() {
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        let finished = expectation(description: "failed")
        var outcome: Result<String, Error>!
        // Port 1 is reserved and nothing listens on it.
        transport.connect(host: "127.0.0.1", port: 1, mode: .trustOnFirstUse, timeout: 5.0) { result in
            outcome = result
            finished.fulfill()
        }
        wait(for: [finished], timeout: 15.0)
        guard case .failure = outcome! else {
            return XCTFail("connecting to a closed port must fail")
        }
    }

    func testCloseReportsNilToOnClose() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()

        guard case .success = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint)) else {
            return XCTFail("handshake failed")
        }
        let closed = expectation(description: "closed")
        transport.onClose = { error in
            XCTAssertNil(error, "an intentional close is not an error")
            closed.fulfill()
        }
        transport.close()
        wait(for: [closed], timeout: 5.0)
    }

    func testPeerHangUpReportsAnErrorToOnClose() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let transport = PinnedTLSTransport()
        defer { transport.close() }

        guard case .success = connect(transport, to: server, mode: .pinned(fingerprint: server.fingerprint)) else {
            return XCTFail("handshake failed")
        }
        let closed = expectation(description: "peer hung up")
        transport.onClose = { error in
            XCTAssertNotNil(error, "an unexpected drop must be reported as an error")
            closed.fulfill()
        }
        server.dropConnections()
        wait(for: [closed], timeout: 10.0)
    }
}
