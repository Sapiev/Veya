import SpotCoreKit
import SwiftUI

/// The window's inspector: what plays now, what the user queued, and the rest of the context.
struct QueuePanel: View {
    let player: PlayerModel?
    let library: LibraryModel
    let playlists: PlaylistModel
    @State private var selection: Set<Int> = []
    @FocusState private var listFocused: Bool

    /// Rows resolve metadata in batches of this size as they scroll in.
    private static let resolveAhead = 50

    var body: some View {
        Group {
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
        // Track list rows drag their URIs.
        .dropDestination(for: String.self) { uris, _ in
            guard let player, !uris.isEmpty else { return false }
            player.addToQueue(uris)
            return true
        }
        .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
    }

    private func queue(_ player: PlayerModel) -> some View {
        List(selection: $selection) {
            if let current = player.nowPlaying {
                Section {
                    QueueRow(uri: current.uri, library: library, current: true)
                        .task(id: current.uri) { library.resolve([current.uri]) }
                        .selectionDisabled()
                } header: {
                    QueueLabel(title: Text("Now Playing"))
                }
            }
            Section {
                if player.upNext.isEmpty {
                    Text("Songs you add to the queue play next.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, uri in
                    QueueRow(uri: uri, library: library)
                        .task(id: uri) { Self.resolve(player.upNext, from: offset, in: library) }
                        .contextMenu {
                            Button("Remove from Queue") { player.removeFromUpNext(at: removal(offset)) }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { player.removeFromUpNext(at: [offset]) }
                        }
                        .tag(offset)
                }
                .onMove { player.moveInUpNext(fromOffsets: $0, toOffset: $1) }
            } header: {
                HStack {
                    QueueLabel(title: Text("Next in Queue"))
                    Spacer()
                    Button("Clear Queue") { player.clearUpNext() }
                        .buttonStyle(.borderless)
                        .disabled(player.upNext.isEmpty)
                }
            }
            if !player.nextFromContext.isEmpty {
                Section {
                    // Negative ids keep these rows apart from Up Next's, whose ids are their positions.
                    ForEach(player.nextFromContext.indices.map { -1 - $0 }, id: \.self) { id in
                        let offset = -1 - id
                        QueueRow(uri: player.nextFromContext[offset], library: library)
                            .task(id: player.nextFromContext[offset]) {
                                Self.resolve(player.nextFromContext, from: offset, in: library)
                            }
                            .selectionDisabled()
                    }
                } header: {
                    QueueLabel(title: Text(nextFromTitle(player.context)))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("queue")
        // A row click selects without focusing the list, which Delete and the arrow keys need.
        .focused($listFocused)
        .onChange(of: selection) { if !selection.isEmpty { listFocused = true } }
        .onDeleteCommand {
            player.removeFromUpNext(at: IndexSet(selection))
            selection = []
        }
        .onChange(of: player.upNext) { selection = [] }
        .task(id: player.context) {
            if let context = player.context { library.resolve([context]) }
        }
    }

    /// The selection when the clicked row is part of it, else just that row.
    private func removal(_ offset: Int) -> IndexSet {
        selection.contains(offset) ? IndexSet(selection) : [offset]
    }

    static func resolve(_ uris: [String], from offset: Int, in library: LibraryModel) {
        library.resolve(Array(uris[offset ..< min(offset + resolveAhead, uris.count)]))
    }

    private func nextFromTitle(_ context: String?) -> String {
        guard let name = context.flatMap(contextName) else { return String(localized: "Next Up") }
        return String(localized: "Next From: \(name)")
    }

    private func contextName(_ uri: String) -> String? {
        for case let .playlist(playlistURI, name, _, _, _) in playlists.rootlist where playlistURI == uri {
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
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

/// A queued song: artwork, title and artists; the playing one's title in the tint, white over artwork.
struct QueueRow: View {
    let uri: String
    let library: LibraryModel
    var current = false
    var onArtwork = false
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        let item = library.metadata[uri]
        let row = TrackList.Row(number: 0, entry: TrackEntry(uri: uri), item: item)
        HStack(spacing: Theme.s3) {
            ArtworkView(artwork: Self.artwork(item), side: 40)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title.isEmpty ? String(localized: "Loading…") : row.title)
                    .font(.system(size: 13, weight: current && onArtwork ? .bold : .regular))
                    .foregroundStyle(titleColor)
                Text(row.artists.map(\.name).formatted(.list(type: .and)))
                    .font(.system(size: 12))
                    .foregroundStyle(onArtwork ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.secondary))
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, Theme.s2)
        .frame(minHeight: 52)
        .background(hovering ? (onArtwork ? .white.opacity(0.1) : .fill) : .clear, in: .rect(cornerRadius: Theme.smallRadius))
        .onHover { hovering = $0 }
        .opacity(row.playable ? 1 : 0.4)
    }

    private var titleColor: Color {
        if onArtwork { .white } else if current { Color(palette.tintText) } else { .primary }
    }

    private static func artwork(_ item: MetadataItem?) -> [Artwork] {
        switch item {
        case let .track(track): track.artwork
        case let .episode(episode): episode.artwork
        default: []
        }
    }
}
