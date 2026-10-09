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
                Section("Now Playing") {
                    QueueRow(uri: current.uri, library: library)
                        .onAppear { library.resolve([current.uri]) }
                        .selectionDisabled()
                }
            }
            Section {
                if player.upNext.isEmpty {
                    Text("Songs you add to the queue play next.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(player.upNext.enumerated()), id: \.offset) { offset, uri in
                    QueueRow(uri: uri, library: library)
                        .onAppear { resolve(player.upNext, from: offset) }
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
                    Text("Next in Queue")
                    Spacer()
                    Button("Clear Queue") { player.clearUpNext() }
                        .buttonStyle(.borderless)
                        .disabled(player.upNext.isEmpty)
                }
            }
            if !player.nextFromContext.isEmpty {
                Section(nextFromTitle(player.context)) {
                    // Negative ids keep these rows apart from Up Next's, whose ids are their positions.
                    ForEach(player.nextFromContext.indices.map { -1 - $0 }, id: \.self) { id in
                        let offset = -1 - id
                        QueueRow(uri: player.nextFromContext[offset], library: library)
                            .onAppear { resolve(player.nextFromContext, from: offset) }
                            .selectionDisabled()
                    }
                }
            }
        }
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

    private func resolve(_ uris: [String], from offset: Int) {
        library.resolve(Array(uris[offset ..< min(offset + Self.resolveAhead, uris.count)]))
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

private struct QueueRow: View {
    let uri: String
    let library: LibraryModel

    var body: some View {
        let row = TrackList.Row(number: 0, entry: TrackEntry(uri: uri), item: library.metadata[uri])
        VStack(alignment: .leading, spacing: 1) {
            Text(row.title.isEmpty ? String(localized: "Loading…") : row.title)
                .lineLimit(1)
            Text(row.artists.map(\.name).formatted(.list(type: .and)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .opacity(row.playable ? 1 : 0.4)
    }
}
