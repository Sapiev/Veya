import Observation

public typealias PlaylistLog = @MainActor (LogLevel, String) -> Void

/// The user's root playlist list, folders included, in the user's order.
@MainActor
@Observable
public final class PlaylistModel {
    public private(set) var rootlist: [RootlistEntry] = []
    public private(set) var state: LibraryLoadState?
    /// Each opened playlist's attributes with every track loaded so far.
    public private(set) var pages: [String: PlaylistPage] = [:]
    public private(set) var pageState: [String: LibraryLoadState] = [:]

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

    /// Shows a fully cached playlist at once, then fetches its tracks page by page.
    @discardableResult
    public func loadPage(_ uri: String) -> Task<Void, Never> {
        if pageState[uri] == nil {
            let cached = playlists.cachedPage(uri: uri, from: 0, length: .max)
            pages[uri] = cached
            pageState[uri] = cached == nil ? .loading : .loaded
        }
        return Task { await refreshPage(uri) }
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
