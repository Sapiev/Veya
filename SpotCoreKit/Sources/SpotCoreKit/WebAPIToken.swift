import Foundation

public protocol TokenRefresher: Sendable {
    func refresh(refreshToken: String) async throws -> OAuthTokens
}

public struct SpotTokenRefresher: TokenRefresher {
    public init() {}

    public func refresh(refreshToken: String) async throws -> OAuthTokens {
        try await refreshTokens(config: defaultOauthConfig(), refreshToken: refreshToken)
    }
}

public enum WebAPITokenError: Error, Equatable, Sendable {
    /// No refresh token is stored: signed out, or signed in before Veya kept one.
    case notAvailable
    /// Spotify rejected the stored refresh token, which is now deleted.
    case rejected
}

/// Hands out Web API access tokens. The refresh token in `store` is the source
/// of truth: the cache only answers for the token currently stored, so a
/// sign-out or a new sign-in invalidates it without telling the actor.
public actor WebAPITokenProvider {
    /// Refresh this long before expiry so a token never lapses mid-request.
    public static let expiryMargin: TimeInterval = 60

    private struct Cached {
        let refreshToken: String
        let accessToken: String
        let expiresAt: Date
    }

    private let store: any CredentialStore
    private let refresher: any TokenRefresher
    private let now: @Sendable () -> Date
    private var cached: Cached?
    private var inFlight: (refreshToken: String, task: Task<String, any Error>)?

    public init(
        store: any CredentialStore,
        refresher: any TokenRefresher = SpotTokenRefresher(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.store = store
        self.refresher = refresher
        self.now = now
    }

    /// Lets the first call after sign-in skip a refresh.
    public func seed(_ tokens: OAuthTokens) {
        cached = Cached(
            refreshToken: tokens.refreshToken,
            accessToken: tokens.accessToken,
            expiresAt: now().addingTimeInterval(TimeInterval(tokens.expiresInSecs))
        )
    }

    public func accessToken() async throws -> String {
        guard let data = try store.load(), let refreshToken = String(data: data, encoding: .utf8) else {
            throw WebAPITokenError.notAvailable
        }
        if let cached, cached.refreshToken == refreshToken,
           now() < cached.expiresAt.addingTimeInterval(-Self.expiryMargin)
        {
            return cached.accessToken
        }
        if let inFlight, inFlight.refreshToken == refreshToken {
            return try await inFlight.task.value
        }
        let task = Task { try await self.refresh(refreshToken) }
        inFlight = (refreshToken, task)
        return try await task.value
    }

    private func refresh(_ refreshToken: String) async throws -> String {
        defer {
            if inFlight?.refreshToken == refreshToken {
                inFlight = nil
            }
        }
        let tokens: OAuthTokens
        do {
            tokens = try await refresher.refresh(refreshToken: refreshToken)
        } catch AuthError.RefreshRejected {
            try replace(refreshToken, with: nil)
            throw WebAPITokenError.rejected
        }
        // Spotify may already have revoked the old token, so persist the rotated one first.
        if tokens.refreshToken != refreshToken {
            try replace(refreshToken, with: tokens.refreshToken)
        }
        seed(tokens)
        return tokens.accessToken
    }

    /// Leaves the store alone when a sign-out or new sign-in changed it meanwhile.
    private func replace(_ expected: String, with next: String?) throws {
        guard try store.load() == Data(expected.utf8) else { return }
        if let next {
            try store.save(Data(next.utf8))
        } else {
            try store.delete()
        }
    }
}
