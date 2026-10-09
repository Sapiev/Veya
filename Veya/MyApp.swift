import AppKit
import SpotCoreKit
import SwiftUI

@main struct MyApp: App {
    /// One window and one session per app, restored exactly once at launch.
    @State private var session: SessionModel
    @State private var signIn: SignInModel
    @State private var systemEvents: SystemEvents
    @State private var signOutFailed = false
    private let artworkLoader: ArtworkLoader?
    private let metadataStore: MetadataStore?

    init() {
        Diagnostics.startLogging()
        let dependencies = AppDependencies.make()
        artworkLoader = dependencies.artworkLoader
        metadataStore = dependencies.metadataStore
        let session = SessionModel(
            store: dependencies.store,
            refreshTokenStore: dependencies.refreshTokenStore,
            connector: dependencies.connector
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
        _signIn = State(initialValue: SignInModel(browser: dependencies.browser, startFlow: dependencies.startFlow))
        _systemEvents = State(initialValue: SystemEvents(
            onWake: { session.systemDidWake() },
            onNetworkChange: { session.networkChanged(available: $0) }
        ))
    }

    var body: some Scene {
        Window("Veya", id: "main") {
            ContentView(session: session, signIn: signIn, metadataStore: metadataStore) {
                AccountCommands.signOut(session, failed: $signOutFailed)
            }
            .environment(\.artworkLoader, artworkLoader)
            .alert("Couldn't Sign Out Completely", isPresented: $signOutFailed) {
                Button("Try Again") { AccountCommands.signOut(session, failed: $signOutFailed) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The saved sign-in is still in the Keychain, so Veya may sign in again at launch.")
            }
        }
        .commands {
            AccountCommands(session: session, signOutFailed: $signOutFailed)
            NavigationCommands()
            CommandGroup(after: .help) {
                Button("Export Diagnostics…") {
                    Task { await Diagnostics.export() }
                }
            }
        }
    }
}

private struct AccountCommands: Commands {
    let session: SessionModel
    @Binding var signOutFailed: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Account") {
            Button("Sign Out") {
                openWindow(id: "main")
                Self.signOut(session, failed: $signOutFailed)
            }
            .disabled(session.state == .signedOut)
        }
    }

    /// Raised on the next turn: an alert button's own action can reset its flag.
    @MainActor
    static func signOut(_ session: SessionModel, failed: Binding<Bool>) {
        do {
            try session.signOut()
        } catch {
            Task { @MainActor in failed.wrappedValue = true }
        }
    }
}
