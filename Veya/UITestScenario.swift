#if DEBUG
    import Foundation
    import os
    import SpotCoreKit

    /// Picked by VeyaUITests through the environment, so no UI test reaches
    /// Spotify or the user's Keychain. Raw values are mirrored in VeyaUITests.
    enum UITestScenario: String {
        /// No saved sign-in; signing in succeeds.
        case signedOut
        /// No saved sign-in; the user closes the Spotify window.
        case signInCancelled
        /// A saved sign-in restores at launch.
        case signedIn
        /// The first restore fails; Try Again succeeds.
        case restoreFails
        /// Signed in, and the connection has dropped.
        case reconnecting
        /// No saved sign-in; signing in finds a Free account.
        case notPremium
        /// Signed in with 10,000 liked songs.
        case largeLibrary
        /// Signed in with nothing saved and no playlists.
        case emptyLibrary
        /// Signed in; the library and playlists can't be fetched and nothing is cached.
        case libraryFails
        /// Signed in before Veya asked for the scope Recently Played needs.
        case recentlyPlayedNeedsSignIn

        static let environmentKey = "VEYA_UI_TEST_SCENARIO"

        /// Each launch starts with no recent searches and default settings.
        private static func freshDefaults() -> UserDefaults {
            let suite = "veya-ui-test"
            UserDefaults().removePersistentDomain(forName: suite)
            return UserDefaults(suiteName: suite)!
        }

        /// A typo in a test must fail loudly, not launch against real Spotify.
        static func current() -> UITestScenario? {
            guard let name = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
            guard let scenario = UITestScenario(rawValue: name) else {
                fatalError("Unknown \(environmentKey) \(name)")
            }
            return scenario
        }

        private var library: LibraryFill {
            switch self {
            case .largeLibrary: .liked(10000)
            case .emptyLibrary: .empty
            case .libraryFails: .failing
            default: .liked(5)
            }
        }

        var dependencies: AppDependencies {
            let hasSavedSignIn = ![.signedOut, .signInCancelled, .notPremium].contains(self)
            let signInCompletes = self != .signInCancelled
            return AppDependencies(
                store: InMemoryCredentialStore(blob: hasSavedSignIn ? ScenarioSession.blob : nil),
                refreshTokenStore: InMemoryCredentialStore(blob: nil),
                connector: ScenarioConnector(
                    failures: self == .restoreFails ? 1 : 0,
                    premium: self != .notPremium,
                    initial: self == .reconnecting ? .reconnecting(attempt: 1, retryInSecs: 30) : nil,
                    library: library,
                    recentlyPlayedScope: self != .recentlyPlayedNeedsSignIn
                ),
                browser: ScenarioBrowser(dismissedByUser: !signInCompletes),
                startFlow: { ScenarioFlow(completes: signInCompletes) },
                artworkLoader: nil,
                defaults: Self.freshDefaults(),
                episodeProgress: ScenarioEpisodeProgress()
            )
        }
    }

    private final nonisolated class InMemoryCredentialStore: CredentialStore {
        private let blob: OSAllocatedUnfairLock<Data?>

        init(blob: Data?) {
            self.blob = OSAllocatedUnfairLock(initialState: blob)
        }

        func load() throws -> Data? {
            blob.withLock { $0 }
        }

        func save(_ blob: Data) throws {
            self.blob.withLock { $0 = blob }
        }

        func delete() throws {
            blob.withLock { $0 = nil }
        }
    }

    private struct ScenarioConnectError: Error {}

    /// What the signed-in library and playlists hold.
    private enum LibraryFill {
        /// Liked songs "Song 1"... plus one album, one artist, one show and one playlist.
        case liked(Int)
        case empty
        case failing
    }

    private final nonisolated class ScenarioConnector: SessionConnector {
        private let failuresLeft: OSAllocatedUnfairLock<Int>
        private let premium: Bool
        private let initial: ConnectionState?
        private let library: LibraryFill
        private let recentlyPlayedScope: Bool

        init(failures: Int, premium: Bool, initial: ConnectionState?, library: LibraryFill, recentlyPlayedScope: Bool) {
            failuresLeft = OSAllocatedUnfairLock(initialState: failures)
            self.premium = premium
            self.initial = initial
            self.library = library
            self.recentlyPlayedScope = recentlyPlayedScope
        }

        func isPremium(accessToken _: String) async throws -> Bool {
            premium
        }

        func connect(accessToken _: String) async throws -> any SessionHandle {
            try nextSession()
        }

        func connect(storedCredentials _: Data) async throws -> any SessionHandle {
            try nextSession()
        }

        func setAudioCacheLimit(bytes _: UInt64) throws {}

        func clearMetadataCache() throws {}

        private func nextSession() throws -> any SessionHandle {
            let fails = failuresLeft.withLock { left in
                defer { left = max(left - 1, 0) }
                return left > 0
            }
            if fails {
                throw ScenarioConnectError()
            }
            return ScenarioSession(initial: initial, library: library, recentlyPlayedScope: recentlyPlayedScope)
        }
    }

    private final nonisolated class ScenarioSession: SessionHandle {
        static let blob = Data("ui-test-credentials".utf8)
        private let initial: ConnectionState?
        private let library: LibraryFill
        private let recentlyPlayedScope: Bool

        init(initial: ConnectionState?, library: LibraryFill, recentlyPlayedScope: Bool) {
            self.initial = initial
            self.library = library
            self.recentlyPlayedScope = recentlyPlayedScope
        }

        func storedCredentials() throws -> Data {
            Self.blob
        }

        func shutdown() {}

        func setObserver(observer: any ConnectionObserver) {
            if let initial {
                observer.onStateChanged(state: initial)
            }
        }

        func systemDidWake() {}

        func networkChanged(available _: Bool) {}

        func reconnect() {}

        func makeLibrary(store _: MetadataStore?) -> any LibraryServiceProtocol {
            ScenarioLibrary(fill: library)
        }

        func makeMetadata(store _: MetadataStore?) -> any MetadataServiceProtocol {
            ScenarioMetadata()
        }

        func makePlaylists(store _: MetadataStore?) -> any PlaylistServiceProtocol {
            ScenarioPlaylists(fill: library)
        }

        func makeSearch() -> any SearchServiceProtocol {
            ScenarioSearch()
        }

        func makeRecentlyPlayed(accessToken _: @escaping @Sendable () async throws -> String) -> any RecentlyPlayedProvider {
            ScenarioRecentlyPlayed(fill: library, scope: recentlyPlayedScope)
        }

        @MainActor
        func makePlayer(observer: any PlayerObserver, settings _: PlaybackSettings) async throws -> PlayerConnection {
            PlayerConnection(player: ScenarioPlayer(observer: observer), engine: nil)
        }
    }

    private nonisolated let scenarioTrackURI = "spotify:track:ui-test"

    /// Liked song `n` is "Song n"; song 3 is region locked so its row is dimmed.
    private nonisolated func likedSongURI(_ n: Int) -> String {
        "spotify:track:ui-test-\(n)"
    }

    private nonisolated func scenarioTrack(_ uri: String) -> TrackMetadata? {
        if uri == scenarioTrackURI {
            return TrackMetadata(
                uri: uri, title: "Test Track", artists: [ItemRef(uri: "spotify:artist:ui-test", name: "Test Artist")],
                album: ItemRef(uri: "spotify:album:ui-test", name: "Test Album"), durationMs: 180_000,
                explicit: false, playability: .playable, artwork: []
            )
        }
        guard let n = uri.split(separator: "-").last.flatMap({ Int($0) }), uri == likedSongURI(n) else { return nil }
        return TrackMetadata(
            uri: uri, title: "Song \(n)", artists: [ItemRef(uri: "spotify:artist:ui-test", name: "Test Artist")],
            album: ItemRef(uri: "spotify:album:ui-test", name: "Test Album"), durationMs: UInt32(120_000 + n * 1000),
            explicit: false, playability: n == 3 ? .regionLocked : .playable, artwork: []
        )
    }

    private nonisolated let scenarioArtist = ArtistMetadata(
        uri: "spotify:artist:ui-test", name: "Test Artist", artwork: [],
        topTracks: [likedSongURI(2), likedSongURI(1)], albums: ["spotify:album:ui-test"], singles: [scenarioSingle.uri],
        compilations: [], related: [ItemRef(uri: scenarioRelated.uri, name: scenarioRelated.name)]
    )
    private nonisolated let scenarioRelated = ArtistMetadata(
        uri: "spotify:artist:ui-test-related", name: "Related Artist", artwork: [],
        topTracks: [], albums: [], singles: [], compilations: [], related: []
    )
    /// Songs 1, 2 and 4; song 3 is the region-locked one.
    private nonisolated let scenarioAlbum = AlbumMetadata(
        uri: "spotify:album:ui-test", title: "Test Album", artists: [ItemRef(uri: "spotify:artist:ui-test", name: "Test Artist")],
        tracks: [1, 2, 4].map(likedSongURI), playability: .playable, artwork: [], year: 2024,
        copyrights: ["© 2024 Veya Test Records"]
    )
    private nonisolated let scenarioSingle = AlbumMetadata(
        uri: "spotify:album:ui-test-single", title: "Test Single", artists: [ItemRef(uri: "spotify:artist:ui-test", name: "Test Artist")],
        tracks: [likedSongURI(5)], playability: .playable, artwork: [], year: 2025, copyrights: []
    )
    private nonisolated let scenarioPlaylistURI = "spotify:playlist:ui-test"
    /// Spotify-owned, so Home lists it under Made for You.
    private nonisolated let scenarioMixURI = "spotify:playlist:ui-test-mix"

    /// Newest first: not started, halfway through, and played.
    private nonisolated let scenarioEpisodes = [
        scenarioEpisode("new", "New Episode", publishedAt: 1_759_300_200),
        scenarioEpisode("halfway", "Halfway Episode", publishedAt: 1_758_700_000),
        scenarioEpisode("finished", "Finished Episode", publishedAt: 1_758_100_000),
    ]

    /// An hour long, with "Notes for <title>" as its description.
    private nonisolated func scenarioEpisode(_ id: String, _ title: String, publishedAt: Int64) -> EpisodeMetadata {
        EpisodeMetadata(
            uri: "spotify:episode:ui-test-\(id)", title: title, showName: "Test Podcast", description: "Notes for \(title)",
            durationMs: 3_600_000, explicit: false, playability: .playable, artwork: [], publishedAt: publishedAt
        )
    }

    private nonisolated let scenarioShow = ShowMetadata(
        uri: "spotify:show:ui-test", name: "Test Podcast", publisher: "Veya Test Studio",
        description: "A podcast about testing Veya", artwork: [], episodes: scenarioEpisodes.map(\.uri)
    )

    /// 25 of 60 minutes into "Halfway Episode"; "Finished Episode" is played.
    private nonisolated struct ScenarioEpisodeProgress: EpisodeProgressProvider {
        func progress(uris: [String]) async throws -> [EpisodeProgress] {
            [
                EpisodeProgress(uri: scenarioEpisodes[1].uri, resumePositionMs: 1_500_000, fullyPlayed: false),
                EpisodeProgress(uri: scenarioEpisodes[2].uri, resumePositionMs: 0, fullyPlayed: true),
            ].filter { uris.contains($0.uri) }
        }
    }

    /// A paused "Test Track" that answers play and pause with the matching events.
    /// Songs 5 and 6 are queued and songs 7 and 8 follow; playing a list makes it the context.
    private final nonisolated class ScenarioPlayer: SpotPlayerProtocol {
        private let observer: any PlayerObserver
        private let snapshot = OSAllocatedUnfairLock(initialState: QueueSnapshot(
            current: scenarioTrackURI, upNext: [likedSongURI(5), likedSongURI(6)],
            nextFromContext: [likedSongURI(7), likedSongURI(8)], shuffle: false, repeat: .off, autoplay: true
        ))

        init(observer: any PlayerObserver) {
            self.observer = observer
            observer.onEvent(event: .trackChanged(uri: scenarioTrackURI, name: "Test Track", durationMs: 180_000))
            observer.onEvent(event: .paused(uri: scenarioTrackURI, positionMs: 0))
        }

        func play() { observer.onEvent(event: .playing(uri: scenarioTrackURI, positionMs: 0)) }
        func pause() { observer.onEvent(event: .paused(uri: scenarioTrackURI, positionMs: 0)) }
        func addToQueue(uri: String) throws { snapshot.withLock { $0.upNext.append(uri) } }
        func clearQueue() { snapshot.withLock { $0.upNext.removeAll() } }
        func load(uri: String, startMs: UInt32, autoplay _: Bool) async throws {
            snapshot.withLock {
                $0.current = uri
                $0.nextFromContext = []
            }
            let episode = scenarioEpisodes.first { $0.uri == uri }
            observer.onEvent(event: .trackChanged(uri: uri, name: episode?.title ?? "", durationMs: episode?.durationMs ?? 180_000))
            observer.onEvent(event: .playing(uri: uri, positionMs: startMs))
        }
        func loadTracks(uris: [String], startIndex: UInt32, contextUri _: String?, autoplay _: Bool) throws {
            let uri = uris[Int(startIndex)]
            snapshot.withLock {
                $0.current = uri
                $0.nextFromContext = Array(uris.dropFirst(Int(startIndex) + 1))
            }
            observer.onEvent(event: .trackChanged(uri: uri, name: scenarioTrack(uri)?.title ?? "", durationMs: 180_000))
            observer.onEvent(event: .playing(uri: uri, positionMs: 0))
        }
        func moveInQueue(from: UInt32, to: UInt32) throws {
            snapshot.withLock { $0.upNext.insert($0.upNext.remove(at: Int(from)), at: Int(to)) }
        }

        func next() {}
        func playNext(uri: String) throws { snapshot.withLock { $0.upNext.insert(uri, at: 0) } }
        func previous() {}
        func queue() -> QueueSnapshot { snapshot.withLock { $0 } }
        func removeFromQueue(index: UInt32) throws { _ = snapshot.withLock { $0.upNext.remove(at: Int(index)) } }
        func seek(positionMs _: UInt32) {}
        func setAutoplay(on _: Bool) {}
        func setBitrate(bitrate _: Bitrate) async {}
        func setNormalisation(normalisation _: LoudnessPreset?) async {}
        func setRepeat(mode _: RepeatMode) {}
        func setShuffle(on _: Bool) {}
        func setVolume(volume _: UInt16) {}
        func stop() {}
    }

    /// Liked songs newest first, nothing else saved; never changes.
    private final nonisolated class ScenarioLibrary: LibraryServiceProtocol {
        private let fill: LibraryFill

        init(fill: LibraryFill) {
            self.fill = fill
        }

        func cached(kind: LibraryKind) -> [LibraryItem] {
            guard case let .liked(likedSongs) = fill else { return [] }
            let newest: Int64 = 1_760_000_000
            switch kind {
            case .tracks:
                return (1 ..< likedSongs + 1).map {
                    LibraryItem(uri: likedSongURI($0), addedAt: newest - Int64($0) * 86400)
                }
            case .albums:
                return [LibraryItem(uri: scenarioAlbum.uri, addedAt: newest)]
            case .artists:
                return [LibraryItem(uri: scenarioArtist.uri, addedAt: newest)]
            case .shows:
                return [LibraryItem(uri: scenarioShow.uri, addedAt: newest)]
            }
        }

        func refresh(kind: LibraryKind) async throws -> [LibraryItem] {
            if case .failing = fill { throw LibraryError.Request(message: "ui-test") }
            return cached(kind: kind)
        }

        func setSaved(uri _: String, saved _: Bool) async throws {}

        func waitForChange() async {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// "Road Trip" and Spotify's "Daily Mix 1" when the library is filled; they never change.
    private final nonisolated class ScenarioPlaylists: PlaylistServiceProtocol {
        private let fill: LibraryFill

        init(fill: LibraryFill) {
            self.fill = fill
        }

        func cachedRootlist() -> [RootlistEntry] {
            guard case .liked = fill else { return [] }
            return [
                .playlist(uri: scenarioPlaylistURI, name: "Road Trip", owner: "ui-test", trackCount: 3, parent: nil),
                .playlist(uri: scenarioMixURI, name: "Daily Mix 1", owner: "spotify", trackCount: 2, parent: nil),
            ]
        }

        func rootlist() async throws -> [RootlistEntry] {
            if case .failing = fill { throw PlaylistError.Request(message: "ui-test") }
            return cachedRootlist()
        }

        func cachedPage(uri _: String, from _: UInt32, length _: UInt32) -> PlaylistPage? {
            nil
        }

        /// Road Trip has songs 1, 2 and 5, Daily Mix 1 songs 4 and 6, each on one page.
        func page(uri: String, from: UInt32, length _: UInt32) async throws -> PlaylistPage {
            guard case .liked = fill, [scenarioPlaylistURI, scenarioMixURI].contains(uri) else {
                throw PlaylistError.Request(message: "ui-test")
            }
            let mix = uri == scenarioMixURI
            let songs = mix ? [4, 6] : [1, 2, 5]
            let tracks = from > 0 ? [] : songs.map {
                PlaylistTrack(uri: likedSongURI($0), addedBy: "ui-test", addedAt: 1_760_000_000 - Int64($0) * 86400)
            }
            return PlaylistPage(
                uri: uri, revision: "ui-test", name: mix ? "Daily Mix 1" : "Road Trip",
                description: mix ? "Made for you" : "Songs for the road", owner: mix ? "spotify" : "ui-test",
                collaborative: false, artwork: [], total: UInt32(songs.count), offset: from, tracks: tracks
            )
        }

        func followerCount(uri _: String) async throws -> UInt64 {
            0
        }

        func waitForChange() async -> PlaylistChange {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            return .rootlist
        }
    }

    /// Songs 2 and 1, played from Test Album, Road Trip and Test Artist.
    private final nonisolated class ScenarioRecentlyPlayed: RecentlyPlayedProvider {
        private let fill: LibraryFill
        private let scope: Bool

        init(fill: LibraryFill, scope: Bool) {
            self.fill = fill
            self.scope = scope
        }

        func recentlyPlayed() async throws -> RecentlyPlayed {
            guard scope else { throw HomeError.MissingScope }
            switch fill {
            case .liked:
                return RecentlyPlayed(
                    tracks: [likedSongURI(2), likedSongURI(1)],
                    contexts: [scenarioAlbum.uri, scenarioPlaylistURI, scenarioArtist.uri]
                )
            case .empty:
                return RecentlyPlayed(tracks: [], contexts: [])
            case .failing:
                throw HomeError.Network(message: "ui-test")
            }
        }
    }

    /// "test" finds a track section with one more page, an artist and an album;
    /// "fail" fails; anything else finds nothing.
    private final nonisolated class ScenarioSearch: SearchServiceProtocol {
        func search(query: String, limit _: UInt32) async throws -> [SearchGroup] {
            let query = query.lowercased()
            if query.contains("fail") { throw SearchError.Request(message: "ui-test") }
            guard query.contains("test") else { return [] }
            return [
                SearchGroup(kind: .track, total: 4, offset: 0, hits: (1 ... 3).map(Self.track)),
                SearchGroup(kind: .artist, total: 1, offset: 0, hits: [
                    SearchHit(uri: "spotify:artist:ui-test", name: "Test Artist", subtitle: "Artist", artwork: [], explicit: false),
                ]),
                SearchGroup(kind: .album, total: 1, offset: 0, hits: [
                    SearchHit(uri: "spotify:album:ui-test", name: "Test Album", subtitle: "Test Artist", artwork: [], explicit: false),
                ]),
            ]
        }

        func page(query _: String, kind: SearchKind, offset: UInt32, limit _: UInt32) async throws -> SearchGroup {
            SearchGroup(kind: kind, total: 4, offset: offset, hits: kind == .track && offset == 3 ? [Self.track(4)] : [])
        }

        private static func track(_ n: Int) -> SearchHit {
            SearchHit(uri: likedSongURI(n), name: "Song \(n)", subtitle: "Test Artist", artwork: [], explicit: false)
        }
    }

    private final nonisolated class ScenarioMetadata: MetadataServiceProtocol {
        func items(uris: [String]) async throws -> [MetadataItem] {
            uris.map { uri -> MetadataItem in
                if uri == scenarioAlbum.uri { return .album(album: scenarioAlbum) }
                if uri == scenarioArtist.uri { return .artist(artist: scenarioArtist) }
                if uri == scenarioRelated.uri { return .artist(artist: scenarioRelated) }
                if uri == scenarioSingle.uri { return .album(album: scenarioSingle) }
                if uri == scenarioShow.uri { return .show(show: scenarioShow) }
                if let episode = scenarioEpisodes.first(where: { $0.uri == uri }) { return .episode(episode: episode) }
                return scenarioTrack(uri).map { .track(track: $0) } ?? .unavailable(uri: uri, error: .notFound)
            }
        }
    }

    private final class ScenarioBrowser: SignInBrowser {
        private let dismissedByUser: Bool

        init(dismissedByUser: Bool) {
            self.dismissedByUser = dismissedByUser
        }

        func present(_: URL) async -> SignInBrowserResult {
            if dismissedByUser {
                return .dismissedByUser
            }
            try? await Task.sleep(for: .seconds(3600))
            return .closed
        }
    }

    private final nonisolated class ScenarioFlow: SignInFlow {
        private let completes: Bool
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(completes: Bool) {
            self.completes = completes
        }

        func authorizeURL() -> String {
            "https://accounts.spotify.com/authorize"
        }

        /// SignInModel's task group waits for this child, so it must end on `cancel()`.
        func finish() async throws -> OAuthTokens {
            if completes {
                return OAuthTokens(accessToken: "ui-test", refreshToken: "ui-test", expiresInSecs: 3600, scopes: [])
            }
            while !cancelled.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CancellationError()
        }

        func cancel() {
            cancelled.withLock { $0 = true }
        }

        func callbackReceived() -> Bool {
            completes
        }
    }
#endif
