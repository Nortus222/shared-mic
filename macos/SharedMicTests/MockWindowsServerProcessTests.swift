import XCTest
import Network
@testable import SharedMic

final class MockWindowsServerProcessTests: XCTestCase {
    func testHarnessInterpreterAndModulesArePresent() {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: RepositoryPaths.pythonExecutable.path),
                      "harness/.venv/bin/python is missing — see harness/README.md")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: RepositoryPaths.harnessDirectory.appendingPathComponent("sharedmic_protocol/server.py").path))
    }

    func testStartsAndPublishesItsPortFingerprintAndPairingString() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }

        XCTAssertGreaterThan(server.port, 0)
        XCTAssertEqual(server.fingerprint.count, 64)
        XCTAssertEqual(server.fingerprint, server.fingerprint.lowercased())
        XCTAssertNotNil(Hex.decode(server.fingerprint))
        XCTAssertEqual(server.pairingString.count, SharedMicProtocol.pairingStringLength)
        XCTAssertEqual(server.token.count, SharedMicProtocol.tokenBytes)
    }

    /// The pairing string the mock prints is the one a user would type, and it
    /// must decode to the token the mock actually authenticates against.
    func testPairingStringDecodesToTheServersToken() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        XCTAssertEqual(try PairingString.decode(server.pairingString), server.token)
    }

    func testEachInstanceGetsAFreshCertificateAndPort() throws {
        let first = try MockWindowsServerProcess()
        defer { first.terminate() }
        let second = try MockWindowsServerProcess()
        defer { second.terminate() }
        XCTAssertNotEqual(first.fingerprint, second.fingerprint)
        XCTAssertNotEqual(first.port, second.port)
    }

    func testAcceptsATCPConnectionOnItsPort() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }

        let connected = expectation(description: "tcp connect")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: server.port),
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "test.tcp"))
        wait(for: [connected], timeout: 5.0)
        connection.cancel()
    }

    func testControlCommandsDoNotKillTheServer() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        server.setMicPresent(false)
        server.setMicPresent(true)
        server.dropConnections()

        // Still listening after all three commands.
        let connected = expectation(description: "tcp connect after commands")
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: server.port),
            using: .tcp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        connection.start(queue: DispatchQueue(label: "test.tcp.after"))
        wait(for: [connected], timeout: 5.0)
        connection.cancel()
    }
}
