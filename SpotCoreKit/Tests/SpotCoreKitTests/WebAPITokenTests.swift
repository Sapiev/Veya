import Foundation
import os
import SpotCoreKit
import Testing

/// Each refresh waits until the test resolves it, in call order.
final class FakeRefresher: TokenRefresher {
    private struct Box {
        var calls: [String] = []
        var waiters: [CheckedContinuation<OAuthTokens, any Error>] = []
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())

    var calls: [String] {
        box.withLock { $0.calls }
    }

    var pending: Int {
        box.withLock { $0.waiters.count }
    }

    func refresh(refreshToken: String) async throws -> OAuthTokens {
        try await withCheckedThrowingContinuation { continuation in
            box.withLock { box in
                box.calls.append(refreshToken)
                box.waiters.append(continuation)
            }
        }
    }

    func resolve(_ index: Int, with result: Result<OAuthTokens, any Error>) {
        let waiter = box.withLock { $0.waiters[index] }
        waiter.resume(with: result)
    }
}

final class FakeClock: Sendable {
    private let date = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_000_000))

    var now: Date {
        date.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        date.withLock { $0.addTimeInterval(seconds) }
    }
}

private func issued(access: String, refresh: String, expiresIn: UInt64 = 3600) -> OAuthTokens {
    OAuthTokens(accessToken: access, refreshToken: refresh, expiresInSecs: expiresIn, scopes: ["streaming"])
}

private func stored(_ token: String) -> Data {
    Data(token.utf8)
}

@Suite(.timeLimit(.minutes(1)))
struct WebAPITokenProviderTests {
    private let refresher = FakeRefresher()
    private let clock = FakeClock()

    private func provider(_ store: FakeStore) -> WebAPITokenProvider {
        WebAPITokenProvider(store: store, refresher: refresher, now: { [clock] in clock.now })
    }

    /// Starts `accessToken()` and waits until it is parked in the refresher.
    private func refreshing(_ provider: WebAPITokenProvider, calls: Int = 1) async throws -> Task<String, any Error> {
        let task = Task { try await provider.accessToken() }
        try await waitUntil { refresher.calls.count == calls }
        return task
    }

    @Test func missingRefreshTokenIsNotAvailable() async {
        let provider = provider(FakeStore())

        await #expect(throws: WebAPITokenError.notAvailable) { try await provider.accessToken() }
        #expect(refresher.calls.isEmpty)
    }

    @Test func seededTokenIsReusedWithoutRefresh() async throws {
        let provider = provider(FakeStore(blob: stored("rt-1")))
        await provider.seed(issued(access: "at-1", refresh: "rt-1"))

        #expect(try await provider.accessToken() == "at-1")
        clock.advance(by: 3600 - WebAPITokenProvider.expiryMargin - 1)
        #expect(try await provider.accessToken() == "at-1")
        #expect(refresher.calls.isEmpty)
    }

    @Test func refreshesNearExpiryAndCachesTheResult() async throws {
        let store = FakeStore(blob: stored("rt-1"))
        let provider = provider(store)
        await provider.seed(issued(access: "at-1", refresh: "rt-1"))
        clock.advance(by: 3600 - WebAPITokenProvider.expiryMargin)

        let task = try await refreshing(provider)
        refresher.resolve(0, with: .success(issued(access: "at-2", refresh: "rt-1")))

        #expect(try await task.value == "at-2")
        #expect(try await provider.accessToken() == "at-2")
        #expect(refresher.calls == ["rt-1"])
        #expect(store.saves == 0)
    }

    @Test func rotatedRefreshTokenIsPersisted() async throws {
        let store = FakeStore(blob: stored("rt-1"))
        let provider = provider(store)

        let task = try await refreshing(provider)
        refresher.resolve(0, with: .success(issued(access: "at-2", refresh: "rt-2")))

        #expect(try await task.value == "at-2")
        #expect(store.blob == stored("rt-2"))
        #expect(try await provider.accessToken() == "at-2")
        #expect(refresher.calls == ["rt-1"])
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let provider = provider(FakeStore(blob: stored("rt-1")))

        let first = try await refreshing(provider)
        let others = (0 ..< 4).map { _ in Task { try await provider.accessToken() } }
        try await Task.sleep(for: .milliseconds(50))
        refresher.resolve(0, with: .success(issued(access: "at-2", refresh: "rt-2")))

        #expect(try await first.value == "at-2")
        for other in others {
            #expect(try await other.value == "at-2")
        }
        #expect(refresher.calls == ["rt-1"])
    }

    @Test func rejectedRefreshTokenIsDeleted() async throws {
        let store = FakeStore(blob: stored("rt-1"))
        let provider = provider(store)

        let task = try await refreshing(provider)
        refresher.resolve(0, with: .failure(AuthError.RefreshRejected))

        await #expect(throws: WebAPITokenError.rejected) { try await task.value }
        #expect(store.blob == nil)
        await #expect(throws: WebAPITokenError.notAvailable) { try await provider.accessToken() }
    }

    @Test func networkFailureKeepsTokenAndNextCallRetries() async throws {
        let store = FakeStore(blob: stored("rt-1"))
        let provider = provider(store)

        let failing = try await refreshing(provider)
        refresher.resolve(0, with: .failure(AuthError.Network(message: "offline")))
        await #expect(throws: AuthError.self) { try await failing.value }
        #expect(store.blob == stored("rt-1"))

        let retry = try await refreshing(provider, calls: 2)
        refresher.resolve(1, with: .success(issued(access: "at-2", refresh: "rt-1")))
        #expect(try await retry.value == "at-2")
    }

    @Test func signOutDuringRefreshDoesNotResurrectTheToken() async throws {
        let store = FakeStore(blob: stored("rt-1"))
        let provider = provider(store)

        let task = try await refreshing(provider)
        try store.delete()
        refresher.resolve(0, with: .success(issued(access: "at-2", refresh: "rt-2")))
        _ = try await task.value

        #expect(store.blob == nil)
        await #expect(throws: WebAPITokenError.notAvailable) { try await provider.accessToken() }
    }

    @Test func rejectionAfterNewSignInKeepsTheNewToken() async throws {
        let store = FakeStore(blob: stored("rt-1"))
        let provider = provider(store)

        let task = try await refreshing(provider)
        store.replace(with: stored("rt-new"))
        refresher.resolve(0, with: .failure(AuthError.RefreshRejected))

        await #expect(throws: WebAPITokenError.rejected) { try await task.value }
        #expect(store.blob == stored("rt-new"))
    }

    @Test func seedForAnotherRefreshTokenIsIgnored() async throws {
        let provider = provider(FakeStore(blob: stored("rt-current")))
        await provider.seed(issued(access: "at-stale", refresh: "rt-old"))

        let task = try await refreshing(provider)
        refresher.resolve(0, with: .success(issued(access: "at-current", refresh: "rt-current")))

        #expect(try await task.value == "at-current")
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionRefreshTokenTests {
    private let connector = FakeConnector()
    private let refresher = FakeRefresher()
    private let logs = LogSpy()

    private func model(store: FakeStore = FakeStore(), refreshTokens: FakeStore) -> SessionModel {
        SessionModel(
            store: store,
            refreshTokenStore: refreshTokens,
            connector: connector,
            tokenRefresher: refresher,
            log: logs.log
        )
    }

    private func signIn(_ model: SessionModel) async throws {
        let task = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(FakeSession()))
        await task.value
        #expect(model.state == .ready)
    }

    @Test func signInSavesRefreshTokenAndSeedsAccessToken() async throws {
        let refreshTokens = FakeStore()
        let model = model(refreshTokens: refreshTokens)

        try await signIn(model)

        #expect(refreshTokens.blob == Data(tokens.refreshToken.utf8))
        #expect(try await model.webAPITokens.accessToken() == tokens.accessToken)
        #expect(refresher.calls.isEmpty)
    }

    @Test func failedSignInSavesNoRefreshToken() async throws {
        let refreshTokens = FakeStore()
        let model = model(refreshTokens: refreshTokens)

        let task = model.connect(tokens: tokens)
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .failure(SessionError.LoginFailed(reason: "no")))
        await task.value

        #expect(refreshTokens.saves == 0)
    }

    @Test func refreshTokenSaveFailureIsLoggedAndSessionStaysReady() async throws {
        let refreshTokens = FakeStore(saveError: KeychainError(status: -25308))
        let model = model(refreshTokens: refreshTokens)

        try await signIn(model)

        #expect(logs.entries.contains { $0.0 == .warn && $0.1.contains("-25308") })
        #expect(!logs.entries.contains { $0.1.contains(tokens.refreshToken) })
    }

    @Test func signOutDeletesRefreshToken() async throws {
        let refreshTokens = FakeStore()
        let model = model(refreshTokens: refreshTokens)
        try await signIn(model)

        try model.signOut()

        #expect(refreshTokens.blob == nil)
        await #expect(throws: WebAPITokenError.notAvailable) { try await model.webAPITokens.accessToken() }
    }

    @Test func signOutDeletesRefreshTokenEvenWhenCredentialDeleteFails() async throws {
        let store = FakeStore(blob: storedBlob)
        store.failDeletes(with: KeychainError(status: -25308))
        let refreshTokens = FakeStore(blob: Data("rt".utf8))
        let model = model(store: store, refreshTokens: refreshTokens)

        #expect(throws: KeychainError(status: -25308)) { try model.signOut() }
        #expect(refreshTokens.blob == nil)
    }

    @Test func restoreLeavesStoredRefreshTokenInPlace() async throws {
        let refreshTokens = FakeStore(blob: Data("rt".utf8))
        let model = model(store: FakeStore(blob: storedBlob), refreshTokens: refreshTokens)

        let task = model.restore()
        try await waitUntil { connector.pending == 1 }
        connector.resolve(0, with: .success(FakeSession()))
        await task.value

        #expect(refreshTokens.saves == 0)
        #expect(refreshTokens.blob == Data("rt".utf8))
    }
}
