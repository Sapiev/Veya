import AppKit
import MediaPlayer
import Observation

/// Mirrors the player into Control Center and takes the media keys, AirPods
/// taps and Control Center buttons; these reach it with the window closed.
@MainActor
public final class MediaControls {
    public enum Command: Equatable, Sendable {
        case play, pause, togglePlayPause, next, previous, like
        case seek(positionMs: UInt32)
    }

    /// What Control Center shows; `rate` is 0 while paused so the system clock holds still.
    public struct Info: Equatable {
        public var title: String
        public var artist: String
        public var album: String?
        public var durationMs: UInt32
        public var elapsedMs: UInt32
        public var rate: Float
        public var isPlaying: Bool
        public var saved: Bool
    }

    public typealias Publish = @MainActor (Info?, CGImage?) -> Void

    private var player: PlayerModel?
    private var library: LibraryModel?
    private let artworkLoader: ArtworkLoader?
    private let publish: Publish
    private let commands: MPRemoteCommandCenter?
    /// Bumped on every rebind, so tracking armed for an earlier player stops.
    private var binding = 0
    /// Keyed by the artwork list, which arrives with the track's metadata after it starts.
    private var artwork: (source: [Artwork], image: CGImage?)?
    private var artworkLoad: Task<Void, Never>?

    public init(
        artworkLoader: ArtworkLoader?,
        commands: MPRemoteCommandCenter? = .shared(),
        publish: @escaping Publish = MediaControls.publishToSystem
    ) {
        self.artworkLoader = artworkLoader
        self.commands = commands
        self.publish = publish
        if let commands { register(commands) }
    }

    /// Follows `player` until the next call; nil clears Control Center.
    public func bind(player: PlayerModel?, library: LibraryModel?) {
        guard player !== self.player || library !== self.library else { return }
        self.player = player
        self.library = library
        binding += 1
        follow(binding)
    }

    /// What Control Center shows right now; nil while nothing is loaded.
    public var current: Info? {
        Self.info(player: player, library: library, at: .now)
    }

    @discardableResult
    public func perform(_ command: Command) -> Bool {
        guard let player else { return false }
        switch command {
        case .play: if !player.isPlaying { player.togglePlayPause() }
        case .pause: if player.isPlaying { player.togglePlayPause() }
        case .togglePlayPause: player.togglePlayPause()
        case .next: player.next()
        case .previous: player.previous()
        case let .seek(positionMs): player.seek(to: positionMs)
        case .like:
            guard let uri = player.nowPlaying?.uri, let library else { return false }
            library.setSaved(uri, !library.isSaved(uri))
        }
        return true
    }

    static func info(player: PlayerModel?, library: LibraryModel?, at date: Date) -> Info? {
        guard let player, let now = player.nowPlaying else { return nil }
        return Info(
            title: now.title,
            artist: now.artists.map(\.name).joined(separator: ", "),
            album: now.album?.name,
            durationMs: now.durationMs,
            elapsedMs: player.position(at: date),
            rate: player.isPlaying ? player.rate : 0,
            isPlaying: player.isPlaying,
            saved: library?.isSaved(now.uri) ?? false
        )
    }

    private func follow(_ armed: Int) {
        guard armed == binding else { return }
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(armed) }
        }
    }

    private func update() {
        let info = Self.info(player: player, library: library, at: .now)
        commands?.likeCommand.isActive = info?.saved ?? false
        guard let now = player?.nowPlaying else {
            artworkLoad?.cancel()
            artwork = nil
            publish(nil, nil)
            return
        }
        if artwork?.source != now.artwork { loadArtwork(now.artwork) }
        publish(info, artwork?.image)
    }

    private func loadArtwork(_ source: [Artwork]) {
        artworkLoad?.cancel()
        artwork = (source, nil)
        guard let artworkLoader, !source.isEmpty else { return }
        artworkLoad = Task { [weak self] in
            let image = await artworkLoader.image(for: source, pixels: 600)
            guard let self, !Task.isCancelled, artwork?.source == source else { return }
            artwork = (source, image)
            publish(Self.info(player: player, library: library, at: .now), image)
        }
    }

    private func register(_ center: MPRemoteCommandCenter) {
        let routes: [(MPRemoteCommand, @Sendable (MPRemoteCommandEvent) -> Command?)] = [
            (center.playCommand, { _ in .play }),
            (center.pauseCommand, { _ in .pause }),
            (center.togglePlayPauseCommand, { _ in .togglePlayPause }),
            (center.nextTrackCommand, { _ in .next }),
            (center.previousTrackCommand, { _ in .previous }),
            (center.likeCommand, { _ in .like }),
            (center.changePlaybackPositionCommand, { event in
                (event as? MPChangePlaybackPositionCommandEvent).map {
                    .seek(positionMs: UInt32(min(max(0, $0.positionTime * 1000), Double(UInt32.max))))
                }
            }),
        ]
        for (command, route) in routes {
            command.isEnabled = true
            command.addTarget(handler: Self.handler(route) { [weak self] in self?.perform($0) })
        }
    }

    /// Nonisolated: the handler runs on a thread MediaPlayer picks, and a closure
    /// formed on the main actor would trap there; the command hops back instead.
    nonisolated static func handler<Event>(
        _ route: @escaping @Sendable (Event) -> Command?,
        perform: @escaping @MainActor (Command) -> Void
    ) -> (Event) -> MPRemoteCommandHandlerStatus {
        { event in
            guard let command = route(event) else { return .commandFailed }
            Task { @MainActor in perform(command) }
            return .success
        }
    }

    public static func publishToSystem(_ info: Info?, _ image: CGImage?) {
        let center = MPNowPlayingInfoCenter.default()
        guard let info else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var fields: [String: Any] = [
            MPMediaItemPropertyTitle: info.title,
            MPMediaItemPropertyArtist: info.artist,
            MPMediaItemPropertyPlaybackDuration: Double(info.durationMs) / 1000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(info.elapsedMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: Double(info.rate),
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = info.album { fields[MPMediaItemPropertyAlbumTitle] = album }
        if let image { fields[MPMediaItemPropertyArtwork] = artwork(image) }
        center.nowPlayingInfo = fields
        center.playbackState = info.isPlaying ? .playing : .paused
    }

    /// Nonisolated: the system asks for the image on a background thread, where a
    /// closure formed on the main actor would trap.
    nonisolated static func artwork(_ image: CGImage) -> MPMediaItemArtwork {
        let size = CGSize(width: image.width, height: image.height)
        let picture = NSImage(cgImage: image, size: size)
        return MPMediaItemArtwork(boundsSize: size) { _ in picture }
    }
}
