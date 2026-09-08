import SwiftUI

@main
struct SharedMicApp: App {
    @StateObject private var model = AppModel()

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
