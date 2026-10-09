import AppKit
import SpotCoreKit
import SwiftUI

extension FocusedValues {
    /// The key window's history, so ⌘[ and ⌘] act on the window in front.
    @Entry var navigationHistory: NavigationHistory?
    @Entry var queueVisible: Binding<Bool>?
}

/// The signed-in main window: sidebar of destinations, detail for the current route.
struct AppShell: View {
    private let session: any SessionHandle
    private let metadata: any MetadataServiceProtocol
    @State private var history = NavigationHistory()
    @State private var playlists: PlaylistModel
    @State private var library: LibraryModel
    private let settings: PlaybackSettings
    @State private var player: PlayerModel?
    @State private var search: SearchModel
    @State private var searchFocusRequest = 0
    private let recentSearches: RecentSearches
    @SceneStorage("sidebarVisible") private var sidebarVisible = true
    @SceneStorage("queueVisible") private var queueVisible = false

    init(session: any SessionHandle, metadataStore: MetadataStore?, recentSearches: RecentSearches, settings: PlaybackSettings) {
        self.session = session
        self.settings = settings
        self.recentSearches = recentSearches
        _search = State(initialValue: SearchModel(service: session.makeSearch()))
        let metadata = session.makeMetadata(store: metadataStore)
        self.metadata = metadata
        _playlists = State(initialValue: PlaylistModel(playlists: session.makePlaylists(store: metadataStore)))
        _library = State(initialValue: LibraryModel(library: session.makeLibrary(store: metadataStore), metadata: metadata))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            Sidebar(selection: selection, playlists: playlists)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            switch history.current {
            case .search:
                SearchView(search: search, recent: recentSearches, player: player, history: history, focusRequest: searchFocusRequest)
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
            default:
                RouteView(route: history.current)
            }
        }
        .inspector(isPresented: $queueVisible) {
            QueuePanel(player: player, library: library, playlists: playlists)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: history.back)
                    .disabled(!history.canGoBack)
                    .help("Back")
                Button("Forward", systemImage: "chevron.right", action: history.forward)
                    .disabled(!history.canGoForward)
                    .help("Forward")
            }
        }
        .focusedSceneValue(\.navigationHistory, history)
        .focusedSceneValue(\.queueVisible, $queueVisible)
        .focusedSceneValue(\.focusSearch, focusSearch)
        .background {
            // ⌘F is in the Go menu; ⌘L is the browser habit for the same thing.
            Button("Search", action: focusSearch)
                .keyboardShortcut("l")
                .hidden()
        }
        .background(SwipeNavigation(history: history))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let player {
                NowPlayingBar(player: player, library: library, history: history, queueVisible: $queueVisible)
            }
        }
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
                player = try await PlayerModel.start(session: session, metadata: metadata, settings: settings)
            } catch {
                // Type name only: messages may carry server text.
                logMessage(level: .error, category: "player", message: "Player unavailable: \(type(of: error))")
            }
        }
    }

    private func focusSearch() {
        history.navigate(to: .search)
        searchFocusRequest += 1
    }

    private var selection: Binding<Route?> {
        Binding(get: { history.current }, set: { if let route = $0 { history.navigate(to: route) } })
    }

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarVisible ? .all : .detailOnly }, set: { sidebarVisible = $0 != .detailOnly })
    }
}

private struct Sidebar: View {
    @Binding var selection: Route?
    let playlists: PlaylistModel

    var body: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house").tag(Route.home)
            Label("Search", systemImage: "magnifyingglass").tag(Route.search)
            Section("Library") {
                Label("Liked Songs", systemImage: "heart").tag(Route.likedSongs)
                Label("Albums", systemImage: "square.stack").tag(Route.albums)
                Label("Artists", systemImage: "music.mic").tag(Route.artists)
                Label("Podcasts", systemImage: "mic").tag(Route.podcasts)
            }
            Section("Playlists") {
                // shortcut: folders are flattened, nest them with DisclosureGroup once folders matter in the UI.
                ForEach(playlists.rootlist, id: \.self) { entry in
                    if case let .playlist(uri, name, _, _, _) = entry {
                        Label(name, systemImage: "music.note.list").tag(Route.playlist(uri: uri))
                    }
                }
                if playlists.rootlist.isEmpty {
                    switch playlists.state {
                    case .loaded:
                        Text("No Playlists")
                            .foregroundStyle(.secondary)
                    case .failed:
                        Text("Couldn't Load Playlists")
                            .foregroundStyle(.secondary)
                        Button("Try Again") { playlists.load() }
                            .buttonStyle(.borderless)
                    case .loading, nil:
                        EmptyView()
                    }
                }
            }
        }
        .listStyle(.sidebar)
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

/// Saved albums, followed artists or followed shows by name; each opens its page.
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
                List(items, id: \.uri) { item in
                    Button(name(item.uri)) { history.navigate(to: route(item.uri)) }
                        .buttonStyle(.plain)
                }
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

    private func route(_ uri: String) -> Route {
        switch kind {
        case .albums: .album(uri: uri)
        case .artists: .artist(uri: uri)
        default: .show(uri: uri)
        }
    }
}

private struct PageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .accessibilityIdentifier("routeTitle")
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)
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

/// Placeholder per route until its screen lands (Home: PBI-307, shows: PBI-306).
private struct RouteView: View {
    let route: Route

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2)
                .accessibilityIdentifier("routeTitle")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }

    private var title: String {
        switch route {
        case .home: String(localized: "Home")
        case .search: String(localized: "Search")
        case .likedSongs: String(localized: "Liked Songs")
        case .albums: String(localized: "Albums")
        case .artists: String(localized: "Artists")
        case .podcasts: String(localized: "Podcasts")
        case .playlist: String(localized: "Playlist")
        case .album: String(localized: "Album")
        case .artist: String(localized: "Artist")
        case .show: String(localized: "Podcast")
        }
    }

    private var symbol: String {
        switch route {
        case .home: "house"
        case .search: "magnifyingglass"
        case .likedSongs: "heart"
        case .albums, .album: "square.stack"
        case .artists, .artist: "music.mic"
        case .podcasts, .show: "mic"
        case .playlist: "music.note.list"
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

/// Go menu: ⌘[ and ⌘] like Finder and Safari; View menu: the queue inspector.
struct NavigationCommands: Commands {
    @FocusedValue(\.navigationHistory) private var history
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedValue(\.queueVisible) private var queueVisible

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            // ⌥⌘I is the system's Show Inspector shortcut.
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
