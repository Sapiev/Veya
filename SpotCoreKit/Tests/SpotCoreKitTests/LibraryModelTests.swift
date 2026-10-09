import Foundation
import SpotCoreKit
import Testing

private let older = LibraryItem(uri: "spotify:track:older", addedAt: 100)
private let middle = LibraryItem(uri: "spotify:track:middle", addedAt: 200)
private let newer = LibraryItem(uri: "spotify:track:newer", addedAt: 300)
private let refused = LibraryError.Request(message: "refused")

@MainActor
struct LibraryModelTests {
    private let library: FakeLibrary
    private let metadata = FakeMetadata()
    private let logs = LogSpy()
    private let model: LibraryModel

    init() {
        library = FakeLibrary(cached: [.tracks: [middle, older]], server: [.tracks: [newer, middle, older]])
        model = LibraryModel(library: library, metadata: metadata, log: logs.log)
    }

    @Test func showsTheCacheBeforeTheSyncCompletes() async throws {
        library.holdRefreshes()
        let sync = model.load(.tracks)

        #expect(model.items[.tracks] == [middle, older])
        #expect(model.loadState[.tracks] == .loaded)
        try await waitUntil { library.heldRefreshCount == 1 }
        library.releaseRefreshes()
        await sync.value
        #expect(model.items[.tracks] == [newer, middle, older])
        #expect(model.isSaved(newer.uri))
    }

    @Test func aFailedSyncKeepsTheCache() async {
        library.failRefreshes(with: refused)
        await model.load(.tracks).value

        #expect(model.items[.tracks] == [middle, older])
        #expect(model.loadState[.tracks] == .loaded)
        #expect(logs.entries.contains { $0.0 == .warn })
    }

    @Test func aFailedSyncWithNothingCachedFails() async {
        library.failRefreshes(with: refused)
        let sync = model.load(.albums)
        #expect(model.loadState[.albums] == .loading)
        await sync.value

        #expect(model.loadState[.albums] == .failed)
        #expect(model.items[.albums] == [])
    }

    @Test func savesAtTheTopBeforeTheServerAnswers() async throws {
        await model.load(.tracks).value
        let write = try #require(model.setSaved("spotify:track:liked", true))

        #expect(model.isSaved("spotify:track:liked"))
        #expect(model.items[.tracks]?.first?.uri == "spotify:track:liked")
        try await waitUntil { library.writes.count == 1 }
        library.finishWrite(0)
        await write.value
        #expect(model.isSaved("spotify:track:liked"))
        #expect(library.writes.map(\.saved) == [true])
        #expect(model.saveFailure == nil)
    }

    @Test func aRefusedUnsaveRestoresTheItemAndReportsIt() async throws {
        await model.load(.tracks).value
        let write = try #require(model.setSaved(middle.uri, false))

        #expect(model.items[.tracks] == [newer, older])
        #expect(!model.isSaved(middle.uri))
        try await waitUntil { library.writes.count == 1 }
        library.finishWrite(0, error: refused)
        await write.value
        #expect(model.items[.tracks] == [newer, middle, older])
        #expect(model.isSaved(middle.uri))
        #expect(model.saveFailure?.uri == middle.uri)
        #expect(model.saveFailure?.saved == false)
    }

    @Test func aToggleDuringAWriteIsSentAfterIt() async throws {
        await model.load(.tracks).value
        let write = try #require(model.setSaved("spotify:album:x", true))
        try await waitUntil { library.writes.count == 1 }
        model.setSaved("spotify:album:x", false)

        #expect(!model.isSaved("spotify:album:x"))
        library.finishWrite(0)
        try await waitUntil { library.writes.count == 2 }
        library.finishWrite(1)
        await write.value
        #expect(library.writes.map(\.saved) == [true, false])
        #expect(!model.isSaved("spotify:album:x"))
        #expect(model.saveFailure == nil)
    }

    @Test func aSyncDuringAWriteKeepsTheToggle() async throws {
        await model.load(.tracks).value
        let write = try #require(model.setSaved("spotify:track:liked", true))
        try await waitUntil { library.writes.count == 1 }

        await model.load(.tracks).value
        #expect(model.isSaved("spotify:track:liked"))
        library.finishWrite(0)
        await write.value
        #expect(model.isSaved("spotify:track:liked"))
    }

    @Test func aSyncThatStartedBeforeAWriteLandedIsRepeated() async throws {
        await model.load(.tracks).value
        let write = try #require(model.setSaved("spotify:track:liked", true))
        try await waitUntil { library.writes.count == 1 }
        library.holdRefreshes()
        let sync = model.load(.tracks)
        try await waitUntil { library.heldRefreshCount == 1 }

        let liked = LibraryItem(uri: "spotify:track:liked", addedAt: 400)
        library.finishWrite(0)
        await write.value
        library.setServer([liked, newer, middle, older], for: .tracks)
        library.releaseRefreshes()
        await sync.value
        #expect(model.isSaved(liked.uri))
        #expect(model.items[.tracks] == [liked, newer, middle, older])
    }

    @Test func resolvesOnlyUnknownURIsNotAlreadyRequested() async throws {
        let first = try #require(model.resolve(["spotify:track:a", "spotify:track:b"]))
        let second = try #require(model.resolve(["spotify:track:b", "spotify:track:c"]))
        try await waitUntil { metadata.pending == 2 }
        metadata.release()
        await first.value
        await second.value

        #expect(metadata.requested == [["spotify:track:a", "spotify:track:b"], ["spotify:track:c"]])
        #expect(model.metadata["spotify:track:a"] == .unavailable(uri: "spotify:track:a", error: .notFound))
        #expect(model.resolve(["spotify:track:a", "spotify:track:c"]) == nil)
        #expect(metadata.requested.count == 2)
    }

    @Test func watchRefreshesTheKindsLoadedSoFar() async throws {
        await model.load(.tracks).value
        let watcher = Task { await model.watch() }
        try await waitUntil { library.changeWaiters == 1 }

        library.setServer([older], for: .tracks)
        library.pushChange()
        try await waitUntil { model.items[.tracks] == [older] }
        #expect(library.refreshes == [.tracks, .tracks])
        watcher.cancel()
        try await waitUntil { library.changeWaiters == 1 }
        library.pushChange()
        await watcher.value
    }
}
