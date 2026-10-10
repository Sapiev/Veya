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
            PageHero(kind: "Album", title: album.title, artwork: album.artwork) {
                HStack(spacing: 0) {
                    ArtistLinks(artists: album.artists) { history.navigate(to: .artist(uri: $0)) }
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                    Dot()
                    Text(summary(album))
                }
            }
            PageActions(uris: album.tracks, context: album.uri, player: player) {
                let saved = library.isSaved(album.uri)
                IconButton(
                    label: saved ? "Remove from Library" : "Save to Library",
                    systemImage: saved ? "heart.fill" : "heart",
                    isOn: saved
                ) { library.setSaved(album.uri, !saved) }
            }
            TrackList(
                entries: album.tracks.map { TrackEntry(uri: $0, addedAt: nil) },
                context: album.uri,
                library: library,
                player: player,
                playlists: playlists,
                history: history,
                showsAlbum: false
            )
            .scrollContentBackground(.hidden)
            if !album.copyrights.isEmpty {
                Text(album.copyrights.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.s8)
                    .padding(.vertical, Theme.s3)
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
        let fullBleed = artist.artwork.contains(where: \.isLarge)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if fullBleed {
                    ArtistHero(artist: artist)
                } else {
                    PageHero(kind: "Artist", title: artist.name, artwork: artist.artwork, round: true) { EmptyView() }
                }
                PageActions(uris: artist.topTracks, context: artist.uri, player: player) {
                    let following = library.isSaved(artist.uri)
                    Button(following ? "Following" : "Follow") { library.setSaved(artist.uri, !following) }
                        .buttonStyle(PillStyle(isOn: following))
                        .accessibilityValue(following ? Text("On") : Text("Off"))
                }
                VStack(alignment: .leading, spacing: 28) {
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
                .padding(.horizontal, Theme.s8)
                .padding(.bottom, Theme.s8)
            }
        }
        // The picture starts at the window's top edge, under the floating top bar (`.artist-hero` margin-top: -64px).
        .ignoresSafeArea(.container, edges: fullBleed ? .top : [])
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
                        .scrollContentBackground(.hidden)
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
        VStack(alignment: .leading, spacing: 0) {
            PageHero(kind: "Playlist", title: page.name, artwork: page.artwork, description: page.description) {
                HStack(spacing: 0) {
                    Text("By \(page.owner) · \(page.total) songs")
                    if let followers = playlists.followers[page.uri], followers > 0 {
                        Dot()
                        Text("\(followers.formatted()) followers")
                    }
                }
            }
            PageActions(uris: page.tracks.map(\.uri), context: page.uri, player: player) {
                Spacer()
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
            }
        }
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
            .font(Theme.heroTitle)
            .tracking(-1.7)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .accessibilityIdentifier("routeTitle")
    }
}

struct PageSection<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s3) {
            Text(title)
                .font(Theme.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// A detail page's header (`.hero`): artwork, kind, title, description and a
/// subtitle line over a wash of the palette's glow.
struct PageHero<Subtitle: View>: View {
    let kind: LocalizedStringKey
    let title: String
    let artwork: [Artwork]
    var round = false
    var description = ""
    @ViewBuilder let subtitle: () -> Subtitle
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .bottom, spacing: Theme.s6) {
            ArtworkView(artwork: artwork, side: 232)
                .overlay {
                    if artwork.isEmpty {
                        Image(systemName: "music.note")
                            .font(.system(size: 64))
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Theme.cardRadius)))
                .shadow(color: .black.opacity(0.4), radius: 25, y: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(kind)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                PageHeading(title: title)
                    .padding(.top, Theme.s1)
                    .padding(.bottom, Theme.s3)
                if !description.isEmpty {
                    Text(description)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                        .padding(.bottom, Theme.s2)
                }
                subtitle()
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        // The design's 340 pt hero starts under the 64 pt top bar; pages begin below the bar.
        .padding(.horizontal, Theme.s8)
        .padding(.top, 56)
        .padding(.bottom, Theme.s6)
        .frame(maxWidth: .infinity, minHeight: 276, alignment: .bottomLeading)
        .background {
            LinearGradient(colors: [Color(palette.glow).opacity(0.9), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }
}

/// The artist's picture full bleed (`.artist-hero`), darkening into the window's ambient color.
private struct ArtistHero: View {
    let artist: ArtistMetadata
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: Theme.s1) {
            Text("Artist")
                .font(.system(size: 12, weight: .semibold))
                .opacity(0.9)
            PageHeading(title: artist.name)
        }
        .foregroundStyle(dark ? Color.white : Color.primary)
        .shadow(color: dark ? .black.opacity(0.45) : .white.opacity(0.6), radius: 9, y: 2)
        .padding(.horizontal, Theme.s8)
        .padding(.bottom, Theme.s6)
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .bottomLeading)
        .background {
            GeometryReader { proxy in
                // Pulling past the top stretches the picture, so no gap opens above it.
                let pull = max(0, proxy.frame(in: .scrollView).minY)
                let height = proxy.size.height + pull
                let side = max(proxy.size.width, height)
                ZStack(alignment: .topLeading) {
                    // Faces sit near the top of artist photos; keep the upper fifth in view.
                    ArtworkView(artwork: artist.artwork, side: side)
                        .offset(y: -(side - height) * 0.22)
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.12), location: 0),
                            .init(color: .black.opacity(0.18), location: 0.45),
                            .init(color: Color(palette.ambient).opacity(0.92), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(width: proxy.size.width, height: height, alignment: .topLeading)
                .clipped()
                .offset(y: -pull)
            }
            .accessibilityHidden(true)
        }
    }
}

private extension Artwork {
    /// Big enough to fill the artist header; `width` is 0 when Spotify doesn't report it.
    var isLarge: Bool {
        width >= 600 || size == .large || size == .xLarge
    }
}

private struct Dot: View {
    var body: some View {
        Text(verbatim: "·")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .accessibilityHidden(true)
    }
}

/// The page's play from the top and shuffle, then page-specific controls (`.actions`).
private struct PageActions<Extra: View>: View {
    let uris: [String]
    let context: String
    let player: PlayerModel?
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        let disabled = uris.isEmpty || player == nil
        HStack(spacing: Theme.s4) {
            Group {
                PlayFab(label: "Play", large: true) {
                    player?.play(uris, from: 0, context: context)
                }
                // The now-playing bar has its own Play and Shuffle buttons.
                .accessibilityIdentifier("pagePlay")
                IconButton(label: "Shuffle", systemImage: "shuffle") {
                    player?.setShuffle(true)
                    player?.play(uris, from: Int.random(in: uris.indices), context: context)
                }
                .accessibilityIdentifier("pageShuffle")
            }
            .disabled(disabled)
            .opacity(disabled ? 0.4 : 1)
            extra()
        }
        .padding(.horizontal, Theme.s8)
        .padding(.vertical, Theme.s5)
    }
}

/// A 40 pt round icon button (`.icon-btn`); tinted while `isOn`.
private struct IconButton: View {
    let label: LocalizedStringKey
    let systemImage: String
    var isOn: Bool?
    let action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(width: 40, height: 40)
                .background(hovering ? Color.fill : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn == true ? AnyShapeStyle(Color(palette.tintText)) : hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .accessibilityLabel(Text(label))
        .accessibilityValue(isOn.map { $0 ? Text("On") : Text("Off") } ?? Text(verbatim: ""))
        .help(Text(label))
        .onHover { hovering = $0 }
        .animation(Theme.fast, value: hovering)
    }
}

/// An outlined capsule toggle (`.pill`), tinted while on.
private struct PillStyle: ButtonStyle {
    let isOn: Bool
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        let color = isOn ? Color(palette.tintText) : Color.primary
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, Theme.s4)
            .frame(height: 32)
            .overlay { Capsule().strokeBorder(isOn ? color : Color.primary.opacity(0.2)) }
            .contentShape(.capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The artist's most played tracks; clicking one plays the list from it.
private struct TopTracks: View {
    let uris: [String]
    let context: String
    let library: LibraryModel
    let player: PlayerModel?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(uris.prefix(10).enumerated()), id: \.offset) { index, uri in
                let track: TrackMetadata? = if case let .track(track) = library.metadata[uri] { track } else { nil }
                TopTrackRow(
                    number: index + 1,
                    track: track,
                    playing: player?.nowPlaying?.uri == uri,
                    animating: player?.isPlaying == true
                ) { play(from: index) }
            }
        }
        .frame(maxWidth: 640)
    }

    /// Like `TrackList`, refuses an unplayable track and leaves known ones out.
    private func play(from index: Int) {
        let playable = uris.filter { uri in
            if case let .track(track) = library.metadata[uri] { track.playability == .playable } else { true }
        }
        if let start = playable.firstIndex(of: uris[index]) {
            player?.play(playable, from: start, context: context)
        }
    }
}

private struct TopTrackRow: View {
    let number: Int
    let track: TrackMetadata?
    let playing: Bool
    let animating: Bool
    let play: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        let playability = track?.playability ?? .playable
        Button(action: play) {
            HStack(spacing: Theme.s3) {
                Group {
                    if playing {
                        Equalizer(animating: animating)
                    } else {
                        Text(number, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24)
                ArtworkView(artwork: track?.artwork ?? [], side: 40)
                    .clipShape(.rect(cornerRadius: 4))
                Text(track?.title ?? String(localized: "Loading…"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(playing ? AnyShapeStyle(Color(palette.tintText)) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Spacer()
                if let track {
                    Text(Duration.milliseconds(Int(track.durationMs)).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.s2)
            .frame(minHeight: 56)
            .background(hovering ? Color.fill : .clear, in: .rect(cornerRadius: Theme.smallRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(playability == .playable ? 1 : 0.45)
        .help(playability.unavailableHelp ?? "")
        .onHover { hovering = $0 }
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

struct Card: View {
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
