import Foundation
import os
@testable import SpotCoreKit
import Testing

final class FakePlayer: SpotPlayerProtocol {
    private let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
    /// Up Next behaves like the core queue so position mapping can be checked by outcome.
    private let snapshot: OSAllocatedUnfairLock<QueueSnapshot>
    private let failsLoad: Bool

    struct LoadFailed: Error {}

    init(
        shuffle: Bool = false,
        repeat mode: RepeatMode = .off,
        upNext: [String] = [],
        nextFromContext: [String] = [],
        failsLoad: Bool = false
    ) {
        self.failsLoad = failsLoad
        snapshot = OSAllocatedUnfairLock(initialState: QueueSnapshot(
            current: nil, upNext: upNext, nextFromContext: nextFromContext, shuffle: shuffle, repeat: mode, autoplay: true
        ))
    }

    /// Stands in for the player advancing on its own, e.g. a track ending.
    func setUpNext(_ uris: [String]) {
        snapshot.withLock { $0.upNext = uris }
    }

    /// Stands in for a Connect remote changing the queue's modes.
    func setModes(shuffle: Bool, repeat mode: RepeatMode) {
        snapshot.withLock {
            $0.shuffle = shuffle
            $0.repeat = mode
        }
    }

    var recorded: [String] {
        calls.withLock { $0 }
    }

    private func record(_ call: String) {
        calls.withLock { $0.append(call) }
    }

    func addToQueue(uri: String) throws {
        record("addToQueue \(uri)")
        snapshot.withLock { $0.upNext.append(uri) }
    }

    func clearQueue() {
        record("clearQueue")
        snapshot.withLock { $0.upNext.removeAll() }
    }

    func load(uri: String, startMs: UInt32, autoplay _: Bool) async throws {
        record("load \(uri) \(startMs)")
        if failsLoad { throw LoadFailed() }
    }
    func loadTracks(uris: [String], startIndex: UInt32, contextUri: String?, inContextOrder: Bool, autoplay _: Bool) throws {
        record("loadTracks \(uris.joined(separator: ",")) \(startIndex) \(contextUri ?? "-")\(inContextOrder ? " in order" : "")")
    }
    func moveInQueue(from: UInt32, to: UInt32) throws {
        record("move \(from) \(to)")
        snapshot.withLock { $0.upNext.insert($0.upNext.remove(at: Int(from)), at: Int(to)) }
    }

    func next() { record("next") }
    func pause() { record("pause") }
    func play() { record("play") }
    func playNext(uri: String) throws {
        record("playNext \(uri)")
        snapshot.withLock { $0.upNext.insert(uri, at: 0) }
    }

    func previous() { record("previous") }
    func skip(count: UInt32) { record("skip \(count)") }
    func queue() -> QueueSnapshot { snapshot.withLock { $0 } }
    func removeFromQueue(index: UInt32) throws {
        record("remove \(index)")
        _ = snapshot.withLock { $0.upNext.remove(at: Int(index)) }
    }

    func seek(positionMs: UInt32) { record("seek \(positionMs)") }
    func setAutoplay(on: Bool) { record("autoplay \(on)") }
    func setBitrate(bitrate: Bitrate) async { record("bitrate \(bitrate)") }
    func setLocalFolders(paths: [String]) async { record("local folders \(paths)") }
    func setNormalisation(normalisation: LoudnessPreset?) async { record("normalisation \(normalisation.map { "\($0)" } ?? "off")") }
    func setRepeat(mode: RepeatMode) { record("repeat \(mode)") }
    func setShuffle(on: Bool) { record("shuffle \(on)") }
    func setVolume(volume: UInt16) { record("volume \(volume)") }
    func setRemoteVolume(volume: UInt16) { record("remote volume \(volume)") }
    func stop() { record("stop") }
    func stopLocal() { record("stopLocal") }
}

private let trackURI = "spotify:track:1"
private let episodeURI = "spotify:episode:1"

private let trackItem = MetadataItem.track(track: TrackMetadata(
    uri: trackURI, title: "Song", artists: [ItemRef(uri: "spotify:artist:1", name: "Band")],
    album: ItemRef(uri: "spotify:album:1", name: "Record"), durationMs: 200_000,
    explicit: false, playability: .playable, artwork: []
))

@MainActor
struct PlayerModelTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1000)
    }

    private let defaults = UserDefaults(suiteName: "PlayerModelTests-\(UUID().uuidString)")!

    private func model(
        _ player: FakePlayer = FakePlayer(),
        metadata: any MetadataServiceProtocol = StubMetadata([trackItem]),
        clock: Clock = Clock(),
        settings: PlaybackSettings? = nil
    ) -> PlayerModel {
        PlayerModel(
            player: player, engine: nil, metadata: metadata, settings: settings ?? PlaybackSettings(defaults: defaults),
            clock: { clock.now }, log: { _, _ in }
        )
    }

    @Test func startsWithTheQueuesShuffleAndRepeat() {
        let player = model(FakePlayer(shuffle: true, repeat: .track))
        #expect(player.shuffle)
        #expect(player.repeatMode == .track)
        #expect(player.nowPlaying == nil)
    }

    @Test func trackChangeShowsTheTrackThenItsMetadata() async {
        let player = model()
        player.apply(.trackChanged(uri: trackURI, name: "Song", durationMs: 200_000))
        #expect(player.nowPlaying?.title == "Song")
        #expect(player.nowPlaying?.artists == [])

        await player.resolution?.value
        #expect(player.nowPlaying?.artists == [ItemRef(uri: "spotify:artist:1", name: "Band")])
        #expect(player.nowPlaying?.album?.uri == "spotify:album:1")
    }

    @Test func staleMetadataDoesNotOverwriteANewerTrack() async {
        let metadata = StubMetadata([trackItem])
        metadata.hold(trackURI)
        let player = model(metadata: metadata)
        player.apply(.trackChanged(uri: trackURI, name: "Song", durationMs: 1))
        let first = player.resolution
        player.apply(.trackChanged(uri: "spotify:track:2", name: "Other", durationMs: 1))

        while metadata.waiting == 0 { await Task.yield() }
        metadata.release()
        await first?.value
        #expect(player.nowPlaying?.title == "Other")
        #expect(player.nowPlaying?.artists == [])
    }

    @Test func positionAdvancesOnlyWhilePlayingAndStopsAtTheEnd() {
        let clock = Clock()
        let player = model(clock: clock)
        player.apply(.trackChanged(uri: trackURI, name: "Song", durationMs: 10_000))
        player.apply(.playing(uri: trackURI, positionMs: 1000))

        #expect(player.position(at: clock.now.addingTimeInterval(2.5)) == 3500)
        #expect(player.position(at: clock.now.addingTimeInterval(60)) == 10_000)

        player.apply(.paused(uri: trackURI, positionMs: 4000))
        #expect(player.position(at: clock.now.addingTimeInterval(5)) == 4000)
    }

    @Test func positionAdvancesAtTheEpisodeSpeed() {
        let clock = Clock()
        PlaybackSettings(defaults: defaults).episodeSpeed = 2
        let faster = model(clock: clock)
        faster.apply(.trackChanged(uri: episodeURI, name: "Ep", durationMs: 100_000))
        faster.apply(.playing(uri: episodeURI, positionMs: 0))
        #expect(faster.position(at: clock.now.addingTimeInterval(1)) == 2000)
    }

    @Test func seekMovesThePositionAtOnce() {
        let fake = FakePlayer()
        let player = model(fake)
        player.apply(.trackChanged(uri: trackURI, name: "Song", durationMs: 10_000))
        player.seek(to: 5000)
        #expect(fake.recorded == ["seek 5000"])
        #expect(player.position(at: .distantFuture) == 5000)
    }

    @Test func togglePlayPauseFollowsTheReportedState() {
        let fake = FakePlayer()
        let player = model(fake)
        player.togglePlayPause()
        player.apply(.playing(uri: trackURI, positionMs: 0))
        player.togglePlayPause()
        #expect(fake.recorded == ["play", "pause"])
    }

    @Test func repeatCyclesOffContextTrack() {
        let fake = FakePlayer()
        let player = model(fake)
        player.cycleRepeat()
        #expect(player.repeatMode == .context)
        player.cycleRepeat()
        #expect(player.repeatMode == .track)
        player.cycleRepeat()
        #expect(player.repeatMode == .off)
        #expect(fake.recorded == ["repeat context", "repeat track", "repeat off"])
    }

    @Test func volumeIsPersistedAndSentToThePlayer() {
        let fake = FakePlayer()
        let player = model(fake)
        player.volume = 0
        #expect(fake.recorded == ["volume 0"])
        #expect(PlaybackSettings(defaults: defaults).volume == 0)
    }

    @Test func settingsChangesReachTheLivePlayerOnce() async {
        let fake = FakePlayer()
        let settings = PlaybackSettings(defaults: defaults)
        let player = model(fake, settings: settings)

        settings.bitrate = .kbps96
        settings.normalises = false
        settings.volume = 0
        while fake.recorded.count < 3 {
            await Task.yield()
        }
        await player.settingsApply?.value
        #expect(fake.recorded == ["volume 0", "bitrate kbps96", "normalisation off"])

        settings.loudness = .loud
        settings.normalises = true
        while fake.recorded.count < 4 {
            await Task.yield()
        }
        await player.settingsApply?.value
        #expect(fake.recorded.last == "normalisation loud")
        #expect(fake.recorded.count == 4)
    }

    /// PBI-501: a phone's volume change moves the slider and is not sent back.
    @Test func remoteVolumeIsPersistedWithoutEchoingBack() async {
        let fake = FakePlayer()
        let settings = PlaybackSettings(defaults: defaults)
        let player = model(fake, settings: settings)

        player.apply(.volumeChanged(volume: 0))
        for _ in 0 ..< 20 {
            await Task.yield()
        }

        #expect(player.volume == 0)
        #expect(PlaybackSettings(defaults: defaults).volume == 0)
        #expect(fake.recorded.isEmpty)
    }

    /// PBI-501: a phone's queue and mode changes show without a local action.
    @Test func remoteQueueChangeRefreshesUpNextAndModes() {
        let fake = FakePlayer()
        let player = model(fake)
        fake.setUpNext(["spotify:track:4uLU6hMCjMI75M1A2tKUQA"])
        fake.setModes(shuffle: true, repeat: .context)

        player.apply(.queueChanged)

        #expect(player.upNext == ["spotify:track:4uLU6hMCjMI75M1A2tKUQA"])
        #expect(player.shuffle)
        #expect(player.repeatMode == .context)
    }

    /// PBI-501: Connect starts with the saved name and restarts when it changes.
    @Test func connectStartsWithTheSettingsAndRestartsOnChange() async {
        let settings = PlaybackSettings(defaults: defaults, macName: "Studio Mac")
        let devices = ConnectStarts()
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([trackItem]), settings: settings,
            startConnect: devices.start, clock: Date.init, log: { _, _ in }
        )
        await player.connectStart?.value
        #expect(devices.started == ["Studio Mac off"])

        settings.connectDeviceName = "Den"
        while devices.started.count < 2 {
            await Task.yield()
        }
        await player.connectStart?.value

        #expect(devices.started == ["Studio Mac off", "Den off"])
        #expect(devices.made.map(\.shutdowns) == [1, 0])
        #expect(devices.order == ["start", "shutdown", "start"], "the old device finished unregistering first")
    }

    /// PBI-501: only the first Connect device restores the last playback, with the Web API token.
    @Test func firstConnectDeviceRestoresTheLastPlaybackOnce() async {
        let settings = PlaybackSettings(defaults: defaults, macName: "Studio Mac")
        let devices = ConnectStarts()
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([trackItem]), settings: settings,
            startConnect: devices.start, restoreToken: { "web-token" }, clock: Date.init, log: { _, _ in }
        )
        await player.connectStart?.value
        settings.connectDeviceName = "Den"
        while devices.started.count < 2 {
            await Task.yield()
        }
        await player.connectStart?.value
        while devices.made[0].restores.isEmpty {
            await Task.yield()
        }

        #expect(devices.made.map(\.restores) == [["web-token"], []])
    }

    /// PBI-501: this Mac's playback is saved on track change, pause, every 5 s of play and quit.
    @Test func localPlaybackIsSavedForTheNextLaunch() {
        let clock = Clock()
        let settings = PlaybackSettings(defaults: defaults)
        let player = model(clock: clock, settings: settings)
        let at = { (ms: UInt32) in
            SavedPlayback(
                trackUri: trackURI, contextUri: nil, positionMs: ms,
                savedAtMs: Int64(clock.now.timeIntervalSince1970 * 1000)
            )
        }
        player.apply(.loading(uri: trackURI, positionMs: 0))
        player.apply(.trackChanged(uri: trackURI, name: "Song", durationMs: 200_000))
        #expect(settings.lastPlayback == at(0))

        player.apply(.playing(uri: trackURI, positionMs: 0))
        clock.now += 3
        player.apply(.position(uri: trackURI, positionMs: 3000))
        #expect(settings.lastPlayback?.positionMs == 0, "throttled")
        clock.now += 3
        player.apply(.position(uri: trackURI, positionMs: 6000))
        #expect(settings.lastPlayback == at(6000))

        clock.now += 1
        player.apply(.paused(uri: trackURI, positionMs: 7000))
        #expect(settings.lastPlayback == at(7000))
        #expect(PlaybackSettings(defaults: defaults).lastPlayback == at(7000), "persisted")

        player.apply(.remoteChanged(deviceName: "Phone", volume: nil))
        clock.now += 1
        player.apply(.paused(uri: trackURI, positionMs: 9000))
        #expect(settings.lastPlayback?.positionMs == 7000, "Remote mode plays elsewhere")

        player.apply(.remoteChanged(deviceName: nil, volume: nil))
        player.teardown()
        #expect(settings.lastPlayback == at(9000), "saved on quit")
    }

    /// PBI-501: the restore gets the saved playback.
    @Test func restoreGetsTheSavedPlayback() async {
        let settings = PlaybackSettings(defaults: defaults)
        let saved = SavedPlayback(trackUri: trackURI, contextUri: "spotify:album:1", positionMs: 5, savedAtMs: 9)
        settings.lastPlayback = saved
        let devices = ConnectStarts()
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([trackItem]), settings: settings,
            startConnect: devices.start, restoreToken: { "web-token" }, clock: Date.init, log: { _, _ in }
        )
        await player.connectStart?.value
        while devices.made[0].restores.isEmpty {
            await Task.yield()
        }

        #expect(devices.made[0].restoredFrom == [saved])
    }

    /// PBI-501: without a Web API token the restore is skipped and logged.
    @Test func restoreWithoutATokenIsSkipped() async {
        struct NoToken: Error {}
        let devices = ConnectStarts()
        var logged: [String] = []
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([trackItem]),
            settings: PlaybackSettings(defaults: defaults), startConnect: devices.start,
            restoreToken: { throw NoToken() }, clock: Date.init, log: { logged.append($1) }
        )
        await player.connectStart?.value
        while logged.isEmpty {
            await Task.yield()
        }

        #expect(logged == ["Skipped restoring the last playback: NoToken"])
        #expect(devices.made.map(\.restores) == [[]])
    }

    /// PBI-501: Spirc's player takes bitrate and loudness at start, so a change restarts Connect.
    @Test func tuningChangeRestartsConnectAfterThePlayerIsRetuned() async {
        let settings = PlaybackSettings(defaults: defaults, macName: "Studio Mac")
        let fake = FakePlayer()
        let devices = ConnectStarts()
        let player = PlayerModel(
            player: fake, engine: nil, metadata: StubMetadata([trackItem]), settings: settings,
            startConnect: devices.start, clock: Date.init, log: { _, _ in }
        )
        await player.connectStart?.value

        settings.bitrate = .kbps96
        while devices.started.count < 2 {
            await Task.yield()
        }
        await player.connectStart?.value

        #expect(fake.recorded == ["bitrate kbps96"])
        #expect(devices.made.map(\.shutdowns) == [1, 0])
    }

    @Test func savedAutoplayOffReachesANewPlayer() {
        let settings = PlaybackSettings(defaults: defaults)
        settings.autoplay = false
        let fake = FakePlayer()

        let player = model(fake, settings: settings)

        withExtendedLifetime(player) {
            #expect(fake.recorded == ["autoplay false"])
        }
    }

    @Test func autoplaySwitchReachesTheLivePlayerOnce() async {
        let fake = FakePlayer()
        let settings = PlaybackSettings(defaults: defaults)
        let player = model(fake, settings: settings)

        settings.autoplay = false
        while fake.recorded.isEmpty {
            await Task.yield()
        }
        settings.autoplay = false
        await Task.yield()

        withExtendedLifetime(player) {
            #expect(fake.recorded == ["autoplay false"])
        }
    }

    @Test func unchangedSettingsSendNothing() async {
        let fake = FakePlayer()
        let settings = PlaybackSettings(defaults: defaults)
        let player = model(fake, settings: settings)
        settings.bitrate = settings.bitrate
        settings.audioCacheLimitBytes = 1
        await Task.yield()
        await Task.yield()
        #expect(player.settingsApply == nil)
        #expect(fake.recorded == [])
    }

    /// PBI-703: saved folders reach the new player before Connect starts, so Spirc's player has them.
    @Test func savedLocalFoldersReachANewPlayerBeforeConnectStarts() async {
        let settings = PlaybackSettings(defaults: defaults, macName: "Studio Mac")
        let folder = URL.temporaryDirectory
        settings.addLocalFolders([folder])
        let fake = FakePlayer()
        let devices = ConnectStarts()

        let player = PlayerModel(
            player: fake, engine: nil, metadata: StubMetadata([trackItem]), settings: settings,
            startConnect: devices.start, clock: Date.init, log: { _, _ in }
        )
        await player.settingsApply?.value
        await player.connectStart?.value

        #expect(fake.recorded == ["local folders \(settings.localFolderPaths)"])
        #expect(devices.started == ["Studio Mac off"])
    }

    @Test func localFolderChangeRetunesThePlayerOnce() async {
        let fake = FakePlayer()
        let settings = PlaybackSettings(defaults: defaults)
        let player = model(fake, settings: settings)

        settings.addLocalFolders([URL.temporaryDirectory])
        while fake.recorded.isEmpty {
            await Task.yield()
        }
        await player.settingsApply?.value
        let paths = settings.localFolderPaths
        settings.removeLocalFolder(URL.temporaryDirectory)
        while fake.recorded.count < 2 {
            await Task.yield()
        }
        await player.settingsApply?.value

        #expect(fake.recorded == ["local folders \(paths)", "local folders []"])
    }

    /// PBI-703: librespot skips a local file it can't play; the user learns why.
    @Test func unplayableLocalFileShowsItsTitle() async {
        let local = "spotify:local:Band:Record:Hi-Res+Song:200"
        let item = MetadataItem.track(track: TrackMetadata(
            uri: local, title: "Hi-Res Song", artists: [ItemRef(uri: "", name: "Band")],
            album: ItemRef(uri: "", name: "Record"), durationMs: 200_000, explicit: false, playability: .playable, artwork: []
        ))
        let player = model(metadata: StubMetadata([trackItem, item]))

        player.apply(.unavailable(uri: trackURI))
        #expect(player.unplayableResolution == nil)
        player.apply(.unavailable(uri: local))
        await player.unplayableResolution?.value

        #expect(player.unplayableLocalFile == "Hi-Res Song")
    }

    @Test func stopClearsWhatIsPlaying() {
        let player = model()
        player.apply(.trackChanged(uri: trackURI, name: "Song", durationMs: 10_000))
        player.apply(.playing(uri: trackURI, positionMs: 0))
        player.apply(.stopped)
        #expect(player.nowPlaying == nil)
        #expect(!player.isPlaying)
    }

    @Test func playLoadsTheListFromTheChosenTrack() {
        let fake = FakePlayer()
        let player = model(fake)
        player.play(["a", "b", "c"], from: 1, context: "spotify:playlist:1")
        player.play(["c", "a"], from: 1, context: "spotify:playlist:1", inContextOrder: true)
        player.play(["a"], from: 0)
        player.play(["a"], from: 3)
        #expect(fake.recorded == [
            "loadTracks a,b,c 1 spotify:playlist:1", "loadTracks c,a 1 spotify:playlist:1 in order", "loadTracks a 0 -",
        ])
    }

    @Test func playOneItemLoadsItFromTheStartPositionAsTheContext() async {
        let fake = FakePlayer()
        let player = model(fake)
        await player.play(episodeURI, startingAt: 90000).value
        #expect(fake.recorded == ["load \(episodeURI) 90000"])
        #expect(player.context == episodeURI)
    }

    @Test func playOneItemThatFailsToLoadKeepsTheContext() async {
        let player = model(FakePlayer(failsLoad: true))
        player.play(["a"], from: 0, context: "spotify:playlist:1")
        await player.play(episodeURI, startingAt: 0).value
        #expect(player.context == "spotify:playlist:1")
    }

    @Test func playNextKeepsTheSelectionOrderAtTheFrontOfUpNext() {
        let fake = FakePlayer()
        let player = model(fake)
        player.playNext(["a", "b"])
        player.addToQueue(["c", "d"])
        #expect(fake.recorded == ["playNext b", "playNext a", "addToQueue c", "addToQueue d"])
    }

    @Test func queueMutationsShowTheNewUpNext() {
        let player = model(FakePlayer(nextFromContext: ["x"]))
        #expect(player.nextFromContext == ["x"])
        player.addToQueue(["a", "b"])
        player.playNext(["c"])
        #expect(player.upNext == ["c", "a", "b"])
        player.clearUpNext()
        #expect(player.upNext == [])
    }

    @Test(arguments: [
        ([0], 3, ["b", "c", "a", "d"]),
        ([3], 0, ["d", "a", "b", "c"]),
        ([1, 3], 0, ["b", "d", "a", "c"]),
        ([0, 1], 4, ["c", "d", "a", "b"]),
        ([2], 2, ["a", "b", "c", "d"]),
    ])
    func movesMatchListOnMove(source: [Int], destination: Int, expected: [String]) {
        let player = model(FakePlayer(upNext: ["a", "b", "c", "d"]))
        player.moveInUpNext(fromOffsets: IndexSet(source), toOffset: destination)
        #expect(player.upNext == expected)
    }

    @Test func movesKeepRepeatedTracksApart() {
        let player = model(FakePlayer(upNext: ["a", "b", "a"]))
        player.moveInUpNext(fromOffsets: [2], toOffset: 0)
        #expect(player.upNext == ["a", "a", "b"])
    }

    @Test func removesTheShownRows() {
        let player = model(FakePlayer(upNext: ["a", "b", "c", "d"]))
        player.removeFromUpNext(at: [1, 3])
        #expect(player.upNext == ["a", "c"])
    }

    @Test func skipToARowSkipsPastTheRowsBeforeIt() {
        let fake = FakePlayer(upNext: ["a", "b"])
        let player = model(fake)
        player.skip(to: 1)
        player.skip(to: 5)
        #expect(fake.recorded.filter { $0.hasPrefix("skip") } == ["skip 2"])
    }

    @Test func staleQueuePositionsChangeNothing() {
        let fake = FakePlayer(upNext: ["a", "b", "c"])
        let player = model(fake)
        fake.setUpNext(["b", "c"])
        player.removeFromUpNext(at: [0])
        #expect(player.upNext == ["b", "c"])
        fake.setUpNext(["c"])
        player.moveInUpNext(fromOffsets: [0], toOffset: 2)
        #expect(player.upNext == ["c"])
        #expect(!fake.recorded.contains { $0.hasPrefix("remove") || $0.hasPrefix("move") })
    }

    @Test func playRemembersItsContextAndTrackChangesRefreshTheQueue() {
        let fake = FakePlayer()
        let player = model(fake)
        player.play(["a", "b"], from: 0, context: "spotify:album:1")
        #expect(player.context == "spotify:album:1")
        fake.setUpNext(["z"])
        player.apply(.trackChanged(uri: trackURI, name: "Song", durationMs: 1000))
        #expect(player.upNext == ["z"])
    }
}

final class FakeConnect: SpotConnectProtocol, Sendable {
    private let calls = OSAllocatedUnfairLock<
        (shutdowns: Int, transfers: [String], restores: [String], restoredFrom: [SavedPlayback?])
    >(initialState: (0, [], [], []))
    private let log: ConnectStarts
    private let failsTransfer: Bool

    init(log: ConnectStarts, failsTransfer: Bool = false) {
        self.log = log
        self.failsTransfer = failsTransfer
    }

    var shutdowns: Int { calls.withLock { $0.shutdowns } }
    var transfers: [String] { calls.withLock { $0.transfers } }
    var restores: [String] { calls.withLock { $0.restores } }
    var restoredFrom: [SavedPlayback?] { calls.withLock { $0.restoredFrom } }

    func restoreLastPlayback(accessToken: String, saved: SavedPlayback?) async {
        calls.withLock {
            $0.restores.append(accessToken)
            $0.restoredFrom.append(saved)
        }
    }

    func shutdown() async {
        await Task.yield()
        calls.withLock { $0.shutdowns += 1 }
        await log.note("shutdown")
    }

    func transfer(deviceId: String) async throws {
        calls.withLock { $0.transfers.append(deviceId) }
        await Task.yield()
        if failsTransfer {
            throw ConnectError.Transfer(message: "down")
        }
    }
}

@MainActor
final class ConnectStarts {
    private(set) var started: [String] = []
    private(set) var made: [FakeConnect] = []
    /// Starts and shutdowns in the order they completed.
    private(set) var order: [String] = []

    func note(_ step: String) {
        order.append(step)
    }

    var failTransfers = false

    func start(name: String, zeroconf: Bool) async throws -> any SpotConnectProtocol {
        started.append("\(name) \(zeroconf ? "on" : "off")")
        order.append("start")
        let device = FakeConnect(log: self, failsTransfer: failTransfers)
        made.append(device)
        return device
    }
}
