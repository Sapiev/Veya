import Foundation
import SpotCoreKit
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionSignOutTests {
    private let connector = FakeConnector()
    private let logs = LogSpy()

    private let forgotten = Counter()

    private final class Counter {
        var count = 0
    }

    private func ready(_ session: FakeSession, store: FakeStore) async throws -> SessionModel {
        let forgotten = forgotten
        let model = SessionModel(
            store: store, refreshTokenStore: FakeStore(), connector: connector, log: logs.log,
            forgetPlayback: { forgotten.count += 1 }
        )
        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(session))
        await task.value
        #expect(model.state == .ready)
        return model
    }

    @Test func signOutEndsSessionDeletesItemAndShowsSignIn() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)

        try await model.signOut()

        #expect(model.state == .signedOut)
        #expect(session.shutdownCount == 1)
        #expect(store.blob == nil)
    }

    @Test func quittingKeepsSavedPlayback() async throws {
        let model = try await ready(FakeSession(), store: FakeStore(blob: storedBlob))
        model.shutdown()
        #expect(forgotten.count == 0)
    }

    @Test func rejectedCredentialsForgetSavedPlayback() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))
        session.push(.credentialsRejected)
        try await waitUntil { model.state == .signedOut }
        #expect(forgotten.count == 1)
    }

    @Test func signOutForgetsSavedPlayback() async throws {
        let model = try await ready(FakeSession(), store: FakeStore(blob: storedBlob))
        try await model.signOut()
        #expect(forgotten.count == 1)
    }

    @Test func signOutTwiceIsSafe() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)

        try await model.signOut()
        try await model.signOut()

        #expect(model.state == .signedOut)
        #expect(session.shutdownCount == 1)
        #expect(store.blob == nil)
    }

    @Test func connectedQueuedBeforeSignOutDoesNotSaveAgain() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)
        session.blob = Data("rotated-SECRET-blob".utf8)
        let saves = store.saves

        session.push(.connected)
        try await model.signOut()
        try await Task.sleep(for: .milliseconds(50))

        #expect(store.saves == saves)
        #expect(store.blob == nil)
    }

    @Test func signOutDuringRestoreDropsLateSession() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = SessionModel(store: store, refreshTokenStore: FakeStore(), connector: connector, log: logs.log)
        let late = FakeSession()

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        try await model.signOut()
        connector.resolve(0, with: .success(late))
        await task.value

        #expect(model.state == .signedOut)
        #expect(late.shutdownCount == 1)
        #expect(store.blob == nil)
    }

    @Test func deleteFailureStillEndsSessionAndRetrySucceeds() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)
        store.failDeletes(with: KeychainError(status: -25308))

        await #expect(throws: KeychainError(status: -25308)) { try await model.signOut() }
        #expect(model.state == .signedOut)
        #expect(session.shutdownCount == 1)
        #expect(store.blob == refreshedBlob)
        #expect(logs.entries.contains { $0.0 == .warn && $0.1.contains("-25308") })

        store.failDeletes(with: nil)
        try await model.signOut()
        #expect(store.blob == nil)
    }

    @Test func signOutClearsMetadataCache() async throws {
        let model = try await ready(FakeSession(), store: FakeStore(blob: storedBlob))

        try await model.signOut()

        #expect(connector.metadataClears == 1)
    }

    @Test func metadataClearFailureStillEndsSessionDeletesItemsAndRethrows() async throws {
        let store = FakeStore(blob: storedBlob)
        let refreshTokens = FakeStore(blob: Data("rt".utf8))
        let session = FakeSession()
        let model = SessionModel(store: store, refreshTokenStore: refreshTokens, connector: connector, log: logs.log)
        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(session))
        await task.value
        connector.failMetadataClear(with: DiskFull())

        await #expect(throws: DiskFull()) { try await model.signOut() }
        #expect(model.state == .signedOut)
        #expect(session.shutdownCount == 1)
        #expect(store.blob == nil)
        #expect(refreshTokens.blob == nil)
        #expect(logs.entries.contains { $0.0 == .warn && $0.1.contains("metadata cache") })
    }

    private func startPlayer(on session: FakeSession) async throws -> PlayerModel {
        let suite = "SessionSignOutTests.\(UUID().uuidString)"
        let settings = PlaybackSettings(defaults: UserDefaults(suiteName: suite)!)
        return try await PlayerModel.start(session: session, metadata: StubMetadata([]), settings: settings)
    }

    @Test func signOutStopsPlaybackOnceAndClearsCachesEachTime() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))
        let player = try await startPlayer(on: session)
        #expect(model.attach(player, startedOn: session))

        try await model.signOut()
        try await model.signOut()

        withExtendedLifetime(player) {
            #expect(session.player.recorded.filter { $0 == "stopLocal" }.count == 1)
            #expect(!session.player.recorded.contains("stop"), "PBI-503: teardown never commands a remote")
        }
        #expect(connector.audioClears == 2)
        #expect(connector.metadataClears == 2)
    }

    @Test func playerStartedOnAnEndedSessionIsStopped() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))
        let player = try await startPlayer(on: session)
        try await model.signOut()

        #expect(!model.attach(player, startedOn: session))
        withExtendedLifetime(player) {
            #expect(session.player.recorded.contains("stopLocal"))
            #expect(!session.player.recorded.contains("stop"), "PBI-503: teardown never commands a remote")
        }
    }

    @Test func audioClearFailureStillCompletesSignOutAndRetrySucceeds() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)
        connector.failAudioClear(with: DiskFull())

        await #expect(throws: DiskFull()) { try await model.signOut() }
        #expect(model.state == .signedOut)
        #expect(session.shutdownCount == 1)
        #expect(store.blob == nil)
        #expect(connector.metadataClears == 1)
        #expect(logs.entries.contains { $0.0 == .warn && $0.1.contains("audio cache") })

        connector.failAudioClear(with: nil)
        try await model.signOut()
        #expect(connector.audioClears == 2)
    }

    @Test func clearAudioCacheClearsThroughConnectorOffTheMainThread() async throws {
        let model = SessionModel(store: FakeStore(), refreshTokenStore: FakeStore(), connector: connector, log: logs.log)

        try await model.clearAudioCache()

        #expect(connector.audioClears == 1)
        #expect(connector.cacheWorkOnMain == [false])
    }

    @Test func resetMetadataCacheClearsThroughConnectorOffTheMainThread() async {
        let model = SessionModel(store: FakeStore(), refreshTokenStore: FakeStore(), connector: connector, log: logs.log)

        try? await model.resetMetadataCache()

        #expect(connector.metadataClears == 1)
        #expect(connector.cacheWorkOnMain == [false])
    }

    @Test func signOutClearsCachesOffTheMainThreadBeforeReturning() async throws {
        let model = SessionModel(store: FakeStore(), refreshTokenStore: FakeStore(), connector: connector, log: logs.log)

        try await model.signOut()

        #expect(connector.cacheWorkOnMain == [false, false])
    }
}

private struct DiskFull: Error, Equatable {}
