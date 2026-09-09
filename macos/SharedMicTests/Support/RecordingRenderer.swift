import Foundation
@testable import SharedMic

/// Test double for `RendererControl`, shared by the wiring tests. Thread-safe:
/// the coordinator calls it from the renderer queue while tests read from the
/// test thread. Unbounded on purpose — overflow accounting belongs to the
/// real renderer's bridge, which has its own tests.
final class RecordingRenderer: RendererControl {
    private let lock = NSLock()
    private var _opened = 0
    private var _drained = 0
    private var _finalized = 0
    private var _enqueued: [Data] = []
    private var _open = false
    var openError: Error?

    var opened: Int { synchronized { _opened } }
    var drained: Int { synchronized { _drained } }
    var finalized: Int { synchronized { _finalized } }
    var enqueuedPCM: [Data] { synchronized { _enqueued } }
    var isOpen: Bool { synchronized { _open } }
    var stubPeak: Float = 0

    func open() throws {
        if let error = openError { throw error }
        synchronized { _opened += 1; _open = true }
    }

    func enqueue(pcm: Data) {
        synchronized { _enqueued.append(pcm) }
    }

    func closeAfterDrain() {
        synchronized { _drained += 1 }
    }

    func finalizeClose() {
        synchronized { _finalized += 1; _open = false }
    }

    func takeRenderedPeak() -> Float { synchronized { stubPeak } }

    private func synchronized<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
