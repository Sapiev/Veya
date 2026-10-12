import Foundation
import Observation

public typealias PlaylistLog = @MainActor (LogLevel, String) -> Void

/// A root list row with the rows nested under it; `children` is nil for a playlist.
public struct RootlistNode: Identifiable, Hashable, Sendable {
    /// The folder or playlist URI.
    public let id: String
    public let name: String
    public let children: [RootlistNode]?

    /// Nests `entries` under their folders, keeping the user's order. A row
    /// whose folder does not come before it shows at the top level, and a
    /// repeated URI is dropped, so stray, cyclic or duplicated parents cannot
    /// hide or loop and every node id is unique.
    static func tree(_ entries: [RootlistEntry]) -> [RootlistNode] {
        var rows: [String?: [RootlistEntry]] = [:]
        var folders: Set<String> = []
        var seen: Set<String> = []
        for entry in entries {
            guard seen.insert(entry.uri).inserted else { continue }
            let parent: String?
            switch entry {
            case let .folder(uri, _, folder):
                parent = folder.flatMap { folders.contains($0) ? $0 : nil }
                folders.insert(uri)
            case let .playlist(_, _, _, _, folder, _, _):
                parent = folder.flatMap { folders.contains($0) ? $0 : nil }
            }
            rows[parent, default: []].append(entry)
        }
        func nodes(under parent: String?) -> [RootlistNode] {
            (rows[parent] ?? []).map { entry in
                switch entry {
                case let .folder(uri, name, _):
                    return RootlistNode(id: uri, name: name, children: nodes(under: uri))
                case let .playlist(uri, name, _, _, _, _, _):
                    return RootlistNode(id: uri, name: name, children: nil)
                }
            }
        }
        return nodes(under: nil)
    }
}

private extension RootlistEntry {
    var uri: String {
        switch self {
        case let .folder(uri, _, _), let .playlist(uri, _, _, _, _, _, _): uri
        }
    }
}

/// The user's root playlist list, folders included, in the user's order.
@MainActor
@Observable
public final class PlaylistModel {
    public private(set) var rootlist: [RootlistEntry] = []
    public private(set) var state: LibraryLoadState?
    /// Each opened playlist's attributes with every track loaded so far.
    public private(set) var pages: [String: PlaylistPage] = [:]
    public private(set) var pageState: [String: LibraryLoadState] = [:]
    /// Follower count of each opened playlist, once fetched.
    public private(set) var followers: [String: UInt64] = [:]
    /// Each requested playlist's picture; empty while fetching, on failure, or when it has none.
    public private(set) var artwork: [String: [Artwork]] = [:]
    /// The last edit that didn't stick; the UI clears it once shown.
    public var editError: PlaylistEditError?

    /// Tracks fetched per request while a playlist's contents load.
    static let pageLength: UInt32 = 200

    @ObservationIgnored private let playlists: any PlaylistServiceProtocol
    @ObservationIgnored private let log: PlaylistLog
    /// The last queued track edit of each playlist; edits run one at a time so
    /// each sends the revision the previous one returned.
    @ObservationIgnored private var editQueue: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingEdits: [String: Int] = [:]
    /// Playlists to refetch once their edits drain: a fetch meanwhile would
    /// overwrite the optimistic tracks with an older server page.
    @ObservationIgnored private var staleAfterEdits: Set<String> = []
    /// Bumped by each failed edit: edits queued before it were built on the
    /// rolled-back state and are skipped, later ones run.
    @ObservationIgnored private var failedEdits: [String: Int] = [:]
    /// Each playlist's undo actions are registered on its own target, so they
    /// can be dropped once its tracks change under them.
    @ObservationIgnored private var undoTargets: [String: (manager: UndoManager, target: UndoTarget)] = [:]

    public init(
        playlists: any PlaylistServiceProtocol,
        log: @escaping PlaylistLog = { logMessage(level: $0, category: "playlists", message: $1) }
    ) {
        self.playlists = playlists
        self.log = log
    }

    /// `rootlist` nested by folder.
    public var tree: [RootlistNode] {
        RootlistNode.tree(rootlist)
    }

    /// Shows the cached list at once, then syncs with the server.
    @discardableResult
    public func load() -> Task<Void, Never> {
        if state == nil {
            rootlist = playlists.cachedRootlist()
            state = rootlist.isEmpty ? .loading : .loaded
        }
        return Task { await refresh() }
    }

    /// Refreshes the list whenever it changes elsewhere; runs until cancelled.
    public func watch() async {
        while !Task.isCancelled {
            let change = await playlists.waitForChange()
            guard !Task.isCancelled else { return }
            if case let .playlist(uri) = change {
                if pageState[uri] != nil { await refreshPage(uri) }
                continue
            }
            await refresh()
        }
    }

    /// Shows a fully cached playlist at once, then fetches its tracks page by
    /// page and its follower count.
    @discardableResult
    public func loadPage(_ uri: String) -> Task<Void, Never> {
        if pageState[uri] == nil {
            let cached = playlists.cachedPage(uri: uri, from: 0, length: .max)
            pages[uri] = cached
            pageState[uri] = cached == nil ? .loading : .loaded
        }
        return Task {
            async let count: Void = refreshFollowers(uri)
            await refreshPage(uri)
            await count
        }
    }

    /// Fetches the picture of each playlist not requested before, cache first; a failed
    /// fetch stays empty for the session so repeated calls never re-request it.
    public func loadArtwork(_ uris: [String]) async {
        var fetch: [String] = []
        for uri in uris where artwork[uri] == nil {
            if let cached = playlists.cachedPage(uri: uri, from: 0, length: 0) {
                artwork[uri] = cached.artwork
            } else {
                artwork[uri] = []
                fetch.append(uri)
            }
        }
        await withTaskGroup(of: (String, [Artwork]?).self) { group in
            for uri in fetch {
                group.addTask { [playlists] in
                    (uri, try? await playlists.page(uri: uri, from: 0, length: 0).artwork)
                }
            }
            for await (uri, found) in group {
                if let found { artwork[uri] = found }
            }
        }
    }

    /// A failure keeps the last count, or none; the page shows without it.
    private func refreshFollowers(_ uri: String) async {
        do {
            followers[uri] = try await playlists.followerCount(uri: uri)
        } catch {
            log(.warn, "Couldn't load a playlist's followers: \(String(describing: type(of: error)))")
        }
    }

    private func refreshPage(_ uri: String) async {
        var tracks: [PlaylistTrack] = []
        do {
            repeat {
                guard pendingEdits[uri] == nil else { staleAfterEdits.insert(uri); return }
                var page = try await playlists.page(uri: uri, from: UInt32(tracks.count), length: Self.pageLength)
                guard pendingEdits[uri] == nil else { staleAfterEdits.insert(uri); return }
                tracks += page.tracks
                let done = page.tracks.isEmpty || tracks.count >= page.total
                // Keep a longer cached list on screen until the fetch catches up with it.
                if done || tracks.count >= pages[uri]?.tracks.count ?? 0 {
                    // Another client changed it, so undo's indices no longer hold.
                    if page.revision != pages[uri]?.revision { dropUndo(uri) }
                    page.offset = 0
                    page.tracks = tracks
                    pages[uri] = page
                }
                pageState[uri] = .loaded
                if done { break }
            } while !Task.isCancelled
        } catch {
            log(.warn, "Couldn't load a playlist: \(String(describing: type(of: error)))")
            if pageState[uri] == .loading { pageState[uri] = .failed }
        }
    }

    private func refresh() async {
        do {
            rootlist = try await playlists.rootlist()
            state = .loaded
        } catch {
            // Type name only: messages may carry server text.
            log(.warn, "Couldn't sync playlists: \(String(describing: type(of: error)))")
            if state == .loading { state = .failed }
        }
    }

    // MARK: Editing

    /// The playlists the user can edit, in root list order.
    public var editablePlaylists: [RootlistNode] {
        rootlist.compactMap {
            guard case let .playlist(uri, name, _, _, _, true, _) = $0 else { return nil }
            return RootlistNode(id: uri, name: name, children: nil)
        }
    }

    public func isEditable(_ uri: String) -> Bool {
        rootlist.contains { if case .playlist(uri, _, _, _, _, true, _) = $0 { true } else { false } }
    }

    public func isPublic(_ uri: String) -> Bool {
        rootlist.contains { if case .playlist(uri, _, _, _, _, _, true) = $0 { true } else { false } }
    }

    /// Creates a playlist and returns its URI once the root list shows it.
    @discardableResult
    public func createPlaylist(named name: String, description: String = "", in folder: String? = nil) async -> String? {
        await rootlistEdit { try await playlists.createPlaylist(name: name, description: description, folder: folder) }
    }

    @discardableResult
    public func createFolder(named name: String, in folder: String? = nil) async -> String? {
        await rootlistEdit { try await playlists.createFolder(name: name, folder: folder) }
    }

    public func updateDetails(of uri: String, name: String, description: String) async {
        await rootlistEdit { try await playlists.updateDetails(uri: uri, name: name, description: description) }
        if pageState[uri] != nil { await refreshPage(uri) }
    }

    /// Renames keeping the description, which is fetched when the page isn't open.
    public func rename(_ uri: String, to name: String) async {
        let description: String
        if let page = pages[uri] {
            description = page.description
        } else {
            guard let page = await rootlistEdit({ try await playlists.page(uri: uri, from: 0, length: 0) }) else { return }
            description = page.description
        }
        await updateDetails(of: uri, name: name, description: description)
    }

    /// Re-encodes `imageData` and sets it as the picture, then shows it on the
    /// page and in the sidebar; the raw file never leaves the process.
    public func setPicture(of uri: String, imageData: Data) async {
        do {
            let jpeg = try PlaylistPicture.jpeg(from: imageData)
            try await playlists.setPicture(uri: uri, jpeg: jpeg)
            artwork[uri] = try await playlists.page(uri: uri, from: 0, length: 0).artwork
            if pageState[uri] != nil { await refreshPage(uri) }
        } catch {
            log(.warn, "Couldn't set a playlist's picture: \(String(describing: type(of: error)))")
            editError = Self.editError(error)
        }
    }

    public func delete(_ uri: String) async {
        await rootlistEdit { try await playlists.deletePlaylist(uri: uri) }
    }

    public func setPublic(_ uri: String, _ isPublic: Bool) async {
        await rootlistEdit { try await playlists.setPublic(uri: uri, public: isPublic) }
    }

    /// Appends tracks; not undoable.
    @discardableResult
    public func addTracks(_ trackURIs: [String], to uri: String) -> Task<Void, Never> {
        let now = Int64(Date().timeIntervalSince1970)
        return perform([.append(trackURIs.map { PlaylistTrack(uri: $0, addedBy: "", addedAt: now) })], on: uri, undoManager: nil)
    }

    @discardableResult
    public func removeTracks(at offsets: IndexSet, from uri: String, undoManager: UndoManager?) -> Task<Void, Never> {
        guard let tracks = pages[uri]?.tracks, let last = offsets.last, last < tracks.count else { return Task {} }
        let edits = offsets.rangeView.reversed().map { TrackEdit.remove(Array(tracks[$0]), at: $0.lowerBound) }
        return perform(edits, on: uri, undoManager: undoManager)
    }

    /// Same convention as SwiftUI's `onMove(fromOffsets:toOffset:)`.
    @discardableResult
    public func moveTracks(fromOffsets offsets: IndexSet, toOffset: Int, in uri: String, undoManager: UndoManager?) -> Task<Void, Never> {
        guard let count = pages[uri]?.tracks.count, let last = offsets.last, last < count, toOffset <= count
        else { return Task {} }
        return perform(TrackEdit.moves(offsets, to: toOffset), on: uri, undoManager: undoManager)
    }

    /// Applies `edits` at once, then sends them after the playlist's earlier
    /// edits. A failure restores the tracks from before them and refetches,
    /// so a retried edit that reports a conflict still ends on server truth.
    private func perform(_ edits: [TrackEdit], on uri: String, undoManager: UndoManager?) -> Task<Void, Never> {
        guard !edits.isEmpty else { return Task {} }
        let snapshot = pages[uri]
        var edited = snapshot
        var resolved: [TrackEdit] = []
        for var edit in edits {
            if case let .insert(tracks, at, _) = edit {
                edit = .insert(tracks, at: at, end: edited.map { Int($0.total) } ?? at)
            }
            if edited != nil {
                guard edit.apply(to: &edited!) else { return Task {} }
            } else if case .append = edit {} else {
                return Task {}
            }
            resolved.append(edit)
        }
        if let edited { pages[uri] = edited }
        let inverses = resolved.reversed().compactMap(\.inverse)
        if let undoManager, inverses.count == resolved.count {
            if undoTargets[uri]?.manager !== undoManager { undoTargets[uri] = (undoManager, UndoTarget()) }
            undoManager.registerUndo(withTarget: undoTargets[uri]!.target) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.perform(inverses, on: uri, undoManager: undoManager) }
            }
        }
        let generation = failedEdits[uri, default: 0]
        return enqueueEdit(on: uri) { [self] in
            guard failedEdits[uri, default: 0] == generation else { return }
            do {
                var revision = if let page = pages[uri] {
                    page.revision
                } else {
                    try await playlists.page(uri: uri, from: 0, length: 0).revision
                }
                for edit in resolved {
                    revision = try await send(edit, to: uri, revision: revision)
                    pages[uri]?.revision = revision
                }
            } catch {
                if snapshot != nil { pages[uri] = snapshot }
                failedEdits[uri, default: 0] += 1
                staleAfterEdits.insert(uri)
                editError = Self.editError(error)
                dropUndo(uri)
                log(.warn, "Couldn't edit a playlist: \(String(describing: type(of: error)))")
            }
        }
    }

    private func enqueueEdit(on uri: String, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = editQueue[uri]
        pendingEdits[uri, default: 0] += 1
        let task = Task { [self] in
            await previous?.value
            await work()
            pendingEdits[uri, default: 1] -= 1
            guard pendingEdits[uri] == 0 else { return }
            pendingEdits[uri] = nil
            editQueue[uri] = nil
            if staleAfterEdits.remove(uri) != nil, pageState[uri] != nil { await refreshPage(uri) }
        }
        editQueue[uri] = task
        return task
    }

    private func dropUndo(_ uri: String) {
        guard let undo = undoTargets.removeValue(forKey: uri) else { return }
        undo.manager.removeAllActions(withTarget: undo.target)
    }

    private func send(_ edit: TrackEdit, to uri: String, revision: String) async throws -> String {
        switch edit {
        case let .append(tracks):
            return try await playlists.addTracks(uri: uri, trackUris: tracks.map(\.uri), revision: revision)
        case let .insert(tracks, at, end):
            // The server only appends, so an insert is an append moved into place.
            let added = try await playlists.addTracks(uri: uri, trackUris: tracks.map(\.uri), revision: revision)
            guard at < end else { return added }
            return try await playlists.moveTracks(
                uri: uri, from: UInt32(end), length: UInt32(tracks.count), to: UInt32(at), revision: added
            )
        case let .remove(tracks, at):
            return try await playlists.removeTracks(uri: uri, from: UInt32(at), trackUris: tracks.map(\.uri), revision: revision)
        case let .move(from, length, to):
            return try await playlists.moveTracks(
                uri: uri, from: UInt32(from), length: UInt32(length), to: UInt32(to), revision: revision
            )
        }
    }

    private func rootlistEdit<T>(_ edit: () async throws -> T) async -> T? {
        do {
            let result = try await edit()
            await refresh()
            return result
        } catch {
            log(.warn, "Couldn't edit playlists: \(String(describing: type(of: error)))")
            editError = Self.editError(error)
            return nil
        }
    }

    private static func editError(_ error: Error) -> PlaylistEditError {
        if error is PlaylistPicture.Failure { return .invalidImage }
        return switch error as? PlaylistError {
        case .Conflict?, .InvalidRevision?: .conflict
        case .InvalidImage?: .invalidImage
        default: .failed
        }
    }
}

private final class UndoTarget {}

/// Why a playlist edit didn't stick.
public enum PlaylistEditError: Equatable, Sendable {
    /// The playlist changed elsewhere; the edit was rolled back.
    case conflict
    /// The chosen picture isn't an image, or can't be made small enough.
    case invalidImage
    case failed
}

/// One track edit; indices count in the list as it is just before the edit.
enum TrackEdit: Equatable {
    case append([PlaylistTrack])
    /// `end` is the track count before the insert, filled in when it is queued.
    case insert([PlaylistTrack], at: Int, end: Int)
    case remove([PlaylistTrack], at: Int)
    /// `to` is the index the block goes before, like the service's `moveTracks`.
    case move(from: Int, length: Int, to: Int)

    var inverse: TrackEdit? {
        switch self {
        case .append: nil
        case let .insert(tracks, at, _): .remove(tracks, at: at)
        case let .remove(tracks, at): .insert(tracks, at: at, end: 0)
        case let .move(from, length, to):
            to > from ? .move(from: to - length, length: length, to: from) : .move(from: to, length: length, to: from + length)
        }
    }

    /// Leaves `page` unchanged and returns false when the edit doesn't fit it,
    /// such as an undo whose indices a newer list invalidated.
    @discardableResult
    func apply(to page: inout PlaylistPage) -> Bool {
        let count = page.tracks.count
        switch self {
        case .append: break
        case let .insert(_, at, _):
            guard (0 ... count).contains(at) else { return false }
        case let .remove(tracks, at):
            guard at >= 0, at + tracks.count <= count,
                  page.tracks[at ..< at + tracks.count].map(\.uri) == tracks.map(\.uri) else { return false }
        case let .move(from, length, to):
            guard length > 0, from >= 0, from + length <= count, (0 ... count).contains(to), to <= from || to >= from + length
            else { return false }
        }
        switch self {
        case let .append(tracks):
            page.tracks += tracks
            page.total += UInt32(tracks.count)
        case let .insert(tracks, at, _):
            page.tracks.insert(contentsOf: tracks, at: at)
            page.total += UInt32(tracks.count)
        case let .remove(tracks, at):
            page.tracks.removeSubrange(at ..< at + tracks.count)
            page.total -= min(page.total, UInt32(tracks.count))
        case let .move(from, length, to):
            let block = page.tracks[from ..< from + length]
            page.tracks.removeSubrange(from ..< from + length)
            page.tracks.insert(contentsOf: block, at: to > from ? to - length : to)
        }
        return true
    }

    /// Block moves that reorder like SwiftUI's `move(fromOffsets:toOffset:)`:
    /// runs above the target move down to it in order, runs below move up.
    static func moves(_ offsets: IndexSet, to target: Int) -> [TrackEdit] {
        var below: [Range<Int>] = []
        var above: [Range<Int>] = []
        for run in offsets.rangeView {
            if run.upperBound <= target {
                below.append(run)
            } else if run.lowerBound >= target {
                above.append(run)
            } else {
                below.append(run.lowerBound ..< target)
                above.append(target ..< run.upperBound)
            }
        }
        var edits: [TrackEdit] = []
        var to = target
        for run in below.reversed() {
            if run.upperBound != to { edits.append(.move(from: run.lowerBound, length: run.count, to: to)) }
            to -= run.count
        }
        to = target
        for run in above {
            if run.lowerBound != to { edits.append(.move(from: run.lowerBound, length: run.count, to: to)) }
            to += run.count
        }
        return edits
    }
}
