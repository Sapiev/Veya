import Foundation
@testable import SpotCoreKit
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ShortcutActionsTests {
    private final class Slot<Value> {
        var value: Value?
    }

    private let fake = FakePlayer()
    private let player: PlayerModel
    private let library = LibraryModel(library: FakeLibrary(), metadata: FakeMetadata())
    private let service = PushedPlaylists()
    private let playlists: PlaylistModel

    init() {
        let defaults = UserDefaults(suiteName: "ShortcutActionsTests-\(UUID().uuidString)")!
        player = PlayerModel(
            player: fake, engine: nil, metadata: FakeMetadata(), settings: PlaybackSettings(defaults: defaults)
        )
        playlists = PlaylistModel(playlists: service)
    }

    private func actions(timeout: Duration = .seconds(5)) -> ShortcutActions {
        ShortcutActions(player: { player }, library: { library }, playlists: { playlists }, timeout: timeout)
    }

    @Test func commandsDriveThePlayer() async throws {
        let actions = actions()
        try await actions.perform(.togglePlayPause)
        try await actions.perform(.next)
        try await actions.perform(.previous)
        #expect(fake.recorded == ["play", "next", "previous"])
    }

    @Test func waitsForAPlayerThatStartsLate() async throws {
        let slot = Slot<PlayerModel>()
        let actions = ShortcutActions(player: { slot.value }, library: { library }, playlists: { playlists })
        Task { [player] in
            try await Task.sleep(for: .milliseconds(200))
            slot.value = player
        }
        try await actions.perform(.next)
        #expect(fake.recorded == ["next"])
    }

    @Test func failsWhenNoPlayerStartsInTime() async {
        let actions = ShortcutActions(
            player: { nil }, library: { library }, playlists: { playlists }, timeout: .milliseconds(150)
        )
        await #expect(throws: ShortcutActions.Failure.notReady) { try await actions.perform(.next) }
    }

    @Test func likeSavesTheCurrentTrackAndKeepsItSaved() async throws {
        let actions = actions()
        await #expect(throws: ShortcutActions.Failure.nothingPlaying) { try await actions.likeCurrentTrack() }

        player.apply(.trackChanged(uri: "spotify:track:1", name: "Song", durationMs: 1))
        try await actions.likeCurrentTrack()
        #expect(library.isSaved("spotify:track:1"))
        try await actions.likeCurrentTrack()
        #expect(library.isSaved("spotify:track:1"))
    }

    @Test func currentTrackReportsWhatIsPlaying() async throws {
        let actions = actions()
        await #expect(throws: ShortcutActions.Failure.nothingPlaying) { try await actions.currentTrack() }

        player.apply(.trackChanged(uri: "spotify:track:1", name: "Song", durationMs: 1))
        #expect(try await actions.currentTrack().title == "Song")
    }

    @Test func listsAndFindsPlaylistsWithoutFolders() async throws {
        service.setRootlist([
            .folder(uri: "spotify:folder:1", name: "Focus", parent: nil),
            .playlist(uri: "spotify:playlist:1", name: "Deep Focus", owner: "me", trackCount: 1, parent: "spotify:folder:1", editable: true, public: false),
            .playlist(uri: "spotify:playlist:2", name: "Running", owner: "me", trackCount: 1, parent: nil, editable: true, public: false),
        ])
        let actions = actions()

        #expect(try await actions.playlists().map(\.id) == ["spotify:playlist:1", "spotify:playlist:2"])
        #expect(try await actions.playlists(matching: "focus").map(\.name) == ["Deep Focus"])
    }

    @Test func playsAPlaylistAsItsContext() async throws {
        try await actions().play("spotify:playlist:1")
        #expect(fake.recorded == ["load spotify:playlist:1 0"])
    }

    @Test func reportsAnItemTheCoreCannotLoad() async throws {
        let failing = try PlayerModel(
            player: FakePlayer(failsLoad: true), engine: nil, metadata: FakeMetadata(),
            settings: PlaybackSettings(defaults: #require(UserDefaults(suiteName: "ShortcutActionsTests-\(UUID().uuidString)")))
        )
        let actions = ShortcutActions(player: { failing }, library: { library }, playlists: { playlists })
        await #expect(throws: ShortcutActions.Failure.notPlayable) { try await actions.play("spotify:track:1") }
    }

    @Test func rejectsTextThatIsNotASpotifyURI() async {
        let actions = actions()
        for uri in ["", "spotify:", "https://open.spotify.com/track/1", "track:1", "spotify:foo:bar", "spotify:track:a/b", "spotify:track:"] {
            await #expect(throws: ShortcutActions.Failure.invalidURI) { try await actions.play(uri) }
        }
        #expect(fake.recorded.isEmpty)
    }

    @Test func nowPlayingAnswersWithoutWaiting() {
        #expect(ShortcutActions(player: { nil }, library: { nil }, playlists: { nil }).nowPlaying == nil)

        let actions = actions()
        #expect(actions.nowPlaying == nil)
        player.apply(.trackChanged(uri: "spotify:track:1", name: "Song", durationMs: 1))
        #expect(actions.nowPlaying?.uri == "spotify:track:1")
        #expect(actions.nowPlaying?.info.title == "Song")
    }
}
