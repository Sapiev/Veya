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
                    likedSongs: self == .largeLibrary ? 10000 : 5
                ),
                browser: ScenarioBrowser(dismissedByUser: !signInCompletes),
                startFlow: { ScenarioFlow(completes: signInCompletes) },
                artworkLoader: nil,
                defaults: Self.freshDefaults()
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

    private final nonisolated class ScenarioConnector: SessionConnector {
        private let failuresLeft: OSAllocatedUnfairLock<Int>
        private let premium: Bool
        private let initial: ConnectionState?
        private let likedSongs: Int

        init(failures: Int, premium: Bool, initial: ConnectionState?, likedSongs: Int) {
            failuresLeft = OSAllocatedUnfairLock(initialState: failures)
            self.premium = premium
            self.initial = initial
            self.likedSongs = likedSongs
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
            return ScenarioSession(initial: initial, likedSongs: likedSongs)
        }
    }

    private final nonisolated class ScenarioSession: SessionHandle {
        static let blob = Data("ui-test-credentials".utf8)
        private let initial: ConnectionState?
        private let likedSongs: Int

        init(initial: ConnectionState?, likedSongs: Int) {
            self.initial = initial
            self.likedSongs = likedSongs
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
            ScenarioLibrary(likedSongs: likedSongs)
        }

        func makeMetadata(store _: MetadataStore?) -> any MetadataServiceProtocol {
            ScenarioMetadata()
        }

        func makePlaylists(store _: MetadataStore?) -> any PlaylistServiceProtocol {
            ScenarioPlaylists()
        }

        func makeSearch() -> any SearchServiceProtocol {
            ScenarioSearch()
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

    /// A paused "Test Track" that answers play and pause with the matching events.
    private final nonisolated class ScenarioPlayer: SpotPlayerProtocol {
        private let observer: any PlayerObserver

        init(observer: any PlayerObserver) {
            self.observer = observer
            observer.onEvent(event: .trackChanged(uri: scenarioTrackURI, name: "Test Track", durationMs: 180_000))
            observer.onEvent(event: .paused(uri: scenarioTrackURI, positionMs: 0))
        }

        func play() { observer.onEvent(event: .playing(uri: scenarioTrackURI, positionMs: 0)) }
        func pause() { observer.onEvent(event: .paused(uri: scenarioTrackURI, positionMs: 0)) }
        func addToQueue(uri _: String) throws {}
        func clearQueue() {}
        func load(uri _: String, startMs _: UInt32, autoplay _: Bool) async throws {}
        func loadTracks(uris: [String], startIndex: UInt32, contextUri _: String?, autoplay _: Bool) throws {
            let uri = uris[Int(startIndex)]
            observer.onEvent(event: .trackChanged(uri: uri, name: scenarioTrack(uri)?.title ?? "", durationMs: 180_000))
            observer.onEvent(event: .playing(uri: uri, positionMs: 0))
        }
        func moveInQueue(from _: UInt32, to _: UInt32) throws {}
        func next() {}
        func playNext(uri _: String) throws {}
        func previous() {}
        func queue() -> QueueSnapshot {
            QueueSnapshot(current: scenarioTrackURI, upNext: [], nextFromContext: [], shuffle: false, repeat: .off, autoplay: true)
        }

        func removeFromQueue(index _: UInt32) throws {}
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
        private let likedSongs: Int

        init(likedSongs: Int) {
            self.likedSongs = likedSongs
        }

        func cached(kind: LibraryKind) -> [LibraryItem] {
            guard kind == .tracks else { return [] }
            let newest: Int64 = 1_760_000_000
            return (1 ..< likedSongs + 1).map {
                LibraryItem(uri: likedSongURI($0), addedAt: newest - Int64($0) * 86400)
            }
        }

        func refresh(kind: LibraryKind) async throws -> [LibraryItem] {
            cached(kind: kind)
        }

        func setSaved(uri _: String, saved _: Bool) async throws {}

        func waitForChange() async {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// One playlist that never changes; contents are empty.
    private final nonisolated class ScenarioPlaylists: PlaylistServiceProtocol {
        private static let rootlist: [RootlistEntry] = [
            .playlist(uri: "spotify:playlist:ui-test", name: "Road Trip", owner: "ui-test", trackCount: 0, parent: nil),
        ]

        func cachedRootlist() -> [RootlistEntry] {
            Self.rootlist
        }

        func rootlist() async throws -> [RootlistEntry] {
            Self.rootlist
        }

        func cachedPage(uri _: String, from _: UInt32, length _: UInt32) -> PlaylistPage? {
            nil
        }

        func page(uri _: String, from _: UInt32, length _: UInt32) async throws -> PlaylistPage {
            throw PlaylistError.Request(message: "ui-test")
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
            uris.map { uri in
                scenarioTrack(uri).map { .track(track: $0) } ?? .unavailable(uri: uri, error: .notFound)
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
