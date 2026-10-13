import AppKit
import SpotCoreKit
import SwiftUI

extension FocusedValues {
    /// Focuses the toolbar search field in the key window (⌘F, ⌘K, ⌘L).
    @Entry var focusSearch: WindowAction?
}

/// The toolbar search field (`.search-field`). Typing opens the Search route;
/// the field keeps focus while arrows move the selection, as in Spotlight.
struct SearchField: View {
    let search: SearchModel
    let recent: RecentSearches
    let player: PlayerModel?
    let history: NavigationHistory
    @Binding var selection: SearchResultID?
    let filter: SearchFilter
    /// Bumped by ⌘F, ⌘K and ⌘L; each change focuses the field.
    let focusRequest: Int

    /// Bumped when the Search route opens, so picking it in the sidebar focuses the field.
    @State private var routeFocus = 0

    var body: some View {
        capsule {
            HStack(spacing: Theme.s2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                ToolbarTextField(
                    text: query,
                    prompt: String(localized: "Artists, songs, albums"),
                    label: String(localized: "Search artists, songs and albums"),
                    focusRequest: focusRequest + routeFocus,
                    onKey: handle
                )
                if !search.query.isEmpty {
                    Button {
                        query.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear Search")
                    .help("Clear Search")
                }
                Text(verbatim: "⌘K")
                    .scaledFont(size: 11)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.separator, lineWidth: 0.5) }
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Theme.s3)
            .frame(width: 300, height: 36)
        }
        .onChange(of: history.current) { _, route in
            if route == .search { routeFocus += 1 }
        }
    }

    /// True when the key is handled; arrows and Return act only while the results are on screen.
    private func handle(_ key: ToolbarTextField.Key) -> Bool {
        let onResults = history.current == .search
        switch key {
        case .down where onResults:
            move(by: 1)
        case .up where onResults:
            move(by: -1)
        case .enter:
            if onResults, let selection {
                search.open(selection, recent: recent, player: player, history: history)
            } else {
                recent.add(search.query)
            }
        case .escape where !search.query.isEmpty:
            query.wrappedValue = ""
        case .escape:
            NSApp.keyWindow?.makeFirstResponder(nil)
        default:
            return false
        }
        return true
    }

    /// macOS 26 draws toolbar items on glass already.
    private func capsule(_ content: () -> some View) -> some View {
        content().glassPanel(cornerRadius: 18)
    }

    private var query: Binding<String> {
        Binding(get: { search.query }, set: {
            selection = nil
            search.search($0)
            if !$0.trimmingCharacters(in: .whitespaces).isEmpty, history.current != .search {
                history.navigate(to: .search)
            }
        })
    }

    private func move(by delta: Int) {
        let ids = search.results.ordered(filter)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { $0 + delta } ?? (delta > 0 ? 0 : ids.count - 1)
        selection = ids[min(max(index, 0), ids.count - 1)]
    }
}

/// An AppKit text field because SwiftUI focus doesn't reach toolbar items:
/// ⌘F, ⌘K and ⌘L need to make it first responder.
struct ToolbarTextField: NSViewRepresentable {
    enum Key { case up, down, enter, escape }

    @Binding var text: String
    let prompt: String
    let label: String
    /// Each change makes the field first responder.
    let focusRequest: Int
    let onKey: (Key) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.placeholderString = prompt
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("searchField")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.font = .systemFont(ofSize: 13 * context.environment.textScale)
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            // Async: the window may not hold the field yet. Skipped while editing,
            // since refocusing selects all and the next keystroke would replace the query.
            DispatchQueue.main.async {
                if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ToolbarTextField
        var focusRequest: Int

        init(parent: ToolbarTextField) {
            self.parent = parent
            focusRequest = parent.focusRequest
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): parent.onKey(.down)
            case #selector(NSResponder.insertNewline(_:)): parent.onKey(.enter)
            case #selector(NSResponder.cancelOperation(_:)): parent.onKey(.escape)
            default: false
            }
        }
    }
}

/// The Search route (`viewSearch`): recent searches, followed artists and
/// genres while the toolbar query is empty; then filter chips over the top
/// result beside the songs and a rail per kind, or suggestions when nothing matches.
struct SearchView: View {
    let search: SearchModel
    let webAPI: WebAPIConnection
    let recent: RecentSearches
    let library: LibraryModel
    let player: PlayerModel?
    let history: NavigationHistory
    @Binding var selection: SearchResultID?
    @Binding var filter: SearchFilter
    @AppStorage(SettingsView.tabKey) private var settingsTab = SettingsView.Tab.general
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    private static let suggestions = ["Radiohead", "Currents", "Espresso", "Hip-hop"]
    /// Below this content width the top result stacks above the songs and genres take two columns.
    private static let narrow: CGFloat = 700

    private enum Phase: Equatable {
        case idle, searching, noResults, results, rateLimited, failed
    }

    private var phase: Phase {
        if search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .idle }
        if search.state == .failed { return search.failure == .RateLimited ? .rateLimited : .failed }
        if search.groups.allSatisfy(\.hits.isEmpty) { return search.state == .searching ? .searching : .noResults }
        return .results
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Search")
            .onAppear {
                webAPI.reload()
                filter = .all
            }
            // A rejected refresh token is deleted by the provider.
            .onChange(of: search.state) { _, state in
                if state == .notConnected { webAPI.reload() }
            }
            .onChange(of: webAPI.isConnected) { _, connected in
                if connected, !search.query.isEmpty { search.search(search.query) }
            }
            .task(id: library.items[.artists]) { library.resolve((library.items[.artists] ?? []).map(\.uri)) }
    }

    @ViewBuilder private var content: some View {
        if !webAPI.isConnected {
            EmptyStateView(
                title: "Connect Spotify Web API to Search",
                systemImage: "key",
                message: "Search uses your own Spotify developer app. Add its Client ID in Settings."
            ) {
                Button("Open Settings") {
                    settingsTab = .account
                    openSettings()
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            }
        } else {
            switch phase {
            case .rateLimited:
                EmptyStateView(
                    title: "Search Is Rate Limited",
                    systemImage: "hourglass",
                    message: "Spotify is limiting requests from your Web API app. Try again in a minute."
                ) {
                    Button("Try Again") { search.search(search.query) }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                }
            case .failed:
                FailedState(title: "Couldn't Search") { search.search(search.query) }
            case .searching:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle, .noResults, .results:
                page
            }
        }
    }

    /// One scroll view for idle, no results and results, so typing never resets it.
    private var page: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    switch phase {
                    case .idle: idle
                    case .noResults: noResults
                    default: results(search.results)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Theme.s8)
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: phase)
            .onGeometryChange(for: CGFloat.self) { $0.size.width - 2 * Theme.s8 } action: { width = $0 }
            .accessibilityIdentifier(phase == .results ? "searchResults" : "searchPage")
            .onChange(of: selection) { _, id in
                if let id { withAnimation(reduceMotion ? nil : Theme.fast) { proxy.scrollTo(id) } }
            }
        }
    }

    private func run(_ query: String) {
        selection = nil
        search.search(query)
    }

    // MARK: Idle

    private var idle: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: String(localized: "Search"))
            if !recent.queries.isEmpty {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Recent searches", top: Theme.s6)
                    Spacer()
                    Button("Clear all") { withAnimation(Theme.fast) { recent.clear() } }
                        .buttonStyle(LinkButtonStyle())
                }
                .padding(.horizontal, Theme.s8)
                FlowLayout(spacing: Theme.s2) {
                    ForEach(recent.queries, id: \.self) { query in
                        RecentChip(query: query, run: run) { removed in
                            withAnimation(Theme.fast) { recent.remove(removed) }
                        }
                    }
                }
                .padding(.horizontal, Theme.s8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("recentSearches")
            }
            let followed = followedArtists
            if !followed.isEmpty {
                SectionHeader(title: "Artists you follow").padding(.horizontal, Theme.s8)
                CardRail {
                    ForEach(followed, id: \.uri) { artist in
                        MediaCard(
                            title: artist.name, subtitle: String(localized: "Artist"), artwork: artist.artwork, round: true
                        ) { history.navigate(to: .artist(uri: artist.uri)) }
                    }
                }
            }
            SectionHeader(title: "Browse all").padding(.horizontal, Theme.s8)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Theme.s4), count: width < Self.narrow ? 2 : 3),
                spacing: Theme.s4
            ) {
                ForEach(Genre.all, id: \.name) { genre in
                    GenreCard(genre: genre) { run(genre.name) }
                }
            }
            .padding(.horizontal, Theme.s8)
        }
    }

    private var followedArtists: [ArtistMetadata] {
        (library.items[.artists] ?? []).compactMap { item in
            guard case let .artist(artist) = library.metadata[item.uri] else { return nil }
            return artist
        }
    }

    // MARK: No results

    private var noResults: some View {
        VStack(spacing: Theme.s3) {
            Image(systemName: "magnifyingglass")
                .scaledFont(size: 40, weight: .light)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("No results for “\(search.query.trimmingCharacters(in: .whitespacesAndNewlines))”")
                .scaledFont(size: 17, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Text("Check the spelling, or try one of these:")
                .foregroundStyle(.secondary)
            HStack(spacing: Theme.s2) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion) { run(suggestion) }
                        .buttonStyle(ChipStyle())
                }
            }
            .padding(.top, Theme.s2)
        }
        .scaledFont(size: 14)
        .padding(.vertical, Theme.s12)
        .padding(.horizontal, Theme.s8)
        .frame(maxWidth: .infinity)
    }

    // MARK: Results

    private func results(_ results: SearchResults) -> some View {
        let shown = results.shown(filter)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.s2) {
                ForEach(SearchFilter.allCases, id: \.self) { chip in
                    let count = chip.kind.map(results.count)
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { filter = chip }
                    } label: {
                        HStack(spacing: 6) {
                            Text(chip.title)
                            if let count {
                                Text(count, format: .number)
                                    .fontWeight(.medium)
                                    .monospacedDigit()
                                    .opacity(0.72)
                            }
                        }
                    }
                    .buttonStyle(ChipStyle(selected: shown == chip))
                    .disabled(count == 0)
                    .accessibilityLabel(count.map { Text("\(chip.title), \($0) results") } ?? Text(chip.title))
                    .accessibilityAddTraits(shown == chip ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.s8)
            .padding(.top, Theme.s2)
            switch shown {
            case .all:
                all(results)
            case .songs:
                songList(results.hits(.track))
                    .padding(.horizontal, Theme.s6)
                    .padding(.top, Theme.s6)
                showMore(.track)
            default:
                if let kind = shown.kind {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: MediaCard.width), spacing: Theme.s4, alignment: .top)],
                        alignment: .leading,
                        spacing: Theme.s4
                    ) {
                        ForEach(results.hits(kind), id: \.uri) { card($0, kind) }
                    }
                    .padding(.horizontal, Theme.s6)
                    .padding(.top, Theme.s6)
                    showMore(kind)
                }
            }
        }
    }

    private func all(_ results: SearchResults) -> some View {
        let columns = width >= Self.narrow
        let layout = columns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: Theme.s6))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
        let songs = results.hits(.track)
        return VStack(alignment: .leading, spacing: 0) {
            layout {
                if let top = results.top {
                    let id = SearchResultID(top: true, kind: top.kind, uri: top.hit.uri)
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(title: "Top result", top: Theme.s6)
                        TopResultCard(hit: top.hit, kind: top.kind, selected: selection == id) { activate(id) }
                            .id(id)
                    }
                    .frame(width: columns ? (width - Theme.s6) * 0.4 : nil)
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: "Songs", top: Theme.s6)
                        Spacer()
                        if results.count(.track) > 4 {
                            Button("See all") { filter = .songs }
                                .buttonStyle(LinkButtonStyle())
                        }
                    }
                    if songs.isEmpty {
                        Text("No songs match.")
                            .modifier(Theme.cardSubtitle)
                            .foregroundStyle(.secondary)
                    } else {
                        songList(Array(songs.prefix(4)))
                            .padding(.horizontal, -Theme.s2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Theme.s8)
            ForEach(results.groups.filter { $0.kind != .track }, id: \.kind) { group in
                SectionHeader(title: LocalizedStringKey(group.kind.title)).padding(.horizontal, Theme.s8)
                CardRail {
                    ForEach(group.hits, id: \.uri) { card($0, group.kind) }
                }
            }
        }
    }

    private func songList(_ songs: [SearchHit]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.element.uri) { index, hit in
                let id = SearchResultID(top: false, kind: .track, uri: hit.uri)
                SongRow(
                    number: index + 1,
                    hit: hit,
                    selected: selection == id,
                    playing: player?.nowPlaying?.uri == hit.uri,
                    saved: library.isSaved(hit.uri),
                    select: { selection = id },
                    open: { activate(id) },
                    playNext: { player?.playNext([hit.uri]) },
                    addToQueue: { player?.addToQueue([hit.uri]) },
                    toggleSaved: { library.setSaved(hit.uri, !library.isSaved(hit.uri)) }
                )
                .id(id)
            }
        }
    }

    private func card(_ hit: SearchHit, _ kind: SearchKind) -> some View {
        let id = SearchResultID(top: false, kind: kind, uri: hit.uri)
        return MediaCard(
            title: hit.name, subtitle: hit.subtitle, artwork: hit.artwork,
            round: kind == .artist, playable: kind.plays,
            grouped: true, selected: selection == id
        ) { activate(id) }
        .id(id)
    }

    @ViewBuilder private func showMore(_ kind: SearchKind) -> some View {
        if search.hasMore(kind) {
            Button("Show More") { search.loadMore(kind) }
                .buttonStyle(LinkButtonStyle())
                .padding(.horizontal, Theme.s8)
                .padding(.top, Theme.s4)
        }
    }

    private func activate(_ id: SearchResultID) {
        search.open(id, recent: recent, player: player, history: history)
    }
}

extension SearchModel {
    var results: SearchResults {
        SearchResults(groups: groups, query: query)
    }

    /// Plays tracks and episodes; opens the page of anything else.
    func open(_ id: SearchResultID, recent: RecentSearches, player: PlayerModel?, history: NavigationHistory) {
        recent.add(query)
        switch id.kind {
        case .track:
            let tracks = results.hits(.track).map(\.uri)
            if !id.top, let index = tracks.firstIndex(of: id.uri) {
                player?.play(tracks, from: index)
            } else {
                player?.play([id.uri], from: 0)
            }
        case .episode:
            player?.play([id.uri], from: 0)
        case .artist:
            history.navigate(to: .artist(uri: id.uri))
        case .album:
            history.navigate(to: .album(uri: id.uri))
        case .playlist:
            history.navigate(to: .playlist(uri: id.uri))
        case .show:
            history.navigate(to: .show(uri: id.uri))
        }
    }
}

private extension SearchResults {
    /// Results in display order, for arrow keys.
    func ordered(_ filter: SearchFilter) -> [SearchResultID] {
        func ids(_ kind: SearchKind, _ hits: some Sequence<SearchHit>) -> [SearchResultID] {
            hits.map { SearchResultID(top: false, kind: kind, uri: $0.uri) }
        }
        guard let kind = shown(filter).kind else {
            let top = top.map { [SearchResultID(top: true, kind: $0.kind, uri: $0.hit.uri)] } ?? []
            return top + ids(.track, hits(.track).prefix(4))
                + groups.filter { $0.kind != .track }.flatMap { ids($0.kind, $0.hits) }
        }
        return ids(kind, hits(kind))
    }
}

/// The top result repeats its hit from the section below, so `top` keeps the ids apart.
struct SearchResultID: Hashable {
    let top: Bool
    let kind: SearchKind
    let uri: String
}

/// The top result (`.tr-card`): large art and name on a fill, with a play button for what plays.
private struct TopResultCard: View {
    let hit: SearchHit
    let kind: SearchKind
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s4) {
            ArtworkView(artwork: hit.artwork, side: 96)
                .clipShape(kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Theme.smallRadius)))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name)
                    .modifier(Theme.greeting)
                    .lineLimit(1)
                Text(subtitle)
                    .modifier(Theme.cardSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(Theme.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected || hovering ? Color.fillStrong : Color.fill, in: .rect(cornerRadius: Theme.cardRadius, style: .continuous))
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(hit.name), \(subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .overlay(alignment: .bottomTrailing) {
            // shortcut: artists, albums and playlists open their page instead of a Play button,
            // since search hits carry no track list; play them here once one can be fetched.
            if kind.plays {
                PlayFab(label: "Play", action: open).padding(Theme.s5)
            }
        }
        .onHover { hovering = $0 }
        .animation(Theme.fast, value: hovering)
    }

    /// "Artist", "Album · Daft Punk", "Song · SZA", as `.card-sub` reads.
    private var subtitle: String {
        kind == .artist || kind == .playlist || hit.subtitle.isEmpty ? kind.singular : "\(kind.singular) · \(hit.subtitle)"
    }
}

/// A track row (`.trow` without the album column): number, or play on hover; a click
/// selects, a double click plays.
private struct SongRow: View {
    let number: Int
    let hit: SearchHit
    let selected: Bool
    let playing: Bool
    let saved: Bool
    let select: () -> Void
    let open: () -> Void
    let playNext: () -> Void
    let addToQueue: () -> Void
    let toggleSaved: () -> Void
    @State private var hovering = false
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Theme.s3) {
            Group {
                if hovering {
                    Button(action: open) {
                        Image(systemName: "play.fill")
                            .frame(width: 36, height: 36)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Play \(hit.name)")
                } else {
                    Text(number, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 40)
            ArtworkView(artwork: hit.artwork, side: 40)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name)
                    .scaledFont(size: 14, weight: .medium)
                    .foregroundStyle(playing ? Color(palette.tintText) : Color.primary)
                    .lineLimit(1)
                Text(hit.subtitle)
                    .scaledFont(size: 13)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s2)
        .frame(minHeight: 56)
        .background(
            selected ? Color.fillStrong : hovering ? Color.fill : .clear,
            in: .rect(cornerRadius: Theme.smallRadius, style: .continuous)
        )
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: open)
        // Simultaneous, so a single click selects at once instead of waiting out the double-click interval.
        .simultaneousGesture(TapGesture().onEnded(select))
        .contextMenu {
            Button("Play", action: open)
            Button("Play Next", action: playNext)
            Button("Add to Queue", action: addToQueue)
            Divider()
            Button(saved ? "Remove from Liked Songs" : "Save to Liked Songs", action: toggleSaved)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(hit.subtitle.isEmpty ? hit.name : "\(hit.name), \(hit.subtitle)")
        .accessibilityValue(playing ? "Playing" : "")
        .accessibilityHint("Double-click to play")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { open() }
        .onHover { hovering = $0 }
    }
}

/// A recent search (`.rchip`): the query runs it, the cross removes it.
private struct RecentChip: View {
    let query: String
    let run: (String) -> Void
    let remove: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { run(query) } label: {
                Text(query)
                    .padding(.leading, Theme.s4)
                    .padding(.trailing, Theme.s1)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(query)
            Button { remove(query) } label: {
                Image(systemName: "xmark")
                    .scaledFont(size: 10, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(query) from recent searches")
            .padding(.trailing, 2)
        }
        .modifier(Theme.cardTitle)
        .frame(height: 32)
        .background(Color.fillStrong, in: .capsule)
    }
}

/// A filter or suggestion chip (`.chip`); the selected one is drawn in the text color.
private struct ChipStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        Chip(configuration: configuration, selected: selected)
    }

    private struct Chip: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .modifier(Theme.cardTitle)
                .foregroundStyle(selected ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
                .padding(.horizontal, Theme.s4)
                .frame(height: 32)
                .background(
                    selected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(hovering && isEnabled ? 0.18 : 0.12)),
                    in: .capsule
                )
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(.capsule)
                .onHover { hovering = $0 }
                .animation(Theme.fast, value: hovering)
        }
    }
}

/// A text button (`.link-btn`): secondary, underlined in the text color on hover.
private struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Link(configuration: configuration)
    }

    private struct Link: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .modifier(Theme.cardTitle)
                .foregroundStyle(hovering ? .primary : .secondary)
                .underline(hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// A Browse all tile (`.genre`): the genre's album colors behind its name; a click searches for it.
// shortcut: no tilted album art, since the mockup's covers are commercial art not in the repo;
// add it once genres come from Spotify with their own images.
private struct GenreCard: View {
    let genre: Genre
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let palette = AdaptivePalette(accent: genre.accent, dominant: genre.dominant, dark: true)
        Button(action: open) {
            Color(palette.tint)
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    Text(genre.name)
                        .modifier(Theme.sectionTitle)
                        .foregroundStyle(Color(palette.tintInk))
                        .padding(Theme.s4)
                }
                .clipShape(.rect(cornerRadius: Theme.cardRadius, style: .continuous))
                .scaleEffect(hovering && !reduceMotion ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(genre.name)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

/// The design's genres, each colored by the palette of the album it shows (`GENRES`).
private struct Genre {
    let name: String
    let accent: RGB
    let dominant: RGB

    static let all = [
        ("Pop", "#4a7bd0", "#2a5098"),
        ("Hip-hop", "#a4a8b4", "#2a2b30"),
        ("R&B", "#3a6ea8", "#02152d"),
        ("Electronic", "#c9b27c", "#090d0e"),
        ("Alternative", "#e69131", "#0b0a0b"),
        ("Psychedelic", "#9a6ab0", "#65516a"),
    ].map { Genre(name: $0, accent: RGB(hex: $1)!, dominant: RGB(hex: $2)!) }
}

/// Lays chips out in rows, wrapping to the next row when one is full (`.od-cluster`).
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        for (view, frame) in zip(subviews, arrange(width: bounds.width, subviews).frames) {
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            maxX = max(maxX, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: maxX, height: y + rowHeight))
    }
}

private extension SearchFilter {
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .songs: String(localized: "Songs")
        case .artists: String(localized: "Artists")
        case .albums: String(localized: "Albums")
        case .playlists: String(localized: "Playlists")
        }
    }
}

private extension SearchKind {
    var title: String {
        switch self {
        case .track: String(localized: "Songs")
        case .artist: String(localized: "Artists")
        case .album: String(localized: "Albums")
        case .playlist: String(localized: "Playlists")
        case .show: String(localized: "Podcasts")
        case .episode: String(localized: "Episodes")
        }
    }

    var plays: Bool {
        self == .track || self == .episode
    }

    var singular: String {
        switch self {
        case .track: String(localized: "Song")
        case .artist: String(localized: "Artist")
        case .album: String(localized: "Album")
        case .playlist: String(localized: "Playlist")
        case .show: String(localized: "Podcast")
        case .episode: String(localized: "Episode")
        }
    }
}
