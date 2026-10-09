import Foundation
import SpotCoreKit
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionSignOutTests {
    private let connector = FakeConnector()
    private let logs = LogSpy()

    private func ready(_ session: FakeSession, store: FakeStore) async throws -> SessionModel {
        let model = SessionModel(store: store, refreshTokenStore: FakeStore(), connector: connector, log: logs.log)
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

        try model.signOut()

        #expect(model.state == .signedOut)
        #expect(session.shutdownCount == 1)
        #expect(store.blob == nil)
    }

    @Test func signOutTwiceIsSafe() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)

        try model.signOut()
        try model.signOut()

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
        try model.signOut()
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
        try model.signOut()
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

        #expect(throws: KeychainError(status: -25308)) { try model.signOut() }
        #expect(model.state == .signedOut)
        #expect(session.shutdownCount == 1)
        #expect(store.blob == refreshedBlob)
        #expect(logs.entries.contains { $0.0 == .warn && $0.1.contains("-25308") })

        store.failDeletes(with: nil)
        try model.signOut()
        #expect(store.blob == nil)
    }
}
