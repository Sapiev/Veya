import Foundation

/// PBI-604: what the Shortcuts and Siri actions do. Each waits for the player
/// first, since the system may launch the app just to run one.
@MainActor
public final class ShortcutActions {
    public enum Failure: Error, Equatable {
        /// No signed-in session started its player in time.
        case notReady
        case nothingPlaying
        case invalidURI
    }

    private let player: () -> PlayerModel?
    private let library: () -> LibraryModel?
    private let playlists: () -> PlaylistModel?
    private let timeout: Duration

    public convenience init(session: ActiveSession) {
        self.init(
            player: { session.current?.player },
            library: { session.current?.library },
            playlists: { session.current?.playlists }
        )
    }

    init(
        player: @escaping () -> PlayerModel?,
        library: @escaping () -> LibraryModel?,
        playlists: @escaping () -> PlaylistModel?,
        timeout: Duration = .seconds(20)
    ) {
        self.player = player
        self.library = library
        self.playlists = playlists
        self.timeout = timeout
    }

    public func perform(_ command: MediaControls.Command) async throws(Failure) {
        let player = try await ready(player)
        _ = MediaControls.perform(command, player: player, library: library())
    }

    /// Saves the current track to Liked Songs; one already saved stays saved.
    public func likeCurrentTrack() async throws(Failure) {
        let player = try await ready(player)
        guard let uri = player.nowPlaying?.uri else { throw .nothingPlaying }
        let library = try await ready(library)
        if !library.isSaved(uri) {
            library.setSaved(uri, true)
        }
    }

    public func currentTrack() async throws(Failure) -> MediaControls.Info {
        let player = try await ready(player)
        guard let info = MediaControls.info(player: player, library: library(), at: .now) else {
            throw .nothingPlaying
        }
        return info
    }

    /// The user's playlists, folders left out, whose name contains `query`; nil lists them all.
    public func playlists(matching query: String? = nil) async throws(Failure) -> [RootlistNode] {
        let model = try await ready(playlists)
        if model.rootlist.isEmpty {
            await model.load().value
        }
        return model.rootlist.compactMap { entry in
            guard case let .playlist(uri, name, _, _, _, _, _) = entry,
                  query.map(name.localizedStandardContains) ?? true else { return nil }
            return RootlistNode(id: uri, name: name, children: nil)
        }
    }

    /// What's playing right now, without waiting for a player; for AppleScript properties,
    /// which must answer synchronously.
    public var nowPlaying: (uri: String, info: MediaControls.Info)? {
        guard let player = player(), let uri = player.nowPlaying?.uri,
              let info = MediaControls.info(player: player, library: library(), at: .now) else { return nil }
        return (uri, info)
    }

    /// Plays a track, playlist, album or other `spotify:` URI as the context.
    public func play(_ uri: String) async throws(Failure) {
        // AppleScript passes any text; only Spotify URIs reach the core.
        guard uri.hasPrefix("spotify:"), uri.count > "spotify:".count else { throw .invalidURI }
        try await ready(player).play(uri, startingAt: 0).value
    }

    // shortcut: polls every 100 ms; observe ActiveSession instead if this ever shows up in a profile.
    private func ready<Value>(_ value: () -> Value?) async throws(Failure) -> Value {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let value = value() {
                return value
            }
            guard ContinuousClock.now < deadline, !Task.isCancelled else { throw .notReady }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
