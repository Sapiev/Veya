import Foundation
import os
import SpotCoreKit
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionModelTests {
    private let connector = FakeConnector()
    private let logs = LogSpy()

    /// The clock reads `restoreTook` later on every call after the first, so a restore's duration
    /// never depends on how loaded the machine running the test is.
    private func model(_ store: FakeStore, restoreTook: Duration = .milliseconds(100)) -> SessionModel {
        let base = ContinuousClock.now
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let now = { calls.withLock { n -> ContinuousClock.Instant in defer { n += 1 }; return n == 0 ? base : base + restoreTook } }
        return SessionModel(store: store, refreshTokenStore: FakeStore(), connector: connector, log: logs.log, now: now)
    }

    @Test func startsRestoringSoSignInNeverFlashes() {
        #expect(model(FakeStore()).state == .restoring)
    }

    @Test func restoreWithoutStoredCredentialsIsSignedOut() async {
        let store = FakeStore()
        let model = model(store)

        await model.restore().value

        #expect(model.state == .signedOut)
        #expect(connector.calls.isEmpty)
    }

    @Test func restoreLoadErrorIsKeychainFailureAndKeepsItem() async {
        let store = FakeStore(blob: storedBlob, loadError: KeychainError(status: -25293))
        let model = model(store)

        await model.restore().value

        #expect(model.state == .failed(.keychain))
        #expect(connector.calls.isEmpty)
        #expect(store.deletes == 0)
        #expect(logs.entries.map(\.0) == [.warn])
        #expect(logs.entries.first?.1.contains("-25293") == true)
    }

    @Test func rejectionAfterStoreChangedKeepsNewBlob() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)
        let newer = Data("newer-SECRET-blob".utf8)

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        store.replace(with: newer)
        connector.resolve(0, with: .failure(SessionError.CredentialsRejected))
        await task.value

        #expect(model.state == .signedOut)
        #expect(store.deletes == 0)
        #expect(store.blob == newer)
    }

    @Test func shutdownEndsReadySessionAndKeepsItem() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)
        let session = FakeSession()

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(session))
        await task.value
        model.shutdown()

        #expect(session.shutdownCount == 1)
        #expect(store.blob == refreshedBlob)
    }

    @Test func restoreConnectsSavesRefreshedBlobAndLogsElapsed() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(FakeSession()))
        await task.value

        #expect(model.state == .ready)
        #expect(connector.calls == [.stored(storedBlob)])
        #expect(store.blob == refreshedBlob)
        #expect(logs.entries.count == 1)
        #expect(logs.entries.first?.0 == .info)
        #expect(logs.entries.first?.1.hasPrefix("Session restored in ") == true)
    }

    @Test func aRestoreSlowerThanTheBudgetLogsAWarning() async throws {
        let model = model(FakeStore(blob: storedBlob), restoreTook: SessionModel.readyBudget + .milliseconds(1))

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(FakeSession()))
        await task.value

        #expect(logs.entries.map(\.0) == [.warn])
        #expect(logs.entries.first?.1.hasPrefix("Session restored in ") == true)
    }

    @Test func restoreRunTwiceEndsReadyWithOneLiveSession() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)
        let first = FakeSession()
        let second = FakeSession()

        let task1 = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(first))
        await task1.value
        let task2 = model.restore()
        try await waitUntil { connector.pending == 2 }
        connector.resolve(1, with: .success(second))
        await task2.value

        #expect(model.state == .ready)
        #expect(connector.calls == [.stored(storedBlob), .stored(refreshedBlob)])
        #expect(store.blob == refreshedBlob)
        #expect(store.saves == 2)
        #expect(first.shutdownCount == 1)
        #expect(second.shutdownCount == 0)
    }

    @Test(arguments: [SessionError.CredentialsRejected, .InvalidStoredCredentials])
    func restoreRejectedDeletesItemAndSignsOut(error: SessionError) async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .failure(error))
        await task.value

        #expect(model.state == .signedOut)
        #expect(store.deletes == 1)
        #expect(store.blob == nil)
    }

    @Test(arguments: zip(
        [SessionError.Network(message: "offline"), .LoginFailed(reason: "premium"), .Internal(message: "boom")],
        [SessionFailure.network, .loginFailed, .other]
    ))
    func restoreOtherFailureKeepsItem(error: SessionError, expected: SessionFailure) async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .failure(error))
        await task.value

        #expect(model.state == .failed(expected))
        #expect(store.deletes == 0)
        #expect(store.blob == storedBlob)
    }

    @Test func retryAfterNetworkFailureRestores() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)

        let task1 = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .failure(SessionError.Network(message: "offline")))
        await task1.value
        let task2 = model.retry()
        #expect(model.state == .restoring)
        try await waitUntil { connector.pending == 2 }
        connector.resolve(1, with: .success(FakeSession()))
        await task2.value

        #expect(model.state == .ready)
        #expect(connector.calls == [.stored(storedBlob), .stored(storedBlob)])
    }

    @Test func connectWithTokensSavesBlob() async throws {
        let store = FakeStore()
        let model = model(store)

        let task = model.connect(tokens: tokens)
        #expect(model.state == .connecting)
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(FakeSession()))
        await task.value

        #expect(model.state == .ready)
        #expect(connector.calls == [.token("access-SECRET-1234")])
        #expect(store.blob == refreshedBlob)
        #expect(logs.entries.isEmpty)
    }

    @Test(arguments: zip(
        [SessionError.Network(message: "offline"), .CredentialsRejected, .Internal(message: "boom")],
        [SessionFailure.network, .loginFailed, .other]
    ))
    func connectFailureIsFailed(error: SessionError, expected: SessionFailure) async throws {
        let store = FakeStore()
        let model = model(store)

        let task = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .failure(error))
        await task.value

        #expect(model.state == .failed(expected))
        #expect(store.saves == 0)
    }

    @Test func nonPremiumAccountIsNotPremiumWithoutConnecting() async {
        let store = FakeStore()
        let model = model(store)
        connector.setPremium(.success(false))

        await model.connect(tokens: tokens).value

        #expect(model.state == .notPremium)
        #expect(connector.calls.isEmpty)
        #expect(store.saves == 0)
    }

    @Test func signOutFromNotPremiumIsSignedOut() async throws {
        let model = model(FakeStore())
        connector.setPremium(.success(false))
        await model.connect(tokens: tokens).value

        try await model.signOut()

        #expect(model.state == .signedOut)
    }

    @Test func premiumCheckFailureConnectsAnywayAndLogsWithoutSecrets() async throws {
        let model = model(FakeStore())
        connector.setPremium(.failure(SessionError.Network(message: "offline access-SECRET-1234")))

        let task = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(FakeSession()))
        await task.value

        #expect(model.state == .ready)
        #expect(logs.entries.count == 1)
        #expect(logs.entries.first?.0 == .warn)
        let message = logs.entries.first?.1 ?? ""
        #expect(!message.contains("SECRET"))
    }

    @Test func saveFailureStillReadyAndLogsWithoutSecrets() async throws {
        let store = FakeStore(saveError: KeychainError(status: -25308))
        let model = model(store)

        let task = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(FakeSession()))
        await task.value

        #expect(model.state == .ready)
        #expect(logs.entries.count == 1)
        #expect(logs.entries.first?.0 == .warn)
        let message = logs.entries.first?.1 ?? ""
        #expect(message.contains("-25308"))
        #expect(!message.contains("SECRET"))
    }

    @Test func staleRestoreResultIsDroppedAndItsSessionShutDown() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)
        let stale = FakeSession(blob: Data("stale".utf8))
        let fresh = FakeSession()

        let restoring = model.restore()
        try await waitUntil { connector.pending == 1 }
        let connecting = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 2 }
        connector.resolve(1, with: .success(fresh))
        await connecting.value
        connector.resolve(0, with: .success(stale))
        await restoring.value

        #expect(model.state == .ready)
        #expect(store.blob == refreshedBlob)
        #expect(store.saves == 1)
        #expect(stale.shutdownCount == 1)
        #expect(fresh.shutdownCount == 0)
    }

    @Test func staleRejectionDoesNotDeleteNewerCredentials() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)

        let restoring = model.restore()
        try await waitUntil { connector.pending == 1 }
        let connecting = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 2 }
        connector.resolve(1, with: .success(FakeSession()))
        await connecting.value
        connector.resolve(0, with: .failure(SessionError.CredentialsRejected))
        await restoring.value

        #expect(model.state == .ready)
        #expect(store.deletes == 0)
        #expect(store.blob == refreshedBlob)
    }

    @Test func staleFailureIsDropped() async throws {
        let model = model(FakeStore(blob: storedBlob))

        let first = model.restore()
        try await waitUntil { connector.pending == 1 }
        let second = model.retry()
        try await waitUntil { connector.pending == 2 }
        connector.resolve(0, with: .failure(SessionError.Network(message: "offline")))
        await first.value

        #expect(model.state == .restoring)
        connector.resolve(1, with: .success(FakeSession()))
        await second.value
        #expect(model.state == .ready)
    }

    @Test func connectReplacingReadySessionShutsDownOld() async throws {
        let model = model(FakeStore())
        let old = FakeSession()

        let task1 = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(old))
        await task1.value
        let task2 = model.connect(tokens: tokens)

        #expect(old.shutdownCount == 1)
        try await waitUntil { connector.pending == 2 }
        connector.resolve(1, with: .success(FakeSession()))
        await task2.value
        #expect(model.state == .ready)
    }

    @Test func showSignInDropsInFlightConnect() async throws {
        let store = FakeStore(blob: storedBlob)
        let model = model(store)
        let late = FakeSession()

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        model.showSignIn()
        #expect(model.state == .signedOut)
        connector.resolve(0, with: .success(late))
        await task.value

        #expect(model.state == .signedOut)
        #expect(late.shutdownCount == 1)
        #expect(store.blob == storedBlob)
    }
}
