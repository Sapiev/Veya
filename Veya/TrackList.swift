import AppKit
import SpotCoreKit
import SwiftUI

/// One entry of a track list; `addedAt` is nil where the source has no date.
struct TrackEntry: Equatable {
    var uri: String
    var addedAt: Date?
}

/// Sortable, multi-select track table shared by Liked Songs, albums and playlists.
struct TrackList: View {
    let entries: [TrackEntry]
    /// Seeds autoplay radio after the list; nil for lists without a Spotify URI.
    let context: String?
    let library: LibraryModel
    let player: PlayerModel?
    let playlists: PlaylistModel
    let history: NavigationHistory
    @State private var selection: Set<Row.ID> = []
    @State private var sortOrder = [KeyPathComparator(\Row.number)]

    /// Rows resolve metadata in batches of this size as they scroll in.
    private static let resolveAhead = 50

    var body: some View {
        let rows = sortedRows
        Table(of: Row.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.number) { row in
                NumberCell(row: row, playing: isPlaying(row))
                    .onAppear { resolve(from: row.number - 1) }
            }
            .width(min: 28, ideal: 36, max: 56)
            TableColumn("Title", value: \.title) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title.isEmpty ? String(localized: "Loading…") : row.title)
                        .foregroundStyle(isPlaying(row) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Text(row.artists.map(\.name).formatted(.list(type: .and)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .opacity(row.playable ? 1 : 0.45)
                .help(row.unavailableHelp ?? "")
            }
            .width(min: 160, ideal: 280)
            TableColumn("Album", value: \.albumName) { row in
                Text(row.albumName)
                    .foregroundStyle(.secondary)
                    .opacity(row.playable ? 1 : 0.45)
                    .help(row.unavailableHelp ?? "")
            }
            .width(min: 100, ideal: 200)
            TableColumn("Date Added", value: \.addedSort) { row in
                Text(row.addedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Duration", value: \.durationMs) { row in
                Text(row.durationMs == 0 ? "" : Duration.milliseconds(Int(row.durationMs)).formatted(.time(pattern: .minuteSecond)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 56, ideal: 64, max: 90)
        } rows: {
            ForEach(rows) { row in
                TableRow(row).draggable(row.uri)
            }
        }
        .accessibilityIdentifier("trackList")
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            menu(for: rows.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            play(ids, in: rows)
        }
        .background(ReturnKeyMonitor {
            guard !selection.isEmpty else { return false }
            play(selection, in: sortedRows)
            return true
        })
        .onChange(of: sortOrder) {
            // Sorting by metadata needs every row's metadata, not only the visible ones.
            if sortOrder.first?.keyPath != \Row.number, sortOrder.first?.keyPath != \Row.addedSort {
                library.resolve(entries.map(\.uri))
            }
        }
    }

    @ViewBuilder private func menu(for rows: [Row]) -> some View {
        let uris = rows.map(\.uri)
        if !rows.isEmpty {
            Button("Play Next") { player?.playNext(uris) }
            Button("Add to Queue") { player?.addToQueue(uris) }
            // shortcut: spotcore has no playlist write API yet, enable once it does.
            Button("Add to Playlist") {}
                .disabled(true)
            Divider()
            if rows.count == 1, let row = rows.first {
                if let album = row.album {
                    Button("Go to Album") { history.navigate(to: .album(uri: album.uri)) }
                }
                ArtistMenu(artists: row.artists, history: history)
            }
            Button("Copy Link") { copyLinks(uris) }
            Divider()
            let allSaved = uris.allSatisfy(library.isSaved)
            Button(allSaved ? "Remove from Liked Songs" : "Save to Liked Songs") {
                for uri in uris {
                    library.setSaved(uri, !allSaved)
                }
            }
        }
    }

    private var sortedRows: [Row] {
        let rows = entries.enumerated().map { offset, entry in
            Row(number: offset + 1, entry: entry, item: library.metadata[entry.uri])
        }
        return sortOrder == [KeyPathComparator(\Row.number)] ? rows : rows.sorted(using: sortOrder)
    }

    /// Plays the list in its shown order from the first playable of `ids`,
    /// leaving out rows known to be unplayable; refuses when `ids` has none.
    private func play(_ ids: Set<Row.ID>, in rows: [Row]) {
        let playable = rows.filter(\.playable)
        if let index = playable.firstIndex(where: { ids.contains($0.id) }) {
            player?.play(playable.map(\.uri), from: index, context: context)
        }
    }

    private func isPlaying(_ row: Row) -> Bool {
        player?.nowPlaying?.uri == row.uri
    }

    private func resolve(from index: Int) {
        let end = min(index + Self.resolveAhead, entries.count)
        guard index >= 0, index < end else { return }
        library.resolve(entries[index ..< end].map(\.uri))
    }

    private func copyLinks(_ uris: [String]) {
        let links = uris.compactMap(Self.webLink)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    /// `spotify:track:ID` to `https://open.spotify.com/track/ID`.
    static func webLink(_ uri: String) -> String? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify" else { return nil }
        return "https://open.spotify.com/\(parts[1])/\(parts[2])"
    }

    nonisolated struct Row: Identifiable, Sendable {
        /// 1-based position in the source order; unique even when a playlist repeats a track.
        let number: Int
        let uri: String
        let addedAt: Date?
        let title: String
        let artists: [ItemRef]
        let album: ItemRef?
        let durationMs: UInt32
        let playable: Bool
        let unavailableHelp: String?

        var id: Int { number }
        var albumName: String { album?.name ?? "" }
        var addedSort: Date { addedAt ?? .distantPast }

        init(number: Int, entry: TrackEntry, item: MetadataItem?) {
            self.number = number
            uri = entry.uri
            addedAt = entry.addedAt
            switch item {
            case let .track(track):
                title = track.title
                artists = track.artists
                album = track.album
                durationMs = track.durationMs
                playable = track.playability == .playable
                unavailableHelp = track.playability.unavailableHelp
            case let .episode(episode):
                title = episode.title
                artists = [ItemRef(uri: "", name: episode.showName)]
                album = nil
                durationMs = episode.durationMs
                playable = true
                unavailableHelp = nil
            case .unavailable:
                title = String(localized: "Unavailable")
                artists = []
                album = nil
                durationMs = 0
                playable = false
                unavailableHelp = nil
            default:
                title = ""
                artists = []
                album = nil
                durationMs = 0
                playable = true
                unavailableHelp = nil
            }
        }
    }
}

extension Playability {
    /// Tooltip for a track the account cannot play now; nil when playable.
    nonisolated var unavailableHelp: String? {
        switch self {
        case .playable: nil
        case .regionLocked: String(localized: "Not available in your country")
        case .notYetReleased: String(localized: "Not released yet")
        }
    }
}

/// Return plays the selection unless a text field is editing or a list has focus.
///
/// NSTableView swallows Return before `onKeyPress`, and a SwiftUI `Table` leaves
/// the window as first responder after a row click, so focus can't scope this;
/// the monitor checks the window and what is first responder instead.
private struct ReturnKeyMonitor: NSViewRepresentable {
    /// Returns whether it handled the key.
    let action: () -> Bool

    func makeNSView(context _: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.action = action
    }

    final class MonitorView: NSView {
        var action: () -> Bool = { false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window, Self.isPlainReturn(event),
                      !Self.takesReturn(event.window?.firstResponder), action() else { return event }
                return nil
            }
        }

        private static func isPlainReturn(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            return (event.keyCode == 36 || event.keyCode == 76) && modifiers.isEmpty
        }

        /// Text fields edit through an NSText field editor; one-column lists
        /// (sidebar, search results) are tables that handle Return themselves.
        private static func takesReturn(_ responder: NSResponder?) -> Bool {
            responder is NSText || (responder as? NSTableView).map { $0.numberOfColumns <= 1 } == true
        }
    }
}

private struct NumberCell: View {
    let row: TrackList.Row
    let playing: Bool

    var body: some View {
        if playing {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel("Now Playing")
        } else {
            Text(row.number, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}

private struct ArtistMenu: View {
    let artists: [ItemRef]
    let history: NavigationHistory

    var body: some View {
        let linked = artists.filter { !$0.uri.isEmpty }
        if linked.count == 1, let artist = linked.first {
            Button("Go to Artist") { history.navigate(to: .artist(uri: artist.uri)) }
        } else if linked.count > 1 {
            Menu("Go to Artist") {
                ForEach(linked, id: \.uri) { artist in
                    Button(artist.name) { history.navigate(to: .artist(uri: artist.uri)) }
                }
            }
        }
    }
}
