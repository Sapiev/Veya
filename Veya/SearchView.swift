import SpotCoreKit
import SwiftUI

extension FocusedValues {
    /// Opens Search and focuses its field in the key window (⌘F, ⌘L).
    @Entry var focusSearch: (() -> Void)?
}

/// The Search route: a query field, recent searches while it is empty, then
/// the top result and a section per kind.
struct SearchView: View {
    let search: SearchModel
    let recent: RecentSearches
    let player: PlayerModel?
    let history: NavigationHistory
    /// Bumped by ⌘F / ⌘L; each change focuses the field.
    let focusRequest: Int

    @FocusState private var fieldFocused: Bool
    @State private var selection: ResultID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("routeTitle")
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 12)
            field
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            content
        }
        .navigationTitle("Search")
        .onAppear { fieldFocused = true }
        .onChange(of: focusRequest) { fieldFocused = true }
    }

    // The field keeps focus while arrows move the selection, as in Spotlight,
    // because List swallows Return and its focus can't be tracked.
    private var field: some View {
        TextField("Search", text: query, prompt: Text("Artists, songs, albums or podcasts"))
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .focused($fieldFocused)
            .accessibilityIdentifier("searchField")
            .onKeyPress(.downArrow) {
                move(by: 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                move(by: -1)
                return .handled
            }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                activate(selection)
                return .handled
            }
            .onSubmit { recent.add(search.query) }
    }

    private var query: Binding<String> {
        Binding(get: { search.query }, set: {
            selection = nil
            search.search($0)
        })
    }

    @ViewBuilder private var content: some View {
        if search.query.trimmingCharacters(in: .whitespaces).isEmpty {
            RecentSearchesView(recent: recent) { query in
                search.search(query)
                recent.add(query)
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
            List(selection: $selection) {
                if let top {
                    Section("Top Result") {
                        HitRow(hit: top.hit, kind: top.id.kind, prominent: true).tag(top.id).id(top.id)
                    }
                }
                ForEach(search.groups.filter { !$0.hits.isEmpty }, id: \.kind) { group in
                    Section(group.kind.title) {
                        ForEach(group.hits, id: \.uri) { hit in
                            let id = ResultID(top: false, kind: group.kind, uri: hit.uri)
                            HitRow(hit: hit, kind: group.kind, prominent: false).tag(id).id(id)
                        }
                        if search.hasMore(group.kind) {
                            Button("Show More") { search.loadMore(group.kind) }
                                .buttonStyle(.borderless)
                                .selectionDisabled()
                        }
                    }
                }
            }
            .accessibilityIdentifier("searchResults")
            .contextMenu(forSelectionType: ResultID.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first { activate(id) }
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .background {
                // Return in the field is handled by onSubmit; this covers a clicked list.
                if !fieldFocused, let selection {
                    Button("Open") { activate(selection) }
                        .keyboardShortcut(.return, modifiers: [])
                        .hidden()
                }
            }
        }
    }

    private var top: (id: ResultID, hit: SearchHit)? {
        guard let group = search.groups.first(where: { !$0.hits.isEmpty }), let hit = group.hits.first else { return nil }
        return (ResultID(top: true, kind: group.kind, uri: hit.uri), hit)
    }

    /// Results in display order, for arrow keys.
    private var ordered: [ResultID] {
        let rest = search.groups.flatMap { group in
            group.hits.map { ResultID(top: false, kind: group.kind, uri: $0.uri) }
        }
        return (top.map { [$0.id] } ?? []) + rest
    }

    private func move(by delta: Int) {
        let ids = ordered
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) }.map { $0 + delta } ?? (delta > 0 ? 0 : ids.count - 1)
        selection = ids[min(max(index, 0), ids.count - 1)]
    }

    /// Plays tracks and episodes; opens the page of anything else.
    private func activate(_ id: ResultID) {
        recent.add(search.query)
        switch id.kind {
        case .track:
            let tracks = search.groups.first { $0.kind == .track }?.hits.map(\.uri) ?? []
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
private struct ResultID: Hashable {
    let top: Bool
    let kind: SearchKind
    let uri: String
}

private struct HitRow: View {
    let hit: SearchHit
    let kind: SearchKind
    let prominent: Bool

    var body: some View {
        let side: CGFloat = prominent ? 64 : 36
        HStack(spacing: 12) {
            ArtworkView(artwork: hit.artwork, side: side)
                .clipShape(kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 4)))
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.name)
                    .font(prominent ? .title2.bold() : .body)
                    .lineLimit(1)
                Text(prominent ? kind.singular : hit.subtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, prominent ? 6 : 2)
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
                HStack {
                    Text("Recent Searches")
                        .font(.headline)
                    Spacer()
                    Button("Clear", action: recent.clear)
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, 20)
                List(recent.queries, id: \.self) { query in
                    Button(query) { run(query) }
                        .buttonStyle(.plain)
                }
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
