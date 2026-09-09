import Foundation
import ServiceManagement

/// Launch-at-login seam (spec §2.1, Phase 4 Task 5). The live implementation
/// registers this app itself via SMAppService; tests inject a fake so the
/// suite never touches the real login-item registry. Enabling is explicit
/// (the menu toggle); resuming a stored pairing afterwards is silent via the
/// existing `startIfPaired()` launch path.
public protocol LoginItemControl: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

public final class LoginItemManager: LoginItemControl {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
