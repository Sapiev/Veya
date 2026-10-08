import SwiftUI

@main struct MyApp: App {
    init() {
        Diagnostics.startLogging()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .help) {
                Button("Export Diagnostics…") {
                    Task { await Diagnostics.export() }
                }
            }
        }
    }
}
