import SwiftUI

@main
struct SharedMicApp: App {
    @StateObject private var model = AppModel(store: SharedMicApp.pairingStore())

    /// Under `xcodebuild test` the test host IS this app binary, so a plain
    /// `AppModel()` would read the real login keychain on every test launch.
    /// Each rebuild re-signs ad-hoc, invalidating the approval, which is why
    /// the prompt reappeared every run. The suite must never touch the
    /// keychain (except the owner-gated `SHAREDMIC_TEST_KEYCHAIN=1` run), so
    /// the test host gets a memory store. Shipping launches are unaffected.
    static func pairingStore() -> PairingStore {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil {
            return InMemoryPairingStore()
        }
        return KeychainPairingStore()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: labelSymbol)
        }
        // `.window` rather than the default `.menu`: the pairing form contains
        // TextFields, which a menu-style MenuBarExtra cannot host.
        .menuBarExtraStyle(.window)
    }

    private var labelSymbol: String {
        switch model.state {
        case .streaming: return "mic.fill"
        case .hardStop: return "mic.slash.fill"
        default: return "mic"
        }
    }
}
