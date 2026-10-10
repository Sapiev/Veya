import AppKit
import SpotCoreKit
import SwiftUI

@main struct MyApp: App {
    /// One window and one session per app, restored exactly once at launch.
    @State private var session: SessionModel
    @State private var signIn: SignInModel
    @State private var webAPI: WebAPIConnection
    @State private var systemEvents: SystemEvents
    @State private var signOutFailed = false
    private let artworkLoader: ArtworkLoader?
    private let metadataStore: MetadataStore?
    @State private var recentSearches: RecentSearches
    /// One instance, so Settings window edits reach the live player.
    @State private var settings: PlaybackSettings
    private let defaults: UserDefaults
    private let episodeProgress: any EpisodeProgressProvider

    init() {
        let dependencies = AppDependencies.make()
        defaults = dependencies.defaults
        Diagnostics.startLogging(level: Diagnostics.savedLevel(in: dependencies.defaults))
        _settings = State(initialValue: PlaybackSettings(defaults: dependencies.defaults))
        artworkLoader = dependencies.artworkLoader
        metadataStore = dependencies.metadataStore
        _recentSearches = State(initialValue: RecentSearches(defaults: dependencies.defaults))
        let session = SessionModel(
            store: dependencies.store,
            refreshTokenStore: dependencies.refreshTokenStore,
            connector: dependencies.connector
        )
        session.restore()
        let webAPI = WebAPIConnection(
            store: dependencies.refreshTokenStore,
            defaults: dependencies.defaults,
            browser: dependencies.browser,
            startFlow: dependencies.webAPIStartFlow,
            refresher: dependencies.tokenRefresher
        )
        _webAPI = State(initialValue: webAPI)
        let tokens = webAPI.tokens
        episodeProgress = dependencies.episodeProgress ?? WebAPIEpisodeProgress { try await tokens.accessToken() }
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
            ContentView(
                session: session,
                signIn: signIn,
                webAPI: webAPI,
                metadataStore: metadataStore,
                recentSearches: recentSearches,
                settings: settings,
                episodeProgress: episodeProgress
            ) {
                AccountCommands.signOut(session, failed: $signOutFailed)
            }
            .environment(\.artworkLoader, artworkLoader)
            .defaultAppStorage(defaults)
            .alert("Couldn't Sign Out Completely", isPresented: $signOutFailed) {
                Button("Try Again") { AccountCommands.signOut(session, failed: $signOutFailed) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The saved sign-in is still in the Keychain, so Veya may sign in again at launch.")
            }
        }
        // The ambient wash runs under the traffic lights; the sidebar panel and floating capsules are the chrome.
        .windowStyle(.hiddenTitleBar)
        .commands {
            AccountCommands(session: session, signOutFailed: $signOutFailed)
            NavigationCommands()
            CommandGroup(after: .help) {
                Button("Export Diagnostics…") {
                    Task { await Diagnostics.export() }
                }
            }
        }

        Settings {
            SettingsView(session: session, webAPI: webAPI, settings: settings) {
                AccountCommands.signOut(session, failed: $signOutFailed)
            }
            .defaultAppStorage(defaults)
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
