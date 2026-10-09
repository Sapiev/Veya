import Foundation
import SpotCoreKit
import Testing

private let newerBlob = Data("newer-SECRET-blob".utf8)

/// Gives queued events time to reach the main actor before asserting nothing happened.
@MainActor
private func settle() async throws {
    try await Task.sleep(for: .milliseconds(50))
}

private extension ConnectionStatus {
    var attempt: Int? {
        if case let .reconnecting(attempt, _) = self {
            attempt
        } else {
            nil
        }
    }

    var retryAt: Date? {
        if case let .reconnecting(_, retryAt) = self {
            retryAt
        } else {
            nil
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionReconnectTests {
    private let connector = FakeConnector()
    private let logs = LogSpy()

    private func ready(_ session: FakeSession, store: FakeStore) async throws -> SessionModel {
        let model = SessionModel(store: store, connector: connector, log: logs.log)
        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(session))
        await task.value
        return model
    }

    @Test func reconnectingKeepsReadyAndReportsAttempt() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))

        let before = Date.now
        session.push(.reconnecting(attempt: 2, retryInSecs: 4))
        try await waitUntil { model.connection != .online }
        let after = Date.now

        #expect(model.connection.attempt == 2)
        let retryAt = try #require(model.connection.retryAt)
        #expect(retryAt >= before.addingTimeInterval(4) && retryAt <= after.addingTimeInterval(4))
        #expect(model.state == .ready)
        #expect(logs.entries.last?.0 == .info)
    }

    @Test func connectedRestoresOnlineAndSavesRefreshedBlob() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)

        session.push(.reconnecting(attempt: 1, retryInSecs: 0))
        try await waitUntil { model.connection != .online }
        session.blob = newerBlob
        session.push(.connected)
        try await waitUntil { model.connection == .online }

        #expect(model.state == .ready)
        #expect(store.blob == newerBlob)
        #expect(store.saves == 2)
        #expect(logs.entries.last?.1 == "Reconnected")
        #expect(!logs.entries.contains { $0.1.contains("SECRET") })
    }

    @Test func initialConnectedOnSubscribeSkipsUnchangedSaveAndStaysQuiet() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession(initial: .connected)
        let model = try await ready(session, store: store)

        session.push(.reconnecting(attempt: 1, retryInSecs: 0))
        try await waitUntil { model.connection != .online }

        #expect(store.saves == 1)
        #expect(store.blob == refreshedBlob)
        #expect(logs.entries.count == 2)
    }

    @Test func resaveFailureLogsCaseNameOnly() async throws {
        let session = FakeSession()
        let store = FakeStore(blob: storedBlob, saveError: KeychainError(status: -25308))
        let model = try await ready(session, store: store)
        var warnings: [String] {
            logs.entries.filter { $0.0 == .warn }.map(\.1)
        }

        session.push(.connected)
        try await waitUntil { warnings.count == 2 }

        #expect(model.connection == .online)
        #expect(warnings.allSatisfy { $0.contains("-25308") && !$0.contains("SECRET") })
    }

    @Test func credentialsRejectedDeletesUnchangedBlobAndSignsOut() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)

        session.push(.credentialsRejected)
        try await waitUntil { model.state == .signedOut }

        #expect(store.deletes == 1)
        #expect(store.blob == nil)
        #expect(session.shutdownCount == 1)
        #expect(model.connection == .online)
        #expect(logs.entries.last?.0 == .warn)
    }

    @Test func credentialsRejectedKeepsBlobChangedByAnotherWriter() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)

        store.replace(with: newerBlob)
        session.push(.credentialsRejected)
        try await waitUntil { model.state == .signedOut }

        #expect(store.deletes == 0)
        #expect(store.blob == newerBlob)
    }

    @Test func eventsFromSignedOutSessionAreIgnored() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)

        model.showSignIn()
        session.push(.reconnecting(attempt: 1, retryInSecs: 1))
        session.push(.credentialsRejected)
        try await settle()

        #expect(model.state == .signedOut)
        #expect(model.connection == .online)
        #expect(store.deletes == 0)
        #expect(store.blob == refreshedBlob)
    }

    @Test func eventsFromReplacedSessionAreIgnored() async throws {
        let store = FakeStore(blob: storedBlob)
        let old = FakeSession()
        let model = try await ready(old, store: store)
        let new = FakeSession(blob: newerBlob)

        let connecting = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 2 }
        connector.resolve(1, with: .success(new))
        await connecting.value
        old.push(.reconnecting(attempt: 7, retryInSecs: 9))
        old.push(.credentialsRejected)
        new.push(.reconnecting(attempt: 1, retryInSecs: 2))
        try await waitUntil { model.connection.attempt == 1 }
        try await settle()

        #expect(model.state == .ready)
        #expect(model.connection.attempt == 1)
        #expect(store.deletes == 0)
        #expect(store.blob == newerBlob)
        #expect(new.shutdownCount == 0)
    }

    @Test func shutdownStopsEventHandling() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)

        model.shutdown()
        session.push(.reconnecting(attempt: 1, retryInSecs: 1))
        session.push(.credentialsRejected)
        try await settle()

        #expect(session.shutdownCount == 1)
        #expect(model.connection == .online)
        #expect(store.deletes == 0)
        #expect(store.blob == refreshedBlob)
    }

    @Test func reconnectingQueuedBeforeSignOutIsIgnored() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))
        try await settle()

        session.push(.reconnecting(attempt: 1, retryInSecs: 1))
        model.showSignIn()
        try await settle()

        #expect(model.connection == .online)
    }

    @Test func rejectionQueuedBeforeSignOutIsIgnored() async throws {
        let store = FakeStore(blob: storedBlob)
        let session = FakeSession()
        let model = try await ready(session, store: store)
        try await settle()

        session.push(.credentialsRejected)
        model.showSignIn()
        try await settle()

        #expect(store.deletes == 0)
        #expect(!logs.entries.contains { $0.0 == .warn })
    }

    @Test func rejectionDoesNotDeleteBlobLoadedByEarlierAttempt() async throws {
        let store = FakeStore(blob: storedBlob, saveError: KeychainError(status: -25308))
        let model = SessionModel(store: store, connector: connector, log: logs.log)
        let signedIn = FakeSession()

        let restoring = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .failure(SessionError.Network(message: "offline")))
        await restoring.value
        let connecting = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 2 }
        connector.resolve(1, with: .success(signedIn))
        await connecting.value
        signedIn.push(.credentialsRejected)
        try await waitUntil { model.state == .signedOut }

        #expect(store.deletes == 0)
        #expect(store.blob == storedBlob)
    }

    @Test func releasedModelShutsDownItsSession() async throws {
        let session = FakeSession()
        var model: SessionModel? = try await ready(session, store: FakeStore(blob: storedBlob))
        #expect(model?.state == .ready)

        model = nil
        try await waitUntil { session.shutdownCount == 1 }
    }

    @Test func eventsArriveInOrder() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))

        for attempt in UInt32(1) ... 50 {
            session.push(.reconnecting(attempt: attempt, retryInSecs: attempt))
        }
        session.push(.connected)
        try await waitUntil { logs.entries.last?.1 == "Reconnected" }

        let attempts = logs.entries.filter { $0.1.hasPrefix("Reconnecting:") }.compactMap { entry in
            Int(entry.1.split(separator: " ")[2].dropLast())
        }
        #expect(attempts == Array(1 ... 50))
        #expect(model.connection == .online)
    }

    @Test func wakeAndNetworkForwardToCurrentSession() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))

        model.systemDidWake()
        model.networkChanged(available: false)
        model.networkChanged(available: true)

        #expect(session.wakes == 1)
        #expect(session.network == [false, true])
    }

    @Test func wakeAndNetworkWithoutSessionAreNoOps() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))
        let fresh = SessionModel(store: FakeStore(), connector: connector, log: logs.log)

        model.showSignIn()
        model.systemDidWake()
        model.networkChanged(available: true)
        fresh.systemDidWake()
        fresh.networkChanged(available: false)

        #expect(session.wakes == 0)
        #expect(session.network.isEmpty)
        #expect(fresh.state == .restoring)
    }

    @Test func cacheLimitChangeReconnectsLiveSession() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))

        try model.setAudioCacheLimit(bytes: 512 << 20)

        #expect(connector.cacheLimits == [512 << 20])
        #expect(session.reconnects == 1)
    }

    @Test func cacheLimitChangeWithoutSessionOnlySetsLimit() throws {
        let fresh = SessionModel(store: FakeStore(), connector: connector, log: logs.log)

        try fresh.setAudioCacheLimit(bytes: 2 << 30)

        #expect(connector.cacheLimits == [2 << 30])
    }

    @Test func failedCacheLimitKeepsSessionUntouched() async throws {
        let session = FakeSession()
        let model = try await ready(session, store: FakeStore(blob: storedBlob))
        connector.failCacheLimit(with: CacheError.Io(message: "disk"))

        #expect(throws: CacheError.self) { try model.setAudioCacheLimit(bytes: 1) }
        #expect(session.reconnects == 0)
    }
}
