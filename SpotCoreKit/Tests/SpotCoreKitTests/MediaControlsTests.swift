import CoreGraphics
import Foundation
import ImageIO
import MediaPlayer
@testable import SpotCoreKit
import Testing

@MainActor
struct MediaControlsTests {
    private final class Published {
        var all: [MediaControls.Info?] = []
        var last: MediaControls.Info? {
            all.last ?? nil
        }
    }

    private let fake = FakePlayer()
    private let published = Published()
    private let player: PlayerModel
    private let library = LibraryModel(library: FakeLibrary(), metadata: FakeMetadata())
    private let controls: MediaControls

    init() {
        let defaults = UserDefaults(suiteName: "MediaControlsTests-\(UUID().uuidString)")!
        player = PlayerModel(
            player: fake, engine: nil, metadata: FakeMetadata(), settings: PlaybackSettings(defaults: defaults)
        )
        let published = published
        controls = MediaControls(artworkLoader: nil, commands: nil) { info, _ in published.all.append(info) }
        controls.bind(player: player, library: library)
    }

    @Test func publishesTheTrackAndClearsWhenPlaybackStops() async throws {
        player.apply(.trackChanged(uri: "spotify:track:1", name: "Song", durationMs: 200_000))
        player.apply(.playing(uri: "spotify:track:1", positionMs: 30000))
        try await waitUntil { published.last?.isPlaying == true }
        let info = try #require(published.last)
        #expect(info.title == "Song")
        #expect(info.durationMs == 200_000)
        #expect(info.elapsedMs >= 30000)
        #expect(info.rate == 1)

        player.apply(.stopped)
        try await waitUntil { published.all.last.map { $0 == nil } ?? false }
    }

    @Test func pausedHoldsTheClockStill() async throws {
        player.apply(.trackChanged(uri: "spotify:track:1", name: "Song", durationMs: 200_000))
        player.apply(.paused(uri: "spotify:track:1", positionMs: 5000))
        try await waitUntil { published.last?.elapsedMs == 5000 }
        #expect(published.last?.rate == 0)
        #expect(published.last?.isPlaying == false)
    }

    @Test func commandsDriveThePlayer() {
        controls.perform(.pause)
        controls.perform(.play)
        player.apply(.playing(uri: "spotify:track:1", positionMs: 0))
        controls.perform(.play)
        controls.perform(.togglePlayPause)
        controls.perform(.next)
        controls.perform(.previous)
        controls.perform(.seek(positionMs: 42000))
        #expect(fake.recorded == ["play", "pause", "next", "previous", "seek 42000"])
    }

    @Test func likeTogglesTheCurrentTrackInLikedSongs() async throws {
        #expect(!controls.perform(.like))
        player.apply(.trackChanged(uri: "spotify:track:1", name: "Song", durationMs: 1))
        #expect(controls.perform(.like))
        #expect(library.isSaved("spotify:track:1"))
        try await waitUntil { published.last?.saved == true }
        controls.perform(.like)
        #expect(!library.isSaved("spotify:track:1"))
    }

    @Test func publishesTheCoverOnceTheTracksMetadataBringsIt() async throws {
        let cover = Artwork(url: "https://i.scdn.co/image/cover", size: .default, width: 300, height: 300)
        let track = MetadataItem.track(track: TrackMetadata(
            uri: "spotify:track:1", title: "Song", artists: [], album: ItemRef(uri: "spotify:album:1", name: "Record"), durationMs: 1,
            explicit: false, playability: .playable, artwork: [cover]
        ))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let loader = ArtworkLoader(directory: directory) { _ in try png(side: 300) }
        let defaults = try #require(UserDefaults(suiteName: "MediaControlsTests-\(UUID().uuidString)"))
        let player = PlayerModel(
            player: FakePlayer(), engine: nil, metadata: StubMetadata([track]), settings: PlaybackSettings(defaults: defaults)
        )
        final class Images { var last: CGImage? }
        let images = Images()
        let controls = MediaControls(artworkLoader: loader, commands: nil) { _, image in images.last = image }
        controls.bind(player: player, library: library)

        player.apply(.trackChanged(uri: "spotify:track:1", name: "Song", durationMs: 1))
        #expect(player.nowPlaying?.artwork.isEmpty == true)

        try await waitUntil { images.last != nil }
    }

    @Test func theSystemCanFetchTheCoverOffTheMainThread() async throws {
        let source = try #require(try CGImageSourceCreateWithData(png(side: 64) as CFData, nil))
        let artwork = try MediaControls.artwork(#require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
        let width = await Task.detached { artwork.image(at: CGSize(width: 64, height: 64))?.size.width }.value
        #expect(width == 64)
    }

    @Test func aRemoteCommandFromABackgroundThreadReachesThePlayer() async throws {
        let handler = MediaControls.handler({ (_: Int) in .next }) { [controls] in controls.perform($0) }
        let status = await Task.detached { handler(0) }.value
        #expect(status == .success)
        try await waitUntil { fake.recorded == ["next"] }
    }

    @Test func aRemoteCommandWithNothingLoadedIsNotClaimed() async {
        let handler = MediaControls.handler({ (_: Int) in .next }, isAvailable: { false }) { [controls] in controls.perform($0) }
        let status = await Task.detached { handler(0) }.value
        #expect(status == .noActionableNowPlayingItem)
        #expect(fake.recorded.isEmpty)
    }

    @Test func unbindingClearsControlCenterAndIgnoresCommands() async throws {
        player.apply(.trackChanged(uri: "spotify:track:1", name: "Song", durationMs: 1))
        try await waitUntil { published.last != nil }
        controls.bind(player: nil, library: nil)
        #expect(published.all.last.map { $0 == nil } ?? false)
        #expect(!controls.perform(.next))
        #expect(fake.recorded.isEmpty)
    }
}
