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
    /// `entries` are all of `context`'s tracks in its order, not a filtered subset.
    var entriesInContextOrder = true
    let library: LibraryModel
    let player: PlayerModel?
    let playlists: PlaylistModel
    let history: NavigationHistory
    /// Album pages leave out the album column and the row artwork.
    var showsAlbum = true
    /// The playlist these entries are, all and in order, when the user can edit it.
    var editablePlaylist: String?
    @Environment(\.undoManager) private var undoManager
    @State private var selection: Set<Row.ID> = []
    @State private var sortOrder = [KeyPathComparator(\Row.number)]
    @State private var hover = RowHover()
    @State private var drag = DragSource()

    /// Rows resolve metadata in batches of this size as they scroll in.
    private static let resolveAhead = 50

    var body: some View {
        let rows = sortedRows
        Table(of: Row.self, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.number) { row in
                NumberCell(row: row, playing: isPlaying(row), animating: player?.isPlaying == true, hover: hover) {
                    play([row.id], in: sortedRows)
                }
                .onAppear { resolve(from: row.number - 1) }
                .cellLabel(String(localized: "Number"))
            }
            .width(min: 28, ideal: 40, max: 56)
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: Theme.s3) {
                    if showsAlbum {
                        ArtworkView(artwork: row.artwork, side: 40)
                            .clipShape(.rect(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title.isEmpty ? String(localized: "Loading…") : row.title)
                            .scaledFont(size: 14, weight: .medium)
                            .accentForeground(isPlaying(row))
                        Text(row.artists.map(\.name).formatted(.list(type: .and)))
                            .scaledFont(size: 13)
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
                .frame(minHeight: 48)
                .opacity(row.playable ? 1 : contrast.opacity(0.7))
                .help(row.unavailableHelp ?? "")
                .hoverTracked(row, hover)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityLabel(row))
                .accessibilityHint("Double-click or press Return to play")
                .cellLabel(String(localized: "Title"), row: accessibilityLabel(row))
                .accessibilityAction { play([row.id], in: rows) }
                .accessibilityAction(named: likeActionName(row)) {
                    library.setSaved(row.uri, !library.isSaved(row.uri))
                }
                .accessibilityAction(named: "Add to Queue") { player?.addToQueue([row.uri]) }
            }
            .width(min: 160, ideal: 280)
            TableColumn("Album", value: \.albumName) { row in
                Text(row.albumName)
                    .scaledFont(size: 13)
                    .foregroundStyle(.secondary)
                    .opacity(row.playable ? 1 : contrast.opacity(0.7))
                    .help(row.unavailableHelp ?? "")
                    .hoverTracked(row, hover)
                    .cellLabel(String(localized: "Album"))
            }
            .width(min: 100, ideal: 200)
            .defaultVisibility(showsAlbum ? .visible : .hidden)
            TableColumn("Date Added", value: \.addedSort) { row in
                Text(row.addedAt?.formatted(date: .abbreviated, time: .omitted) ?? "")
                    .scaledFont(size: 13)
                    .foregroundStyle(.secondary)
                    .hoverTracked(row, hover)
                    .cellLabel(String(localized: "Date Added"))
            }
            .width(min: 80, ideal: 110)
            TableColumn(Text(verbatim: "")) { row in
                LikeCell(row: row, library: library, revealed: selection.contains(row.id), hover: hover)
                    .cellLabel(String(localized: "Liked"))
            }
            .width(36)
            TableColumn("Duration", value: \.durationMs) { row in
                Text(row.durationMs == 0 ? "" : Duration.milliseconds(Int(row.durationMs)).formatted(.time(pattern: .minuteSecond)))
                    .scaledFont(size: 13)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .hoverTracked(row, hover)
                    .cellLabel(String(localized: "Duration"))
            }
            .width(min: 56, ideal: 64, max: 90)
            TableColumn(Text(verbatim: "")) { row in
                MoreCell(row: row, revealed: selection.contains(row.id), hover: hover) {
                    menu(for: [row])
                }
                .cellLabel(String(localized: "Options"))
            }
            .width(36)
        } rows: {
            if let playlist = editablePlaylist, sortOrder == [KeyPathComparator(\Row.number)] {
                ForEach(rows) { row in
                    TableRow(row).draggable(drag.payload(row, selection: selection))
                }
                .dropDestination(for: String.self) { index, uris in
                    move(uris, to: index, in: playlist)
                }
            } else {
                ForEach(rows) { row in
                    TableRow(row).draggable(row.uri)
                }
            }
        }
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Tracks")
        .accessibilityIdentifier("trackList")
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            menu(for: rows.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            play(ids, in: rows)
        }
        .background(KeyMonitor(keyCodes: KeyMonitor.returnKeys) {
            guard !selection.isEmpty else { return false }
            play(selection, in: sortedRows)
            return true
        })
        .background(ClickFocusesTable())
        .background(KeyMonitor(keyCodes: KeyMonitor.deleteKeys) {
            guard let editablePlaylist, !selection.isEmpty else { return false }
            remove(selection, from: editablePlaylist)
            return true
        })
        .onChange(of: sortOrder) {
            // Sorting by metadata needs every row's metadata, not only the visible ones.
            if sortOrder.first?.keyPath != \Row.number, sortOrder.first?.keyPath != \Row.addedSort {
                library.resolve(entries.map(\.uri))
            }
        }
    }

    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder private func menu(for rows: [Row]) -> some View {
        let uris = rows.map(\.uri)
        if !rows.isEmpty {
            Button("Play Next") { player?.playNext(uris) }
            Button("Add to Queue") { player?.addToQueue(uris) }
            Menu("Add to Playlist") {
                ForEach(playlists.editablePlaylists) { playlist in
                    Button(playlist.name) { playlists.addTracks(uris, to: playlist.id) }
                }
            }
            .disabled(playlists.editablePlaylists.isEmpty)
            Divider()
            if rows.count == 1, let row = rows.first {
                if let album = row.album, !album.uri.isEmpty {
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
            if let editablePlaylist {
                Button("Remove from This Playlist") { remove(Set(rows.map(\.id)), from: editablePlaylist) }
            }
        }
    }

    /// Row ids are 1-based positions in `entries`, which is the whole playlist.
    private func remove(_ ids: Set<Row.ID>, from playlist: String) {
        playlists.removeTracks(at: IndexSet(ids.map { $0 - 1 }), from: playlist, undoManager: undoManager)
        selection = []
    }

    /// Reorders only a drag that started in this table; other drops are ignored.
    private func move(_ uris: [String], to index: Int, in playlist: String) {
        let dragged = drag.rows
        drag.rows = []
        let rows = sortedRows.filter { dragged.contains($0.id) }
        guard !rows.isEmpty, rows.map(\.uri) == uris else { return }
        playlists.moveTracks(fromOffsets: IndexSet(rows.map { $0.number - 1 }), toOffset: index, in: playlist, undoManager: undoManager)
        selection = []
    }

    private var sortedRows: [Row] {
        let rows = entries.enumerated().map { offset, entry in
            Row(number: offset + 1, entry: entry, item: library.metadata[entry.uri])
        }
        return isUnsorted ? rows : rows.sorted(using: sortOrder)
    }

    private var isUnsorted: Bool { sortOrder == [KeyPathComparator(\Row.number)] }

    /// Plays the list in its shown order from the first playable of `ids`,
    /// leaving out rows known to be unplayable; refuses when `ids` has none.
    private func play(_ ids: Set<Row.ID>, in rows: [Row]) {
        let playable = rows.filter(\.playable)
        if let index = playable.firstIndex(where: { ids.contains($0.id) }) {
            player?.play(playable.map(\.uri), from: index, context: context, inContextOrder: entriesInContextOrder && isUnsorted)
        }
    }

    private func isPlaying(_ row: Row) -> Bool {
        player?.nowPlaying?.uri == row.uri
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
        let artwork: [Artwork]

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
                artwork = track.artwork
            case let .episode(episode):
                title = episode.title
                artists = [ItemRef(uri: "", name: episode.showName)]
                album = nil
                durationMs = episode.durationMs
                playable = true
                unavailableHelp = nil
                artwork = episode.artwork
            case .unavailable:
                title = String(localized: "Unavailable")
                artists = []
                album = nil
                durationMs = 0
                playable = false
                unavailableHelp = nil
                artwork = []
            default:
                title = ""
                artists = []
                album = nil
                durationMs = 0
                playable = true
                unavailableHelp = nil
                artwork = []
            }
        }
    }
}

extension TrackList {
    fileprivate func resolve(from index: Int) {
        let end = min(index + Self.resolveAhead, entries.count)
        guard index >= 0, index < end else { return }
        library.resolve(entries[index ..< end].map(\.uri))
    }

    fileprivate func copyLinks(_ uris: [String]) {
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
}

/// What VoiceOver reads for a row and names its actions.
private extension TrackList {
    func likeActionName(_ row: Row) -> LocalizedStringKey {
        library.isSaved(row.uri) ? "Remove from Liked Songs" : "Save to Liked Songs"
    }

    /// Title, artists, spoken duration and playing state, e.g. "Song 1, Artist, 3 minutes, 12 seconds, Now playing".
    func accessibilityLabel(_ row: Row) -> String {
        let state: String? = if isPlaying(row), player?.isPlaying == true {
            String(localized: "Now playing")
        } else if isPlaying(row) {
            String(localized: "Paused")
        } else if !row.playable {
            row.unavailableHelp ?? String(localized: "Unavailable")
        } else {
            nil
        }
        let parts = [
            row.title.isEmpty ? String(localized: "Loading…") : row.title,
            row.artists.map(\.name).formatted(.list(type: .and)),
            row.durationMs == 0 ? "" : Scrubber.spoken(Double(row.durationMs)),
            state ?? ""
        ]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
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

/// Return plays the selection and Delete removes it, unless a text field is
/// editing or a list has focus.
///
/// NSTableView swallows Return before `onKeyPress`, and a SwiftUI `Table` leaves
/// the window as first responder after a row click, so neither focus nor
/// `onDeleteCommand` can scope this; the monitor checks the window and what is
/// first responder instead.
private struct KeyMonitor: NSViewRepresentable {
    static let returnKeys: Set<UInt16> = [36, 76]
    /// Delete and Forward Delete.
    static let deleteKeys: Set<UInt16> = [51, 117]

    let keyCodes: Set<UInt16>
    /// Returns whether it handled the key.
    let action: () -> Bool

    func makeNSView(context _: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_ view: MonitorView, context _: Context) {
        view.keyCodes = keyCodes
        view.action = action
    }

    final class MonitorView: NSView {
        var keyCodes: Set<UInt16> = []
        var action: () -> Bool = { false }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === window, isPlain(event),
                      !Self.takesKeys(event.window?.firstResponder), action() else { return event }
                return nil
            }
        }

        private func isPlain(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
            return keyCodes.contains(event.keyCode) && modifiers.isEmpty
        }

        /// Text fields edit through an NSText field editor; one-column lists
        /// (sidebar, search results) are tables that handle these keys themselves.
        private static func takesKeys(_ responder: NSResponder?) -> Bool {
            responder is NSText || (responder as? NSTableView).map { $0.numberOfColumns <= 1 } == true
        }
    }
}

/// SwiftUI leaves a table cell's AppKit host and its row without a description, which
/// VoiceOver reads as an empty group; this names the host after its column and the row after `row`.
private struct CellAccessibility: NSViewRepresentable {
    let label: String
    let row: String?

    func makeNSView(context _: Context) -> Namer {
        Namer()
    }

    func updateNSView(_ view: Namer, context _: Context) {
        view.label = label
        view.row = row
        view.apply()
    }

    final class Namer: NSView {
        var label = ""
        var row: String?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        /// Cells are reused across rows, so this runs on every update.
        func apply() {
            var view = superview?.superview
            while let host = view, !(host is NSTableRowView || host is NSTableView) {
                host.setAccessibilityLabel(label)
                view = host.superview
            }
            if let row, let rowView = view as? NSTableRowView {
                rowView.setAccessibilityLabel(row)
            }
        }
    }
}

/// A click in the table makes it first responder, as clicking an AppKit table does;
/// a SwiftUI `Table` leaves the previous one, so the arrow keys would not move the
/// selection and a Filter or search field would keep taking Delete and Return.
private struct ClickFocusesTable: NSViewRepresentable {
    func makeNSView(context _: Context) -> MonitorView {
        MonitorView()
    }

    func updateNSView(_: MonitorView, context _: Context) {}

    final class MonitorView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, let window, event.window === window,
                      bounds.contains(convert(event.locationInWindow, from: nil)) else { return event }
                let hit = window.contentView?.hitTest(event.locationInWindow)
                let table = sequence(first: hit, next: { $0?.superview }).lazy.compactMap { $0 as? NSTableView }.first
                if let table {
                    window.makeFirstResponder(table)
                } else if window.firstResponder is NSText {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }
    }
}

/// The rows of the drag that started in this table, so a drop can tell a
/// reorder from tracks dragged in from elsewhere.
private final class DragSource {
    var rows: Set<TrackList.Row.ID> = []

    /// SwiftUI builds the payload when the drag starts, once per dragged row.
    func payload(_ row: TrackList.Row, selection: Set<TrackList.Row.ID>) -> String {
        rows = selection.contains(row.id) ? selection : [row.id]
        return row.uri
    }
}

/// The row under the pointer, kept out of `TrackList` so a hover redraws only the visible cells.
@Observable private final class RowHover {
    var row: TrackList.Row.ID?
}

private extension View {
    /// Names a table cell for VoiceOver; its contents stay separate elements.
    func cellLabel(_ label: String, row: String? = nil) -> some View {
        background(CellAccessibility(label: label, row: row))
    }

    /// Table cells have gaps between them, so each cell reports the pointer for its row.
    func hoverTracked(_ row: TrackList.Row, _ hover: RowHover) -> some View {
        onHover { inside in
            if inside {
                hover.row = row.id
            } else if hover.row == row.id {
                hover.row = nil
            }
        }
    }
}

/// The row number; a play button under the pointer, the equalizer on the playing row.
private struct NumberCell: View {
    let row: TrackList.Row
    let playing: Bool
    let animating: Bool
    let hover: RowHover
    let play: () -> Void

    var body: some View {
        Group {
            if playing {
                Equalizer(animating: animating)
            } else if hover.row == row.id, row.playable {
                // Return and double-click play the selection too, so this stays a pointer shortcut.
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Play \(row.title)"))
            } else {
                Text(row.number, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40)
        .hoverTracked(row, hover)
    }
}

/// Three bars that bounce while playing; still when paused or under Reduce Motion.
struct Equalizer: View {
    let animating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        EqualizerBars(animating: animating && !reduceMotion, color: prominence == .increased ? palette.tintInk : palette.tintText)
            .frame(width: 13, height: 14)
    }
}

/// Core Animation bounces the bars in the render server; a SwiftUI TimelineView redrew
/// the row every frame, ~13 % CPU during playback (PBI-803).
private struct EqualizerBars: NSViewRepresentable {
    let animating: Bool
    let color: RGB

    private static let still: [CGFloat] = [8, 14, 10]

    /// Speaks for itself: a SwiftUI accessibilityRepresentation over an AppKit view
    /// fails the audit's parent/child check in a table row.
    final class BarsView: NSView {
        override func isAccessibilityElement() -> Bool {
            true
        }

        override func accessibilityRole() -> NSAccessibility.Role? {
            .image
        }

        override func accessibilityLabel() -> String? {
            String(localized: "Now Playing")
        }
    }

    func makeNSView(context _: Context) -> BarsView {
        let view = BarsView()
        view.wantsLayer = true
        for index in Self.still.indices {
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0, y: 0)
            bar.position = CGPoint(x: CGFloat(index) * 5, y: 0)
            bar.cornerRadius = 1
            view.layer?.addSublayer(bar)
        }
        return view
    }

    func updateNSView(_ view: BarsView, context _: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in (view.layer?.sublayers ?? []).enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: 3, height: Self.still[index])
            bar.backgroundColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
            if !animating {
                bar.removeAnimation(forKey: "bounce")
            } else if bar.animation(forKey: "bounce") == nil {
                bar.add(Self.bounce(index), forKey: "bounce")
            }
        }
        CATransaction.commit()
    }

    /// 4 to 14 pt and back over 0.9 s, each bar a third of a cycle behind the last.
    private static func bounce(_ index: Int) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "bounds.size.height")
        animation.fromValue = 4
        animation.toValue = 14
        animation.duration = 0.45
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.timeOffset = 0.3 * Double(index)
        return animation
    }
}

/// Saved songs keep a tinted heart; others show it under the pointer or when selected.
private struct LikeCell: View {
    let row: TrackList.Row
    let library: LibraryModel
    let revealed: Bool
    let hover: RowHover

    var body: some View {
        let saved = library.isSaved(row.uri)
        Button {
            library.setSaved(row.uri, !saved)
        } label: {
            Image(systemName: saved ? "heart.fill" : "heart")
                .accentForeground(saved, else: .secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved ? Text("Remove from Liked Songs") : Text("Save to Liked Songs"))
        .help(saved ? Text("Remove from Liked Songs") : Text("Save to Liked Songs"))
        .opacity(saved || revealed || hover.row == row.id ? 1 : 0)
        .frame(maxWidth: .infinity, minHeight: 40)
        .hoverTracked(row, hover)
    }
}

/// The row's context menu behind a "•••" button, shown under the pointer or when selected.
private struct MoreCell<Items: View>: View {
    let row: TrackList.Row
    let revealed: Bool
    let hover: RowHover
    @ViewBuilder let items: () -> Items

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text("More Options"))
        .help(Text("More Options"))
        .opacity(revealed || hover.row == row.id ? 1 : 0)
        .frame(maxWidth: .infinity, minHeight: 40)
        .hoverTracked(row, hover)
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
