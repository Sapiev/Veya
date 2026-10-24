import SpotCoreKit
import SwiftUI

/// The floating queue panel: what plays now, what the user queued, and the rest of the context.
struct QueuePanel: View {
    let player: PlayerModel?
    let library: LibraryModel
    let playlists: PlaylistModel
    let close: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    /// The upcoming row the arrow keys are on, by its index in `upNext` then `nextFromContext`.
    @FocusState private var focused: Int?

    /// Rows resolve metadata in batches of this size as they scroll in.
    private static let resolveAhead = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Queue")
                    .scaledFont(size: 20, weight: .bold)
                Spacer()
                Button("Close Queue", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .scaledFont(size: 16, weight: .medium)
                    .frame(width: 28, height: 28)
                    .contentShape(.circle)
                    .buttonStyle(.plain)
                    .help("Close Queue")
            }
            .padding([.horizontal, .top], Theme.s5)
            .padding(.bottom, 18)
            if let player, player.nowPlaying != nil || !player.upNext.isEmpty || !player.nextFromContext.isEmpty {
                queue(player)
            } else {
                ContentUnavailableView(
                    "Nothing in the Queue",
                    systemImage: "list.bullet",
                    description: Text("Songs you play or add to the queue appear here.")
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queue Panel")
        .accessibilityIdentifier("queue")
        // Track list rows drag their URIs.
        .dropDestination(for: String.self) { uris, _ in
            guard let player, !uris.isEmpty else { return false }
            player.addToQueue(uris)
            return true
        }
    }

    private func queue(_ player: PlayerModel) -> some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let current = player.nowPlaying {
                    label(Text("Now playing"), first: true)
                    QueueRow(uri: current.uri, library: library, current: true)
                        .padding(.horizontal, Theme.s2)
                        .task(id: current.uri) { library.resolve([current.uri]) }
                }
                // Only songs the user queued; hidden while there are none.
                if !player.upNext.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        label(Text("Next in queue"), first: player.nowPlaying == nil)
                        Spacer()
                        Button("Clear queue", action: player.clearUpNext)
                            .buttonStyle(.plain)
                            .scaledFont(size: 13, weight: .medium)
                            .foregroundStyle(.secondary)
                            .padding(.trailing, Theme.s5)
                    }
                    // Negative ids keep these rows apart from the context's, whose ids are their positions.
                    // Rows carry their URI, so a shrinking list never re-reads a removed position.
                    ForEach(player.upNext.enumerated().map { (id: -1 - $0.offset, uri: $0.element) }, id: \.id) { item in
                        let offset = -1 - item.id
                        row(item.uri, in: player.upNext, at: offset, skip: offset, player: player)
                            .contextMenu {
                                Button("Remove from Queue") { player.removeFromUpNext(at: [offset]) }
                            }
                    }
                }
                if !player.nextFromContext.isEmpty {
                    label(Text(nextFromTitle(player.context)), first: player.nowPlaying == nil && player.upNext.isEmpty)
                    ForEach(Array(player.nextFromContext.enumerated()), id: \.offset) { offset, uri in
                        row(uri, in: player.nextFromContext, at: offset, skip: player.upNext.count + offset, player: player)
                    }
                }
            }
            .padding(.bottom, Theme.s3)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Upcoming Songs")
        }
        .arrowKeyList(Array(0 ..< player.upNext.count + player.nextFromContext.count), focus: $focused) { skip in
            let uri = (player.upNext + player.nextFromContext)[skip]
            // The same rule as clicking: a row that cannot play stays put.
            if TrackList.Row(number: 0, entry: TrackEntry(uri: uri), item: library.metadata[uri]).playable {
                player.skip(to: skip)
            }
        }
        // A new track starts the list over from the top.
        .id(player.nowPlaying?.uri)
        .task(id: player.context) {
            if let context = player.context, context != likedSongsContext {
                library.resolve([context])
            }
        }
    }

    private func row(_ uri: String, in uris: [String], at offset: Int, skip: Int, player: PlayerModel) -> some View {
        QueueRow(uri: uri, library: library) { player.skip(to: skip) }
            .focusRing($focused, equals: skip)
            .padding(.horizontal, Theme.s2)
            .task(id: uri) { Self.resolve(uris, from: offset, in: library) }
    }

    /// A section title (`.q-label`); the first sits under the header, the rest get room above.
    private func label(_ title: Text, first: Bool) -> some View {
        title
            .scaledFont(size: 14, weight: .semibold)
            .foregroundStyle(.primary.opacity(contrast.opacity(0.65)))
            .padding(.horizontal, Theme.s5)
            .padding(.top, first ? 0 : 28)
            .padding(.bottom, 10)
    }

    static func resolve(_ uris: [String], from offset: Int, in library: LibraryModel) {
        library.resolve(Array(uris[offset ..< min(offset + resolveAhead, uris.count)]))
    }

    private func nextFromTitle(_ context: String?) -> String {
        guard let name = context.flatMap(contextName) else { return String(localized: "Next up") }
        return String(localized: "Next from: \(name)")
    }

    private func contextName(_ uri: String) -> String? {
        if uri == likedSongsContext {
            return String(localized: "Liked Songs")
        }
        for case let .playlist(playlistURI, name, _, _, _, _, _) in playlists.rootlist where playlistURI == uri {
            return name
        }
        return switch library.metadata[uri] {
        case let .album(album): album.title
        case let .artist(artist): artist.name
        case let .show(show): show.name
        default: nil
        }
    }
}

/// A queue section title (`.q-label`).
struct QueueLabel: View {
    let title: Text

    var body: some View {
        title
            .scaledFont(size: 12, weight: .semibold)
            .foregroundStyle(.primary)
    }
}

/// A queued song: artwork, title and artists; the playing one's title in the tint, white over artwork.
/// With `play`, a click plays it and hovering shows a play glyph over the artwork.
struct QueueRow: View {
    let uri: String
    let library: LibraryModel
    var current = false
    var onArtwork = false
    var play: (() -> Void)?
    @Environment(\.palette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let item = library.metadata[uri]
        let row = TrackList.Row(number: 0, entry: TrackEntry(uri: uri), item: item)
        HStack(spacing: Theme.s3) {
            ArtworkView(artwork: Self.artwork(item), side: 39)
                .clipShape(.rect(cornerRadius: 4))
                .overlay {
                    if hovering, play != nil {
                        Image(systemName: "play.fill")
                            .scaledFont(size: 13)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black.opacity(0.45), in: .rect(cornerRadius: 4))
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title.isEmpty ? String(localized: "Loading…") : row.title)
                    .scaledFont(size: 15, weight: current && onArtwork ? .bold : .medium)
                    .foregroundStyle(titleColor)
                Text(artistNames(row))
                    .scaledFont(size: 14)
                    .foregroundStyle(
                        onArtwork ? .white.opacity(contrast.opacity(0.7)) : .primary.opacity(contrast.opacity(0.75))
                    )
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.s3)
        .frame(height: 50)
        .background(hovering ? (onArtwork ? .white.opacity(0.1) : .fill) : .clear, in: .rect(cornerRadius: Theme.smallRadius))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .onTapGesture {
            if row.playable {
                play?()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.title.isEmpty ? Text("Loading…") : Text("\(row.title), \(artistNames(row))"))
        .accessibilityValue(current ? Text("Now playing") : Text(row.unavailableHelp ?? ""))
        .accessibilityHint(play == nil || !row.playable ? Text("") : Text("Plays this song"))
        .accessibilityAddTraits(play == nil ? [] : .isButton)
        .accessibilityAction {
            if row.playable {
                play?()
            }
        }
        .accessibilityAction(named: "Play") {
            if row.playable {
                play?()
            }
        }
        .opacity(row.playable ? 1 : contrast.opacity(0.7))
    }

    private func artistNames(_ row: TrackList.Row) -> String {
        row.artists.map(\.name).formatted(.list(type: .and))
    }

    private var titleColor: Color {
        if onArtwork {
            .white
        } else if current {
            Color(palette.tintText)
        } else {
            .primary
        }
    }

    private static func artwork(_ item: MetadataItem?) -> [Artwork] {
        switch item {
        case let .track(track): track.artwork
        case let .episode(episode): episode.artwork
        default: []
        }
    }
}
