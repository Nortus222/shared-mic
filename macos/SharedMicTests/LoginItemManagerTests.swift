import XCTest
@testable import SharedMic

final class FakeLoginItemService: LoginItemService {
    var registered: Bool
    var registerCalls = 0
    var unregisterCalls = 0
    var errorToThrow: Error?

    init(registered: Bool = false) {
        self.registered = registered
    }

    var isRegistered: Bool { registered }

    func register() throws {
        registerCalls += 1
        if let error = errorToThrow { throw error }
        registered = true
    }

    func unregister() throws {
        unregisterCalls += 1
        if let error = errorToThrow { throw error }
        registered = false
    }
}

final class LoginItemManagerTests: XCTestCase {
    func testSetEnabledRegistersOnce() throws {
        let fake = FakeLoginItemService(registered: false)
        let manager = LoginItemManager(service: fake)
        XCTAssertFalse(manager.isEnabled)
        try manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertEqual(fake.registerCalls, 1)
    }

    func testSetEnabledIsIdempotent() throws {
        let fake = FakeLoginItemService(registered: true)
        let manager = LoginItemManager(service: fake)
        try manager.setEnabled(true)
        XCTAssertEqual(fake.registerCalls, 0)
        try manager.setEnabled(false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertEqual(fake.unregisterCalls, 1)
        try manager.setEnabled(false)
        XCTAssertEqual(fake.unregisterCalls, 1)
    }

    func testRegisterErrorPropagates() {
        struct Boom: Error {}
        let fake = FakeLoginItemService(registered: false)
        fake.errorToThrow = Boom()
        let manager = LoginItemManager(service: fake)
        XCTAssertThrowsError(try manager.setEnabled(true))
    }
}

@MainActor
final class LoginLaunchAppModelTests: XCTestCase {
    private func quietModel(loginService: FakeLoginItemService) -> AppModel {
        let fake = FakeCoreAudioQuery()
        return AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false,
                        demandSettings: InMemoryDemandSettingsStore(),
                        makeObserver: { onChange in
                            AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
                        },
                        readSystemInput: { nil },
                        loginItems: LoginItemManager(service: loginService))
    }

    func testInitialStateReflectsService() {
        let service = FakeLoginItemService(registered: true)
        let model = quietModel(loginService: service)
        XCTAssertTrue(model.loginLaunchEnabled)
    }

    func testToggleUpdatesPublishedState() {
        let service = FakeLoginItemService(registered: false)
        let model = quietModel(loginService: service)
        XCTAssertFalse(model.loginLaunchEnabled)
        model.setLoginLaunch(true)
        XCTAssertTrue(model.loginLaunchEnabled)
        model.setLoginLaunch(false)
        XCTAssertFalse(model.loginLaunchEnabled)
    }

    func testToggleFailureSurfacesNotice() {
        struct Boom: Error {}
        let service = FakeLoginItemService(registered: false)
        service.errorToThrow = Boom()
        let model = quietModel(loginService: service)
        model.setLoginLaunch(true)
        XCTAssertFalse(model.loginLaunchEnabled)
        XCTAssertNotNil(model.lastNotice)
    }
}
