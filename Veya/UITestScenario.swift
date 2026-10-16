#if DEBUG
    import CoreGraphics
    import Foundation
    import ImageIO
    import os
    import SpotCoreKit
    import UniformTypeIdentifiers

    /// Picked by VeyaUITests through the environment, so no UI test reaches
    /// Spotify or the user's Keychain. Raw values are mirrored in VeyaUITests.
    enum UITestScenario: String {
        /// No saved sign-in; signing in succeeds.
        case signedOut
        /// No saved sign-in; the user closes the Spotify window.
        case signInCancelled
        /// No saved sign-in; signing in can't reach Spotify.
        case signInFails
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
        /// Signed in; no Web API client ID is set, and connecting one succeeds.
        case webAPINotConnected
        /// Signed in; Connect lists this Mac, an active phone, an idle speaker and a TV that refuses transfers.
        case connectDevices
        /// As `connectDevices`, with the local network permission turned off.
        case localNetworkDenied
        /// Signed in; the phone is playing, so the bar is its remote control.
        case remoteControl
        /// Signed in; the next track edit to a playlist reports it changed elsewhere.
        case playlistConflict
        /// Signed in with two local folders chosen and a Local Mix playlist of local files (PBI-703).
        case localFiles
        /// Signed in; MetricKit delivers a crash from the last run, before the user chose about crash reports (PBI-804).
        case crashedLastTime
        /// Signed in; Connect restored the account's last track paused at 1:35, as at launch (PBI-501).
        case restoredPlayback

        static let environmentKey = "VEYA_UI_TEST_SCENARIO"

        static let clientID = "0123456789abcdef0123456789abcdef"

        /// Each launch starts with no recent searches and default settings.
        private static func freshDefaults(clientID: String?) -> UserDefaults {
            let suite = "veya-ui-test"
            UserDefaults().removePersistentDomain(forName: suite)
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(clientID, forKey: WebAPIConnection.clientIDKey)
            return defaults
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
            default: .liked(5, playlistConflict: self == .playlistConflict, localFiles: self == .localFiles)
            }
        }

        var dependencies: AppDependencies {
            let webAPIConnected = self != .webAPINotConnected
            let defaults = Self.freshDefaults(clientID: webAPIConnected ? Self.clientID : nil)
            if self == .localFiles {
                PlaybackSettings(defaults: defaults).addLocalFolders(Self.localFolders())
            }
            let hasSavedSignIn = ![.signedOut, .signInCancelled, .signInFails, .notPremium].contains(self)
            let signInCompletes = self != .signInCancelled
            return AppDependencies(
                store: InMemoryCredentialStore(blob: hasSavedSignIn ? ScenarioSession.blob : nil),
                refreshTokenStore: InMemoryCredentialStore(blob: webAPIConnected ? Data("ui-test".utf8) : nil),
                connector: ScenarioConnector(
                    failures: self == .restoreFails ? 1 : 0,
                    premium: self != .notPremium,
                    initial: self == .reconnecting ? .reconnecting(attempt: 1, retryInSecs: 30) : nil,
                    library: library,
                    recentlyPlayedScope: self != .recentlyPlayedNeedsSignIn,
                    connectDevices: [.connectDevices, .localNetworkDenied, .remoteControl].contains(self),
                    remote: self == .remoteControl
                ),
                browser: ScenarioBrowser(dismissedByUser: !signInCompletes),
                startFlow: { ScenarioFlow(completes: signInCompletes && self != .signInFails, fails: self == .signInFails) },
                webAPIStartFlow: { _ in ScenarioFlow(completes: true) },
                tokenRefresher: ScenarioRefresher(),
                artworkLoader: nil,
                defaults: defaults,
                episodeProgress: ScenarioEpisodeProgress(),
                choosePhoto: { Self.photo() },
                localNetworkAccess: { [allowed = self != .localNetworkDenied] in AsyncStream { $0.yield(allowed) } },
                crashReportsDirectory: FileManager.default.temporaryDirectory.appending(path: "ui-test-crashes"),
                crashDiagnostics: { [crashed = self == .crashedLastTime] received in
                    if crashed { received([#"{"diagnosticMetaData":{"signal":11}}"#]) }
                }
            )
        }

        /// "Veya Music" and "Veya Mixes", created so they can be bookmarked.
        private static func localFolders() -> [URL] {
            ["Veya Music", "Veya Mixes"].map { name in
                let url = FileManager.default.temporaryDirectory.appending(path: "ui-test-local/\(name)")
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            }
        }

        /// Stands in for the open panel: a 1600 x 1200 PNG, larger than a
        /// playlist picture may be, so the app must scale and re-encode it.
        private static func photo() -> URL? {
            let width = 1600, height = 1200
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1))
            context.fillEllipse(in: CGRect(x: 400, y: 200, width: 800, height: 800))
            let url = FileManager.default.temporaryDirectory.appending(path: "ui-test-photo.png")
            guard let image = context.makeImage(),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            return CGImageDestinationFinalize(destination) ? url : nil
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
        case liked(Int, playlistConflict: Bool = false, localFiles: Bool = false)
        case empty
        case failing
    }

    private final nonisolated class ScenarioConnector: SessionConnector {
        private let failuresLeft: OSAllocatedUnfairLock<Int>
        private let premium: Bool
        private let initial: ConnectionState?
        private let library: LibraryFill
        private let recentlyPlayedScope: Bool
        private let connectDevices: Bool
        private let remote: Bool

        init(
            failures: Int, premium: Bool, initial: ConnectionState?, library: LibraryFill, recentlyPlayedScope: Bool,
            connectDevices: Bool, remote: Bool
        ) {
            self.remote = remote
            failuresLeft = OSAllocatedUnfairLock(initialState: failures)
            self.premium = premium
            self.initial = initial
            self.library = library
            self.recentlyPlayedScope = recentlyPlayedScope
            self.connectDevices = connectDevices
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

        func clearAudioCache() throws {}

        private func nextSession() throws -> any SessionHandle {
            let fails = failuresLeft.withLock { left in
                defer { left = max(left - 1, 0) }
                return left > 0
            }
            if fails {
                throw ScenarioConnectError()
            }
            return ScenarioSession(
                initial: initial, library: library, recentlyPlayedScope: recentlyPlayedScope, connectDevices: connectDevices,
                remote: remote
            )
        }
    }

    private final nonisolated class ScenarioSession: SessionHandle {
        static let blob = Data("ui-test-credentials".utf8)
        private let initial: ConnectionState?
        private let library: LibraryFill
        private let recentlyPlayedScope: Bool
        private let connectDevices: Bool
        private let remote: Bool

        init(initial: ConnectionState?, library: LibraryFill, recentlyPlayedScope: Bool, connectDevices: Bool, remote: Bool) {
            self.initial = initial
            self.library = library
            self.recentlyPlayedScope = recentlyPlayedScope
            self.connectDevices = connectDevices
            self.remote = remote
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

        func makeSearch(accessToken: @escaping @concurrent @Sendable () async throws -> String) -> any SearchServiceProtocol {
            ScenarioSearch(accessToken: accessToken)
        }

        // @concurrent: the app target defaults async closures to nonisolated(nonsending), SpotCoreKit does not.
        func makeRecentlyPlayed(accessToken _: @escaping @concurrent @Sendable () async throws -> String) -> any RecentlyPlayedProvider {
            ScenarioRecentlyPlayed(fill: library, scope: recentlyPlayedScope)
        }

        func makeRecentContexts() -> any RecentContextsProvider {
            ScenarioRecentContexts(fill: library)
        }

        @MainActor
        func makePlayer(observer: any PlayerObserver, settings _: PlaybackSettings) async throws -> PlayerConnection {
            if remote {
                return PlayerConnection(player: ScenarioRemotePlayer(observer: observer), engine: nil) { _, _ in
                    ScenarioConnect(observer: observer)
                }
            }
            guard connectDevices else {
                let restoredAtMs: UInt32 = UITestScenario.current() == .restoredPlayback ? 95_000 : 0
                return PlayerConnection(player: ScenarioPlayer(observer: observer, restoredAtMs: restoredAtMs), engine: nil)
            }
            return PlayerConnection(player: ScenarioPlayer(observer: observer), engine: nil) { _, _ in
                ScenarioConnect(observer: observer)
            }
        }
    }

    private nonisolated let scenarioTrackURI = "spotify:track:uitest"

    /// Liked song `n` is "Song n"; song 3 is region locked so its row is dimmed.
    private nonisolated func likedSongURI(_ n: Int) -> String {
        "spotify:track:uitest\(n)"
    }

    private nonisolated let scenarioLocalMixURI = "spotify:playlist:uitestlocal"

    /// As the core decodes `spotify:local:` entries: no artist or album URI, no artwork.
    /// The player cannot play "Hi-Res Song", as librespot skips files not sampled at 44.1 kHz.
    private nonisolated let scenarioLocalTracks = [("Local Song", 200), ("Hi-Res Song", 240)].map { title, seconds in
        TrackMetadata(
            uri: "spotify:local:Local+Artist:Local+Album:\(title.replacingOccurrences(of: " ", with: "+")):\(seconds)", title: title,
            artists: [ItemRef(uri: "", name: "Local Artist")], album: ItemRef(uri: "", name: "Local Album"),
            durationMs: UInt32(seconds * 1000), explicit: false, playability: .playable, artwork: []
        )
    }

    private nonisolated func scenarioTrack(_ uri: String) -> TrackMetadata? {
        if let local = scenarioLocalTracks.first(where: { $0.uri == uri }) {
            return local
        }
        if uri == scenarioTrackURI {
            return TrackMetadata(
                uri: uri, title: "Test Track", artists: [ItemRef(uri: "spotify:artist:uitest", name: "Test Artist")],
                album: ItemRef(uri: "spotify:album:uitest", name: "Test Album"), durationMs: 180_000,
                explicit: false, playability: .playable, artwork: []
            )
        }
        guard let n = Int(uri.dropFirst("spotify:track:uitest".count)), uri == likedSongURI(n) else { return nil }
        return TrackMetadata(
            uri: uri, title: "Song \(n)", artists: [ItemRef(uri: "spotify:artist:uitest", name: "Test Artist")],
            album: ItemRef(uri: "spotify:album:uitest", name: "Test Album"), durationMs: UInt32(120_000 + n * 1000),
            explicit: false, playability: n == 3 ? .regionLocked : .playable, artwork: []
        )
    }

    private nonisolated let scenarioArtist = ArtistMetadata(
        uri: "spotify:artist:uitest", name: "Test Artist", artwork: [],
        topTracks: [likedSongURI(2), likedSongURI(1), likedSongURI(3)], albums: ["spotify:album:uitest"], singles: [scenarioSingle.uri],
        compilations: [], related: [ItemRef(uri: scenarioRelated.uri, name: scenarioRelated.name)]
    )
    private nonisolated let scenarioRelated = ArtistMetadata(
        // Large enough for the full-bleed header; the scenario never loads artwork.
        uri: "spotify:artist:uitestrelated", name: "Related Artist",
        artwork: [Artwork(url: "https://i.scdn.co/image/ui-test-related", size: .large, width: 640, height: 640)],
        topTracks: [], albums: [], singles: [], compilations: [], related: []
    )
    /// Songs 1, 2 and 4; song 3 is the region-locked one.
    private nonisolated let scenarioAlbum = AlbumMetadata(
        uri: "spotify:album:uitest", title: "Test Album", artists: [ItemRef(uri: "spotify:artist:uitest", name: "Test Artist")],
        tracks: [1, 2, 4].map(likedSongURI), playability: .playable, artwork: [], year: 2024,
        copyrights: ["© 2024 Veya Test Records"]
    )
    private nonisolated let scenarioSingle = AlbumMetadata(
        uri: "spotify:album:uitestsingle", title: "Test Single", artists: [ItemRef(uri: "spotify:artist:uitest", name: "Test Artist")],
        tracks: [likedSongURI(5)], playability: .playable, artwork: [], year: 2025, copyrights: []
    )
    private nonisolated let scenarioPlaylistURI = "spotify:playlist:uitest"
    /// Spotify's playlist mirror of Liked Songs, which spclient lists among recent contexts.
    private nonisolated let scenarioLikedMirrorURI = "spotify:playlist:uitestlikedmirror"
    /// Spotify-owned, so Home lists it under Made for You.
    private nonisolated let scenarioMixURI = "spotify:playlist:uitestmix"
    /// Fran's playlist, outside the root list until followed.
    private nonisolated let scenarioFriendMixURI = "spotify:playlist:uitestfriendmix"

    /// Newest first: not started, halfway through, and played.
    private nonisolated let scenarioEpisodes = [
        scenarioEpisode("new", "New Episode", publishedAt: 1_759_300_200),
        scenarioEpisode("halfway", "Halfway Episode", publishedAt: 1_758_700_000),
        scenarioEpisode("finished", "Finished Episode", publishedAt: 1_758_100_000),
        scenarioEpisode("locked", "Locked Episode", publishedAt: 1_757_500_000, playability: .regionLocked),
    ]

    /// An hour long, with "Notes for <title>" as its description.
    private nonisolated func scenarioEpisode(
        _ id: String, _ title: String, publishedAt: Int64, playability: Playability = .playable
    ) -> EpisodeMetadata {
        EpisodeMetadata(
            uri: "spotify:episode:uitest\(id)", title: title, showName: "Test Podcast", description: "Notes for \(title)",
            durationMs: 3_600_000, explicit: false, playability: playability, artwork: [], publishedAt: publishedAt
        )
    }

    private nonisolated let scenarioShow = ShowMetadata(
        uri: "spotify:show:uitest", name: "Test Podcast", publisher: "Veya Test Studio",
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
    /// A Connect device whose transfers move the active mark, as the next cluster update would.
    private final nonisolated class ScenarioConnect: SpotConnectProtocol {
        private let observer: any PlayerObserver
        private let active = OSAllocatedUnfairLock(initialState: "phone")

        init(observer: any PlayerObserver) {
            self.observer = observer
            publish()
        }

        func shutdown() async {}

        func restoreLastPlayback(accessToken: String, saved: SavedPlayback?) async {}

        func transfer(deviceId: String) async throws {
            if deviceId == "tv" {
                throw ConnectError.Transfer(message: "ui-test")
            }
            active.withLock { $0 = deviceId }
            publish()
        }

        private func publish() {
            let active = active.withLock { $0 }
            let device = { (id: String, name: String, kind: DeviceKind, volume: UInt16) in
                ConnectDevice(
                    id: id, name: name, kind: kind, volume: volume, isActive: id == active, isThisDevice: id == "mac"
                )
            }
            observer.onEvent(event: .devicesChanged(devices: [
                device("mac", "Studio Mac", .computer, .max),
                device("speaker", "Kitchen Speaker", .speaker, 32768),
                device("phone", "Pixel", .smartphone, 6554),
                device("tv", "Living Room TV", .tv, 0),
            ]))
        }
    }

    /// Stands in for spotcore in Remote mode: each command plays out on the
    /// phone and comes back as the cluster's events, as "Remote Track" then liked songs.
    private final nonisolated class ScenarioRemotePlayer: SpotPlayerProtocol {
        private let observer: any PlayerObserver
        private let song = OSAllocatedUnfairLock(initialState: 1)

        /// Unknown to the scenario metadata, so its title stays as the cluster gave it.
        private static let remoteTrackURI = "spotify:track:uitestremote"

        init(observer: any PlayerObserver) {
            self.observer = observer
            observer.onEvent(event: .trackChanged(uri: Self.remoteTrackURI, name: "Remote Track", durationMs: 180_000))
            observer.onEvent(event: .paused(uri: Self.remoteTrackURI, positionMs: 0))
            observer.onEvent(event: .remoteChanged(deviceName: "Pixel", volume: 6554))
        }

        func play() { observer.onEvent(event: .playing(uri: current, positionMs: 0)) }
        func pause() { observer.onEvent(event: .paused(uri: current, positionMs: 0)) }
        func next() {
            let uri = song.withLock {
                $0 += 1
                return likedSongURI($0)
            }
            observer.onEvent(event: .trackChanged(uri: uri, name: scenarioTrack(uri)?.title ?? "", durationMs: 180_000))
            observer.onEvent(event: .playing(uri: uri, positionMs: 0))
        }

        private var current: String {
            let n = song.withLock { $0 }
            return n == 1 ? Self.remoteTrackURI : likedSongURI(n)
        }

        func addToQueue(uri _: String) throws {}
        func clearQueue() {}
        func load(uri _: String, startMs _: UInt32, autoplay _: Bool) async throws {}
        func loadTracks(uris _: [String], startIndex _: UInt32, contextUri _: String?, inContextOrder _: Bool, autoplay _: Bool) throws {}
        func moveInQueue(from _: UInt32, to _: UInt32) throws {}
        func playNext(uri _: String) throws {}
        func previous() {}
        func skip(count _: UInt32) {}
        func queue() -> QueueSnapshot {
            QueueSnapshot(current: current, upNext: [], nextFromContext: [], shuffle: false, repeat: .off, autoplay: true)
        }
        func removeFromQueue(index _: UInt32) throws {}
        func seek(positionMs _: UInt32) {}
        func setAutoplay(on _: Bool) {}
        func setBitrate(bitrate _: Bitrate) async {}
        func setCrossfade(seconds _: UInt8) {}
        func setLocalFolders(paths _: [String]) async {}
        func setNormalisation(normalisation _: LoudnessPreset?) async {}
        func setRepeat(mode _: RepeatMode) {}
        func setShuffle(on _: Bool) {}
        func setVolume(volume _: UInt16) {}
        func setRemoteVolume(volume _: UInt16) {}
        func stop() {}
        func stopLocal() {}
    }

    private final nonisolated class ScenarioPlayer: SpotPlayerProtocol {
        private let observer: any PlayerObserver
        private let snapshot = OSAllocatedUnfairLock(initialState: QueueSnapshot(
            current: scenarioTrackURI, upNext: [likedSongURI(5), likedSongURI(6)],
            nextFromContext: [likedSongURI(7), likedSongURI(8)], shuffle: false, repeat: .off, autoplay: true
        ))

        init(observer: any PlayerObserver, restoredAtMs: UInt32 = 0) {
            self.observer = observer
            observer.onEvent(event: .trackChanged(uri: scenarioTrackURI, name: "Test Track", durationMs: 180_000))
            observer.onEvent(event: .paused(uri: scenarioTrackURI, positionMs: restoredAtMs))
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
        func loadTracks(uris: [String], startIndex: UInt32, contextUri _: String?, inContextOrder _: Bool, autoplay _: Bool) throws {
            let uri = uris[Int(startIndex)]
            if uri == scenarioLocalTracks[1].uri {
                return observer.onEvent(event: .unavailable(uri: uri))
            }
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
        func skip(count: UInt32) {
            let uri: String? = snapshot.withLock {
                let upcoming = $0.upNext + $0.nextFromContext
                guard count >= 1, Int(count) <= upcoming.count else { return nil }
                let fromUpNext = min(Int(count), $0.upNext.count)
                $0.upNext.removeFirst(fromUpNext)
                $0.nextFromContext.removeFirst(Int(count) - fromUpNext)
                $0.current = upcoming[Int(count) - 1]
                return $0.current
            }
            guard let uri else { return }
            observer.onEvent(event: .trackChanged(uri: uri, name: scenarioTrack(uri)?.title ?? "", durationMs: 180_000))
            observer.onEvent(event: .playing(uri: uri, positionMs: 0))
        }
        func queue() -> QueueSnapshot { snapshot.withLock { $0 } }
        func removeFromQueue(index: UInt32) throws { _ = snapshot.withLock { $0.upNext.remove(at: Int(index)) } }
        func seek(positionMs _: UInt32) {}
        func setAutoplay(on _: Bool) {}
        func setBitrate(bitrate _: Bitrate) async {}
        func setCrossfade(seconds _: UInt8) {}
        func setLocalFolders(paths _: [String]) async {}
        func setNormalisation(normalisation _: LoudnessPreset?) async {}
        func setRepeat(mode _: RepeatMode) {}
        func setShuffle(on _: Bool) {}
        func setVolume(volume _: UInt16) {}
        func setRemoteVolume(volume _: UInt16) {}
        func stop() {}
        func stopLocal() {}
    }

    /// Liked songs newest first, nothing else saved; never changes.
    private final nonisolated class ScenarioLibrary: LibraryServiceProtocol {
        private let fill: LibraryFill

        init(fill: LibraryFill) {
            self.fill = fill
        }

        func cached(kind: LibraryKind) -> [LibraryItem] {
            guard case let .liked(likedSongs, _, _) = fill else { return [] }
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

    /// "Road Trip" (the user's, editable) and Spotify's "Daily Mix 1" when the
    /// library is filled; edits change them in memory.
    private final nonisolated class ScenarioPlaylists: PlaylistServiceProtocol {
        private struct Playlist {
            var name: String
            var description: String
            var owner: String
            var songs: [Int]
            /// `spotify:local:` entries, listed after the songs.
            var local: [String] = []
            var revision = 0
            var hasPicture = false
            var likedSongs = false
        }

        private struct State {
            var rootlist: [RootlistEntry] = []
            var playlists: [String: Playlist] = [:]
            var conflictNext = false
            var created = 0
        }

        private let fill: LibraryFill
        private let state: OSAllocatedUnfairLock<State>

        /// Road Trip has songs 1, 2 and 5, Daily Mix 1 songs 4 and 6.
        init(fill: LibraryFill) {
            self.fill = fill
            var state = State()
            if case let .liked(_, conflict, localFiles) = fill {
                let folder = "spotify:user:uitest:folder:mixes"
                state.rootlist = [
                    .playlist(uri: scenarioPlaylistURI, name: "Road Trip", owner: "ui-test", trackCount: 3, parent: nil, editable: true, public: false),
                    .playlist(uri: scenarioMixURI, name: "Daily Mix 1", owner: "spotify", trackCount: 2, parent: nil, editable: false, public: false),
                    .folder(uri: folder, name: "Mixes", parent: nil),
                    .playlist(uri: "spotify:playlist:uitestnested", name: "Morning Mix", owner: "ui-test", trackCount: 0, parent: folder, editable: false, public: false),
                ]
                state.playlists = [
                    scenarioPlaylistURI: Playlist(name: "Road Trip", description: "Songs for the road", owner: "ui-test", songs: [1, 2, 5]),
                    scenarioMixURI: Playlist(name: "Daily Mix 1", description: "Made for you", owner: "spotify", songs: [4, 6]),
                    scenarioLikedMirrorURI: Playlist(name: "Liked Songs", description: "", owner: "spotify", songs: [1], likedSongs: true),
                    scenarioFriendMixURI: Playlist(name: "Fran's Mix", description: "", owner: "fran", songs: [2]),
                ]
                state.conflictNext = conflict
                if localFiles {
                    state.rootlist.append(
                        .playlist(uri: scenarioLocalMixURI, name: "Local Mix", owner: "ui-test", trackCount: 2, parent: nil, editable: false, public: false)
                    )
                    state.playlists[scenarioLocalMixURI] = Playlist(
                        name: "Local Mix", description: "", owner: "ui-test", songs: [], local: scenarioLocalTracks.map(\.uri)
                    )
                }
            }
            self.state = OSAllocatedUnfairLock(initialState: state)
        }

        func cachedRootlist() -> [RootlistEntry] {
            state.withLock { $0.rootlist }
        }

        func rootlist() async throws -> [RootlistEntry] {
            if case .failing = fill { throw PlaylistError.Request(message: "ui-test") }
            return cachedRootlist()
        }

        func cachedPage(uri _: String, from _: UInt32, length _: UInt32) -> PlaylistPage? {
            nil
        }

        /// Each playlist on one page.
        func page(uri: String, from: UInt32, length _: UInt32) async throws -> PlaylistPage {
            let (playlist, entry) = state.withLock { state in
                (state.playlists[uri], state.rootlist.first { if case .playlist(uri, _, _, _, _, _, _) = $0 { true } else { false } })
            }
            guard let playlist else { throw PlaylistError.Request(message: "ui-test") }
            let editable = if case .playlist(_, _, _, _, _, true, _) = entry { true } else { false }
            let tracks = from > 0 ? [] : playlist.songs.map {
                PlaylistTrack(uri: likedSongURI($0), addedBy: "ui-test", addedAt: 1_760_000_000 - Int64($0) * 86400)
            } + playlist.local.map { PlaylistTrack(uri: $0, addedBy: "ui-test", addedAt: 1_760_000_000) }
            return PlaylistPage(
                uri: uri, revision: "\(playlist.revision)", name: playlist.name, description: playlist.description,
                owner: playlist.owner, ownerName: playlist.owner == "fran" ? "Fran" : "UI Test", collaborative: false, editable: editable, likedSongs: playlist.likedSongs,
                artwork: playlist.hasPicture ? [Artwork(url: "https://i.scdn.co/image/ui-test-picture", size: .large, width: 640, height: 640)] : [],
                total: UInt32(playlist.songs.count + playlist.local.count), offset: from, tracks: tracks
            )
        }

        func followerCount(uri _: String) async throws -> UInt64 {
            1234
        }

        func addTracks(uri: String, trackUris: [String], revision: String) async throws -> String {
            try editTracks(uri, revision) { $0 += trackUris.compactMap(Self.songNumber) }
        }

        func removeTracks(uri: String, from: UInt32, trackUris: [String], revision: String) async throws -> String {
            try editTracks(uri, revision) { $0.removeSubrange(Int(from) ..< Int(from) + trackUris.count) }
        }

        func moveTracks(uri: String, from: UInt32, length: UInt32, to: UInt32, revision: String) async throws -> String {
            try editTracks(uri, revision) { songs in
                let range = Int(from) ..< Int(from + length)
                let block = songs[range]
                songs.removeSubrange(range)
                songs.insert(contentsOf: block, at: to > from ? Int(to - length) : Int(to))
            }
        }

        func updateDetails(uri: String, name: String, description: String) async throws {
            state.withLock { state in
                state.playlists[uri]?.name = name
                state.playlists[uri]?.description = description
                state.rootlist = state.rootlist.map { entry in
                    guard case let .playlist(entryURI, _, owner, count, parent, editable, isPublic) = entry, entryURI == uri else { return entry }
                    return .playlist(uri: uri, name: name, owner: owner, trackCount: count, parent: parent, editable: editable, public: isPublic)
                }
            }
        }

        func createPlaylist(name: String, description: String, folder: String?) async throws -> String {
            state.withLock { state in
                state.created += 1
                let uri = "spotify:playlist:uitestnew-\(state.created)"
                state.playlists[uri] = Playlist(name: name, description: description, owner: "ui-test", songs: [])
                state.rootlist.insert(
                    .playlist(uri: uri, name: name, owner: "ui-test", trackCount: 0, parent: folder, editable: true, public: false), at: 0
                )
                return uri
            }
        }

        func createFolder(name: String, folder: String?) async throws -> String {
            state.withLock { state in
                state.created += 1
                let uri = "spotify:user:uitest:folder:new-\(state.created)"
                state.rootlist.insert(.folder(uri: uri, name: name, parent: folder), at: 0)
                return uri
            }
        }

        func followPlaylist(uri: String) async throws {
            state.withLock { state in
                guard let playlist = state.playlists[uri], !state.rootlist.contains(where: { if case .playlist(uri, _, _, _, _, _, _) = $0 { true } else { false } })
                else { return }
                state.rootlist.insert(
                    .playlist(uri: uri, name: playlist.name, owner: playlist.owner, trackCount: UInt32(playlist.songs.count), parent: nil, editable: false, public: true),
                    at: 0
                )
            }
        }

        /// The signed-in "ui-test" follows Fran and Test Artist; Fran shares one playlist and no follows.
        func userProfile(username: String?) async throws -> UserProfile {
            if case .failing = fill { throw PlaylistError.Request(message: "ui-test") }
            if username == "fran" {
                return UserProfile(
                    username: "fran", name: "Fran", artwork: [], followers: 3,
                    playlists: [ProfileItem(uri: scenarioFriendMixURI, name: "Fran's Mix", artwork: [])], following: []
                )
            }
            return UserProfile(
                username: "ui-test", name: "UI Test", artwork: [], followers: 1,
                playlists: [ProfileItem(uri: scenarioPlaylistURI, name: "Road Trip", artwork: [])],
                following: [
                    ProfileItem(uri: "spotify:user:fran", name: "Fran", artwork: []),
                    ProfileItem(uri: "spotify:artist:uitest", name: "Test Artist", artwork: []),
                ]
            )
        }

        func deletePlaylist(uri: String) async throws {
            state.withLock { state in
                state.rootlist.removeAll { if case .playlist(uri, _, _, _, _, _, _) = $0 { true } else { false } }
            }
        }

        /// Takes only what Spotify takes: a JPEG of at most 256 KiB and 640 px a side.
        func setPicture(uri: String, jpeg: Data) async throws {
            guard jpeg.starts(with: [0xFF, 0xD8, 0xFF]), jpeg.count <= 256 * 1024,
                  let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  max(width, height) <= 640
            else { throw PlaylistError.InvalidImage }
            state.withLock { $0.playlists[uri]?.hasPicture = true }
        }

        func setPublic(uri: String, public isPublic: Bool) async throws {
            state.withLock { state in
                state.rootlist = state.rootlist.map { entry in
                    guard case let .playlist(entryURI, name, owner, count, parent, editable, _) = entry, entryURI == uri else { return entry }
                    return .playlist(uri: uri, name: name, owner: owner, trackCount: count, parent: parent, editable: editable, public: isPublic)
                }
            }
        }

        private func editTracks(_ uri: String, _ revision: String, _ change: @Sendable (inout [Int]) -> Void) throws -> String {
            try state.withLock { state in
                guard var playlist = state.playlists[uri] else { throw PlaylistError.Request(message: "ui-test") }
                if state.conflictNext {
                    state.conflictNext = false
                    throw PlaylistError.Conflict
                }
                guard revision == "\(playlist.revision)" else { throw PlaylistError.Conflict }
                change(&playlist.songs)
                playlist.revision += 1
                state.playlists[uri] = playlist
                return "\(playlist.revision)"
            }
        }

        private static func songNumber(_ uri: String) -> Int? {
            Int(uri.dropFirst("spotify:track:uitest".count))
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
                    tracks: [likedSongURI(2), likedSongURI(3), likedSongURI(1)],
                    contexts: [scenarioAlbum.uri, scenarioPlaylistURI, scenarioArtist.uri]
                )
            case .empty:
                return RecentlyPlayed(tracks: [], contexts: [])
            case .failing:
                throw HomeError.Network(message: "ui-test")
            }
        }
    }

    /// spclient's contexts: more than the Web API's, and no Web API scope needed.
    private nonisolated struct ScenarioRecentContexts: RecentContextsProvider {
        let fill: LibraryFill

        func recentContexts() async throws -> [String] {
            switch fill {
            case .liked:
                [scenarioAlbum.uri, scenarioPlaylistURI, scenarioArtist.uri, scenarioSingle.uri, scenarioShow.uri, scenarioLikedMirrorURI]
            case .empty:
                []
            case .failing:
                throw HomeError.Spclient(message: "ui-test")
            }
        }
    }

    /// Needs a Web API token like the real search; "test" finds a track
    /// section with one more page, an artist and an album; "fail" fails;
    /// "busy" is rate limited; anything else finds nothing.
    private final nonisolated class ScenarioSearch: SearchServiceProtocol {
        private let accessToken: @Sendable () async throws -> String

        init(accessToken: @escaping @Sendable () async throws -> String) {
            self.accessToken = accessToken
        }

        func search(query: String, limit _: UInt32) async throws -> [SearchGroup] {
            _ = try await accessToken()
            let query = query.lowercased()
            if query.contains("busy") { throw SearchError.RateLimited }
            if query.contains("fail") { throw SearchError.Request(message: "ui-test") }
            guard query.contains("test") else { return [] }
            return [
                SearchGroup(kind: .track, total: 4, offset: 0, hits: (1 ... 3).map(Self.track)),
                SearchGroup(kind: .artist, total: 1, offset: 0, hits: [
                    SearchHit(uri: "spotify:artist:uitest", name: "Test Artist", subtitle: "Artist", artwork: [], explicit: false),
                ]),
                SearchGroup(kind: .album, total: 1, offset: 0, hits: [
                    SearchHit(uri: "spotify:album:uitest", name: "Test Album", subtitle: "Test Artist", artwork: [], explicit: false),
                ]),
            ]
        }

        func page(query _: String, kind: SearchKind, offset: UInt32, limit _: UInt32) async throws -> SearchGroup {
            _ = try await accessToken()
            return SearchGroup(kind: kind, total: 4, offset: offset, hits: kind == .track && offset == 3 ? [Self.track(4)] : [])
        }

        private static func track(_ n: Int) -> SearchHit {
            SearchHit(uri: likedSongURI(n), name: "Song \(n)", subtitle: "Test Artist", artwork: [], explicit: false)
        }
    }

    private final nonisolated class ScenarioMetadata: MetadataServiceProtocol {
        /// Test Track has synced lyrics, Song 5 unsynced ones, and every other track none.
        func lyrics(trackUri: String) async throws -> Lyrics? {
            switch trackUri {
            case scenarioTrackURI:
                Lyrics(synced: true, lines: [
                    LyricsLine(startMs: 0, words: "Hello from the first line"),
                    LyricsLine(startMs: 60000, words: "Here comes the second line"),
                ])
            case likedSongURI(5): Lyrics(synced: false, lines: [LyricsLine(startMs: 0, words: "Words without timing")])
            default: nil
            }
        }

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

    private struct ScenarioRefresher: TokenRefresher {
        func refresh(clientID _: String, refreshToken: String) async throws -> OAuthTokens {
            OAuthTokens(accessToken: "ui-test", refreshToken: refreshToken, expiresInSecs: 3600, scopes: [])
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
        private let fails: Bool
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(completes: Bool, fails: Bool = false) {
            self.completes = completes
            self.fails = fails
        }

        func authorizeURL() -> String {
            "https://accounts.spotify.com/authorize"
        }

        /// SignInModel's task group waits for this child, so it must end on `cancel()`.
        func finish() async throws -> OAuthTokens {
            if fails {
                throw SignInFailure.network
            }
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
