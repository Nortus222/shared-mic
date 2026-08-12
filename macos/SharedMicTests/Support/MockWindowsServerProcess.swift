import Foundation
@testable import SharedMic

/// Launches the Phase 0 Python mock as a child process and exposes the values a
/// Swift client needs: the ephemeral port, the certificate fingerprint to pin,
/// and the pairing string a user would type.
///
/// `@testable import` is required rather than a plain import: `SharedMic` is an
/// application target, and the test bundle links against it as its BUNDLE_LOADER.
///
/// Every network test in this phase runs against this, which is why no Windows
/// machine is required to build the macOS agent.
final class MockWindowsServerProcess {
    enum LaunchError: Error, CustomStringConvertible {
        case interpreterMissing(String)
        case noHandshakeLine
        case malformedHandshakeLine(String)

        var description: String {
            switch self {
            case .interpreterMissing(let path):
                return "harness interpreter not found at \(path); see harness/README.md"
            case .noHandshakeLine:
                return "mock server exited before printing its handshake line"
            case .malformedHandshakeLine(let line):
                return "mock server printed an unreadable handshake line: \(line)"
            }
        }
    }

    let port: UInt16
    let fingerprint: String
    let pairingString: String
    let token: Data

    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private var terminated = false

    init(micPresent: Bool = true) throws {
        let interpreter = RepositoryPaths.pythonExecutable
        guard FileManager.default.isExecutableFile(atPath: interpreter.path) else {
            throw LaunchError.interpreterMissing(interpreter.path)
        }
        let script = RepositoryPaths.root
            .appendingPathComponent("macos/SharedMicTests/Support/mock_windows_server.py")

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        process = Process()
        process.executableURL = interpreter
        process.arguments = [script.path, RepositoryPaths.harnessDirectory.path, "0"]
        process.currentDirectoryURL = RepositoryPaths.root
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.standardError
        try process.run()

        // Read the single JSON handshake line, byte by byte so no bytes belonging
        // to later command acknowledgements are swallowed.
        let handle = stdoutPipe.fileHandleForReading
        var lineBytes = Data()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !process.isRunning { break }
                continue
            }
            lineBytes.append(chunk)
            if lineBytes.contains(0x0a) { break }
        }
        guard let newlineIndex = lineBytes.firstIndex(of: 0x0a) else {
            process.terminate()
            throw LaunchError.noHandshakeLine
        }
        let line = String(decoding: lineBytes[lineBytes.startIndex..<newlineIndex], as: UTF8.self)
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let portNumber = (object["port"] as? NSNumber)?.intValue,
              let fingerprint = object["fingerprint"] as? String,
              let pairing = object["pairing"] as? String,
              let tokenHex = object["tokenHex"] as? String,
              let token = Hex.decode(tokenHex) else {
            process.terminate()
            throw LaunchError.malformedHandshakeLine(line)
        }

        self.port = UInt16(truncatingIfNeeded: portNumber)
        self.fingerprint = fingerprint
        self.pairingString = pairing
        self.token = token

        if !micPresent {
            setMicPresent(false)
        }
    }

    func setMicPresent(_ present: Bool) {
        write(present ? "micon" : "micoff")
        // The mock notifies connected peers synchronously on the command thread;
        // a short settle keeps the assertion that follows from racing the STATUS.
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// Closes every live connection without stopping the listener — a simulated
    /// network drop that the agent must recover from with backoff.
    func dropConnections() {
        write("drop")
        Thread.sleep(forTimeInterval: 0.1)
    }

    func terminate() {
        guard !terminated else { return }
        terminated = true
        write("quit")
        stdinPipe.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    private func write(_ command: String) {
        guard process.isRunning else { return }
        stdinPipe.fileHandleForWriting.write(Data("\(command)\n".utf8))
    }

    deinit {
        terminate()
    }
}
