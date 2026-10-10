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
    @State private var podcast: PodcastModel
    private let settings: PlaybackSettings
    @State private var player: PlayerModel?
    @State private var search: SearchModel
    @State private var home: HomeModel
    @State private var searchFocusRequest = 0
    @State private var searchSelection: SearchResultID?
    private let recentSearches: RecentSearches
    /// Hands the started player to the session owner, which stops it on sign out; false drops it.
    private let attachPlayer: @MainActor (PlayerModel) -> Bool
    @SceneStorage("sidebarVisible") private var sidebarVisible = true
    @SceneStorage("queueVisible") private var queueVisible = false
    @State private var nowPlayingVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: any SessionHandle,
        webAPITokens: WebAPITokenProvider,
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
        _search = State(initialValue: SearchModel(service: session.makeSearch()))
        let metadata = session.makeMetadata(store: metadataStore)
        self.metadata = metadata
        let playlistService = session.makePlaylists(store: metadataStore)
        _playlists = State(initialValue: PlaylistModel(playlists: playlistService))
        _home = State(initialValue: HomeModel(
            metadata: metadata,
            playlists: playlistService,
            recentlyPlayed: session.makeRecentlyPlayed { try await webAPITokens.accessToken() }
        ))
        _library = State(initialValue: LibraryModel(library: session.makeLibrary(store: metadataStore), metadata: metadata))
        _podcast = State(initialValue: PodcastModel(metadata: metadata, progress: episodeProgress))
    }

    var body: some View {
        NavigationSplitView(columnVisibility: columnVisibility) {
            Sidebar(selection: selection, playlists: playlists, library: library, player: player)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background { AmbientBackground() }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let player {
                        NowPlayingBar(
                            player: player,
                            library: library,
                            history: history,
                            queueVisible: $queueVisible,
                            expanded: $nowPlayingVisible
                        )
                        .padding(Theme.s3)
                    }
                }
        }
        .inspector(isPresented: $queueVisible) {
            QueuePanel(player: player, library: library, playlists: playlists)
        }
        .overlay {
            if nowPlayingVisible, let player {
                NowPlayingView(player: player, library: library, history: history) { nowPlayingVisible = false }
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.standard, value: nowPlayingVisible)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left", action: history.back)
                    .disabled(!history.canGoBack)
                    .help("Back")
                Button("Forward", systemImage: "chevron.right", action: history.forward)
                    .disabled(!history.canGoForward)
                    .help("Forward")
            }
            ToolbarItem(placement: .navigation) {
                SearchField(
                    search: search,
                    recent: recentSearches,
                    player: player,
                    history: history,
                    selection: $searchSelection,
                    focusRequest: searchFocusRequest
                )
            }
        }
        .focusedSceneValue(\.navigationHistory, history)
        .focusedSceneValue(\.queueVisible, $queueVisible)
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
            HomeView(home: home, player: player, history: history)
        case .search:
            SearchView(search: search, recent: recentSearches, player: player, history: history, selection: $searchSelection)
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

    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarVisible ? .all : .detailOnly }, set: { sidebarVisible = $0 != .detailOnly })
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
