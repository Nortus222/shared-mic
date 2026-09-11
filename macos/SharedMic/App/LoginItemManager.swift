import Foundation
import ServiceManagement

/// Abstraction over `SMAppService.mainApp` so the toggle logic is unit
/// testable without touching the real login-item registry.
public protocol LoginItemService: AnyObject {
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

/// Production `SMAppService.mainApp` wrapper. Thin shell: no logic, only
/// forwarding, so there is nothing here that needs a unit test.
public final class SMAppServiceLoginItem: LoginItemService {
    public init() {}

    public var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

/// Login-launch toggle (spec §2.1: both agents launch at login).
///
/// `SMAppService.mainApp` needs no helper tool and no extra entitlement;
/// the app registers itself. Registration resolves the app by bundle ID to
/// its on-disk location, which is why the toggle only means something from
/// an installed copy in /Applications — from DerivedData or a translocated
/// image it registers a path that will not survive.
public final class LoginItemManager {
    private let service: LoginItemService

    public init(service: LoginItemService = SMAppServiceLoginItem()) {
        self.service = service
    }

    public var isEnabled: Bool {
        service.isRegistered
    }

    public func setEnabled(_ enabled: Bool) throws {
        guard enabled != service.isRegistered else { return }
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }
    }
}
