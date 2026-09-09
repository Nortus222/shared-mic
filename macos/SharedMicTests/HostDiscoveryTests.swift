import XCTest
@testable import SharedMic

/// Phase 4 Task 6: Bonjour discovery feeds the pairing form. The fake
/// browser stands in for NetServiceBrowser; manual entry always survives.
@MainActor
final class HostDiscoveryTests: XCTestCase {
    private func model(browser: FakeHostBrowser) -> AppModel {
        let fake = FakeCoreAudioQuery()
        return AppModel(store: InMemoryPairingStore(), clientId: "mac-tests", autoStart: false,
                        demandSettings: InMemoryDemandSettingsStore(),
                        makeObserver: { onChange in
                            AudioDemandObserver(query: fake, pollInterval: 0.02, onChange: onChange)
                        },
                        readSystemInput: { nil },
                        makeBrowser: { browser })
    }

    func testBrowsingStartsWhileUnpaired() {
        let browser = FakeHostBrowser()
        _ = model(browser: browser)
        XCTAssertEqual(browser.started, 1)
    }

    func testFoundHostsAppearAndLossRemoves() {
        let browser = FakeHostBrowser()
        let appModel = model(browser: browser)
        browser.simulateFind(DiscoveredHost(name: "DESKTOP-1", host: "192.168.1.10", port: 47899))
        browser.simulateFind(DiscoveredHost(name: "DESKTOP-2", host: "192.168.1.11", port: 47899))
        XCTAssertEqual(appModel.discoveredHosts.map(\.name), ["DESKTOP-1", "DESKTOP-2"])
        browser.simulateLose(name: "DESKTOP-1")
        XCTAssertEqual(appModel.discoveredHosts.map(\.name), ["DESKTOP-2"])
    }

    func testReannounceReplacesSameName() {
        let browser = FakeHostBrowser()
        let appModel = model(browser: browser)
        browser.simulateFind(DiscoveredHost(name: "DESKTOP-1", host: "192.168.1.10", port: 47899))
        browser.simulateFind(DiscoveredHost(name: "DESKTOP-1", host: "192.168.1.99", port: 47900))
        XCTAssertEqual(appModel.discoveredHosts.count, 1)
        XCTAssertEqual(appModel.discoveredHosts.first?.host, "192.168.1.99")
        XCTAssertEqual(appModel.discoveredHosts.first?.port, 47900)
    }

    func testSelectingAHostFillsTheForm() {
        let browser = FakeHostBrowser()
        let appModel = model(browser: browser)
        let host = DiscoveredHost(name: "DESKTOP-1", host: "192.168.1.10", port: 47899)
        browser.simulateFind(host)
        appModel.selectDiscoveredHost(host)
        XCTAssertEqual(appModel.hostField, "192.168.1.10")
        XCTAssertEqual(appModel.portField, "47899")
    }

    func testManualEntrySurvivesDiscoveryChurn() {
        let browser = FakeHostBrowser()
        let appModel = model(browser: browser)
        appModel.hostField = "10.0.0.9"
        appModel.portField = "48000"
        browser.simulateFind(DiscoveredHost(name: "DESKTOP-1", host: "192.168.1.10", port: 47899))
        browser.simulateLose(name: "DESKTOP-1")
        XCTAssertEqual(appModel.hostField, "10.0.0.9")
        XCTAssertEqual(appModel.portField, "48000")
    }

    func testPairingStopsBrowsing() throws {
        let server = try MockWindowsServerProcess()
        defer { server.terminate() }
        let browser = FakeHostBrowser()
        let appModel = model(browser: browser)
        appModel.hostField = "127.0.0.1"
        appModel.portField = String(server.port)
        appModel.pairingField = server.pairingString
        appModel.pair()
        let paired = expectation(description: "paired")
        func poll() {
            if appModel.state == .idle {
                paired.fulfill()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        poll()
        wait(for: [paired], timeout: 30.0)
        XCTAssertEqual(browser.stopped, 1)
        XCTAssertTrue(appModel.discoveredHosts.isEmpty)
    }

    /// The live browser starts and stops without crashing. No network
    /// assertions: CI machines may or may not have mDNS around.
    func testLiveBrowserStartStopSmoke() {
        let browser = BonjourHostBrowser()
        browser.start()
        browser.stop()
    }
}
