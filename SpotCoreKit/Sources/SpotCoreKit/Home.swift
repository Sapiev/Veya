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

/// "Jump Back In" contexts, newest first; `HomeService` reads them from spclient.
public protocol RecentContextsProvider: Sendable {
    func recentContexts() async throws -> [String]
}

extension HomeService: RecentContextsProvider {}

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
    @ObservationIgnored private let recentContexts: any RecentContextsProvider
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
        recentContexts: any RecentContextsProvider,
        limit: Int = 20,
        log: @escaping HomeLog = { logMessage(level: $0, category: "home", message: $1) }
    ) {
        self.metadata = metadata
        self.playlists = playlists
        recent = recentlyPlayed
        self.recentContexts = recentContexts
        self.limit = limit
        self.log = log
    }

    static let freshFor = Duration.seconds(60)
    @ObservationIgnored private var loadedAt: ContinuousClock.Instant?

    /// `load()` unless Home loaded within the last minute, so coming back to it does not refetch everything.
    @discardableResult
    public func loadIfStale() -> Task<Void, Never>? {
        if state == .loaded, let loadedAt, .now - loadedAt < Self.freshFor {
            return nil
        }
        return load()
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
            loadedAt = state == .loaded ? .now : nil
        }
        running = task
        return task
    }

    /// Jump Back In prefers spclient's contexts and falls back to the Web
    /// API's, so either source failing alone still fills it.
    private func loadRecent(_ mine: Int) async -> Bool {
        async let playsLoaded = Self.attempt { try await self.recent.recentlyPlayed() }
        async let contextsLoaded = Self.attempt { try await self.recentContexts.recentContexts() }
        let (plays, primary) = await (playsLoaded, contextsLoaded)
        let fallback = (try? plays.get().contexts) ?? []
        let contexts = (try? primary.get()).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        async let tracksLoaded = recentTracks(plays)
        async let tilesLoaded = tiles(Array(contexts.prefix(limit)))
        let (tracks, tiles) = await (tracksLoaded, tilesLoaded)
        guard mine == generation else { return true }
        if case let .failure(error) = primary {
            log(.warn, "Couldn't load recent contexts: \(Self.summary(error))")
        }
        jumpBackIn = tiles
        recentlyPlayed = tracks.filter(\.isAvailable)
        switch plays {
        case .success:
            recentlyPlayedNeedsSignIn = false
            return true
        case let .failure(error):
            log(.warn, "Couldn't load recently played: \(Self.summary(error))")
            recentlyPlayedNeedsSignIn = Self.needsSignIn(error)
            // A sign-in hint is shown in place of the section, so Home has not failed.
            return recentlyPlayedNeedsSignIn || !contexts.isEmpty
        }
    }

    private func recentTracks(_ plays: Result<RecentlyPlayed, any Error>) async -> [MetadataItem] {
        guard let uris = try? plays.get().tracks, !uris.isEmpty else { return [] }
        return await (try? metadata.items(uris: Array(uris.prefix(limit)))) ?? []
    }

    private func loadMadeForYou(_ mine: Int) async -> Bool {
        do {
            let uris = try await playlists.rootlist().compactMap { entry -> String? in
                guard case let .playlist(uri, _, owner, _, _, _, _) = entry, owner == Self.spotifyOwner
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
        let items = await (try? metadata.items(uris: others)) ?? []
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
                    await (index, try? playlists.page(uri: uri, from: 0, length: 0))
                }
            }
            var found = [PlaylistPage?](repeating: nil, count: uris.count)
            for await (index, page) in group {
                found[index] = page
            }
            return found.compactMap(\.self)
        }
    }

    private static func attempt<T>(_ body: () async throws -> T) async -> Result<T, any Error> {
        do { return try await .success(body()) } catch { return .failure(error) }
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
        case HomeError.Spclient: "Spclient"
        default: String(describing: type(of: error))
        }
    }
}

private extension MetadataItem {
    var isAvailable: Bool {
        if case .unavailable = self {
            false
        } else {
            true
        }
    }
}
