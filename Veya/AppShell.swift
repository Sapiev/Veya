import AppKit
import SpotCoreKit
import SwiftUI

extension FocusedValues {
    /// The key window's history, so ⌘[ and ⌘] act on the window in front.
    @Entry var navigationHistory: NavigationHistory?
    @Entry var queueVisible: Binding<Bool>?
    @Entry var sidebarVisible: Binding<Bool>?
    @Entry var sidebarCompact: Binding<Bool>?
    @Entry var newPlaylist: WindowAction?
    @Entry var newFolder: WindowAction?
    @Entry var openLink: WindowAction?
}

/// A menu action the key window publishes. Equal while it comes from the same
/// window, whose actions never change, so the menus don't redraw on every window update.
struct WindowAction: Equatable {
    let window: ObjectIdentifier
    let perform: () -> Void

    func callAsFunction() {
        perform()
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.window == rhs.window
    }
}

/// The signed-in main window: sidebar of destinations, detail for the current route.
struct AppShell: View {
    private let scope: SessionScope
    @State private var history = NavigationHistory()
    @State private var searchFocusRequest = 0
    @State private var searchSelection: SearchResultID?
    @State private var searchFilter = SearchFilter.all
    private let recentSearches: RecentSearches
    private let webAPI: WebAPIConnection
    @SceneStorage("sidebarVisible") private var sidebarVisible = true
    @SceneStorage("sidebarCompact") private var sidebarCompact = false
    @SceneStorage("queueVisible") private var queueVisible = false
    /// The full Now Playing view's open tab; nil while it is closed.
    @State private var nowPlayingTab: NowPlayingView.Tab?
    @State private var creatingPlaylist = false
    @State private var openingLink = false
    @Binding private var openedLink: SpotifyLink?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(scope: SessionScope, webAPI: WebAPIConnection, recentSearches: RecentSearches, openedLink: Binding<SpotifyLink?>) {
        self.scope = scope
        self.recentSearches = recentSearches
        self.webAPI = webAPI
        _openedLink = openedLink
    }

    private var metadata: any MetadataServiceProtocol { scope.metadata }
    private var playlists: PlaylistModel { scope.playlists }
    private var search: SearchModel { scope.search }
    private var home: HomeModel { scope.home }
    private var podcast: PodcastModel { scope.podcast }
    private var library: LibraryModel { scope.library }
    private var player: PlayerModel? { scope.player }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                Sidebar(
                    selection: selection, compact: $sidebarCompact, playlists: playlists, library: library, player: player,
                    newPlaylist: newPlaylist, newFolder: newFolder
                )
                    .frame(width: sidebarCompact ? Theme.compactSidebarWidth : Theme.sidebarWidth)
                    .glassPanel(cornerRadius: Theme.panelRadius)
                    .shadow(color: .black.opacity(0.18), radius: 15, y: 8)
                    .padding([.leading, .vertical], Theme.s2)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
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
                // With the sidebar hidden the window buttons sit over the page, so the bar starts past them.
                .padding(.leading, sidebarVisible ? 0 : Theme.windowButtonsWidth)
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
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
        // The page header's backdrop spans the window, so the side panels' glass blurs it without a seam.
        // Read as a background, not state, so scrolling the page doesn't re-evaluate the shell.
        .backgroundPreferenceValue(PageBackdropKey.self) { backdrop in
            if let backdrop {
                GeometryReader { proxy in
                    let hero = proxy[backdrop.bounds]
                    let pull = max(0, hero.minY)
                    let height = hero.height + pull
                    Group {
                        switch backdrop.fill {
                        case let .picture(artwork):
                            ArtistPicture(artwork: artwork, width: proxy.size.width, height: height)
                        case .glow:
                            GlowWash(width: proxy.size.width, height: height)
                        }
                    }
                    .offset(y: hero.minY - pull)
                }
                .accessibilityHidden(true)
            }
        }
        .background { AmbientBackground() }
        .background(TrafficLightInset())
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : Theme.standard, value: sidebarVisible)
        .animation(reduceMotion ? nil : Theme.standard, value: sidebarCompact)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: queueVisible)
        .overlay {
            if let nowPlayingTab, let player {
                NowPlayingView(player: player, library: library, metadata: metadata, history: history, tab: nowPlayingTab) { self.nowPlayingTab = nil }
                    // Covers the window up to its top edge, under the title bar.
                    .ignoresSafeArea()
                    // It covers the whole shell, so VoiceOver must not reach what lies beneath.
                    .accessibilityAddTraits(.isModal)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : Theme.standard, value: nowPlayingTab)
        .focusedSceneValue(\.navigationHistory, history)
        .focusedSceneValue(\.queueVisible, $queueVisible)
        .focusedSceneValue(\.sidebarVisible, $sidebarVisible)
        .focusedSceneValue(\.sidebarCompact, $sidebarCompact)
        .focusedSceneValue(\.focusSearch, action(focusSearch))
        .focusedSceneValue(\.newPlaylist, action(newPlaylist))
        .focusedSceneValue(\.newFolder, action(newFolder))
        .focusedSceneValue(\.openLink, action { openingLink = true })
        .sheet(isPresented: $openingLink) {
            OpenLinkSheet(open: open)
        }
        .onChange(of: openedLink, initial: true) {
            guard let openedLink else { return }
            self.openedLink = nil
            open(openedLink)
        }
        .sheet(isPresented: $creatingPlaylist) {
            PlaylistDetailsSheet(title: "New Playlist", confirm: "Create") { name, description, _ in
                Task {
                    if let uri = await playlists.createPlaylist(named: name, description: description) {
                        history.navigate(to: .playlist(uri: uri))
                    }
                }
            }
        }
        .alert("Couldn't Change Playlist", isPresented: editErrorShown, presenting: playlists.editError) { _ in
            Button("OK") {}
        } message: { error in
            switch error {
            case .conflict: Text("This playlist changed somewhere else. Your change was undone.")
            case .invalidImage: Text("Choose a photo in a common image format, such as JPEG or PNG.")
            case .failed: Text("Check your connection and try again.")
            }
        }
        .alert(unplayableTitle, isPresented: unplayableShown) {
            Button("OK") {}
        } message: {
            Text("Veya plays local MP3, MP4 and FLAC files sampled at 44.1 kHz from the folders in Settings > Playback.")
        }
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

    /// `history` lives exactly as long as this window, so it names the window.
    private func action(_ perform: @escaping () -> Void) -> WindowAction {
        WindowAction(window: ObjectIdentifier(history), perform: perform)
    }

    private func focusSearch() {
        history.navigate(to: .search)
        searchFocusRequest += 1
    }

    private func newPlaylist() {
        creatingPlaylist = true
    }

    private func open(_ link: SpotifyLink) {
        switch link {
        case let .page(route): history.navigate(to: route)
        case let .play(uri): _ = player?.play(uri, startingAt: 0)
        }
    }

    private func newFolder() {
        Task { await playlists.createFolder(named: String(localized: "Untitled Folder")) }
    }

    private var editErrorShown: Binding<Bool> {
        Binding(get: { playlists.editError != nil }, set: { if !$0 { playlists.editError = nil } })
    }

    private var unplayableShown: Binding<Bool> {
        Binding(get: { player?.unplayableLocalFile != nil }, set: { if !$0 { player?.unplayableLocalFile = nil } })
    }

    private var unplayableTitle: Text {
        let title = player?.unplayableLocalFile ?? ""
        return title.isEmpty ? Text("Couldn't Play Local File") : Text("Couldn't Play “\(title)”")
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
            .modifier(Theme.greeting)
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

/// Names the unlabeled group AppKit hosts SwiftUI content in (a window's content, a sidebar section header);
/// no SwiftUI modifier reaches it, and the accessibility audit flags it.
struct HostingGroupLabel: NSViewRepresentable {
    let label: String

    func makeNSView(context _: Context) -> NSView { Anchor(label: label) }
    func updateNSView(_: NSView, context _: Context) {}

    private final class Anchor: NSView {
        let label: String

        init(label: String) {
            self.label = label
            super.init(frame: .zero)
        }

        @available(*, unavailable) required init?(coder _: NSCoder) { nil }

        override func hitTest(_: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            sequence(first: self as NSView, next: \.superview).dropFirst()
                .first { $0.isAccessibilityElement() && $0.accessibilityRole() == .group }?
                .setAccessibilityLabel(label)
        }
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
            .scaledFont(size: 15, weight: .medium)
            .foregroundStyle(isEnabled ? AnyShapeStyle(on ? Color(palette.tintText) : .primary) : AnyShapeStyle(.tertiary))
            .frame(width: 32, height: 32)
            .background((hovering && isEnabled) || on ? Color.fillStrong : .clear, in: .circle)
            .contentShape(.circle)
            .onHover { hovering = $0 }
    }
}

/// File menu: new playlists and folders, opening a Spotify link; Go menu: ⌘[ and ⌘] like Finder and Safari; View menu: the queue inspector.
struct NavigationCommands: Commands {
    @FocusedValue(\.navigationHistory) private var history
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedValue(\.queueVisible) private var queueVisible
    @FocusedValue(\.sidebarVisible) private var sidebarVisible
    @FocusedValue(\.sidebarCompact) private var sidebarCompact
    @FocusedValue(\.newPlaylist) private var newPlaylist
    @FocusedValue(\.newFolder) private var newFolder
    @FocusedValue(\.openLink) private var openLink

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Playlist") { newPlaylist?() }
                .keyboardShortcut("n")
                .disabled(newPlaylist == nil)
            Button("New Folder") { newFolder?() }
                .disabled(newFolder == nil)
            Divider()
            Button("Open Link…") { openLink?() }
                .keyboardShortcut("o")
                .disabled(openLink == nil)
        }
        CommandGroup(after: .sidebar) {
            // The sidebar is a custom panel, so the system's Toggle Sidebar item never appears.
            Button(sidebarVisible?.wrappedValue == false ? "Show Sidebar" : "Hide Sidebar") {
                sidebarVisible?.wrappedValue.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(sidebarVisible == nil)
            Button(sidebarCompact?.wrappedValue == true ? "Expand Sidebar" : "Collapse Sidebar") {
                sidebarCompact?.wrappedValue.toggle()
            }
            .disabled(sidebarCompact == nil || sidebarVisible?.wrappedValue == false)
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

/// File › Open Link: a pasted `open.spotify.com` link or `spotify:` URI.
private struct OpenLinkSheet: View {
    let open: (SpotifyLink) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let link = SpotifyLink(text)
        VStack(alignment: .leading, spacing: Theme.s4) {
            Text("Open Link")
                .scaledFont(size: 13, weight: .bold)
            TextField("Link", text: $text, prompt: Text(verbatim: "https://open.spotify.com/…"))
                .textFieldStyle(.roundedBorder)
            Text("Paste a link from open.spotify.com or a spotify: URI.")
                .scaledFont(size: 12)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open") {
                    if let link { open(link) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(link == nil)
            }
        }
        .padding(Theme.s5)
        .frame(width: 420)
    }
}
