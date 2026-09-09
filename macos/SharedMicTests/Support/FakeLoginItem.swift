import Foundation
@testable import SharedMic

/// Test double for `LoginItemControl`. The suite never touches the real
/// login-item registry.
final class FakeLoginItem: LoginItemControl {
    struct ToggleFailure: Error {}

    var enabled: Bool
    var shouldThrow = false

    init(enabled: Bool = false) {
        self.enabled = enabled
    }

    var isEnabled: Bool { enabled }

    func setEnabled(_ enabled: Bool) throws {
        if shouldThrow { throw ToggleFailure() }
        self.enabled = enabled
    }
}
