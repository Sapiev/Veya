import Foundation
import os
@testable import SpotCoreKit
import Testing

final class FakePlayer: SpotPlayerProtocol {
    private let calls = OSAllocatedUnfairLock<[String]>(initialState: [])
    /// Up Next behaves like the core queue so position mapping can be checked by outcome.
    private let snapshot: OSAllocatedUnfairLock<QueueSnapshot>

    init(shuffle: Bool = false, repeat mode: RepeatMode = .off, upNext: [String] = [], nextFromContext: [String] = []) {
        snapshot = OSAllocatedUnfairLock(initialState: QueueSnapshot(
            current: nil, upNext: upNext, nextFromContext: nextFromContext, shuffle: shuffle, repeat: mode, autoplay: true
        ))
    }

    /// Stands in for the player advancing on its own, e.g. a track ending.
    func setUpNext(_ uris: [String]) {
        snapshot.withLock { $0.upNext = uris }
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

    func load(uri: String, startMs _: UInt32, autoplay _: Bool) async throws { record("load \(uri)") }
    func loadTracks(uris: [String], startIndex: UInt32, contextUri: String?, autoplay _: Bool) throws {
        record("loadTracks \(uris.joined(separator: ",")) \(startIndex) \(contextUri ?? "-")")
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
    func queue() -> QueueSnapshot { snapshot.withLock { $0 } }
    func removeFromQueue(index: UInt32) throws {
        record("remove \(index)")
        _ = snapshot.withLock { $0.upNext.remove(at: Int(index)) }
    }

    func seek(positionMs: UInt32) { record("seek \(positionMs)") }
    func setAutoplay(on: Bool) { record("autoplay \(on)") }
    func setBitrate(bitrate: Bitrate) async { record("bitrate \(bitrate)") }
    func setNormalisation(normalisation: LoudnessPreset?) async { record("normalisation \(normalisation.map { "\($0)" } ?? "off")") }
    func setRepeat(mode: RepeatMode) { record("repeat \(mode)") }
    func setShuffle(on: Bool) { record("shuffle \(on)") }
    func setVolume(volume: UInt16) { record("volume \(volume)") }
    func stop() { record("stop") }
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
        player.play(["a"], from: 0)
        player.play(["a"], from: 3)
        #expect(fake.recorded == ["loadTracks a,b,c 1 spotify:playlist:1", "loadTracks a 0 -"])
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
