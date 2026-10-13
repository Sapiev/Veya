import AppIntents
import AppKit
import SpotCoreKit
import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    /// One window and one session per app, restored exactly once at launch.
    @State private var session: SessionModel
    @State private var activeSession: ActiveSession
    @State private var signIn: SignInModel
    @State private var webAPI: WebAPIConnection
    @State private var systemEvents: SystemEvents
    @State private var signOutFailed = false
    private let artworkLoader: ArtworkLoader?
    private let choosePhoto: (@MainActor () async -> URL?)?
    @State private var recentSearches: RecentSearches
    /// One instance, so Settings window edits reach the live player.
    @State private var settings: PlaybackSettings
    private let defaults: UserDefaults
    @State private var menuBar: MenuBarSettings

    init() {
        let dependencies = AppDependencies.make()
        defaults = dependencies.defaults
        _menuBar = State(initialValue: MenuBarSettings(defaults: dependencies.defaults))
        Diagnostics.startLogging(level: Diagnostics.savedLevel(in: dependencies.defaults))
        let settings = PlaybackSettings(defaults: dependencies.defaults)
        _settings = State(initialValue: settings)
        artworkLoader = dependencies.artworkLoader
        choosePhoto = dependencies.choosePhoto
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
        let episodeProgress = dependencies.episodeProgress ?? WebAPIEpisodeProgress { try await tokens.accessToken() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { session.shutdown() }
        }
        _session = State(initialValue: session)
        let defaults = dependencies.defaults
        let notifications = TrackNotifications { defaults.bool(forKey: SettingsView.trackNotificationsKey) }
        let controls = MediaControls(artworkLoader: dependencies.artworkLoader) { info, image in
            MediaControls.publishToSystem(info, image)
            notifications.update(info, image)
        }
        AppDelegate.controls = controls
        let activeSession = ActiveSession(session: session, controls: controls) { handle in
            SessionScope(
                handle: handle,
                metadataStore: dependencies.metadataStore,
                settings: settings,
                accessToken: { try await tokens.accessToken() },
                episodeProgress: episodeProgress
            ) {
                session.attach($0, startedOn: handle)
            }
        }
        _activeSession = State(initialValue: activeSession)
        let shortcuts = ShortcutActions(session: activeSession)
        AppDependencyManager.shared.add(dependency: shortcuts)
        AppleScript.actions = shortcuts
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
                activeSession: activeSession,
                signIn: signIn,
                webAPI: webAPI,
                recentSearches: recentSearches
            ) {
                AccountCommands.signOut(session, failed: $signOutFailed)
            }
            .environment(\.artworkLoader, artworkLoader)
            .transformEnvironment(\.choosePhoto) { if let choosePhoto { $0 = PhotoChooser(choose: choosePhoto) } }
            .defaultAppStorage(defaults)
            .onAppear { NSApp.setActivationPolicy(.regular) }
            .onDisappear { menuBar.windowClosed() }
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
            MainWindowCommands()
            PlaybackCommands(activeSession: activeSession)
            QuitCommand()
            HelpCommands()
        }

        Window("Keyboard Shortcuts", id: KeyboardShortcutsView.windowID) {
            KeyboardShortcutsView()
        }
        .windowResizability(.contentSize)
        // Help opens it; without this the Window menu lists it a second time.
        .commandsRemoved()

        Settings {
            SettingsView(session: session, webAPI: webAPI, settings: settings, menuBar: menuBar) {
                AccountCommands.signOut(session, failed: $signOutFailed)
            }
            .modifier(ConcreteInk())
            .defaultAppStorage(defaults)
        }

        MenuBarExtra(isInserted: $menuBar.shown) {
            MenuBarPlayer(activeSession: activeSession)
                .modifier(ScalesText())
                .modifier(ConcreteInk())
                .environment(\.artworkLoader, artworkLoader)
                .defaultAppStorage(defaults)
        } label: {
            MenuBarLabel(activeSession: activeSession, showsTitle: menuBar.showsTitle)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Playback and the media keys outlive the window, as in Music.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    static var quitRequested = false
    static var controls: MediaControls?

    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        Self.controls.map(DockMenu.make)
    }

    /// SwiftUI answers AppKit's after-last-window-closed check with yes for a single
    /// `Window` app, without asking this delegate. Only the Quit command or a quit
    /// event (Dock, logout, scripts) ends the app.
    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {

        let event = NSAppleEventManager.shared().currentAppleEvent
        let quitEvent = event?.eventClass == kCoreEventClass && event?.eventID == kAEQuitApplication
        return Self.quitRequested || quitEvent ? .terminateNow : .terminateCancel
    }
}

private struct QuitCommand: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit Veya") {
                AppDelegate.quitRequested = true
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

/// Brings the window back once closed; its hidden title bar keeps it out of the Window menu's list.
private struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Veya") { openWindow(id: "main") }
                .keyboardShortcut("0")
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

    static func signOut(_ session: SessionModel, failed: Binding<Bool>) {
        session.signOut { failed.wrappedValue = true }
    }
}
