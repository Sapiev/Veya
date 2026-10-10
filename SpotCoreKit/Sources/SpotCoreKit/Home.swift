import Foundation
import Observation

public protocol RecentlyPlayedProvider: Sendable {
    func recentlyPlayed() async throws -> RecentlyPlayed
}

/// Reads plays from the Web API with a token from `accessToken`, which needs
/// the `user-read-recently-played` scope.
public struct WebAPIRecentlyPlayed: RecentlyPlayedProvider {
    private let accessToken: @Sendable () async throws -> String

    public init(accessToken: @escaping @Sendable () async throws -> String) {
        self.accessToken = accessToken
    }

    public func recentlyPlayed() async throws -> RecentlyPlayed {
        try await SpotCoreKit.recentlyPlayed(accessToken: accessToken())
    }
}

/// A "Jump Back In" context: playlists have no `MetadataItem` case.
public enum HomeTile: Equatable, Sendable {
    case item(MetadataItem)
    case playlist(PlaylistPage)
}

public typealias HomeLog = @MainActor (LogLevel, String) -> Void

/// The start page. Each section loads on its own and stays empty when it
/// cannot be fetched; the view hides empty sections. Radio comes from
/// `HomeService.radio`.
@MainActor
@Observable
public final class HomeModel {
    public private(set) var recentlyPlayed: [MetadataItem] = []
    public private(set) var jumpBackIn: [HomeTile] = []
    /// Spotify-owned playlists in the account's root list.
    public private(set) var madeForYou: [PlaylistPage] = []
    /// Recently Played failed in a way only a fresh sign-in fixes, such as a
    /// token from before the `user-read-recently-played` scope was added.
    public private(set) var recentlyPlayedNeedsSignIn = false
    /// `.failed` only when every section failed.
    public private(set) var state: LibraryLoadState?

    @ObservationIgnored private let metadata: any MetadataServiceProtocol
    @ObservationIgnored private let playlists: any PlaylistServiceProtocol
    @ObservationIgnored private let recent: any RecentlyPlayedProvider
    @ObservationIgnored private let limit: Int
    @ObservationIgnored private let log: HomeLog
    @ObservationIgnored private var running: Task<Void, Never>?
    /// Bumped by every `load`; sections from an older one are dropped.
    @ObservationIgnored private var generation = 0

    static let spotifyOwner = "spotify"

    public init(
        metadata: any MetadataServiceProtocol,
        playlists: any PlaylistServiceProtocol,
        recentlyPlayed: any RecentlyPlayedProvider,
        limit: Int = 20,
        log: @escaping HomeLog = { logMessage(level: $0, category: "home", message: $1) }
    ) {
        self.metadata = metadata
        self.playlists = playlists
        recent = recentlyPlayed
        self.limit = limit
        self.log = log
    }

    /// Reloads every section; sections keep their old content until replaced.
    @discardableResult
    public func load() -> Task<Void, Never> {
        generation += 1
        let mine = generation
        running?.cancel()
        state = .loading
        let task = Task {
            async let recentLoaded = loadRecent(mine)
            async let madeForYouLoaded = loadMadeForYou(mine)
            let (recentOK, madeOK) = await (recentLoaded, madeForYouLoaded)
            guard mine == generation else { return }
            state = recentOK || madeOK ? .loaded : .failed
        }
        running = task
        return task
    }

    private func loadRecent(_ mine: Int) async -> Bool {
        do {
            let plays = try await recent.recentlyPlayed()
            let tracks = (try? await metadata.items(uris: Array(plays.tracks.prefix(limit)))) ?? []
            let tiles = await tiles(Array(plays.contexts.prefix(limit)))
            guard mine == generation else { return true }
            recentlyPlayed = tracks.filter(\.isAvailable)
            jumpBackIn = tiles
            recentlyPlayedNeedsSignIn = false
            return true
        } catch {
            guard mine == generation else { return true }
            log(.warn, "Couldn't load recently played: \(Self.summary(error))")
            recentlyPlayed = []
            jumpBackIn = []
            recentlyPlayedNeedsSignIn = Self.needsSignIn(error)
            // A sign-in hint is shown in place of the section, so Home has not failed.
            return recentlyPlayedNeedsSignIn
        }
    }

    private func loadMadeForYou(_ mine: Int) async -> Bool {
        do {
            let uris = try await playlists.rootlist().compactMap { entry -> String? in
                guard case let .playlist(uri, _, owner, _, _) = entry, owner == Self.spotifyOwner
                else { return nil }
                return uri
            }
            let pages = await headers(Array(uris.prefix(limit)))
            guard mine == generation else { return true }
            madeForYou = pages
            return true
        } catch {
            guard mine == generation else { return true }
            log(.warn, "Couldn't load the root list: \(Self.summary(error))")
            madeForYou = []
            return false
        }
    }

    /// Contexts in input order; ones that fail to resolve are left out.
    private func tiles(_ uris: [String]) async -> [HomeTile] {
        let isPlaylist = { (uri: String) in uri.hasPrefix("spotify:playlist:") }
        let others = uris.filter { !isPlaylist($0) }
        let pages = await headers(uris.filter(isPlaylist))
        let items = (try? await metadata.items(uris: others)) ?? []
        var byURI = [String: HomeTile]()
        for (uri, item) in zip(others, items) where item.isAvailable {
            byURI[uri] = .item(item)
        }
        for page in pages {
            byURI[page.uri] = .playlist(page)
        }
        return uris.compactMap { byURI[$0] }
    }

    /// Playlist headers without tracks, in input order; failures are left out.
    private func headers(_ uris: [String]) async -> [PlaylistPage] {
        await withTaskGroup(of: (Int, PlaylistPage?).self) { group in
            for (index, uri) in uris.enumerated() {
                group.addTask { [playlists] in
                    (index, try? await playlists.page(uri: uri, from: 0, length: 0))
                }
            }
            var found = [PlaylistPage?](repeating: nil, count: uris.count)
            for await (index, page) in group {
                found[index] = page
            }
            return found.compactMap(\.self)
        }
    }

    private static func needsSignIn(_ error: any Error) -> Bool {
        switch error {
        case HomeError.MissingScope, WebAPITokenError.notAvailable, WebAPITokenError.rejected: true
        default: false
        }
    }

    /// Error case names only: messages may carry server text.
    private static func summary(_ error: any Error) -> String {
        switch error {
        case HomeError.MissingScope: "MissingScope"
        case HomeError.Network: "Network"
        case HomeError.Request: "Request"
        case HomeError.Malformed: "Malformed"
        default: String(describing: type(of: error))
        }
    }
}

private extension MetadataItem {
    var isAvailable: Bool {
        if case .unavailable = self { false } else { true }
    }
}
