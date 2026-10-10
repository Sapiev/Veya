import SpotCoreKit
import SwiftUI

/// A greeting over Jump Back In as quick tiles, then Made for You, followed artists and Recently Played;
/// a section that is empty or failed is hidden.
struct HomeView: View {
    let home: HomeModel
    let library: LibraryModel
    let player: PlayerModel?
    let history: NavigationHistory

    var body: some View {
        let recent = home.recentlyPlayed.compactMap { Tile($0) }
        let jumpBackIn = home.jumpBackIn.compactMap { Tile($0) }
        let madeForYou = home.madeForYou.map { Tile($0) }
        let artists = (library.items[.artists] ?? []).compactMap { library.metadata[$0.uri].flatMap(Tile.init) }
        VStack(alignment: .leading, spacing: 0) {
            LoadStateView(
                state: home.state,
                isEmpty: recent.isEmpty && jumpBackIn.isEmpty && madeForYou.isEmpty && !home.recentlyPlayedNeedsSignIn,
                empty: EmptyState(title: "Nothing Here Yet", systemImage: "house", message: "Music you play appears here."),
                failureTitle: "Couldn't Load Home",
                retry: { home.load() }
            ) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.greeting(at: .now))
                            .font(Theme.greeting)
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("greeting")
                            .padding(.horizontal, Theme.s8)
                            .padding(.top, Theme.s2)
                        if home.recentlyPlayedNeedsSignIn {
                            Label(
                                "Sign out and sign in again to see Recently Played and Jump Back In.",
                                systemImage: "info.circle"
                            )
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.s8)
                            .padding(.top, Theme.s4)
                        }
                        QuickAccess(tiles: jumpBackIn) { open($0) }
                        Shelf(title: "Made for you", tiles: madeForYou, subtitleLines: 2) { _, tile in open(tile) }
                        Shelf(title: "Artists you follow", tiles: artists) { _, tile in open(tile) }
                        Shelf(title: "Recently Played", tiles: recent) { index, _ in
                            let queue = recent.enumerated().filter { $0.element.playable }
                            if let start = queue.firstIndex(where: { $0.offset == index }) {
                                player?.play(queue.map(\.element.uri), from: start)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, Theme.s8)
                }
                .accessibilityIdentifier("home")
            }
        }
        .navigationTitle("Home")
        .task { home.load() }
        .task(id: library.items[.artists]) { library.resolve((library.items[.artists] ?? []).map(\.uri)) }
    }

    static func greeting(at date: Date) -> LocalizedStringKey {
        switch Calendar.current.component(.hour, from: date) {
        case ..<5: "Good night"
        case ..<12: "Good morning"
        case ..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    /// Tracks and episodes have no page, so they play instead.
    private func open(_ tile: Tile) {
        if let route = tile.route {
            history.navigate(to: route)
        } else if tile.playable {
            player?.play([tile.uri], from: 0)
        }
    }
}

/// One section as a row of cards; hidden when it has none.
private struct Shelf: View {
    let title: LocalizedStringKey
    let tiles: [Tile]
    var subtitleLines = 1
    let activate: (Int, Tile) -> Void

    var body: some View {
        if !tiles.isEmpty {
            SectionHeader(title: title)
                .padding(.horizontal, Theme.s8)
            CardRail {
                // Offsets as ids: a track played twice appears twice.
                ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                    MediaCard(
                        title: tile.title, subtitle: tile.subtitle, subtitleLines: subtitleLines, artwork: tile.artwork,
                        round: tile.round, playable: tile.route == nil && tile.playable
                    ) {
                        activate(index, tile)
                    }
                    .opacity(tile.playable ? 1 : 0.45)
                }
            }
        }
    }
}

/// The top shelf as an untitled grid of short tiles under the greeting (`.quick`); hidden when it has none.
private struct QuickAccess: View {
    let tiles: [Tile]
    let activate: (Tile) -> Void

    var body: some View {
        if !tiles.isEmpty {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.s2), count: 3), spacing: Theme.s2) {
                ForEach(Array(tiles.prefix(6).enumerated()), id: \.offset) { _, tile in
                    QuickTile(tile: tile) { activate(tile) }
                }
            }
            .padding(.horizontal, Theme.s8)
            .padding(.top, Theme.s4)
        }
    }
}

private struct QuickTile: View {
    let tile: Tile
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Theme.s3) {
                ArtworkView(artwork: tile.artwork, side: 56)
                    .clipShape(tile.round ? AnyShape(Circle()) : AnyShape(Rectangle()))
                Text(tile.title)
                    .font(Theme.cardTitle)
                    .lineLimit(1)
                Spacer(minLength: Theme.s2)
            }
            .frame(height: 56)
            .background(hovering ? Color.fillStrong : Color.fill)
            .clipShape(.rect(cornerRadius: Theme.smallRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tile.subtitle.map { "\(tile.title), \($0)" } ?? tile.title)
        .overlay(alignment: .trailing) {
            if tile.route == nil, tile.playable, hovering {
                HoverPlay(action: open).padding(.trailing, Theme.s2)
            }
        }
        .opacity(tile.playable ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(Theme.fast, value: hovering)
    }
}

/// What a card shows and the page it opens; `route` is nil for what plays instead.
private struct Tile {
    let uri: String
    let title: String
    var subtitle: String?
    let artwork: [Artwork]
    var round = false
    var route: Route?
    var playable = true
}

private extension Tile {
    init?(_ item: MetadataItem) {
        switch item {
        case let .track(track):
            self.init(uri: track.uri, title: track.title, subtitle: Self.names(track.artists), artwork: track.artwork)
            playable = track.playability == .playable
        case let .episode(episode):
            self.init(uri: episode.uri, title: episode.title, subtitle: episode.showName, artwork: episode.artwork)
            playable = episode.playability == .playable
        case let .album(album):
            self.init(
                uri: album.uri, title: album.title, subtitle: Self.names(album.artists), artwork: album.artwork,
                route: .album(uri: album.uri)
            )
        case let .artist(artist):
            self.init(
                uri: artist.uri, title: artist.name, subtitle: String(localized: "Artist"), artwork: artist.artwork,
                round: true, route: .artist(uri: artist.uri)
            )
        case let .show(show):
            self.init(
                uri: show.uri, title: show.name, subtitle: show.publisher, artwork: show.artwork, route: .show(uri: show.uri)
            )
        case .unavailable:
            return nil
        }
    }

    init(_ page: PlaylistPage) {
        self.init(
            uri: page.uri, title: page.name, subtitle: page.description.isEmpty ? nil : page.description,
            artwork: page.artwork, route: .playlist(uri: page.uri)
        )
    }

    init?(_ tile: HomeTile) {
        switch tile {
        case let .item(item): self.init(item)
        case let .playlist(page): self.init(page)
        }
    }

    private static func names(_ artists: [ItemRef]) -> String {
        artists.map(\.name).joined(separator: ", ")
    }
}
