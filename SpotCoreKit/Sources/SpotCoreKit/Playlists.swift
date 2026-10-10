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
            case let .playlist(_, _, _, _, folder):
                parent = folder.flatMap { folders.contains($0) ? $0 : nil }
            }
            rows[parent, default: []].append(entry)
        }
        func nodes(under parent: String?) -> [RootlistNode] {
            (rows[parent] ?? []).map { entry in
                switch entry {
                case let .folder(uri, name, _):
                    return RootlistNode(id: uri, name: name, children: nodes(under: uri))
                case let .playlist(uri, name, _, _, _):
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
        case let .folder(uri, _, _), let .playlist(uri, _, _, _, _): uri
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

    /// Tracks fetched per request while a playlist's contents load.
    static let pageLength: UInt32 = 200

    @ObservationIgnored private let playlists: any PlaylistServiceProtocol
    @ObservationIgnored private let log: PlaylistLog

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
                var page = try await playlists.page(uri: uri, from: UInt32(tracks.count), length: Self.pageLength)
                tracks += page.tracks
                let done = page.tracks.isEmpty || tracks.count >= page.total
                // Keep a longer cached list on screen until the fetch catches up with it.
                if done || tracks.count >= pages[uri]?.tracks.count ?? 0 {
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
}
