import AppKit
import SpotCoreKit
import SwiftUI

extension FocusedValues {
    /// The key window's history, so ⌘[ and ⌘] act on the window in front.
    @Entry var navigationHistory: NavigationHistory?
    @Entry var queueVisible: Binding<Bool>?
    @Entry var sidebarVisible: Binding<Bool>?
}

/// The signed-in main window: sidebar of destinations, detail for the current route.
struct AppShell: View {
    private let session: any SessionHandle
    private let metadata: any MetadataServiceProtocol
    @State private var history = NavigationHistory()
    @State private var playlists: PlaylistModel
    @State private var library: LibraryModel
    @State private var podcast: PodcastModel
    private let settings: PlaybackSettings
    @State private var player: PlayerModel?
    @State private var search: SearchModel
    @State private var home: HomeModel
    @State private var searchFocusRequest = 0
    @State private var searchSelection: SearchResultID?
    @State private var searchFilter = SearchFilter.all
    private let recentSearches: RecentSearches
    private let webAPI: WebAPIConnection
    /// Hands the started player to the session owner, which stops it on sign out; false drops it.
    private let attachPlayer: @MainActor (PlayerModel) -> Bool
    @SceneStorage("sidebarVisible") private var sidebarVisible = true
    @SceneStorage("queueVisible") private var queueVisible = false
    /// The full Now Playing view's open tab; nil while it is closed.
    @State private var nowPlayingTab: NowPlayingView.Tab?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: any SessionHandle,
        webAPI: WebAPIConnection,
        metadataStore: MetadataStore?,
        recentSearches: RecentSearches,
        settings: PlaybackSettings,
        episodeProgress: any EpisodeProgressProvider,
        attachPlayer: @escaping @MainActor (PlayerModel) -> Bool
    ) {
        self.session = session
        self.attachPlayer = attachPlayer
        self.settings = settings
        self.recentSearches = recentSearches
        self.webAPI = webAPI
        let tokens = webAPI.tokens
        _search = State(initialValue: SearchModel(service: session.makeSearch { try await tokens.accessToken() }))
        let metadata = session.makeMetadata(store: metadataStore)
        self.metadata = metadata
        let playlistService = session.makePlaylists(store: metadataStore)
        _playlists = State(initialValue: PlaylistModel(playlists: playlistService))
        _home = State(initialValue: HomeModel(
            metadata: metadata,
            playlists: playlistService,
            recentlyPlayed: session.makeRecentlyPlayed { try await tokens.accessToken() }
        ))
        _library = State(initialValue: LibraryModel(library: session.makeLibrary(store: metadataStore), metadata: metadata))
        _podcast = State(initialValue: PodcastModel(metadata: metadata, progress: episodeProgress))
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                Sidebar(selection: selection, playlists: playlists, library: library, player: player)
                    .frame(width: Theme.sidebarWidth)
                    .glassPanel(cornerRadius: Theme.panelRadius)
                    .shadow(color: .black.opacity(0.18), radius: 15, y: 8)
                    .padding([.leading, .vertical], Theme.s2)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            // Pages scroll under the floating top bar and player; the insets keep their ends reachable.
            // The bar is a sibling, not an overlay on `page`, so the search field survives route changes.
            ZStack(alignment: .top) {
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .safeAreaPadding(.top, 64)
                    .safeAreaPadding(.bottom, player == nil ? Theme.s8 : Theme.playerHeight + Theme.s8)
                TopBar(history: history, queueVisible: $queueVisible, nowPlayingTab: player?.nowPlaying == nil ? nil : $nowPlayingTab) {
                    SearchField(
                        search: search,
                        recent: recentSearches,
                        player: player,
                        history: history,
                        selection: $searchSelection,
                        filter: searchFilter,
                        focusRequest: searchFocusRequest
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if let player {
                    NowPlayingBar(
                        player: player,
                        library: library,
                        history: history,
                        queueVisible: $queueVisible,
                        expanded: $nowPlayingTab
                    )
                    .padding(Theme.s3)
                }
            }
            if queueVisible {
                QueuePanel(player: player, library: library, playlists: playlists) { queueVisible = false }
                    .frame(width: Theme.queueWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .glassPanel(cornerRadius: Theme.panelRadius)
                    // The rounded panel clips the scrolling rows, so the last one peeks at the bottom edge.
                    .clipShape(.rect(cornerRadius: Theme.panelRadius))
                    .shadow(color: .black.opacity(0.18), radius: 15, y: 8)
                    .padding([.trailing, .vertical], Theme.s2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // The artist header's picture spans the window, so the side panels' glass blurs the same image without a seam.
        // Read as a background, not state, so scrolling the artist page doesn't re-evaluate the shell.
        .backgroundPreferenceValue(ArtistBackdropKey.self) { backdrop in
            if let backdrop {
                GeometryReader { proxy in
                    let hero = proxy[backdrop.bounds]
                    let pull = max(0, hero.minY)
                    ArtistPicture(artwork: backdrop.artwork, width: proxy.size.width, height: hero.height + pull)
                        .offset(y: hero.minY - pull)
                }
                .accessibilityHidden(true)
            }
        }
        .background { AmbientBackground() }
        .background(TrafficLightInset())
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : Theme.standard, value: sidebarVisible)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: queueVisible)
        .overlay {
            if let nowPlayingTab, let player {
                NowPlayingView(player: player, library: library, history: history, tab: nowPlayingTab) { self.nowPlayingTab = nil }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.standard, value: nowPlayingTab)
        .focusedSceneValue(\.navigationHistory, history)
        .focusedSceneValue(\.queueVisible, $queueVisible)
        .focusedSceneValue(\.sidebarVisible, $sidebarVisible)
        .focusedSceneValue(\.focusSearch, focusSearch)
        .background {
            // ⌘F is in the Go menu; ⌘L is the browser habit, ⌘K the design's hint.
            Button("Search", action: focusSearch)
                .keyboardShortcut("l")
                .hidden()
            Button("Search", action: focusSearch)
                .keyboardShortcut("k")
                .hidden()
        }
        .background(SwipeNavigation(history: history))
        .modifier(AdaptiveColors(artwork: player?.nowPlaying?.artwork ?? []))
        .task {
            playlists.load()
            await playlists.watch()
        }
        .task {
            library.load(.tracks)
            await library.watch()
        }
        .task {
            do {
                let started = try await PlayerModel.start(session: session, metadata: metadata, settings: settings)
                if attachPlayer(started) { player = started }
            } catch {
                // Type name only: messages may carry server text.
                logMessage(level: .error, category: "player", message: "Player unavailable: \(type(of: error))")
            }
        }
    }

    @ViewBuilder private var page: some View {
        switch history.current {
        case .home:
            HomeView(home: home, library: library, player: player, history: history)
        case .search:
            SearchView(
                search: search, webAPI: webAPI, recent: recentSearches, library: library, player: player, history: history,
                selection: $searchSelection, filter: $searchFilter
            )
        case .likedSongs:
            LikedSongs(library: library, player: player, playlists: playlists, history: history)
        case .albums:
            SavedItems(kind: .albums, library: library, history: history)
        case .artists:
            SavedItems(kind: .artists, library: library, history: history)
        case .podcasts:
            SavedItems(kind: .shows, library: library, history: history)
        case let .album(uri):
            AlbumPage(uri: uri, library: library, player: player, playlists: playlists, history: history)
        case let .artist(uri):
            ArtistPage(uri: uri, library: library, player: player, history: history)
        case let .playlist(uri):
            PlaylistPageView(uri: uri, library: library, player: player, playlists: playlists, history: history)
        case let .show(uri):
            ShowPage(uri: uri, podcast: podcast, player: player)
        }
    }

    private func focusSearch() {
        history.navigate(to: .search)
        searchFocusRequest += 1
    }

    private var selection: Binding<Route?> {
        Binding(get: { history.current }, set: { if let route = $0 { history.navigate(to: route) } })
    }
}

private struct LikedSongs: View {
    let library: LibraryModel
    let player: PlayerModel?
    let playlists: PlaylistModel
    let history: NavigationHistory

    var body: some View {
        let items = library.items[.tracks] ?? []
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: LibraryKind.tracks.title)
            LoadStateView(
                state: library.loadState[.tracks],
                isEmpty: items.isEmpty,
                empty: LibraryKind.tracks.empty,
                failureTitle: LibraryKind.tracks.failureTitle,
                retry: { library.load(.tracks) }
            ) {
                TrackList(
                    entries: items.map { TrackEntry(uri: $0.uri, addedAt: Date(timeIntervalSince1970: TimeInterval($0.addedAt))) },
                    context: nil,
                    library: library,
                    player: player,
                    playlists: playlists,
                    history: history
                )
            }
        }
        .navigationTitle(LibraryKind.tracks.title)
    }
}

/// Saved albums, followed artists or followed shows as a grid of cards; each opens its page.
private struct SavedItems: View {
    let kind: LibraryKind
    let library: LibraryModel
    let history: NavigationHistory

    var body: some View {
        let items = library.items[kind] ?? []
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: kind.title)
            LoadStateView(
                state: library.loadState[kind],
                isEmpty: items.isEmpty,
                empty: kind.empty,
                failureTitle: kind.failureTitle,
                retry: { library.load(kind) }
            ) {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: MediaCard.width), spacing: Theme.s4, alignment: .top)],
                        alignment: .leading,
                        spacing: Theme.s4
                    ) {
                        ForEach(items, id: \.uri) { item in
                            MediaCard(title: name(item.uri), artwork: artwork(item.uri), round: kind == .artists) {
                                history.navigate(to: route(item.uri))
                            }
                        }
                    }
                    .padding(.horizontal, Theme.s8)
                    .padding(.bottom, Theme.s8)
                }
                .accessibilityIdentifier("savedItems")
                .task(id: items) { library.resolve(items.map(\.uri)) }
            }
        }
        .navigationTitle(kind.title)
        .task { library.load(kind) }
    }

    private func name(_ uri: String) -> String {
        switch library.metadata[uri] {
        case let .album(album): album.title
        case let .artist(artist): artist.name
        case let .show(show): show.name
        case .unavailable: String(localized: "Unavailable")
        default: String(localized: "Loading…")
        }
    }

    private func artwork(_ uri: String) -> [Artwork] {
        switch library.metadata[uri] {
        case let .album(album): album.artwork
        case let .artist(artist): artist.artwork
        case let .show(show): show.artwork
        default: []
        }
    }

    private func route(_ uri: String) -> Route {
        switch kind {
        case .albums: .album(uri: uri)
        case .artists: .artist(uri: uri)
        default: .show(uri: uri)
        }
    }
}

struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.greeting)
            .accessibilityIdentifier("routeTitle")
            .padding(.horizontal, Theme.s8)
            .padding(.top, Theme.s5)
            .padding(.bottom, Theme.s3)
    }
}

private extension LibraryKind {
    var title: String {
        switch self {
        case .tracks: String(localized: "Liked Songs")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .shows: String(localized: "Podcasts")
        }
    }

    var empty: EmptyState {
        switch self {
        case .tracks: EmptyState(title: "No Liked Songs", systemImage: "heart", message: "Songs you like appear here.")
        case .albums: EmptyState(title: "No Saved Albums", systemImage: "square.stack", message: "Albums you save appear here.")
        case .artists: EmptyState(title: "No Followed Artists", systemImage: "music.mic", message: "Artists you follow appear here.")
        case .shows: EmptyState(title: "No Followed Podcasts", systemImage: "mic", message: "Podcasts you follow appear here.")
        }
    }

    var failureTitle: LocalizedStringKey {
        switch self {
        case .tracks: "Couldn't Load Liked Songs"
        case .albums: "Couldn't Load Albums"
        case .artists: "Couldn't Load Artists"
        case .shows: "Couldn't Load Podcasts"
        }
    }
}

/// Trackpad page swipes (System Settings > Trackpad > Swipe between pages) move through history.
private struct SwipeNavigation: View {
    let history: NavigationHistory
    @State private var monitor: Any?

    var body: some View {
        Color.clear
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { event in
                    if event.deltaX > 0 {
                        history.back()
                    } else if event.deltaX < 0 {
                        history.forward()
                    }
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// The floating capsules over the page (`.toolbar`): history, search and the queue toggle.
private struct TopBar<Search: View>: View {
    let history: NavigationHistory
    @Binding var queueVisible: Bool
    /// Nil while nothing plays, which disables Full-Window Now Playing.
    let nowPlayingTab: Binding<NowPlayingView.Tab?>?
    @ViewBuilder let search: () -> Search
    @AppStorage(SettingsView.tabKey) private var settingsTab = SettingsView.Tab.general
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: Theme.s2) {
            HStack(spacing: 0) {
                Button("Back", systemImage: "chevron.left", action: history.back)
                    .disabled(!history.canGoBack)
                    .help("Back")
                Button("Forward", systemImage: "chevron.right", action: history.forward)
                    .disabled(!history.canGoForward)
                    .help("Forward")
            }
            .padding(.horizontal, Theme.s1)
            .frame(height: 36)
            .glassPanel(cornerRadius: 18)
            search()
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                // The design's "More options" menu (`moreMenu`).
                Menu {
                    Button("Adaptive Color…") {
                        settingsTab = .general
                        openSettings()
                    }
                    Divider()
                    Button("Full-Window Now Playing") { nowPlayingTab?.wrappedValue = .lyrics }
                        .disabled(nowPlayingTab == nil)
                } label: {
                    Label("More Options", systemImage: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help("More Options")
                Toggle(isOn: $queueVisible) {
                    Label("Queue", systemImage: "sidebar.right")
                }
                .toggleStyle(.button)
                .buttonStyle(CapsuleIconButtonStyle(on: queueVisible))
                .help(queueVisible ? "Hide Queue" : "Show Queue")
            }
            .padding(.horizontal, Theme.s1)
            .frame(height: 36)
            .glassPanel(cornerRadius: 18)
        }
        .buttonStyle(CapsuleIconButtonStyle())
        .labelStyle(.iconOnly)
        .padding(.horizontal, Theme.s4)
        .frame(height: 40)
        .padding(.top, 10)
    }
}

/// Moves the window buttons inside the sidebar panel, where the design draws them (`.traffic`: 20 pt in, 18 pt down).
/// AppKit lays the titlebar out again on resize and full screen, so the position is reapplied after each.
private struct TrafficLightInset: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSView { Anchor() }
    func updateNSView(_: NSView, context _: Context) {}

    private final class Anchor: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            ]
            observers = names.map { observe($0, window) }
            // AppKit also re-lays out the titlebar on clicks and key/main changes; watching the frames catches every pass.
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap(window.standardWindowButton)
            let views = buttons + [buttons.first?.superview?.superview].compactMap { $0 }
            observers += views.map { view in
                view.postsFrameChangedNotifications = true
                return observe(NSView.frameDidChangeNotification, view)
            }
            place()
        }

        private func observe(_ name: Notification.Name, _ object: AnyObject) -> NSObjectProtocol {
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            place()
        }

        private func place() {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window, !window.styleMask.contains(.fullScreen),
                      let close = window.standardWindowButton(.closeButton),
                      let container = close.superview?.superview else { return }
                let top: CGFloat = 18, left: CGFloat = 20, gap: CGFloat = 8
                // The titlebar container clips its buttons, so it grows to reach them.
                let height = close.frame.height + 2 * top
                let frame = NSRect(
                    x: container.frame.minX, y: window.frame.height - height,
                    width: container.frame.width, height: height
                )
                // Setting only on change keeps the frame observers from looping.
                if container.frame != frame { container.frame = frame }
                for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
                    guard let button = window.standardWindowButton(kind) else { continue }
                    let y = (button.superview?.frame.height ?? height) - top - button.frame.height
                    let origin = NSPoint(x: left + CGFloat(index) * (button.frame.width + gap), y: y)
                    if button.frame.origin != origin { button.setFrameOrigin(origin) }
                }
            }
        }
    }
}

/// A 32 pt round toolbar button (`.tb-btn`): fills on hover, tinted while toggled on.
private struct CapsuleIconButtonStyle: ButtonStyle {
    var on = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleIconButton(configuration: configuration, on: on)
    }
}

private struct CapsuleIconButton: View {
    let configuration: ButtonStyleConfiguration
    let on: Bool
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(isEnabled ? AnyShapeStyle(on ? Color(palette.tintText) : .primary) : AnyShapeStyle(.tertiary))
            .frame(width: 32, height: 32)
            .background((hovering && isEnabled) || on ? Color.fillStrong : .clear, in: .circle)
            .contentShape(.circle)
            .onHover { hovering = $0 }
    }
}

/// Go menu: ⌘[ and ⌘] like Finder and Safari; View menu: the queue inspector.
struct NavigationCommands: Commands {
    @FocusedValue(\.navigationHistory) private var history
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedValue(\.queueVisible) private var queueVisible
    @FocusedValue(\.sidebarVisible) private var sidebarVisible

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            // The sidebar is a custom panel, so the system's Toggle Sidebar item never appears.
            Button(sidebarVisible?.wrappedValue == false ? "Show Sidebar" : "Hide Sidebar") {
                sidebarVisible?.wrappedValue.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(sidebarVisible == nil)
            // ⌥⌘I is the system's Show Inspector shortcut; the queue panel plays that role.
            Button(queueVisible?.wrappedValue == true ? "Hide Queue" : "Show Queue") {
                queueVisible?.wrappedValue.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(queueVisible == nil)
        }
        CommandMenu("Go") {
            Button("Search") { focusSearch?() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
            Divider()
            Button("Back") { history?.back() }
                .keyboardShortcut("[")
                .disabled(history?.canGoBack != true)
            Button("Forward") { history?.forward() }
                .keyboardShortcut("]")
                .disabled(history?.canGoForward != true)
        }
    }
}
