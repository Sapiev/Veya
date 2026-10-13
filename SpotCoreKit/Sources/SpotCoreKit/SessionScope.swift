import Foundation
import Observation

/// One signed-in session's player, library and page models, kept outside the
/// window so playback and the media keys carry on with it closed, and built
/// once so redrawing the window starts no new services.
@MainActor
@Observable
public final class SessionScope {
    public let handle: any SessionHandle
    public let metadata: any MetadataServiceProtocol
    public let library: LibraryModel
    public let playlists: PlaylistModel
    public let search: SearchModel
    public let home: HomeModel
    public let podcast: PodcastModel
    public private(set) var player: PlayerModel?
    @ObservationIgnored private let settings: PlaybackSettings
    /// Hands the started player to the session owner, which stops it on sign out; false drops it.
    @ObservationIgnored private let attach: (PlayerModel) -> Bool

    /// `accessToken` is the Web API token behind search and recently played.
    public init(
        handle: any SessionHandle,
        metadataStore: MetadataStore?,
        settings: PlaybackSettings,
        accessToken: @escaping @Sendable () async throws -> String,
        episodeProgress: any EpisodeProgressProvider,
        attach: @escaping (PlayerModel) -> Bool
    ) {
        self.handle = handle
        self.settings = settings
        self.attach = attach
        let metadata = handle.makeMetadata(store: metadataStore)
        self.metadata = metadata
        library = LibraryModel(library: handle.makeLibrary(store: metadataStore), metadata: metadata)
        let playlistService = handle.makePlaylists(store: metadataStore)
        playlists = PlaylistModel(playlists: playlistService)
        search = SearchModel(service: handle.makeSearch(accessToken: accessToken))
        home = HomeModel(
            metadata: metadata,
            playlists: playlistService,
            recentlyPlayed: handle.makeRecentlyPlayed(accessToken: accessToken)
        )
        podcast = PodcastModel(metadata: metadata, progress: episodeProgress)
    }

    /// Starts the player and follows the library until cancelled.
    public func run() async {
        async let started: Void = startPlayer()
        library.load(.tracks)
        await library.watch()
        await started
    }

    private func startPlayer() async {
        do {
            let started = try await PlayerModel.start(session: handle, metadata: metadata, settings: settings)
            if attach(started) { player = started }
        } catch {
            // Type name only: messages may carry server text.
            logMessage(level: .error, category: "player", message: "Player unavailable: \(type(of: error))")
        }
    }
}

/// Keeps the current session's scope for the app's lifetime and points the
/// media controls at its player.
@MainActor
@Observable
public final class ActiveSession {
    public private(set) var scope: SessionScope?
    @ObservationIgnored private let session: SessionModel
    @ObservationIgnored private let controls: MediaControls
    @ObservationIgnored private let make: (any SessionHandle) -> SessionScope
    @ObservationIgnored private var running: Task<Void, Never>?

    public init(session: SessionModel, controls: MediaControls, make: @escaping (any SessionHandle) -> SessionScope) {
        self.session = session
        self.controls = controls
        self.make = make
        follow()
    }

    /// The scope of the session that is ready now; nil while the scope still
    /// belongs to the session that just ended.
    public var current: SessionScope? {
        guard let handle = session.session, let scope, scope.handle === handle else { return nil }
        return scope
    }

    private func follow() {
        withObservationTracking {
            let handle = session.session
            if scope?.handle !== handle {
                running?.cancel()
                scope = handle.map(make)
                running = scope.map { scope in Task { await scope.run() } }
            }
            controls.bind(player: scope?.player, library: scope?.library)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow() }
        }
    }
}

extension SessionModel {
    /// Signs out and calls `failed` on the next main-actor turn if any step
    /// failed, so an alert button's own action can't reset the flag it raised.
    public func signOut(failed: @escaping @MainActor () -> Void) {
        do {
            try signOut()
        } catch {
            Task { @MainActor in failed() }
        }
    }
}
