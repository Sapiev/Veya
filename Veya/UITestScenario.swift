#if DEBUG
    import Foundation
    import os
    import SpotCoreKit

    /// Picked by VeyaUITests through the environment, so no UI test reaches
    /// Spotify or the user's Keychain. Raw values are mirrored in VeyaUITests.
    enum UITestScenario: String {
        /// No saved sign-in; signing in succeeds.
        case signedOut
        /// No saved sign-in; the user closes the Spotify window.
        case signInCancelled
        /// A saved sign-in restores at launch.
        case signedIn
        /// The first restore fails; Try Again succeeds.
        case restoreFails
        /// Signed in, and the connection has dropped.
        case reconnecting
        /// No saved sign-in; signing in finds a Free account.
        case notPremium

        static let environmentKey = "VEYA_UI_TEST_SCENARIO"

        /// A typo in a test must fail loudly, not launch against real Spotify.
        static func current() -> UITestScenario? {
            guard let name = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
            guard let scenario = UITestScenario(rawValue: name) else {
                fatalError("Unknown \(environmentKey) \(name)")
            }
            return scenario
        }

        var dependencies: AppDependencies {
            let hasSavedSignIn = ![.signedOut, .signInCancelled, .notPremium].contains(self)
            let signInCompletes = self != .signInCancelled
            return AppDependencies(
                store: InMemoryCredentialStore(blob: hasSavedSignIn ? ScenarioSession.blob : nil),
                refreshTokenStore: InMemoryCredentialStore(blob: nil),
                connector: ScenarioConnector(
                    failures: self == .restoreFails ? 1 : 0,
                    premium: self != .notPremium,
                    initial: self == .reconnecting ? .reconnecting(attempt: 1, retryInSecs: 30) : nil
                ),
                browser: ScenarioBrowser(dismissedByUser: !signInCompletes),
                startFlow: { ScenarioFlow(completes: signInCompletes) },
                artworkLoader: nil
            )
        }
    }

    private final nonisolated class InMemoryCredentialStore: CredentialStore {
        private let blob: OSAllocatedUnfairLock<Data?>

        init(blob: Data?) {
            self.blob = OSAllocatedUnfairLock(initialState: blob)
        }

        func load() throws -> Data? {
            blob.withLock { $0 }
        }

        func save(_ blob: Data) throws {
            self.blob.withLock { $0 = blob }
        }

        func delete() throws {
            blob.withLock { $0 = nil }
        }
    }

    private struct ScenarioConnectError: Error {}

    private final nonisolated class ScenarioConnector: SessionConnector {
        private let failuresLeft: OSAllocatedUnfairLock<Int>
        private let premium: Bool
        private let initial: ConnectionState?

        init(failures: Int, premium: Bool, initial: ConnectionState?) {
            failuresLeft = OSAllocatedUnfairLock(initialState: failures)
            self.premium = premium
            self.initial = initial
        }

        func isPremium(accessToken _: String) async throws -> Bool {
            premium
        }

        func connect(accessToken _: String) async throws -> any SessionHandle {
            try nextSession()
        }

        func connect(storedCredentials _: Data) async throws -> any SessionHandle {
            try nextSession()
        }

        func setAudioCacheLimit(bytes _: UInt64) throws {}

        private func nextSession() throws -> any SessionHandle {
            let fails = failuresLeft.withLock { left in
                defer { left = max(left - 1, 0) }
                return left > 0
            }
            if fails {
                throw ScenarioConnectError()
            }
            return ScenarioSession(initial: initial)
        }
    }

    private final nonisolated class ScenarioSession: SessionHandle {
        static let blob = Data("ui-test-credentials".utf8)
        private let initial: ConnectionState?

        init(initial: ConnectionState?) {
            self.initial = initial
        }

        func storedCredentials() throws -> Data {
            Self.blob
        }

        func shutdown() {}

        func setObserver(observer: any ConnectionObserver) {
            if let initial {
                observer.onStateChanged(state: initial)
            }
        }

        func systemDidWake() {}

        func networkChanged(available _: Bool) {}

        func reconnect() {}

        func makeLibrary(cacheDirectory _: URL?) -> any LibraryServiceProtocol {
            ScenarioLibrary()
        }

        func makeMetadata() -> any MetadataServiceProtocol {
            ScenarioMetadata()
        }
    }

    /// An empty library that never changes.
    private final nonisolated class ScenarioLibrary: LibraryServiceProtocol {
        func cached(kind _: LibraryKind) -> [LibraryItem] {
            []
        }

        func refresh(kind _: LibraryKind) async throws -> [LibraryItem] {
            []
        }

        func setSaved(uri _: String, saved _: Bool) async throws {}

        func waitForChange() async {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private final nonisolated class ScenarioMetadata: MetadataServiceProtocol {
        func items(uris: [String]) async throws -> [MetadataItem] {
            uris.map { .unavailable(uri: $0, error: .notFound) }
        }
    }

    private final class ScenarioBrowser: SignInBrowser {
        private let dismissedByUser: Bool

        init(dismissedByUser: Bool) {
            self.dismissedByUser = dismissedByUser
        }

        func present(_: URL) async -> SignInBrowserResult {
            if dismissedByUser {
                return .dismissedByUser
            }
            try? await Task.sleep(for: .seconds(3600))
            return .closed
        }
    }

    private final nonisolated class ScenarioFlow: SignInFlow {
        private let completes: Bool
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(completes: Bool) {
            self.completes = completes
        }

        func authorizeURL() -> String {
            "https://accounts.spotify.com/authorize"
        }

        /// SignInModel's task group waits for this child, so it must end on `cancel()`.
        func finish() async throws -> OAuthTokens {
            if completes {
                return OAuthTokens(accessToken: "ui-test", refreshToken: "ui-test", expiresInSecs: 3600, scopes: [])
            }
            while !cancelled.withLock({ $0 }) {
                try await Task.sleep(for: .milliseconds(20))
            }
            throw CancellationError()
        }

        func cancel() {
            cancelled.withLock { $0 = true }
        }

        func callbackReceived() -> Bool {
            completes
        }
    }
#endif
