import AppKit
import SpotCoreKit
import SwiftUI

extension FocusedValues {
    /// The key window's history, so ⌘[ and ⌘] act on the window in front.
    @Entry var navigationHistory: NavigationHistory?
}

/// The signed-in main window: sidebar of destinations, detail for the current route.
struct AppShell: View {
    private let session: any SessionHandle
    private let metadata: any MetadataServiceProtocol
    @State private var history = NavigationHistory()
    @State private var playlists: PlaylistModel
    @State private var library: LibraryModel
    @State private var settings = PlaybackSettings()
    @State private var player: PlayerModel?
    @SceneStorage("sidebarVisible") private var sidebarVisible = true
    /// Read by the queue inspector (PBI-406).
    @SceneStorage("queueVisible") private var queueVisible = false

    init(session: any SessionHandle, metadataStore: MetadataStore?) {
        self.session = session
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
            case .likedSongs:
                LikedSongs(library: library, player: player, playlists: playlists, history: history)
            default:
                RouteView(route: history.current, playlists: playlists)
            }
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
            Text("Liked Songs")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("routeTitle")
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            switch library.loadState[.tracks] {
            case .loading where items.isEmpty:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed where items.isEmpty:
                Text("Couldn't load Liked Songs.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            default:
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
        .navigationTitle("Liked Songs")
    }
}

/// Placeholder per route until its screen lands (PBI-404 onwards).
private struct RouteView: View {
    let route: Route
    let playlists: PlaylistModel

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
        case let .playlist(uri): playlistName(uri) ?? String(localized: "Playlist")
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

    private func playlistName(_ uri: String) -> String? {
        for case let .playlist(entryURI, name, _, _, _) in playlists.rootlist where entryURI == uri {
            return name
        }
        return nil
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

/// Go menu: ⌘[ and ⌘] like Finder and Safari.
struct NavigationCommands: Commands {
    @FocusedValue(\.navigationHistory) private var history

    var body: some Commands {
        CommandMenu("Go") {
            Button("Back") { history?.back() }
                .keyboardShortcut("[")
                .disabled(history?.canGoBack != true)
            Button("Forward") { history?.forward() }
                .keyboardShortcut("]")
                .disabled(history?.canGoForward != true)
        }
    }
}
