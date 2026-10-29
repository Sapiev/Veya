import Foundation
import Observation
import os

public typealias WebAPIFlowStarter = @Sendable (OAuthConfig) async throws -> any SignInFlow

/// The Web API connection through the user's own Spotify app, since the shared
/// librespot client ID is rate limited there. The client ID is public (PKCE),
/// so it lives in defaults; its refresh token lives in `store`.
@MainActor
@Observable
public final class WebAPIConnection {
    /// Must match the redirect URI registered in the user's app.
    public nonisolated static let redirectPort: UInt16 = 8898
    public nonisolated static let redirectURI = "http://127.0.0.1:\(redirectPort)/login"
    public nonisolated static let clientIDKey = "webAPIClientID"

    public private(set) var clientID: String
    public private(set) var isConnected = false
    /// The latest connect attempt; its state drives progress and errors.
    public private(set) var attempt: SignInModel?
    /// The refresh token could not be saved after a successful sign-in.
    public private(set) var saveFailed = false
    /// The stored refresh token could not be deleted; the connection stays.
    public private(set) var disconnectFailed = false

    @ObservationIgnored public let tokens: WebAPITokenProvider
    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let browser: any SignInBrowser
    @ObservationIgnored private let startFlow: WebAPIFlowStarter
    /// What `tokens` reads off the main actor.
    @ObservationIgnored private let sharedClientID: OSAllocatedUnfairLock<String>

    public init(
        store: any CredentialStore,
        defaults: UserDefaults = .standard,
        browser: any SignInBrowser,
        startFlow: @escaping WebAPIFlowStarter = { try await LoginFlow.start(config: $0) },
        refresher: any TokenRefresher = SpotTokenRefresher()
    ) {
        self.store = store
        self.defaults = defaults
        self.browser = browser
        self.startFlow = startFlow
        let clientID = defaults.string(forKey: Self.clientIDKey) ?? ""
        self.clientID = clientID
        let shared = OSAllocatedUnfairLock(initialState: clientID)
        sharedClientID = shared
        tokens = WebAPITokenProvider(store: store, clientID: { shared.withLock { $0 } }, refresher: refresher)
        reload()
    }

    public nonisolated static func config(clientID: String) -> OAuthConfig {
        OAuthConfig(clientId: clientID, redirectPort: redirectPort)
    }

    /// Spotify client IDs are 32 hex characters.
    public nonisolated static func isValid(clientID: String) -> Bool {
        clientID.utf8.count == 32 && clientID.allSatisfy(\.isHexDigit)
    }

    /// Re-reads the store, which a sign-out or a rejected refresh may have cleared.
    public func reload() {
        isConnected = Self.isValid(clientID: clientID) && ((try? store.load()) ?? nil) != nil
    }

    /// Signs in through `clientID`'s app. A different client ID first drops the
    /// stored refresh token, which belongs to the old app.
    @discardableResult
    public func connect(clientID newID: String) -> Task<Void, Never>? {
        let newID = newID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValid(clientID: newID) else { return nil }
        if newID != clientID {
            do {
                try disconnect()
            } catch {
                return nil
            }
            clientID = newID
            sharedClientID.withLock { $0 = newID }
            defaults.set(newID, forKey: Self.clientIDKey)
        }
        attempt?.cancel()
        saveFailed = false
        let config = Self.config(clientID: newID)
        let startFlow = startFlow
        let model = SignInModel(browser: browser, startFlow: { try await startFlow(config) })
        attempt = model
        let signIn = model.signIn()
        return Task {
            await signIn.value
            guard attempt === model, let tokens = model.takeCredentials()?.tokens else { return }
            do {
                try store.save(Data(tokens.refreshToken.utf8))
            } catch {
                logMessage(level: .warn, category: "webapi", message: "Couldn't save the refresh token: \(error)")
                saveFailed = true
                return
            }
            await self.tokens.seed(tokens)
            reload()
        }
    }

    /// Safe to repeat: deleting a missing token succeeds.
    public func disconnect() throws {
        attempt?.cancel()
        attempt = nil
        saveFailed = false
        disconnectFailed = false
        do {
            try store.delete()
        } catch {
            logMessage(level: .warn, category: "webapi", message: "Couldn't delete the refresh token: \(error)")
            disconnectFailed = true
            throw error
        }
        isConnected = false
    }
}
