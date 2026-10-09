import AppKit
import SpotCoreKit
import SwiftUI

@main struct MyApp: App {
    /// One window and one session per app, restored exactly once at launch.
    @State private var session: SessionModel
    @State private var signIn = SignInModel(browser: WebAuthenticationBrowser())

    init() {
        Diagnostics.startLogging()
        let session = SessionModel(
            store: KeychainCredentialStore(
                service: Bundle.main.bundleIdentifier ?? "Veya",
                account: "spotcore-credentials"
            )
        )
        session.restore()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { session.shutdown() }
        }
        _session = State(initialValue: session)
    }

    var body: some Scene {
        Window("Veya", id: "main") {
            ContentView(session: session, signIn: signIn)
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
