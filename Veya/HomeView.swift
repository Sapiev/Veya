import SpotCoreKit
import SwiftUI

/// Recently Played, Jump Back In and Made for You; a section that is empty or failed is hidden.
struct HomeView: View {
    let home: HomeModel
    let player: PlayerModel?
    let history: NavigationHistory

    var body: some View {
        let recent = home.recentlyPlayed.compactMap { Tile($0) }
        let jumpBackIn = home.jumpBackIn.compactMap { Tile($0) }
        let madeForYou = home.madeForYou.map { Tile($0) }
        VStack(alignment: .leading, spacing: 0) {
            PageTitle(title: String(localized: "Home"))
            LoadStateView(
                state: home.state,
                isEmpty: recent.isEmpty && jumpBackIn.isEmpty && madeForYou.isEmpty && !home.recentlyPlayedNeedsSignIn,
                empty: EmptyState(title: "Nothing Here Yet", systemImage: "house", message: "Music you play appears here."),
                failureTitle: "Couldn't Load Home",
                retry: { home.load() }
            ) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if home.recentlyPlayedNeedsSignIn {
                            Label(
                                "Sign out and sign in again to see Recently Played and Jump Back In.",
                                systemImage: "info.circle"
                            )
                            .foregroundStyle(.secondary)
                        }
                        Shelf(title: "Recently Played", tiles: recent) { index, _ in
                            player?.play(recent.map(\.uri), from: index)
                        }
                        Shelf(title: "Jump Back In", tiles: jumpBackIn) { _, tile in open(tile) }
                        Shelf(title: "Made for You", tiles: madeForYou) { _, tile in open(tile) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .bottom], 20)
                }
            }
        }
        .navigationTitle("Home")
        .task { home.load() }
    }

    /// Tracks and episodes have no page, so they play instead.
    private func open(_ tile: Tile) {
        if let route = tile.route {
            history.navigate(to: route)
        } else {
            player?.play([tile.uri], from: 0)
        }
    }
}

/// One section as a row of cards; hidden when it has none.
private struct Shelf: View {
    let title: LocalizedStringKey
    let tiles: [Tile]
    let activate: (Int, Tile) -> Void

    var body: some View {
        if !tiles.isEmpty {
            PageSection(title: title) {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        // Offsets as ids: a track played twice appears twice.
                        ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                            Card(title: tile.title, subtitle: tile.subtitle, artwork: tile.artwork, round: tile.round) {
                                activate(index, tile)
                            }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
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
}

private extension Tile {
    init?(_ item: MetadataItem) {
        switch item {
        case let .track(track):
            self.init(uri: track.uri, title: track.title, subtitle: Self.names(track.artists), artwork: track.artwork)
        case let .episode(episode):
            self.init(uri: episode.uri, title: episode.title, subtitle: episode.showName, artwork: episode.artwork)
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
        self.init(uri: page.uri, title: page.name, artwork: page.artwork, route: .playlist(uri: page.uri))
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
