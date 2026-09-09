import Foundation
@testable import SharedMic

/// Test double for `HostBrowser`. Scripted discoveries drive the model's
/// pairing-form list without touching the network.
final class FakeHostBrowser: HostBrowser {
    weak var delegate: HostBrowserDelegate?
    var started = 0
    var stopped = 0

    func start() { started += 1 }
    func stop() { stopped += 1 }

    func simulateFind(_ host: DiscoveredHost) {
        delegate?.hostBrowser(self, didFind: host)
    }

    func simulateLose(name: String) {
        delegate?.hostBrowser(self, didLoseHostNamed: name)
    }
}
