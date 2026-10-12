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

/// Serves the root list set last and in-memory playlists that take writes
/// against their revision; `push` delivers a dealer change, `holdWrites()`
/// parks writes until `releaseWrites()`, and `failNextWrite` fails one.
final class PushedPlaylists: PlaylistServiceProtocol {
    private struct Box {
        var rootlist: [RootlistEntry] = []
        var pageRequests: [String] = []
        var changeWaiters: [CheckedContinuation<PlaylistChange, Never>] = []
        var tracks: [String: [PlaylistTrack]] = [:]
        var revisions: [String: Int] = [:]
        /// Each write as "<kind> <revision sent>".
        var writes: [String] = []
        var failNextWrite: PlaylistError?
        var holdingWrites = false
        var writeWaiters: [CheckedContinuation<Void, Never>] = []
        /// The last picture set on each playlist.
        var pictures: [String: Data] = [:]
        var created: [String: String] = [:]
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var pageRequests: [String] { box.withLock { $0.pageRequests } }
    var changeWaiters: Int { box.withLock { $0.changeWaiters.count } }
    var writes: [String] { box.withLock { $0.writes } }
    var parkedWrites: Int { box.withLock { $0.writeWaiters.count } }
    var pictures: [String: Data] { box.withLock { $0.pictures } }
    /// Each created playlist's description by URI.
    var createdDescriptions: [String: String] { box.withLock { $0.created } }
    func setRootlist(_ entries: [RootlistEntry]) { box.withLock { $0.rootlist = entries } }
    func setTracks(_ tracks: [PlaylistTrack], of uri: String) { box.withLock { $0.tracks[uri] = tracks } }
    /// Another client's edit: new tracks under a new revision.
    func changeElsewhere(_ tracks: [PlaylistTrack], of uri: String) {
        box.withLock { box in
            box.tracks[uri] = tracks
            box.revisions[uri, default: 0] += 1
        }
    }
    func tracks(of uri: String) -> [PlaylistTrack] { box.withLock { $0.tracks[uri] ?? [] } }
    func failNextWrite(_ error: PlaylistError) { box.withLock { $0.failNextWrite = error } }
    func holdWrites() { box.withLock { $0.holdingWrites = true } }
    func releaseWrites() {
        let waiters = box.withLock { box in
            box.holdingWrites = false
            defer { box.writeWaiters = [] }
            return box.writeWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func push(_ change: PlaylistChange) {
        let waiters = box.withLock { box in
            defer { box.changeWaiters = [] }
            return box.changeWaiters
        }
        waiters.forEach { $0.resume(returning: change) }
    }

    func page(uri: String, from: UInt32, length: UInt32) async throws -> PlaylistPage {
        let (all, revision) = box.withLock { box in
            box.pageRequests.append(uri)
            return (box.tracks[uri] ?? [], box.revisions[uri, default: 0])
        }
        let start = min(Int(from), all.count)
        var page = playlistPage(uri, tracks: Array(all[start ..< min(start + Int(length), all.count)]), total: all.count, offset: from)
        page.revision = "r\(revision)"
        if box.withLock({ $0.pictures[uri] }) != nil {
            page.artwork = [Artwork(url: "https://i.scdn.co/image/\(uri)", size: .large, width: 640, height: 640)]
        }
        return page
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

    func addTracks(uri: String, trackUris: [String], revision: String) async throws -> String {
        try await write("add", uri, revision) { tracks in
            tracks += trackUris.map { PlaylistTrack(uri: $0, addedBy: "me", addedAt: 0) }
        }
    }

    func removeTracks(uri: String, from: UInt32, trackUris: [String], revision: String) async throws -> String {
        try await write("remove", uri, revision) { tracks in
            let range = Int(from) ..< Int(from) + trackUris.count
            guard range.upperBound <= tracks.count, tracks[range].map(\.uri) == trackUris else { throw PlaylistError.Conflict }
            tracks.removeSubrange(range)
        }
    }

    func moveTracks(uri: String, from: UInt32, length: UInt32, to: UInt32, revision: String) async throws -> String {
        try await write("move", uri, revision) { tracks in
            let range = Int(from) ..< Int(from + length)
            let block = tracks[range]
            tracks.removeSubrange(range)
            tracks.insert(contentsOf: block, at: to > from ? Int(to - length) : Int(to))
        }
    }

    func createPlaylist(name: String, description: String, folder: String?) async throws -> String {
        let uri = "spotify:playlist:\(name)"
        box.withLock {
            $0.rootlist.insert(.playlist(uri: uri, name: name, owner: "me", trackCount: 0, parent: folder, editable: true, public: false), at: 0)
            $0.created[uri] = description
        }
        return uri
    }

    /// Takes JPEG only, as the service does.
    func setPicture(uri: String, jpeg: Data) async throws {
        guard jpeg.starts(with: [0xFF, 0xD8, 0xFF]), jpeg.count <= 256 * 1024 else { throw PlaylistError.InvalidImage }
        box.withLock { $0.pictures[uri] = jpeg }
    }

    private func write(
        _ kind: String, _ uri: String, _ revision: String, _ change: @Sendable (inout [PlaylistTrack]) throws -> Void
    ) async throws -> String {
        await withCheckedContinuation { continuation in
            let held = box.withLock { box in
                if box.holdingWrites { box.writeWaiters.append(continuation) }
                return box.holdingWrites
            }
            if !held { continuation.resume() }
        }
        return try box.withLock { box in
            box.writes.append("\(kind) \(revision)")
            if let error = box.failNextWrite {
                box.failNextWrite = nil
                throw error
            }
            guard revision == "r\(box.revisions[uri, default: 0])" else { throw PlaylistError.Conflict }
            var tracks = box.tracks[uri] ?? []
            try change(&tracks)
            box.tracks[uri] = tracks
            box.revisions[uri, default: 0] += 1
            return "r\(box.revisions[uri]!)"
        }
    }
}

func playlistPage(_ uri: String, tracks: [PlaylistTrack], total: Int, offset: UInt32 = 0, name: String = "Mix") -> PlaylistPage {
    PlaylistPage(
        uri: uri, revision: "r", name: name, description: "", owner: "me", ownerName: "Me", collaborative: false, editable: false,
        artwork: [], total: UInt32(total), offset: offset, tracks: tracks
    )
}

private let mix = "spotify:playlist:37i9dQZF1E35AAAAAAAAAA"
private let other = "spotify:playlist:2222222222222222222222"

private func playlist(_ uri: String, _ name: String, in folder: String? = nil) -> RootlistEntry {
    .playlist(uri: uri, name: name, owner: "me", trackCount: 1, parent: folder, editable: false, public: false)
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

    @Test func loadArtworkPrefersTheCacheAndRequestsEachPlaylistOnce() async {
        var cached = playlistPage(mix, tracks: [], total: 0)
        cached.artwork = [Artwork(url: "https://i.scdn.co/image/a64", size: .small, width: 64, height: 64)]
        let fromCache = PagedPlaylists(uri: mix, tracks: [], cached: cached)
        let model = PlaylistModel(playlists: fromCache)
        await model.loadArtwork([mix])
        #expect(model.artwork[mix] == cached.artwork)
        #expect(fromCache.requested.isEmpty)

        let fetched = PagedPlaylists(uri: other, tracks: [], fails: true)
        let failing = PlaylistModel(playlists: fetched)
        await failing.loadArtwork([other])
        await failing.loadArtwork([other])
        #expect(failing.artwork[other] == [])
        #expect(fetched.requested == [0])
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

        // Cancelling before the watcher waits again would let it start one more wait.
        try await waitUntil { service.changeWaiters == 1 }
        watcher.cancel()
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

    /// Two nested start-group entries with the same id decode as a folder inside itself.
    @Test func treeDropsRepeatedURIsSoASelfNestedFolderEnds() {
        let folder = "spotify:user:me:folder:aa"
        let entries: [RootlistEntry] = [
            .folder(uri: folder, name: "Outer", parent: nil),
            .folder(uri: folder, name: "Outer again", parent: folder),
            playlist("spotify:playlist:1", "Inside", in: folder),
            playlist("spotify:playlist:1", "Inside", in: folder),
        ]

        #expect(RootlistNode.tree(entries) == [
            RootlistNode(id: folder, name: "Outer", children: [
                RootlistNode(id: "spotify:playlist:1", name: "Inside", children: nil),
            ]),
        ])
    }
}
