import SwiftUI

@main
struct SharedMicApp: App {
    var body: some Scene {
        MenuBarExtra("SharedMic", systemImage: "mic") {
            Button("Quit SharedMic") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
