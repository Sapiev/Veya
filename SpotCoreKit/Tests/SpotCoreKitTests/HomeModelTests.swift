import Foundation
import os
@testable import SpotCoreKit
import Testing

final class StubRecentlyPlayed: RecentlyPlayedProvider {
    private let result: Result<RecentlyPlayed, HomeError>

    init(_ result: Result<RecentlyPlayed, HomeError>) {
        self.result = result
    }

    func recentlyPlayed() async throws -> RecentlyPlayed {
        try result.get()
    }
}

/// A call from a cancelled (superseded) load waits for `release` and then
/// answers `stale`; any other call answers `fresh` at once.
final class SupersededRecentlyPlayed: RecentlyPlayedProvider {
    private let stale: RecentlyPlayed
    private let fresh: RecentlyPlayed
    private let gate = OSAllocatedUnfairLock<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>(
        initialState: (false, [])
    )

    init(stale: RecentlyPlayed, fresh: RecentlyPlayed) {
        self.stale = stale
        self.fresh = fresh
    }

    func release() {
        gate.withLock { gate in
            gate.open = true
            defer { gate.waiters = [] }
            return gate.waiters
        }.forEach { $0.resume() }
    }

    func recentlyPlayed() async throws -> RecentlyPlayed {
        guard Task.isCancelled else { return fresh }
        await withCheckedContinuation { continuation in
            let open = gate.withLock { gate in
                if !gate.open { gate.waiters.append(continuation) }
                return gate.open
            }
            if open { continuation.resume() }
        }
        return stale
    }
}

final class FailingMetadata: MetadataServiceProtocol {
    func items(uris _: [String]) async throws -> [MetadataItem] {
        throw MetadataError.Request(message: "down")
    }
}

/// Root list and playlist headers from fixed data; unknown playlists fail.
final class StubPlaylists: PlaylistServiceProtocol {
    private let rootlist: Result<[RootlistEntry], PlaylistError>
    private let pages: [String: PlaylistPage]

    init(rootlist: Result<[RootlistEntry], PlaylistError>, pages: [PlaylistPage]) {
        self.rootlist = rootlist
        self.pages = Dictionary(uniqueKeysWithValues: pages.map { ($0.uri, $0) })
    }

    func rootlist() async throws -> [RootlistEntry] {
        try rootlist.get()
    }

    func page(uri: String, from _: UInt32, length _: UInt32) async throws -> PlaylistPage {
        guard let page = pages[uri] else { throw PlaylistError.Request(message: "missing") }
        return page
    }

    func followerCount(uri _: String) async throws -> UInt64 { 0 }
    func waitForChange() async -> PlaylistChange { .rootlist }
}

private let track1 = "spotify:track:4uLU6hMCjMI75M1A2tKUQC"
private let track2 = "spotify:track:512ojhOuo1ktJprKbVcKyQ"
private let goneTrack = "spotify:track:0000000000000000000000"
private let album = "spotify:album:4rOoJ6Egrf8K2IrywzwOMk"
private let mix = "spotify:playlist:37i9dQZF1E35AAAAAAAAAA"
private let weekly = "spotify:playlist:37i9dQZEVXcAAAAAAAAAAA"
private let mine = "spotify:playlist:1111111111111111111111"
private let deleted = "spotify:playlist:2222222222222222222222"

private func track(_ uri: String) -> MetadataItem {
    .track(track: TrackMetadata(
        uri: uri, title: uri, artists: [], album: ItemRef(uri: album, name: "A"), durationMs: 1000,
        explicit: false, playability: .playable, artwork: []
    ))
}

private let albumItem = MetadataItem.album(album: AlbumMetadata(
    uri: album, title: "A", artists: [], tracks: [], playability: .playable, artwork: []
))

private func page(_ uri: String, owner: String = "spotify") -> PlaylistPage {
    PlaylistPage(
        uri: uri, revision: "r", name: uri, description: "", owner: owner, collaborative: false,
        artwork: [], total: 30, offset: 0, tracks: []
    )
}

private func entry(_ uri: String, owner: String) -> RootlistEntry {
    .playlist(uri: uri, name: uri, owner: owner, trackCount: 30, parent: nil)
}

private let rootlist: [RootlistEntry] = [
    .folder(uri: "spotify:start-group:f", name: "F", parent: nil),
    entry(weekly, owner: "spotify"),
    entry(mine, owner: "me"),
    entry(deleted, owner: "spotify"),
    entry(mix, owner: "spotify"),
]

private let history = RecentlyPlayed(tracks: [track1, goneTrack, track2], contexts: [mix, album, deleted])

@MainActor
private func model(
    recent: Result<RecentlyPlayed, HomeError> = .success(history),
    rootlist list: Result<[RootlistEntry], PlaylistError> = .success(rootlist),
    log: @escaping HomeLog = { _, _ in }
) -> HomeModel {
    HomeModel(
        metadata: StubMetadata([track(track1), track(track2), albumItem]),
        playlists: StubPlaylists(rootlist: list, pages: [page(mix), page(weekly), page(mine, owner: "me")]),
        recentlyPlayed: StubRecentlyPlayed(recent),
        log: log
    )
}

@MainActor
struct HomeModelTests {
    @Test func loadsEverySectionInServerOrderDroppingUnresolvable() async {
        let home = model()

        await home.load().value

        #expect(home.state == .loaded)
        #expect(home.recentlyPlayed == [track(track1), track(track2)])
        #expect(home.jumpBackIn == [.playlist(page(mix)), .item(albumItem)])
        #expect(home.madeForYou == [page(weekly), page(mix)])
    }

    @Test func recentlyPlayedFailureHidesOnlyItsSections() async {
        var logged: [String] = []
        let home = model(recent: .failure(.MissingScope)) { logged.append($1) }

        await home.load().value

        #expect(home.state == .loaded)
        #expect(home.recentlyPlayed.isEmpty)
        #expect(home.jumpBackIn.isEmpty)
        #expect(home.madeForYou == [page(weekly), page(mix)])
        #expect(logged == ["Couldn't load recently played: MissingScope"])
    }

    @Test func rootlistFailureHidesOnlyMadeForYou() async {
        let home = model(rootlist: .failure(.Request(message: "x")))

        await home.load().value

        #expect(home.state == .loaded)
        #expect(home.madeForYou.isEmpty)
        #expect(home.recentlyPlayed.count == 2)
    }

    @Test func everySectionFailingFails() async {
        let home = model(recent: .failure(.Network(message: "x")), rootlist: .failure(.Request(message: "x")))

        await home.load().value

        #expect(home.state == .failed)
    }

    @Test func olderLoadFinishingLastDoesNotOverwriteNewer() async {
        let recent = SupersededRecentlyPlayed(
            stale: history, fresh: RecentlyPlayed(tracks: [track2], contexts: [])
        )
        let home = HomeModel(
            metadata: StubMetadata([track(track1), track(track2), albumItem]),
            playlists: StubPlaylists(rootlist: .success(rootlist), pages: [page(mix), page(weekly)]),
            recentlyPlayed: recent,
            log: { _, _ in }
        )

        // Back to back, so neither load has started when the second begins.
        let older = home.load()
        let newer = home.load()
        await newer.value
        recent.release()
        await older.value

        #expect(home.recentlyPlayed == [track(track2)])
        #expect(home.jumpBackIn.isEmpty)
        #expect(home.state == .loaded)
    }

    @Test func metadataFailureKeepsPlaylistContexts() async {
        var logged: [String] = []
        let home = HomeModel(
            metadata: FailingMetadata(),
            playlists: StubPlaylists(rootlist: .success(rootlist), pages: [page(mix), page(weekly)]),
            recentlyPlayed: StubRecentlyPlayed(.success(history)),
            log: { logged.append($1) }
        )

        await home.load().value

        #expect(home.recentlyPlayed.isEmpty)
        #expect(home.jumpBackIn == [.playlist(page(mix))])
        #expect(logged.isEmpty)
    }

    @Test func limitCapsEachSection() async {
        let home = HomeModel(
            metadata: StubMetadata([track(track1), track(track2), albumItem]),
            playlists: StubPlaylists(rootlist: .success(rootlist), pages: [page(mix), page(weekly)]),
            recentlyPlayed: StubRecentlyPlayed(.success(history)),
            limit: 1,
            log: { _, _ in }
        )

        await home.load().value

        #expect(home.recentlyPlayed == [track(track1)])
        #expect(home.jumpBackIn == [.playlist(page(mix))])
        #expect(home.madeForYou == [page(weekly)])
    }
}
