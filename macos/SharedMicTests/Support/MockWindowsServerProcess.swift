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
        case handshakeTimedOut(TimeInterval)
        case malformedHandshakeLine(String)

        var description: String {
            switch self {
            case .interpreterMissing(let path):
                return "harness interpreter not found at \(path); see harness/README.md"
            case .noHandshakeLine:
                return "mock server exited before printing its handshake line"
            case .handshakeTimedOut(let timeout):
                return "mock server did not print its handshake line within \(timeout)s " +
                    "(it may be hung importing sharedmic_protocol or generating its certificate)"
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

        // Read the single JSON handshake line. The read itself happens on a
        // background queue because `FileHandle.availableData` blocks with no
        // timeout of its own; the `semaphore.wait(timeout:)` below is what
        // actually bounds the wait, regardless of whether the child ever
        // writes anything. Without this, a child hung between `process.run()`
        // and its handshake `print(...)` (e.g. stuck importing
        // sharedmic_protocol) would wedge `xcodebuild test` indefinitely —
        // XCTest has no default per-test timeout.
        let handle = stdoutPipe.fileHandleForReading
        let line: String
        do {
            line = try Self.readHandshakeLine(from: handle, timeout: Self.handshakeTimeout)
        } catch {
            // One shutdown path with one set of guarantees: even a
            // handshake failure tears the child down the same way
            // terminate() would, rather than a bare process.terminate().
            Self.shutdown(process: process, stdin: stdinPipe)
            throw error
        }
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let portNumber = (object["port"] as? NSNumber)?.intValue,
              let fingerprint = object["fingerprint"] as? String,
              let pairing = object["pairing"] as? String,
              let tokenHex = object["tokenHex"] as? String,
              let token = Hex.decode(tokenHex) else {
            Self.shutdown(process: process, stdin: stdinPipe)
            throw LaunchError.malformedHandshakeLine(line)
        }

        self.port = UInt16(truncatingIfNeeded: portNumber)
        self.fingerprint = fingerprint
        self.pairingString = pairing
        self.token = token

        // Drain everything the child writes to stdout from here on (the ack/
        // error JSON line for every micoff/micon/drop command). Nothing reads
        // it — no test asserts on ack contents — but if it goes unread the
        // pipe can eventually fill, which would block the child's
        // `print(..., flush=True)` and in turn stop it from reading further
        // stdin commands: a wedge with no test-visible cause. Discarding here
        // keeps the pipe from ever backing up.
        handle.readabilityHandler = { fh in
            _ = fh.availableData
        }

        if !micPresent {
            setMicPresent(false)
        }
    }

    private static let handshakeTimeout: TimeInterval = 30

    /// Reads up to and including the first `\n` on `handle`, bounding the
    /// total wait to `timeout` regardless of how long any individual
    /// `availableData` call blocks for.
    private static func readHandshakeLine(from handle: FileHandle, timeout: TimeInterval) throws -> String {
        final class Box { var data = Data() }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue(label: "mock-windows-server.handshake-read").async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }  // EOF: the child closed stdout without ever writing a line
                box.data.append(chunk)
                if box.data.contains(0x0a) { break }
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw LaunchError.handshakeTimedOut(timeout)
        }
        guard let newlineIndex = box.data.firstIndex(of: 0x0a) else {
            throw LaunchError.noHandshakeLine
        }
        return String(decoding: box.data[box.data.startIndex..<newlineIndex], as: UTF8.self)
    }

    /// The one place that knows how to shut the child down: ask nicely
    /// (`quit` on stdin), give it up to 5s to exit, then escalate to
    /// `Process.terminate()`. Used both by the instance `terminate()` and by
    /// every handshake-failure path in `init`, so there is exactly one set of
    /// shutdown guarantees no matter how far `init` got before failing.
    private static func shutdown(process: Process, stdin: Pipe) {
        if process.isRunning {
            stdin.fileHandleForWriting.write(Data("quit\n".utf8))
        }
        stdin.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            process.terminate()
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
        // Stop the stdout drain before tearing the child down so it can't
        // fire its callback against a handle whose process is gone.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        Self.shutdown(process: process, stdin: stdinPipe)
    }

    private func write(_ command: String) {
        guard process.isRunning else { return }
        stdinPipe.fileHandleForWriting.write(Data("\(command)\n".utf8))
    }

    deinit {
        terminate()
    }
}
