import Foundation

/// Locates repository files from the test bundle.
///
/// `#filePath` is the absolute path of THIS source file at compile time:
/// `<repo>/macos/SharedMicTests/Support/RepositoryPaths.swift`. Four
/// `deletingLastPathComponent()` calls walk Support -> SharedMicTests -> macos ->
/// repository root. Using the source tree rather than a copied resource bundle
/// means the tests read the same committed vector files the Python harness does,
/// so the two can never silently drift apart.
enum RepositoryPaths {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // SharedMicTests
            .deletingLastPathComponent()   // macos
            .deletingLastPathComponent()   // repository root
    }

    static var vectorsDirectory: URL {
        root.appendingPathComponent("protocol/vectors", isDirectory: true)
    }

    static var harnessDirectory: URL {
        root.appendingPathComponent("harness", isDirectory: true)
    }

    /// There is no bare `python` on this machine and the system `python3` has no
    /// pytest — the harness virtualenv interpreter is the only usable one.
    static var pythonExecutable: URL {
        harnessDirectory.appendingPathComponent(".venv/bin/python")
    }
}
