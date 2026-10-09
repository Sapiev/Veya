import Observation

public typealias PlaylistLog = @MainActor (LogLevel, String) -> Void

/// The user's root playlist list, folders included, in the user's order.
@MainActor
@Observable
public final class PlaylistModel {
    public private(set) var rootlist: [RootlistEntry] = []
    public private(set) var state: LibraryLoadState?

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
            if case .playlist = change { continue }
            await refresh()
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
