import Foundation
import Observation

/// Registers the player as a Spotify Connect device with a name and zeroconf choice.
public typealias ConnectStarter = @MainActor (_ name: String, _ zeroconf: Bool) async throws -> any SpotConnectProtocol

/// A player and the engine that renders its output; `engine` and `startConnect` are nil only in fakes.
public struct PlayerConnection {
    public let player: any SpotPlayerProtocol
    public let engine: AudioEngine?
    public let startConnect: ConnectStarter?

    public init(player: any SpotPlayerProtocol, engine: AudioEngine?, startConnect: ConnectStarter? = nil) {
        self.player = player
        self.engine = engine
        self.startConnect = startConnect
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
        return PlayerConnection(player: player, engine: engine) { [self] name, zeroconf in
            try await SpotConnect.start(session: self, player: player, name: name, zeroconf: zeroconf)
        }
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
    /// Tracks the user queued; they play before the rest of the context.
    public private(set) var upNext: [String] = []
    public private(set) var nextFromContext: [String] = []
    /// The queue's own id for the playing item; `nowPlaying.uri` can be a relinked one the context does not list.
    private var queueCurrent: String?
    /// The account's Spotify Connect devices, this Mac first.
    public private(set) var devices: [ConnectDevice] = []
    /// A Connect device is running, so playback can move between devices.
    public private(set) var hasConnect = false
    /// A transfer is in flight; one runs at a time.
    public private(set) var transferring = false
    /// Why the last transfer failed, until the next one starts.
    public private(set) var transferFailed = false
    /// The title of a local file librespot couldn't play, until the user dismisses the message.
    public var unplayableLocalFile: String?

    /// The device this Mac controls in Remote mode (PBI-503). Set by the core's
    /// Remote mode, not the device list: a paused active phone does not count.
    public private(set) var playingOn: String?

    /// Whether choosing a device now moves playback.
    public var canTransfer: Bool {
        hasConnect && !transferring
    }
    /// What Veya last started playback from; the player itself doesn't report it.
    public private(set) var context: String?
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
    @ObservationIgnored private(set) var unplayableResolution: Task<Void, Never>?
    /// What the player and engine were last given, so a change is sent once.
    @ObservationIgnored private var applied: Applied
    /// Async setters run in order, so the last change wins.
    @ObservationIgnored private(set) var settingsApply: Task<Void, Never>?
    @ObservationIgnored private let startConnect: ConnectStarter?
    /// Restarts run in order, so the last name and zeroconf choice win.
    @ObservationIgnored private(set) var connectStart: Task<Void, Never>?
    @ObservationIgnored private var connectDevice: (any SpotConnectProtocol)?
    /// When `settings.lastPlayback` was last written.
    @ObservationIgnored private var lastSaved = Date.distantPast
    /// The Web API token for the launch restore, which the first Connect device runs.
    @ObservationIgnored private var restoreToken: (@Sendable () async throws -> String)?

    private struct Applied: Equatable {
        var volume: UInt16
        var bitrate: Bitrate
        var normalisation: LoudnessPreset?
        var crossfade: UInt8
        var outputDeviceUID: String?
        var rate: Float
        var autoplay: Bool
        var connectName: String
        var zeroconf: Bool
        var localFolders: [String]
    }

    init(
        player: any SpotPlayerProtocol,
        engine: AudioEngine?,
        metadata: any MetadataServiceProtocol,
        settings: PlaybackSettings,
        startConnect: ConnectStarter? = nil,
        restoreToken: (@Sendable () async throws -> String)? = nil,
        clock: @escaping () -> Date = Date.init,
        log: @escaping PlayerLog = { logMessage(level: $0, category: "player", message: $1) }
    ) {
        self.player = player
        self.startConnect = startConnect
        self.restoreToken = restoreToken
        self.engine = engine
        self.metadata = metadata
        self.settings = settings
        self.clock = clock
        self.log = log
        let queue = player.queue()
        shuffle = queue.shuffle
        repeatMode = queue.repeat
        upNext = queue.upNext
        nextFromContext = queue.nextFromContext
        queueCurrent = queue.current
        // The player and engine were created with these values.
        applied = Applied(
            volume: settings.playerVolume,
            bitrate: settings.bitrate,
            normalisation: settings.normalisation,
            // A new player starts with crossfade off, so `followSettings` applies the setting.
            crossfade: 0,
            outputDeviceUID: settings.outputDeviceUID,
            rate: 1,
            autoplay: queue.autoplay,
            connectName: settings.connectDeviceName,
            zeroconf: settings.zeroconf,
            localFolders: []
        )
        followSettings()
        // Saved local folders retune the player, which restarts Connect once it is done.
        if settingsApply == nil {
            restartConnect()
        }
    }

    isolated deinit {
        events?.cancel()
        connectStart?.cancel()
        if let connectDevice {
            Task { await connectDevice.shutdown() }
        }
        player.stopLocal()
    }

    /// Creates the session's player and applies its events until the model is released.
    /// `restoreToken` is the Web API token behind the launch restore.
    public static func start(
        session: any SessionHandle,
        metadata: any MetadataServiceProtocol,
        settings: PlaybackSettings,
        restoreToken: (@Sendable () async throws -> String)? = nil
    ) async throws -> PlayerModel {
        let (stream, continuation) = AsyncStream.makeStream(of: PlaybackEvent.self)
        let connection = try await session.makePlayer(observer: PlaybackEventRelay(continuation), settings: settings)
        let model = PlayerModel(
            player: connection.player,
            engine: connection.engine,
            metadata: metadata,
            settings: settings,
            startConnect: connection.startConnect,
            restoreToken: restoreToken
        )
        model.events = Task { [weak model] in
            for await event in stream {
                model?.apply(event)
            }
        }
        return model
    }

    /// The speed the current item plays at.
    var rate: Float {
        settings.rate(for: nowPlaying?.uri ?? "")
    }

    /// Playback position at `date`, advanced from the last report while playing.
    public func position(at date: Date) -> UInt32 {
        guard isPlaying else { return positionMs }
        let elapsed = max(0, date.timeIntervalSince(positionAnchor)) * 1000 * Double(rate)
        let advanced = UInt32(min(Double(positionMs) + elapsed, Double(UInt32.max)))
        return nowPlaying.map { min(advanced, $0.durationMs) } ?? advanced
    }

    func apply(_ event: PlaybackEvent) {
        switch event {
        case let .loading(uri, position):
            isPlaying = false
            report(position)
            // A new item starts without a length, so the metadata lookup fills in its own.
            let known = nowPlaying?.uri == uri ? nowPlaying : nil
            show(uri, title: known?.title ?? "", durationMs: known?.durationMs ?? 0)
            refreshQueue()
        case let .playing(_, position):
            report(position)
            isPlaying = true
        case let .paused(_, position):
            report(position)
            isPlaying = false
            saveLastPlayback()
        case let .position(_, position):
            report(position)
            saveLastPlayback(throttled: true)
        case let .trackChanged(uri, name, durationMs):
            show(uri, title: name, durationMs: durationMs)
            refreshQueue()
            saveLastPlayback()
        case .endOfTrack:
            break
        case let .unavailable(uri):
            log(.warn, "Track unavailable, skipping")
            if uri.hasPrefix("spotify:local:") {
                showUnplayable(uri)
            }
        case .stopped:
            isPlaying = false
            nowPlaying = nil
            report(0)
            refreshQueue()
        case let .volumeChanged(volume):
            // Recorded as applied first, so the remote's volume is not sent back.
            applied.volume = volume
            settings.volume = Double(volume) / Double(UInt16.max)
        case let .remoteChanged(deviceName, volume):
            playingOn = deviceName
            remoteVolume = volume.map { Double($0) / Double(UInt16.max) }
        case let .devicesChanged(devices):
            self.devices = devices
        case .queueChanged:
            let queue = player.queue()
            shuffle = queue.shuffle
            repeatMode = queue.repeat
            upNext = queue.upNext
            nextFromContext = queue.nextFromContext
            queueCurrent = queue.current
        }
    }

    /// Plays `uris` from `index`; `context` seeds radio once the list runs out.
    /// `inContextOrder`: `uris` are `context`'s tracks in its own order, not sorted or filtered,
    /// so Spotify can record the plays under the context.
    public func play(_ uris: [String], from index: Int, context: String? = nil, inContextOrder: Bool = false) {
        guard uris.indices.contains(index) else { return }
        perform("play") {
            // `autoplay` here starts the track; radio after the list follows `PlaybackSettings.autoplay`.
            try player.loadTracks(
                uris: uris, startIndex: UInt32(index), contextUri: context, inContextOrder: inContextOrder, autoplay: true
            )
        }
        self.context = context
        refreshQueue()
    }

    /// Plays the single item `uri`, such as an episode, from `startMs`.
    @discardableResult
    public func play(_ uri: String, startingAt startMs: UInt32) -> Task<Void, Never> {
        let player = player
        return Task {
            do {
                try await player.load(uri: uri, startMs: startMs, autoplay: true)
                context = uri
            } catch {
                // Type name only: messages may carry server text.
                log(.warn, "Couldn't play: \(String(describing: type(of: error)))")
            }
            refreshQueue()
        }
    }

    /// Puts `uris` at the front of Up Next, keeping their order.
    public func playNext(_ uris: [String]) {
        perform("queue") {
            for uri in uris.reversed() {
                try player.playNext(uri: uri)
            }
        }
        refreshQueue()
    }

    public func addToQueue(_ uris: [String]) {
        perform("queue") {
            for uri in uris {
                try player.addToQueue(uri: uri)
            }
        }
        refreshQueue()
    }

    /// Removes Up Next rows by their shown position.
    public func removeFromUpNext(at offsets: IndexSet) {
        guard queueIsCurrent(), offsets.allSatisfy(upNext.indices.contains) else { return }
        perform("remove from queue") {
            for index in offsets.reversed() {
                try player.removeFromQueue(index: UInt32(index))
            }
        }
        refreshQueue()
    }

    /// Moves Up Next rows like `List.onMove`: `destination` is a position before the move.
    public func moveInUpNext(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard queueIsCurrent(), source.allSatisfy(upNext.indices.contains), (0 ... upNext.count).contains(destination)
        else { return }
        var target = upNext.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        target.insert(contentsOf: source.map { upNext[$0] }, at: destination - source.count(in: 0 ..< destination))
        var current = upNext
        perform("reorder queue") {
            // The player moves one row at a time, so put each misplaced row in its final place.
            for index in target.indices where current[index] != target[index] {
                guard let from = current[(index + 1)...].firstIndex(of: target[index]) else { continue }
                try player.moveInQueue(from: UInt32(from), to: UInt32(index))
                current.insert(current.remove(at: from), at: index)
            }
        }
        refreshQueue()
    }

    public func clearUpNext() {
        player.clearQueue()
        refreshQueue()
    }

    /// Up Next shifts when a track ends; acting on stale positions would hit the wrong rows.
    private func queueIsCurrent() -> Bool {
        let shown = upNext
        refreshQueue()
        return upNext == shown
    }

    private func refreshQueue() {
        let queue = player.queue()
        upNext = queue.upNext
        nextFromContext = queue.nextFromContext
        queueCurrent = queue.current
    }

    private func perform(_ action: String, _ body: () throws -> Void) {
        do {
            try body()
        } catch {
            // Type name only: messages may carry server text.
            log(.warn, "Couldn't \(action): \(String(describing: type(of: error)))")
        }
    }

    /// For sign-out and quit: stops only this Mac's playback and never
    /// commands a device it is controlling. Safe to repeat.
    public func teardown() {
        saveLastPlayback()
        player.stopLocal()
        apply(.stopped)
    }

    /// Safe to repeat.
    public func stop() {
        player.stop()
        apply(.stopped)
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

    /// Plays the upcoming row at `offset`: Up Next rows first, then the context's.
    public func skip(to offset: Int) {
        guard queueIsCurrent(), (0 ..< upNext.count + nextFromContext.count).contains(offset) else { return }
        player.skip(count: UInt32(offset + 1))
        refreshQueue()
    }

    public func seek(to positionMs: UInt32) {
        player.seek(positionMs: positionMs)
        report(positionMs)
    }

    public func setShuffle(_ on: Bool) {
        player.setShuffle(on: on)
        shuffle = on
        refreshQueue()
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

    /// 0...1, persisted; in Remote mode the remote device's, which is sent
    /// to it but never saved.
    public var volume: Double {
        get { remoteVolume ?? settings.volume }
        set {
            if remoteVolume != nil {
                remoteVolume = newValue
                player.setRemoteVolume(volume: UInt16((min(max(newValue, 0), 1) * Double(UInt16.max)).rounded()))
                return
            }
            settings.volume = newValue
            applySettings()
        }
    }

    /// The remote device's volume while this Mac controls it (PBI-503).
    private var remoteVolume: Double?

    /// Nil follows the system default; persisted.
    public var outputDeviceUID: String? {
        get { settings.outputDeviceUID }
        set {
            settings.outputDeviceUID = newValue
            applySettings()
        }
    }

    /// Re-arms on every change, so edits in the Settings window reach the live player.
    private func followSettings() {
        withObservationTracking {
            applySettings()
        } onChange: { [weak self] in
            Task { @MainActor in self?.followSettings() }
        }
    }

    private func applySettings() {
        let target = Applied(
            volume: settings.playerVolume,
            bitrate: settings.bitrate,
            normalisation: settings.normalisation,
            crossfade: settings.crossfadeSeconds,
            outputDeviceUID: settings.outputDeviceUID,
            rate: settings.rate(for: nowPlaying?.uri ?? ""),
            autoplay: settings.autoplay,
            connectName: settings.connectDeviceName,
            zeroconf: settings.zeroconf,
            localFolders: settings.localFolderPaths
        )
        let previous = applied
        guard target != previous else { return }
        applied = target
        if target.connectName != previous.connectName || target.zeroconf != previous.zeroconf {
            restartConnect()
        }
        if target.volume != previous.volume {
            player.setVolume(volume: target.volume)
        }
        if target.outputDeviceUID != previous.outputDeviceUID {
            engine?.outputDeviceUID = target.outputDeviceUID
        }
        if target.rate != previous.rate {
            engine?.rate = target.rate
        }
        if target.autoplay != previous.autoplay {
            player.setAutoplay(on: target.autoplay)
        }
        if target.crossfade != previous.crossfade {
            player.setCrossfade(seconds: target.crossfade)
        }
        guard target.bitrate != previous.bitrate || target.normalisation != previous.normalisation
            || target.localFolders != previous.localFolders else { return }
        let player = player
        let pending = settingsApply
        settingsApply = Task { [weak self] in
            await pending?.value
            if target.bitrate != previous.bitrate {
                await player.setBitrate(bitrate: target.bitrate)
            }
            if target.normalisation != previous.normalisation {
                await player.setNormalisation(normalisation: target.normalisation)
            }
            if target.localFolders != previous.localFolders {
                await player.setLocalFolders(paths: target.localFolders)
            }
            // Spirc's player takes the tuning when it starts.
            self?.restartConnect()
        }
    }

    /// Moves playback, with its position and queue, to the Connect device `id`.
    /// Nil when it is already playing there or another transfer is in flight.
    @discardableResult
    public func transfer(to id: String) -> Task<Void, Never>? {
        guard let connectDevice, canTransfer, devices.first(where: { $0.id == id })?.isActive != true else { return nil }
        transferring = true
        transferFailed = false
        return Task {
            defer { transferring = false }
            do {
                try await connectDevice.transfer(deviceId: id)
            } catch {
                transferFailed = true
                // Type name only: messages may carry server text.
                log(.warn, "Couldn't move playback: \(String(describing: type(of: error)))")
            }
        }
    }

    /// Replaces the Connect device, as librespot fixes its name, zeroconf and tuning at start.
    /// The old device is unregistered first, so its late unregister cannot remove the new one.
    private func restartConnect() {
        guard let startConnect else { return }
        let name = settings.connectDeviceName
        let zeroconf = settings.zeroconf
        let pending = connectStart
        connectStart = Task { [weak self] in
            await pending?.value
            guard let self, !Task.isCancelled else { return }
            await connectDevice?.shutdown()
            connectDevice = nil
            hasConnect = false
            do {
                let device = try await startConnect(name, zeroconf)
                guard !Task.isCancelled else { return await device.shutdown() }
                connectDevice = device
                hasConnect = true
                restoreLastPlayback(on: device)
            } catch {
                // Type name only: messages may carry server text.
                log(.warn, "Couldn't start Spotify Connect: \(String(describing: type(of: error)))")
            }
        }
    }

    /// Saves this Mac's playback for the next launch's restore; Remote mode plays elsewhere.
    /// shortcut: `context` is what Veya last started, so a remote that starts another context
    /// here leaves it stale; read the cluster's context URI if restores land on the wrong track.
    private func saveLastPlayback(throttled: Bool = false) {
        guard playingOn == nil, let uri = queueCurrent ?? nowPlaying?.uri, !uri.isEmpty else { return }
        let now = clock()
        if throttled, now.timeIntervalSince(lastSaved) < 5 { return }
        lastSaved = now
        settings.lastPlayback = SavedPlayback(
            trackUri: uri,
            contextUri: context,
            positionMs: position(at: now),
            savedAtMs: Int64(now.timeIntervalSince1970 * 1000)
        )
    }

    /// Runs once, off the start task so a slow Web API holds up no restart.
    private func restoreLastPlayback(on device: any SpotConnectProtocol) {
        guard let token = restoreToken else { return }
        restoreToken = nil
        let log = log
        Task {
            do {
                try await device.restoreLastPlayback(accessToken: token(), saved: settings.lastPlayback)
            } catch {
                // Type name only: messages may carry server text.
                log(.info, "Skipped restoring the last playback: \(String(describing: type(of: error)))")
            }
        }
    }

    /// The title comes from the core, which decodes it from the `spotify:local:` URI.
    private func showUnplayable(_ uri: String) {
        unplayableResolution = Task {
            let item = try? await metadata.items(uris: [uri]).first
            if case let .track(track) = item {
                unplayableLocalFile = track.title
            } else {
                unplayableLocalFile = ""
            }
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
        applySettings()
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
