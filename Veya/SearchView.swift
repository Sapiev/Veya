import AppKit
import SpotCoreKit
import SwiftUI

extension FocusedValues {
    /// Focuses the toolbar search field in the key window (⌘F, ⌘K, ⌘L).
    @Entry var focusSearch: (() -> Void)?
}

/// The toolbar search field (`.search-field`). Typing opens the Search route;
/// the field keeps focus while arrows move the selection, as in Spotlight.
struct SearchField: View {
    let search: SearchModel
    let recent: RecentSearches
    let player: PlayerModel?
    let history: NavigationHistory
    @Binding var selection: SearchResultID?
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
                Text(verbatim: "⌘K")
                    .font(.system(size: 11))
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
        let ids = search.ordered
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
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = prompt
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier("searchField")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
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

/// The Search route: recent searches while the toolbar query is empty, then
/// the top result beside the songs and a rail per kind.
struct SearchView: View {
    let search: SearchModel
    let webAPI: WebAPIConnection
    let recent: RecentSearches
    let player: PlayerModel?
    let history: NavigationHistory
    @Binding var selection: SearchResultID?
    @AppStorage(SettingsView.tabKey) private var settingsTab = SettingsView.Tab.general
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationTitle("Search")
            .onAppear { webAPI.reload() }
            // A rejected refresh token is deleted by the provider.
            .onChange(of: search.state) { _, state in
                if state == .notConnected { webAPI.reload() }
            }
            .onChange(of: webAPI.isConnected) { _, connected in
                if connected, !search.query.isEmpty { search.search(search.query) }
            }
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
        } else if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle(title: String(localized: "Search"))
                RecentSearchesView(recent: recent) { query in
                    search.search(query)
                    recent.add(query)
                }
            }
        } else if search.state == .failed, search.failure == .RateLimited {
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
        } else if search.state == .failed {
            FailedState(title: "Couldn't Search") { search.search(search.query) }
        } else if search.groups.allSatisfy(\.hits.isEmpty) {
            if search.state == .searching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: search.query)
            }
        } else {
            results
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: Theme.s6) {
                        if let top = search.top {
                            VStack(alignment: .leading, spacing: 0) {
                                SectionHeader(title: "Top Result")
                                TopResultCard(hit: top.hit, kind: top.id.kind, selected: selection == top.id) {
                                    activate(top.id)
                                }
                                .id(top.id)
                            }
                            .frame(minWidth: 220, maxWidth: 360)
                        }
                        if let songs = search.sections.first(where: { $0.kind == .track }) {
                            VStack(alignment: .leading, spacing: 0) {
                                header(songs.kind)
                                ForEach(songs.hits, id: \.uri) { hit in
                                    let id = SearchResultID(top: false, kind: .track, uri: hit.uri)
                                    SongRow(hit: hit, selected: selection == id) { activate(id) }.id(id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, Theme.s8)
                    ForEach(search.sections.filter { $0.kind != .track }, id: \.kind) { group in
                        header(group.kind).padding(.horizontal, Theme.s8)
                        CardRail {
                            ForEach(group.hits, id: \.uri) { hit in
                                let id = SearchResultID(top: false, kind: group.kind, uri: hit.uri)
                                MediaCard(
                                    title: hit.name, subtitle: hit.subtitle, artwork: hit.artwork,
                                    round: group.kind == .artist, playable: group.kind.plays,
                                    grouped: true, selected: selection == id
                                ) { activate(id) }
                                .id(id)
                            }
                        }
                    }
                }
                .padding(.bottom, Theme.s8)
            }
            .accessibilityIdentifier("searchResults")
            .onChange(of: selection) { _, id in
                if let id { withAnimation(Theme.fast) { proxy.scrollTo(id) } }
            }
        }
    }

    private func header(_ kind: SearchKind) -> some View {
        HStack(alignment: .lastTextBaseline) {
            SectionHeader(title: LocalizedStringKey(kind.title))
            Spacer()
            if search.hasMore(kind) {
                Button("Show More") { search.loadMore(kind) }
                    .buttonStyle(.borderless)
                    .font(Theme.cardTitle)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Theme.s3)
            }
        }
    }

    private func activate(_ id: SearchResultID) {
        search.open(id, recent: recent, player: player, history: history)
    }
}

private extension SearchModel {
    /// Non-empty groups with songs first, beside the top result, as they are drawn.
    var sections: [SearchGroup] {
        let groups = self.groups.filter { !$0.hits.isEmpty }
        return groups.filter { $0.kind == .track } + groups.filter { $0.kind != .track }
    }

    var top: (id: SearchResultID, hit: SearchHit)? {
        guard let group = groups.first(where: { !$0.hits.isEmpty }), let hit = group.hits.first else { return nil }
        return (SearchResultID(top: true, kind: group.kind, uri: hit.uri), hit)
    }

    /// Results in display order, for arrow keys.
    var ordered: [SearchResultID] {
        let rest = sections.flatMap { group in
            group.hits.map { SearchResultID(top: false, kind: group.kind, uri: $0.uri) }
        }
        return (top.map { [$0.id] } ?? []) + rest
    }

    /// Plays tracks and episodes; opens the page of anything else.
    func open(_ id: SearchResultID, recent: RecentSearches, player: PlayerModel?, history: NavigationHistory) {
        recent.add(query)
        switch id.kind {
        case .track:
            let tracks = groups.first { $0.kind == .track }?.hits.map(\.uri) ?? []
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
                    .font(Theme.greeting)
                    .lineLimit(1)
                Text(kind.singular)
                    .font(Theme.cardSubtitle)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(Theme.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected || hovering ? Color.fillStrong : Color.fill, in: .rect(cornerRadius: Theme.cardRadius))
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .overlay(alignment: .bottomTrailing) {
            if kind.plays {
                PlayFab(label: "Play", action: open).padding(Theme.s5)
            }
        }
        .onHover { hovering = $0 }
        .animation(Theme.fast, value: hovering)
    }
}

private struct SongRow: View {
    let hit: SearchHit
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Theme.s3) {
            ArtworkView(artwork: hit.artwork, side: 40)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Text(hit.subtitle)
                    .font(Theme.cardSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s2)
        .padding(.vertical, Theme.s1)
        .background(
            selected ? Color.fillStrong : hovering ? Color.fill : .clear,
            in: .rect(cornerRadius: Theme.smallRadius)
        )
        .contentShape(.rect)
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
        .onHover { hovering = $0 }
    }
}

private struct RecentSearchesView: View {
    let recent: RecentSearches
    let run: (String) -> Void

    var body: some View {
        if recent.queries.isEmpty {
            ContentUnavailableView(
                "No Recent Searches",
                systemImage: "magnifyingglass",
                description: Text("Search for artists, songs, albums or podcasts.")
            )
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .lastTextBaseline) {
                    SectionHeader(title: "Recent Searches")
                    Spacer()
                    Button("Clear", action: recent.clear)
                        .buttonStyle(.borderless)
                        .font(Theme.cardTitle)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Theme.s3)
                }
                .padding(.horizontal, Theme.s8)
                List(recent.queries, id: \.self) { query in
                    Button(query) { run(query) }
                        .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
                .contentMargins(.horizontal, Theme.s6, for: .scrollContent)
                .accessibilityIdentifier("recentSearches")
            }
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
