import Foundation
import os
import SpotCoreKit
import Testing

/// Spotify redirects back at once with `tokens`, or `finish()` throws `error`.
private final class InstantFlow: SignInFlow {
    private let result: Result<OAuthTokens, any Error>

    init(_ result: Result<OAuthTokens, any Error>) {
        self.result = result
    }

    func authorizeURL() -> String { "https://accounts.spotify.com/authorize" }
    func finish() async throws -> OAuthTokens { try result.get() }
    func cancel() {}
    func callbackReceived() -> Bool { true }
}

/// Stays open until the presenting task is cancelled.
private final class OpenBrowser: SignInBrowser {
    func present(_: URL) async -> SignInBrowserResult {
        try? await Task.sleep(for: .seconds(3600))
        return .closed
    }
}

private let issued = OAuthTokens(accessToken: "at-own", refreshToken: "rt-own", expiresInSecs: 3600, scopes: [])
private let otherClientID = "fedcba9876543210fedcba9876543210"

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WebAPIConnectionTests {
    private let store = FakeStore()
    private let defaults: UserDefaults = {
        let suite = "WebAPIConnectionTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }()
    private let refresher = FakeRefresher()
    private let configs = OSAllocatedUnfairLock(initialState: [OAuthConfig]())

    private func connection(_ result: Result<OAuthTokens, any Error> = .success(issued)) -> WebAPIConnection {
        WebAPIConnection(
            store: store,
            defaults: defaults,
            browser: OpenBrowser(),
            startFlow: { [configs] config in
                configs.withLock { $0.append(config) }
                return InstantFlow(result)
            },
            refresher: refresher
        )
    }

    @Test func startsNotConnected() {
        let connection = connection()

        #expect(!connection.isConnected)
        #expect(connection.clientID.isEmpty)
    }

    @Test(arguments: ["", "abc", "0123456789abcdef0123456789abcdeg", "0123456789abcdef0123456789abcdef0"])
    func invalidClientIDNeverStartsASignIn(clientID: String) {
        let connection = connection()

        #expect(connection.connect(clientID: clientID) == nil)
        #expect(configs.withLock { $0 }.isEmpty)
        #expect(defaults.string(forKey: WebAPIConnection.clientIDKey) == nil)
    }

    @Test func connectSignsInWithTheOwnClientIDAndKeepsItsRefreshToken() async throws {
        let connection = connection()

        await connection.connect(clientID: " \(ownClientID) ")?.value

        #expect(configs.withLock { $0 } == [OAuthConfig(clientId: ownClientID, redirectPort: 8898)])
        #expect(connection.isConnected)
        #expect(store.blob == Data("rt-own".utf8))
        #expect(defaults.string(forKey: WebAPIConnection.clientIDKey) == ownClientID)
        #expect(try await connection.tokens.accessToken() == "at-own")
        #expect(refresher.calls.isEmpty)
    }

    @Test func changingTheClientIDDropsTheOldRefreshToken() async {
        defaults.set(ownClientID, forKey: WebAPIConnection.clientIDKey)
        try? store.save(Data("rt-old".utf8))
        let connection = connection(.failure(AuthError.Denied(reason: "no")))
        #expect(connection.isConnected)

        await connection.connect(clientID: otherClientID)?.value

        #expect(store.blob == nil)
        #expect(!connection.isConnected)
        #expect(connection.clientID == otherClientID)
        #expect(connection.attempt?.state == .failed(.denied))
    }

    @Test func reconnectingTheSameClientIDKeepsTheTokenUntilReplaced() async {
        defaults.set(ownClientID, forKey: WebAPIConnection.clientIDKey)
        try? store.save(Data("rt-old".utf8))
        let connection = connection(.failure(AuthError.Denied(reason: "no")))

        await connection.connect(clientID: ownClientID)?.value

        #expect(store.blob == Data("rt-old".utf8))
        #expect(connection.isConnected)
    }

    @Test func disconnectIsIdempotent() async throws {
        let connection = connection()
        await connection.connect(clientID: ownClientID)?.value

        try connection.disconnect()
        try connection.disconnect()

        #expect(!connection.isConnected)
        #expect(store.blob == nil)
        await #expect(throws: WebAPITokenError.notAvailable) { try await connection.tokens.accessToken() }
    }

    @Test func reloadNoticesATokenDeletedElsewhere() async {
        let connection = connection()
        await connection.connect(clientID: ownClientID)?.value

        try? store.delete()
        connection.reload()

        #expect(!connection.isConnected)
    }
}
