import Foundation
import os
@testable import SpotCoreKit
import Testing

/// Serves a playlist in windows; `hold()` parks requests until `release()`.
final class PagedPlaylists: PlaylistServiceProtocol {
    private struct Box {
        var requested: [UInt32] = []
        var holding = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let uri: String
    private let tracks: [PlaylistTrack]
    private let cached: PlaylistPage?
    private let fails: Bool
    /// Nil fails the follower count request.
    private let followers: UInt64?
    private let box = OSAllocatedUnfairLock(initialState: Box())

    init(uri: String, tracks: [PlaylistTrack], cached: PlaylistPage? = nil, fails: Bool = false, followers: UInt64? = 0) {
        self.uri = uri
        self.tracks = tracks
        self.cached = cached
        self.fails = fails
        self.followers = followers
    }

    var requested: [UInt32] { box.withLock { $0.requested } }
    func hold() { box.withLock { $0.holding = true } }
    /// Lets parked requests through; `keepHolding` parks the ones after them.
    func release(keepHolding: Bool = false) {
        let waiters = box.withLock { box in
            box.holding = keepHolding
            defer { box.waiters = [] }
            return box.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func page(uri: String, from: UInt32, length: UInt32) async throws -> PlaylistPage {
        await withCheckedContinuation { continuation in
            let held = box.withLock { box in
                box.requested.append(from)
                if box.holding { box.waiters.append(continuation) }
                return box.holding
            }
            if !held { continuation.resume() }
        }
        if fails { throw PlaylistError.Request(message: "down") }
        let start = min(Int(from), tracks.count)
        let window = Array(tracks[start ..< min(start + Int(length), tracks.count)])
        return playlistPage(uri, tracks: window, total: tracks.count, offset: from)
    }

    func cachedPage(uri _: String, from _: UInt32, length _: UInt32) -> PlaylistPage? { cached }
    func cachedRootlist() -> [RootlistEntry] { [] }
    func rootlist() async throws -> [RootlistEntry] { [] }
    func followerCount(uri _: String) async throws -> UInt64 {
        guard let followers else { throw PlaylistError.Request(message: "down") }
        return followers
    }

    func waitForChange() async -> PlaylistChange {
        await withUnsafeContinuation { _ in }
    }
}

/// Serves the root list set last and empty playlists; `push` delivers a dealer change.
final class PushedPlaylists: PlaylistServiceProtocol {
    private struct Box {
        var rootlist: [RootlistEntry] = []
        var pageRequests: [String] = []
        var changeWaiters: [CheckedContinuation<PlaylistChange, Never>] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var pageRequests: [String] { box.withLock { $0.pageRequests } }
    var changeWaiters: Int { box.withLock { $0.changeWaiters.count } }
    func setRootlist(_ entries: [RootlistEntry]) { box.withLock { $0.rootlist = entries } }

    func push(_ change: PlaylistChange) {
        let waiters = box.withLock { box in
            defer { box.changeWaiters = [] }
            return box.changeWaiters
        }
        waiters.forEach { $0.resume(returning: change) }
    }

    func page(uri: String, from: UInt32, length _: UInt32) async throws -> PlaylistPage {
        box.withLock { $0.pageRequests.append(uri) }
        return playlistPage(uri, tracks: [], total: 0, offset: from)
    }

    func cachedPage(uri _: String, from _: UInt32, length _: UInt32) -> PlaylistPage? { nil }
    func cachedRootlist() -> [RootlistEntry] { [] }
    func rootlist() async throws -> [RootlistEntry] { box.withLock { $0.rootlist } }
    func followerCount(uri _: String) async throws -> UInt64 { 0 }
    func waitForChange() async -> PlaylistChange {
        await withCheckedContinuation { continuation in
            box.withLock { $0.changeWaiters.append(continuation) }
        }
    }
}

func playlistPage(_ uri: String, tracks: [PlaylistTrack], total: Int, offset: UInt32 = 0, name: String = "Mix") -> PlaylistPage {
    PlaylistPage(
        uri: uri, revision: "r", name: name, description: "", owner: "me", collaborative: false,
        artwork: [], total: UInt32(total), offset: offset, tracks: tracks
    )
}

private let mix = "spotify:playlist:37i9dQZF1E35AAAAAAAAAA"
private let other = "spotify:playlist:2222222222222222222222"

private func playlist(_ uri: String, _ name: String, in folder: String? = nil) -> RootlistEntry {
    .playlist(uri: uri, name: name, owner: "me", trackCount: 1, parent: folder)
}

private func tracks(_ count: Int) -> [PlaylistTrack] {
    (0 ..< count).map { PlaylistTrack(uri: "spotify:track:\($0)", addedBy: "me", addedAt: Int64($0)) }
}

@MainActor
struct PlaylistPageTests {
    @Test func showsTheCachedPlaylistBeforeAnyRequestReturns() async throws {
        let service = PagedPlaylists(uri: mix, tracks: tracks(3), cached: playlistPage(mix, tracks: tracks(2), total: 2, name: "Cached"))
        service.hold()
        let model = PlaylistModel(playlists: service)

        let task = model.loadPage(mix)
        #expect(model.pages[mix]?.name == "Cached")
        #expect(model.pages[mix]?.tracks.count == 2)
        #expect(model.pageState[mix] == .loaded)

        service.release()
        await task.value
        #expect(model.pages[mix]?.name == "Mix")
        #expect(model.pages[mix]?.tracks == tracks(3))
    }

    @Test func loadsEveryPageOfALongPlaylist() async {
        let count = Int(PlaylistModel.pageLength) * 2 + 5
        let service = PagedPlaylists(uri: mix, tracks: tracks(count))
        let model = PlaylistModel(playlists: service)

        await model.loadPage(mix).value

        #expect(model.pages[mix]?.tracks == tracks(count))
        #expect(service.requested == [0, PlaylistModel.pageLength, PlaylistModel.pageLength * 2])
    }

    @Test func keepsALongerCachedListUntilTheFetchCatchesUp() async throws {
        let count = Int(PlaylistModel.pageLength) + 10
        let service = PagedPlaylists(uri: mix, tracks: tracks(count), cached: playlistPage(mix, tracks: tracks(count), total: count))
        let model = PlaylistModel(playlists: service)

        service.hold()
        let task = model.loadPage(mix)
        try await waitUntil { service.requested.count == 1 }
        service.release(keepHolding: true)
        try await waitUntil { service.requested.count == 2 }
        #expect(model.pages[mix]?.tracks.count == count)
        service.release()
        await task.value
        #expect(model.pages[mix]?.tracks == tracks(count))
    }

    @Test func failsOnlyWhenNothingIsCached() async {
        let failing = PlaylistModel(playlists: PagedPlaylists(uri: mix, tracks: [], fails: true), log: { _, _ in })
        await failing.loadPage(mix).value
        #expect(failing.pageState[mix] == .failed)

        let stale = PlaylistModel(
            playlists: PagedPlaylists(uri: mix, tracks: [], cached: playlistPage(mix, tracks: tracks(1), total: 1), fails: true),
            log: { _, _ in }
        )
        await stale.loadPage(mix).value
        #expect(stale.pageState[mix] == .loaded)
        #expect(stale.pages[mix]?.tracks == tracks(1))
    }

    @Test func emptyPlaylistLoadsWithoutLooping() async {
        let service = PagedPlaylists(uri: mix, tracks: [])
        let model = PlaylistModel(playlists: service)

        await model.loadPage(mix).value

        #expect(model.pageState[mix] == .loaded)
        #expect(model.pages[mix]?.tracks == [])
        #expect(service.requested == [0])
    }

    @Test func loadsTheFollowerCountAlongsideTheTracks() async {
        let model = PlaylistModel(playlists: PagedPlaylists(uri: mix, tracks: tracks(1), followers: 1234))

        await model.loadPage(mix).value

        #expect(model.followers[mix] == 1234)
        #expect(model.pages[mix]?.tracks == tracks(1))
    }

    @Test func followerCountFailureStillShowsThePage() async {
        let model = PlaylistModel(playlists: PagedPlaylists(uri: mix, tracks: tracks(1), followers: nil), log: { _, _ in })

        await model.loadPage(mix).value

        #expect(model.followers[mix] == nil)
        #expect(model.pageState[mix] == .loaded)
    }

    @Test func dealerPushesRefreshTheRootListAndOpenPlaylistsOnly() async throws {
        let service = PushedPlaylists()
        let model = PlaylistModel(playlists: service)
        await model.load().value
        await model.loadPage(mix).value
        let watcher = Task { await model.watch() }

        try await waitUntil { service.changeWaiters == 1 }
        service.setRootlist([playlist(mix, "Mix")])
        service.push(.rootlist)
        try await waitUntil { model.rootlist == [playlist(mix, "Mix")] }

        try await waitUntil { service.changeWaiters == 1 }
        service.push(.playlist(uri: other))
        try await waitUntil { service.changeWaiters == 1 }
        service.push(.playlist(uri: mix))
        try await waitUntil { service.pageRequests.count == 2 }
        #expect(service.pageRequests == [mix, mix])

        watcher.cancel()
        try await waitUntil { service.changeWaiters == 1 }
        service.push(.resync)
        await watcher.value
    }

    @Test func treeNestsRowsUnderEarlierFoldersInOrder() {
        let road = "spotify:user:me:folder:aa"
        let inner = "spotify:user:me:folder:bb"
        let loop = "spotify:user:me:folder:cc"
        let entries: [RootlistEntry] = [
            playlist("spotify:playlist:1", "Top"),
            .folder(uri: road, name: "Road", parent: nil),
            playlist("spotify:playlist:2", "Nested", in: road),
            .folder(uri: inner, name: "Inner", parent: road),
            playlist("spotify:playlist:3", "Deep", in: inner),
            playlist("spotify:playlist:4", "Stray", in: "spotify:user:me:folder:gone"),
            .folder(uri: loop, name: "Loop", parent: loop),
        ]

        #expect(RootlistNode.tree(entries) == [
            RootlistNode(id: "spotify:playlist:1", name: "Top", children: nil),
            RootlistNode(id: road, name: "Road", children: [
                RootlistNode(id: "spotify:playlist:2", name: "Nested", children: nil),
                RootlistNode(id: inner, name: "Inner", children: [
                    RootlistNode(id: "spotify:playlist:3", name: "Deep", children: nil),
                ]),
            ]),
            RootlistNode(id: "spotify:playlist:4", name: "Stray", children: nil),
            RootlistNode(id: loop, name: "Loop", children: []),
        ])
    }
}
