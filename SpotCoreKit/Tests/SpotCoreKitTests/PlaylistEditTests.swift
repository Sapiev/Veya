import Foundation
@testable import SpotCoreKit
import Testing

private let mix = "spotify:playlist:37i9dQZF1E35AAAAAAAAAA"

private func tracks(_ ids: [Int]) -> [PlaylistTrack] {
    ids.map { PlaylistTrack(uri: "spotify:track:\($0)", addedBy: "me", addedAt: 0) }
}

/// An undo manager the test groups by hand, since no run loop ends its events.
@MainActor
private func manualUndo() -> UndoManager {
    let undo = UndoManager()
    undo.groupsByEvent = false
    return undo
}

@MainActor
struct PlaylistEditTests {
    private func loaded(_ ids: [Int]) async -> (PushedPlaylists, PlaylistModel) {
        let service = PushedPlaylists()
        service.setTracks(tracks(ids), of: mix)
        let model = PlaylistModel(playlists: service, log: { _, _ in })
        await model.loadPage(mix).value
        return (service, model)
    }

    @Test func editsShowAtOnceAndChainTheRevisionEachReturns() async throws {
        let (service, model) = await loaded([0, 1, 2, 3, 4])
        service.holdWrites()

        let remove = model.removeTracks(at: [1], from: mix, undoManager: nil)
        let move = model.moveTracks(fromOffsets: [0], toOffset: 4, in: mix, undoManager: nil)
        #expect(model.pages[mix]?.tracks == tracks([2, 3, 4, 0]))
        #expect(model.pages[mix]?.total == 4)
        try await waitUntil { service.parkedWrites == 1 }

        service.releaseWrites()
        await remove.value
        await move.value
        #expect(service.writes == ["remove r0", "move r1"])
        #expect(service.tracks(of: mix) == tracks([2, 3, 4, 0]))
        #expect(model.pages[mix]?.tracks == tracks([2, 3, 4, 0]))
        #expect(model.pages[mix]?.revision == "r2")
        #expect(model.editError == nil)
    }

    @Test func addingAppendsAndUsesTheLatestRevision() async {
        let (service, model) = await loaded([0])
        await model.removeTracks(at: [0], from: mix, undoManager: nil).value
        await model.addTracks(["spotify:track:9"], to: mix).value
        #expect(service.writes == ["remove r0", "add r1"])
        #expect(model.pages[mix]?.tracks.map(\.uri) == ["spotify:track:9"])
    }

    @Test func aConflictRollsBackSkipsQueuedEditsAndEndsOnTheServerList() async throws {
        let (service, model) = await loaded([0, 1, 2])
        service.setTracks(tracks([0, 1, 2, 7]), of: mix)
        service.failNextWrite(.Conflict)
        service.holdWrites()
        let undo = manualUndo()

        undo.beginUndoGrouping()
        let first = model.removeTracks(at: [0], from: mix, undoManager: undo)
        undo.endUndoGrouping()
        let second = model.moveTracks(fromOffsets: [0], toOffset: 2, in: mix, undoManager: nil)
        try await waitUntil { service.parkedWrites == 1 }
        service.releaseWrites()
        await first.value
        await second.value

        #expect(service.writes == ["remove r0"])
        #expect(model.editError == .conflict)
        #expect(model.pages[mix]?.tracks == tracks([0, 1, 2, 7]))
        #expect(!undo.canUndo)
    }

    @Test func aFailureIsReportedAsFailed() async {
        let (service, model) = await loaded([0, 1])
        service.failNextWrite(.Request(message: "down"))
        await model.removeTracks(at: [0], from: mix, undoManager: nil).value
        #expect(model.editError == .failed)
        #expect(model.pages[mix]?.tracks == tracks([0, 1]))
    }

    @Test func undoAndRedoARemoval() async throws {
        let (service, model) = await loaded([0, 1, 2, 3, 4])
        let undo = manualUndo()

        undo.beginUndoGrouping()
        let remove = model.removeTracks(at: [1, 3, 4], from: mix, undoManager: undo)
        undo.endUndoGrouping()
        #expect(model.pages[mix]?.tracks == tracks([0, 2]))
        await remove.value

        undo.undo()
        #expect(model.pages[mix]?.tracks == tracks([0, 1, 2, 3, 4]))
        try await waitUntil { service.tracks(of: mix) == tracks([0, 1, 2, 3, 4]) }

        undo.redo()
        #expect(model.pages[mix]?.tracks == tracks([0, 2]))
        try await waitUntil { service.tracks(of: mix) == tracks([0, 2]) }
        #expect(model.pages[mix]?.tracks == tracks([0, 2]))
        #expect(model.editError == nil)
    }

    @Test func undoAndRedoAMove() async throws {
        let (service, model) = await loaded([0, 1, 2, 3, 4])
        let undo = manualUndo()

        undo.beginUndoGrouping()
        let move = model.moveTracks(fromOffsets: [0, 2], toOffset: 5, in: mix, undoManager: undo)
        undo.endUndoGrouping()
        #expect(model.pages[mix]?.tracks == tracks([1, 3, 4, 0, 2]))
        await move.value
        #expect(service.tracks(of: mix) == tracks([1, 3, 4, 0, 2]))

        undo.undo()
        #expect(model.pages[mix]?.tracks == tracks([0, 1, 2, 3, 4]))
        try await waitUntil { service.tracks(of: mix) == tracks([0, 1, 2, 3, 4]) }

        undo.redo()
        try await waitUntil { service.tracks(of: mix) == tracks([1, 3, 4, 0, 2]) }
        #expect(model.pages[mix]?.tracks == tracks([1, 3, 4, 0, 2]))
    }

    @Test func aPushDuringAnEditRefreshesOnlyAfterTheQueueDrains() async throws {
        let (service, model) = await loaded([0, 1, 2])
        let watcher = Task { await model.watch() }
        defer { watcher.cancel() }
        try await waitUntil { service.changeWaiters == 1 }
        service.holdWrites()

        let remove = model.removeTracks(at: [0], from: mix, undoManager: nil)
        try await waitUntil { service.parkedWrites == 1 }
        let requests = service.pageRequests.count
        service.push(.playlist(uri: mix))
        try await waitUntil { service.changeWaiters == 1 }
        #expect(service.pageRequests.count == requests)
        #expect(model.pages[mix]?.tracks == tracks([1, 2]))

        service.releaseWrites()
        await remove.value
        #expect(service.pageRequests.count == requests + 1)
        #expect(model.pages[mix]?.tracks == tracks([1, 2]))
        #expect(model.pages[mix]?.revision == "r1")
    }

    @Test func undoIsDroppedWhenARefreshBringsAnotherClientsChange() async {
        let (service, model) = await loaded([0, 1, 2, 3, 4])
        let undo = manualUndo()
        undo.beginUndoGrouping()
        await model.removeTracks(at: [4], from: mix, undoManager: undo).value
        undo.endUndoGrouping()

        await model.loadPage(mix).value
        #expect(undo.canUndo)

        service.changeElsewhere(tracks([0]), of: mix)
        await model.loadPage(mix).value
        #expect(model.pages[mix]?.tracks == tracks([0]))
        #expect(!undo.canUndo)
    }

    @Test func editsThatNoLongerFitTheListAreRefused() {
        var page = playlistPage(mix, tracks: tracks([0, 1, 2]), total: 3)
        let before = page
        #expect(!TrackEdit.move(from: 2, length: 2, to: 0).apply(to: &page))
        #expect(!TrackEdit.move(from: 0, length: 1, to: 4).apply(to: &page))
        #expect(!TrackEdit.move(from: 0, length: 2, to: 1).apply(to: &page))
        #expect(!TrackEdit.remove(tracks([2, 3]), at: 2).apply(to: &page))
        #expect(!TrackEdit.remove(tracks([1]), at: 0).apply(to: &page))
        #expect(!TrackEdit.insert(tracks([9]), at: 4, end: 3).apply(to: &page))
        #expect(page == before)
    }

    /// The model logs a failed edit after rolling it back, so an edit made from
    /// the log hook is one the user makes after the failure, before the queue drains.
    @Test func anEditMadeAfterAFailureStillRunsAndUndoes() async throws {
        let service = PushedPlaylists()
        service.setTracks(tracks([0, 1, 2]), of: mix)
        let undo = manualUndo()
        var later: Task<Void, Never>?
        var model: PlaylistModel!
        model = PlaylistModel(playlists: service, log: { _, message in
            guard later == nil, message.hasPrefix("Couldn't edit") else { return }
            undo.beginUndoGrouping()
            later = model.removeTracks(at: [2], from: mix, undoManager: undo)
            undo.endUndoGrouping()
        })
        await model.loadPage(mix).value
        service.failNextWrite(.Conflict)
        service.holdWrites()

        let failing = model.removeTracks(at: [0], from: mix, undoManager: nil)
        let skipped = model.removeTracks(at: [0], from: mix, undoManager: nil)
        try await waitUntil { service.parkedWrites == 1 }
        service.releaseWrites()
        await failing.value
        await skipped.value
        try await waitUntil { later != nil }
        await later?.value

        #expect(service.writes == ["remove r0", "remove r0"])
        #expect(service.tracks(of: mix) == tracks([0, 1]))
        #expect(model.pages[mix]?.tracks == tracks([0, 1]))
        #expect(undo.canUndo)
        undo.undo()
        try await waitUntil { service.tracks(of: mix) == tracks([0, 1, 2]) }
    }

    /// Every selection and target of a short list matches SwiftUI's
    /// `move(fromOffsets:toOffset:)`, and the inverses restore the list.
    @Test func blockMovesReorderLikeSwiftUIAndInvert() {
        let count = 6
        let original = tracks(Array(0 ..< count))
        for mask in 1 ..< (1 << count) {
            let offsets = IndexSet((0 ..< count).filter { mask & (1 << $0) != 0 })
            for target in 0 ... count {
                let picked = offsets.map { original[$0] }
                let rest = original.indices.filter { !offsets.contains($0) }
                let split = rest.count(where: { $0 < target })
                let expected = rest[..<split].map { original[$0] } + picked + rest[split...].map { original[$0] }

                var page = playlistPage(mix, tracks: original, total: count)
                let edits = TrackEdit.moves(offsets, to: target)
                edits.forEach { $0.apply(to: &page) }
                #expect(page.tracks == expected, "offsets \(Array(offsets)) to \(target)")
                edits.reversed().compactMap(\.inverse).forEach { $0.apply(to: &page) }
                #expect(page.tracks == original)
            }
        }
    }

    @Test func createsAPlaylistAndShowsItInTheRootList() async {
        let service = PushedPlaylists()
        let model = PlaylistModel(playlists: service, log: { _, _ in })

        let uri = await model.createPlaylist(named: "New", description: "Fresh")
        #expect(service.createdDescriptions == ["spotify:playlist:New": "Fresh"])

        #expect(uri == "spotify:playlist:New")
        #expect(model.editablePlaylists.map(\.id) == ["spotify:playlist:New"])
        #expect(model.isEditable("spotify:playlist:New"))
    }

    @Test func rootListEditsRunOneAfterAnotherAndBothShow() async {
        let model = PlaylistModel(playlists: PushedPlaylists(), log: { _, _ in })

        async let first = model.createPlaylist(named: "A")
        async let second = model.createPlaylist(named: "B")
        let created = await [first, second]

        #expect(created.compactMap(\.self).count == 2)
        #expect(model.rootlist.count == 2)
    }

    @Test func aNewPictureIsReencodedThenShownOnThePageAndInTheSidebar() async {
        let (service, model) = await loaded([0])
        let png = noiseImage(width: 1200, height: 900)

        await model.setPicture(of: mix, imageData: png)

        let sent = service.pictures[mix]
        #expect(sent != nil && sent != png)
        #expect(sent?.starts(with: [0xFF, 0xD8, 0xFF]) == true)
        #expect(model.pages[mix]?.artwork.isEmpty == false)
        #expect(model.artwork[mix] == model.pages[mix]?.artwork)
        #expect(model.editError == nil)
    }

    @Test func aPictureThatIsNotAnImageIsRefusedWithoutAnUpload() async {
        let (service, model) = await loaded([0])
        await model.setPicture(of: mix, imageData: Data("text".utf8))
        #expect(service.pictures.isEmpty)
        #expect(model.editError == .invalidImage)
    }

    @Test func aFailedRootListEditSetsTheError() async {
        let model = PlaylistModel(playlists: PushedPlaylists(), log: { _, _ in })
        await model.delete(mix)
        #expect(model.editError == .failed)
    }
}
