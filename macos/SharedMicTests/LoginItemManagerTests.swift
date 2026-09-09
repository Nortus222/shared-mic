import XCTest
@testable import SharedMic

/// Phase 4 Task 5: launch-at-login toggle. The fake stands in for
/// SMAppService; the live service is never touched in tests.
@MainActor
final class LoginItemManagerTests: XCTestCase {
    private func model(loginItem: FakeLoginItem) -> AppModel {
        let fake = FakeCoreAudioQuery()
        return AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false,
                        demandSettings: InMemoryDemandSettingsStore(),
                        makeObserver: { onChange in
                            AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
                        },
                        readSystemInput: { nil },
                        makeLoginItem: { loginItem })
    }

    func testLoginItemReflectsServiceStateAtLaunch() {
        XCTAssertTrue(model(loginItem: FakeLoginItem(enabled: true)).loginItemEnabled)
        XCTAssertFalse(model(loginItem: FakeLoginItem(enabled: false)).loginItemEnabled)
    }

    func testToggleEnablesAndDisables() {
        let loginItem = FakeLoginItem()
        let appModel = model(loginItem: loginItem)
        appModel.setLoginItemEnabled(true)
        XCTAssertTrue(appModel.loginItemEnabled)
        XCTAssertTrue(loginItem.enabled)
        appModel.setLoginItemEnabled(false)
        XCTAssertFalse(appModel.loginItemEnabled)
        XCTAssertFalse(loginItem.enabled)
    }

    func testToggleFailureSurfacesNoticeAndKeepsState() {
        let loginItem = FakeLoginItem()
        loginItem.shouldThrow = true
        let appModel = model(loginItem: loginItem)
        appModel.setLoginItemEnabled(true)
        XCTAssertFalse(appModel.loginItemEnabled)
        XCTAssertNotNil(appModel.lastNotice)
    }
}
