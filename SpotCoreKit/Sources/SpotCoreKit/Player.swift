import Foundation
import Observation

/// A player and the engine that renders its output; `engine` is nil only in fakes.
public struct PlayerConnection {
    public let player: any SpotPlayerProtocol
    public let engine: AudioEngine?

    public init(player: any SpotPlayerProtocol, engine: AudioEngine?) {
        self.player = player
        self.engine = engine
    }
}

extension SpotSession {
    @MainActor
    public func makePlayer(observer: any PlayerObserver, settings: PlaybackSettings) async throws -> PlayerConnection {
        let output = AudioOutput()
        let engine = try AudioEngine(output: output)
        engine.outputDeviceUID = settings.outputDeviceUID
        try engine.start()
        let player = try await SpotPlayer(
            session: self,
            output: output,
            observer: observer,
            volume: settings.playerVolume,
            normalisation: settings.normalisation,
            bitrate: settings.bitrate
        )
        return PlayerConnection(player: player, engine: engine)
    }
}

private final class PlaybackEventRelay: PlayerObserver {
    private let continuation: AsyncStream<PlaybackEvent>.Continuation

    init(_ continuation: AsyncStream<PlaybackEvent>.Continuation) {
        self.continuation = continuation
    }

    func onEvent(event: PlaybackEvent) {
        continuation.yield(event)
    }
}

public typealias PlayerLog = @MainActor (LogLevel, String) -> Void

/// What is playing and the transport controls, driven by the player's events.
@MainActor
@Observable
public final class PlayerModel {
    public struct NowPlaying: Equatable, Sendable {
        public var uri: String
        public var title: String
        /// For an episode, the show's name with an empty URI.
        public var artists: [ItemRef]
        public var album: ItemRef?
        public var artwork: [Artwork]
        public var durationMs: UInt32
    }

    public private(set) var nowPlaying: NowPlaying?
    public private(set) var isPlaying = false
    public private(set) var shuffle = false
    public private(set) var repeatMode = RepeatMode.off
    private(set) var positionMs: UInt32 = 0
    /// When `positionMs` was reported; playback has advanced since if playing.
    private(set) var positionAnchor = Date.distantPast

    @ObservationIgnored private let player: any SpotPlayerProtocol
    @ObservationIgnored private let engine: AudioEngine?
    @ObservationIgnored private let metadata: any MetadataServiceProtocol
    @ObservationIgnored private let settings: PlaybackSettings
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let log: PlayerLog
    @ObservationIgnored private var events: Task<Void, Never>?
    @ObservationIgnored private(set) var resolution: Task<Void, Never>?

    init(
        player: any SpotPlayerProtocol,
        engine: AudioEngine?,
        metadata: any MetadataServiceProtocol,
        settings: PlaybackSettings,
        clock: @escaping () -> Date = Date.init,
        log: @escaping PlayerLog = { logMessage(level: $0, category: "player", message: $1) }
    ) {
        self.player = player
        self.engine = engine
        self.metadata = metadata
        self.settings = settings
        self.clock = clock
        self.log = log
        let queue = player.queue()
        shuffle = queue.shuffle
        repeatMode = queue.repeat
    }

    isolated deinit {
        events?.cancel()
        player.stop()
    }

    /// Creates the session's player and applies its events until the model is released.
    public static func start(
        session: any SessionHandle,
        metadata: any MetadataServiceProtocol,
        settings: PlaybackSettings
    ) async throws -> PlayerModel {
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        let connection = try await session.makePlayer(observer: PlaybackEventRelay(continuation), settings: settings)
        let model = PlayerModel(player: connection.player, engine: connection.engine, metadata: metadata, settings: settings)
        model.events = Task { [weak model] in
            for await event in stream {
                model?.apply(event)
            }
        }
        return model
    }

    /// Playback position at `date`, advanced from the last report while playing.
    public func position(at date: Date) -> UInt32 {
        guard isPlaying else { return positionMs }
        let rate = Double(settings.rate(for: nowPlaying?.uri ?? ""))
        let elapsed = max(0, date.timeIntervalSince(positionAnchor)) * 1000 * rate
        let advanced = UInt32(min(Double(positionMs) + elapsed, Double(UInt32.max)))
        return nowPlaying.map { min(advanced, $0.durationMs) } ?? advanced
    }

    func apply(_ event: PlaybackEvent) {
        switch event {
        case let .loading(uri, position):
            isPlaying = false
            report(position)
            show(uri, title: nowPlaying?.uri == uri ? nowPlaying?.title ?? "" : "", durationMs: nowPlaying?.durationMs ?? 0)
        case let .playing(_, position):
            report(position)
            isPlaying = true
        case let .paused(_, position):
            report(position)
            isPlaying = false
        case let .position(_, position):
            report(position)
        case let .trackChanged(uri, name, durationMs):
            show(uri, title: name, durationMs: durationMs)
        case .endOfTrack:
            break
        case .unavailable:
            log(.warn, "Track unavailable, skipping")
        case .stopped:
            isPlaying = false
            nowPlaying = nil
            report(0)
        }
    }

    /// Plays `uris` from `index`; `context` seeds radio once the list runs out.
    public func play(_ uris: [String], from index: Int, context: String? = nil) {
        guard uris.indices.contains(index) else { return }
        perform("play") {
            try player.loadTracks(uris: uris, startIndex: UInt32(index), contextUri: context, autoplay: true)
        }
    }

    /// Puts `uris` at the front of Up Next, keeping their order.
    public func playNext(_ uris: [String]) {
        perform("queue") {
            for uri in uris.reversed() {
                try player.playNext(uri: uri)
            }
        }
    }

    public func addToQueue(_ uris: [String]) {
        perform("queue") {
            for uri in uris {
                try player.addToQueue(uri: uri)
            }
        }
    }

    private func perform(_ action: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            // Type name only: messages may carry server text.
            log(.warn, "Couldn't \(action): \(String(describing: type(of: error)))")
        }
    }

    public func togglePlayPause() {
        isPlaying ? player.pause() : player.play()
    }

    public func next() {
        player.next()
    }

    public func previous() {
        player.previous()
    }

    public func seek(to positionMs: UInt32) {
        player.seek(positionMs: positionMs)
        report(positionMs)
    }

    public func setShuffle(_ on: Bool) {
        player.setShuffle(on: on)
        shuffle = on
    }

    /// Off, then the whole context, then the current track.
    public func cycleRepeat() {
        let mode: RepeatMode = switch repeatMode {
        case .off: .context
        case .context: .track
        case .track: .off
        }
        player.setRepeat(mode: mode)
        repeatMode = mode
    }

    /// 0...1, persisted.
    public var volume: Double {
        get { settings.volume }
        set {
            settings.volume = newValue
            player.setVolume(volume: settings.playerVolume)
        }
    }

    /// Nil follows the system default; persisted.
    public var outputDeviceUID: String? {
        get { settings.outputDeviceUID }
        set {
            settings.outputDeviceUID = newValue
            engine?.outputDeviceUID = newValue
        }
    }

    private func report(_ position: UInt32) {
        positionMs = position
        positionAnchor = clock()
    }

    private func show(_ uri: String, title: String, durationMs: UInt32) {
        guard nowPlaying?.uri != uri || nowPlaying?.title != title else { return }
        let known = nowPlaying?.uri == uri ? nowPlaying : nil
        nowPlaying = NowPlaying(
            uri: uri,
            title: title,
            artists: known?.artists ?? [],
            album: known?.album,
            artwork: known?.artwork ?? [],
            durationMs: durationMs
        )
        engine?.rate = settings.rate(for: uri)
        if known == nil {
            resolution = Task { await resolve(uri) }
        }
    }

    private func resolve(_ uri: String) async {
        let item: MetadataItem
        do {
            guard let first = try await metadata.items(uris: [uri]).first else { return }
            item = first
        } catch {
            // Type name only: messages may carry server text.
            log(.warn, "Couldn't load now-playing metadata: \(String(describing: type(of: error)))")
            return
        }
        guard var current = nowPlaying, current.uri == uri else { return }
        switch item {
        case let .track(track):
            current.title = track.title
            current.artists = track.artists
            current.album = track.album
            current.artwork = track.artwork
            if current.durationMs == 0 { current.durationMs = track.durationMs }
        case let .episode(episode):
            current.title = episode.title
            current.artists = [ItemRef(uri: "", name: episode.showName)]
            current.artwork = episode.artwork
            if current.durationMs == 0 { current.durationMs = episode.durationMs }
        default:
            return
        }
        nowPlaying = current
    }
}
