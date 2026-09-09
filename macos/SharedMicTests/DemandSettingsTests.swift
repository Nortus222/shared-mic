import XCTest
@testable import SharedMic

final class DemandSettingsTests: XCTestCase {
    func testDefaultsMatchSpec() {
        let settings = DemandSettings()
        XCTAssertFalse(settings.disabled)
        XCTAssertEqual(settings.stopDebounceMs, 1000)
        XCTAssertEqual(settings.holdSeconds, 1800, accuracy: 0.001)
    }

    func testDebounceClampsTo500Through2000() {
        XCTAssertEqual(DemandSettings(stopDebounceMs: 499).stopDebounceMs, 500)
        XCTAssertEqual(DemandSettings(stopDebounceMs: 2001).stopDebounceMs, 2000)
        XCTAssertEqual(DemandSettings(stopDebounceMs: 750).stopDebounceMs, 750)
    }

    func testDisabledRoundTripsThroughTheStore() {
        let store = InMemoryDemandSettingsStore()
        var loaded = store.load()
        loaded.disabled = true
        store.save(loaded)
        XCTAssertTrue(store.load().disabled)
    }

    func testHoldActiveNeverPersists() {
        let store = InMemoryDemandSettingsStore()
        XCTAssertEqual(store.load(), DemandSettings())
    }

    func testUserDefaultsStoreRoundTrips() {
        let suite = UserDefaults(suiteName: "com.sharedmic.DemandSettingsTests")!
        suite.removePersistentDomain(forName: "com.sharedmic.DemandSettingsTests")
        let store = UserDefaultsDemandSettingsStore(defaults: suite)
        XCTAssertFalse(store.load().disabled)
        store.save(DemandSettings(disabled: true, stopDebounceMs: 750, holdSeconds: 600))
        let reloaded = UserDefaultsDemandSettingsStore(defaults: suite).load()
        XCTAssertTrue(reloaded.disabled)
        XCTAssertEqual(reloaded.stopDebounceMs, 750)
        XCTAssertEqual(reloaded.holdSeconds, 600, accuracy: 0.001)
        suite.removePersistentDomain(forName: "com.sharedmic.DemandSettingsTests")
    }
}
