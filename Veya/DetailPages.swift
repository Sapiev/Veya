import SpotCoreKit
import SwiftUI

extension LibraryModel {
    /// One item's lookup as a load state: failed only when nothing was found.
    func lookupState(_ uri: String) -> LibraryLoadState {
        if metadata[uri] != nil { return .loaded }
        return unresolved.contains(uri) ? .failed : .loading
    }
}

/// Album header, play and shuffle, tracks and copyright.
struct AlbumPage: View {
    let uri: String
    let library: LibraryModel
    let player: PlayerModel?
    let playlists: PlaylistModel
    let history: NavigationHistory

    var body: some View {
        let album: AlbumMetadata? = if case let .album(album) = library.metadata[uri] { album } else { nil }
        LoadStateView(
            state: library.lookupState(uri),
            isEmpty: album == nil,
            empty: EmptyState(title: "Album Unavailable", systemImage: "square.stack", message: "Spotify can't show this album."),
            failureTitle: "Couldn't Load Album",
            retry: { library.resolve([uri]) }
        ) {
            if let album {
                content(album)
            }
        }
        .navigationTitle(album?.title ?? String(localized: "Album"))
        .task(id: uri) { library.resolve([uri]) }
    }

    private func content(_ album: AlbumMetadata) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 20) {
                ArtworkView(artwork: album.artwork, side: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 6) {
                    PageHeading(title: album.title)
                    ArtistLinks(artists: album.artists) { history.navigate(to: .artist(uri: $0)) }
                        .font(.title3)
                    Text(summary(album))
                        .foregroundStyle(.secondary)
                    PlayButtons(uris: album.tracks, context: album.uri, player: player)
                        .padding(.top, 6)
                }
            }
            .padding(20)
            TrackList(
                entries: album.tracks.map { TrackEntry(uri: $0, addedAt: nil) },
                context: album.uri,
                library: library,
                player: player,
                playlists: playlists,
                history: history
            )
            if !album.copyrights.isEmpty {
                Text(album.copyrights.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        }
        .task(id: album.tracks) { library.resolve(album.tracks) }
    }

    /// "2024 · 12 songs, 48 min"; the length appears once every track is known.
    private func summary(_ album: AlbumMetadata) -> String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        var count = String(localized: "\(album.tracks.count) songs")
        let durations = album.tracks.compactMap { uri -> UInt32? in
            if case let .track(track) = library.metadata[uri] { track.durationMs } else { nil }
        }
        if !album.tracks.isEmpty, durations.count == album.tracks.count {
            let total = Duration.milliseconds(durations.reduce(0) { $0 + Int($1) })
            count += ", " + total.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        }
        parts.append(count)
        return parts.joined(separator: " · ")
    }
}

/// Artist header, top tracks, discography by group, related artists and Follow.
struct ArtistPage: View {
    let uri: String
    let library: LibraryModel
    let player: PlayerModel?
    let history: NavigationHistory

    var body: some View {
        let artist: ArtistMetadata? = if case let .artist(artist) = library.metadata[uri] { artist } else { nil }
        LoadStateView(
            state: library.lookupState(uri),
            isEmpty: artist == nil,
            empty: EmptyState(title: "Artist Unavailable", systemImage: "music.mic", message: "Spotify can't show this artist."),
            failureTitle: "Couldn't Load Artist",
            retry: { library.resolve([uri]) }
        ) {
            if let artist {
                content(artist)
            }
        }
        .navigationTitle(artist?.name ?? String(localized: "Artist"))
        .task(id: uri) {
            library.resolve([uri])
            library.load(.artists)
        }
    }

    private func content(_ artist: ArtistMetadata) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom, spacing: 20) {
                    ArtworkView(artwork: artist.artwork, side: 160)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 10) {
                        PageHeading(title: artist.name)
                        HStack {
                            PlayButtons(uris: artist.topTracks, context: artist.uri, player: player)
                            let following = library.isSaved(artist.uri)
                            Button(following ? "Following" : "Follow") { library.setSaved(artist.uri, !following) }
                                .accessibilityValue(following ? Text("On") : Text("Off"))
                        }
                    }
                }
                if !artist.topTracks.isEmpty {
                    PageSection(title: "Popular") {
                        TopTracks(uris: artist.topTracks, context: artist.uri, library: library, player: player)
                    }
                }
                AlbumGrid(title: "Albums", uris: artist.albums, library: library, history: history)
                AlbumGrid(title: "Singles and EPs", uris: artist.singles, library: library, history: history)
                AlbumGrid(title: "Compilations", uris: artist.compilations, library: library, history: history)
                if !artist.related.isEmpty {
                    PageSection(title: "Fans Also Like") {
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(artist.related, id: \.uri) { related in
                                    Card(
                                        title: related.name,
                                        artwork: artwork(related.uri),
                                        round: true
                                    ) { history.navigate(to: .artist(uri: related.uri)) }
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                }
            }
            .padding(20)
        }
        .task(id: artist) {
            library.resolve(artist.topTracks + artist.albums + artist.singles + artist.compilations + artist.related.map(\.uri))
        }
    }

    private func artwork(_ uri: String) -> [Artwork] {
        if case let .artist(artist) = library.metadata[uri] { artist.artwork } else { [] }
    }
}

/// Playlist header, description, owner, play and shuffle, filter and tracks.
struct PlaylistPageView: View {
    let uri: String
    let library: LibraryModel
    let player: PlayerModel?
    let playlists: PlaylistModel
    let history: NavigationHistory
    @State private var filter = ""

    var body: some View {
        let page = playlists.pages[uri]
        VStack(alignment: .leading, spacing: 0) {
            if let page {
                header(page)
            }
            LoadStateView(
                state: playlists.pageState[uri],
                isEmpty: page?.tracks.isEmpty ?? true,
                empty: EmptyState(title: "No Songs", systemImage: "music.note.list", message: "Songs added to this playlist appear here."),
                failureTitle: "Couldn't Load Playlist",
                retry: { playlists.loadPage(uri) }
            ) {
                let entries = filtered(page?.tracks ?? [])
                if entries.isEmpty {
                    ContentUnavailableView.search(text: filter)
                } else {
                    TrackList(entries: entries, context: uri, library: library, player: player, playlists: playlists, history: history)
                }
            }
        }
        .navigationTitle(page?.name ?? String(localized: "Playlist"))
        .task(id: uri) { playlists.loadPage(uri) }
        .onChange(of: filter) {
            // Filtering matches titles, artists and albums, so every row needs its metadata.
            if !filter.isEmpty { library.resolve(page?.tracks.map(\.uri) ?? []) }
        }
    }

    private func header(_ page: PlaylistPage) -> some View {
        HStack(alignment: .bottom, spacing: 20) {
            ArtworkView(artwork: page.artwork, side: 160)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                PageHeading(title: page.name)
                if !page.description.isEmpty {
                    Text(page.description)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("By \(page.owner) · \(page.total) songs")
                    .foregroundStyle(.secondary)
                HStack {
                    PlayButtons(uris: page.tracks.map(\.uri), context: page.uri, player: player)
                    Spacer()
                    TextField("Filter", text: $filter)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                .padding(.top, 6)
            }
        }
        .padding(20)
    }

    private func filtered(_ tracks: [PlaylistTrack]) -> [TrackEntry] {
        let entries = tracks.map { TrackEntry(uri: $0.uri, addedAt: $0.addedAt == 0 ? nil : Date(timeIntervalSince1970: TimeInterval($0.addedAt))) }
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter { entry in
            guard case let .track(track) = library.metadata[entry.uri] else { return false }
            return ([track.title, track.album.name] + track.artists.map(\.name)).contains { $0.localizedStandardContains(query) }
        }
    }
}

struct PageHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.largeTitle.bold())
            .lineLimit(2)
            .accessibilityIdentifier("routeTitle")
    }
}

private struct PageSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold())
            content()
        }
    }
}

/// Play from the top, or turn shuffle on and play from a random track.
private struct PlayButtons: View {
    let uris: [String]
    let context: String
    let player: PlayerModel?

    var body: some View {
        HStack {
            Button("Play", systemImage: "play.fill") {
                player?.play(uris, from: 0, context: context)
            }
            .buttonStyle(.borderedProminent)
            // The now-playing bar has its own Play and Shuffle buttons.
            .accessibilityIdentifier("pagePlay")
            Button("Shuffle", systemImage: "shuffle") {
                player?.setShuffle(true)
                player?.play(uris, from: Int.random(in: uris.indices), context: context)
            }
            .accessibilityIdentifier("pageShuffle")
        }
        .disabled(uris.isEmpty || player == nil)
    }
}

/// The artist's most played tracks; clicking one plays the list from it.
private struct TopTracks: View {
    let uris: [String]
    let context: String
    let library: LibraryModel
    let player: PlayerModel?

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(uris.prefix(10).enumerated()), id: \.offset) { index, uri in
                let track: TrackMetadata? = if case let .track(track) = library.metadata[uri] { track } else { nil }
                Button {
                    player?.play(uris, from: index, context: context)
                } label: {
                    HStack {
                        Text(index + 1, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Text(track?.title ?? String(localized: "Loading…"))
                            .foregroundStyle(player?.nowPlaying?.uri == uri ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        Spacer()
                        if let track {
                            Text(Duration.milliseconds(Int(track.durationMs)).formatted(.time(pattern: .minuteSecond)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(track.map { $0.playability == .playable } ?? true ? 1 : 0.45)
            }
        }
        .frame(maxWidth: 560)
    }
}

/// One discography group as cards; hidden when the group is empty.
private struct AlbumGrid: View {
    let title: LocalizedStringKey
    let uris: [String]
    let library: LibraryModel
    let history: NavigationHistory

    var body: some View {
        if !uris.isEmpty {
            PageSection(title: title) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(uris, id: \.self) { uri in
                        let album: AlbumMetadata? = if case let .album(album) = library.metadata[uri] { album } else { nil }
                        Card(
                            title: album?.title ?? String(localized: "Loading…"),
                            subtitle: album?.year.map(String.init),
                            artwork: album?.artwork ?? []
                        ) { history.navigate(to: .album(uri: uri)) }
                    }
                }
            }
        }
    }
}

private struct Card: View {
    let title: String
    var subtitle: String?
    let artwork: [Artwork]
    var round = false
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                ArtworkView(artwork: artwork, side: 140)
                    .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 6)))
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 140, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
