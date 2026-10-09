import Foundation
import Observation

/// A connected session; `storedCredentials()` is the opaque blob to persist.
public protocol SessionHandle: AnyObject, Sendable {
    func storedCredentials() throws -> Data
    func shutdown()
    func setObserver(observer: any ConnectionObserver)
    func systemDidWake()
    func networkChanged(available: Bool)
    func reconnect()
    /// Without `cacheDirectory` the library is fetched again on every launch.
    func makeLibrary(cacheDirectory: URL?) -> any LibraryServiceProtocol
    func makeMetadata() -> any MetadataServiceProtocol
}

extension SpotSession: SessionHandle {
    public func makeLibrary(cacheDirectory: URL?) -> any LibraryServiceProtocol {
        LibraryService(session: self, cacheDir: cacheDirectory?.path(percentEncoded: false))
    }

    public func makeMetadata() -> any MetadataServiceProtocol {
        MetadataService(session: self)
    }
}

public protocol SessionConnector: Sendable {
    func isPremium(accessToken: String) async throws -> Bool
    func connect(accessToken: String) async throws -> any SessionHandle
    func connect(storedCredentials: Data) async throws -> any SessionHandle
    /// Applies to sessions connected afterwards.
    func setAudioCacheLimit(bytes: UInt64) throws
}

public struct SpotSessionConnector: SessionConnector {
    private let audioCache: AudioCache?

    /// Without `audioCache` every play downloads the file again.
    public init(audioCache: AudioCache? = nil) {
        self.audioCache = audioCache
    }

    public func isPremium(accessToken: String) async throws -> Bool {
        try await isPremiumAccount(accessToken: accessToken)
    }

    public func connect(accessToken: String) async throws -> any SessionHandle {
        try await SpotSession.connectWithToken(accessToken: accessToken, cache: audioCache)
    }

    public func connect(storedCredentials: Data) async throws -> any SessionHandle {
        try await SpotSession.connectWithStored(credentials: storedCredentials, cache: audioCache)
    }

    public func setAudioCacheLimit(bytes: UInt64) throws {
        try audioCache?.setLimitBytes(limitBytes: bytes)
    }
}

public enum SessionFailure: Error, Equatable, Sendable {
    case network
    case loginFailed
    /// The saved sign-in exists but could not be read.
    case keychain
    case other

    init(_ error: any Error) {
        switch error {
        case SessionError.Network: self = .network
        case SessionError.LoginFailed, SessionError.CredentialsRejected: self = .loginFailed
        default: self = .other
        }
    }
}

public enum SessionState: Equatable, Sendable {
    case restoring
    case signedOut
    case connecting
    case ready
    /// Signed in to Spotify with a Free or other non-Premium account; never connected.
    case notPremium
    case failed(SessionFailure)
}

public enum ConnectionStatus: Equatable, Sendable {
    case online
    /// `retryAt` is when the next attempt starts; now or past while one runs.
    case reconnecting(attempt: Int, retryAt: Date)
}

/// Rust calls this on its own threads while holding a lock, so it only
/// enqueues; the stream keeps the calls in order.
private final class ConnectionStateRelay: ConnectionObserver {
    private let continuation: AsyncStream<ConnectionState>.Continuation

    init(_ continuation: AsyncStream<ConnectionState>.Continuation) {
        self.continuation = continuation
    }

    func onStateChanged(state: ConnectionState) {
        continuation.yield(state)
    }
}

public typealias SessionLog = @MainActor (LogLevel, String) -> Void

/// Store calls run synchronously on the main actor so a delete and a later
/// save can never reorder.
@MainActor
@Observable
public final class SessionModel {
    public private(set) var state: SessionState = .restoring
    public private(set) var connection: ConnectionStatus = .online

    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private let refreshTokenStore: any CredentialStore
    /// Web API access for this account; throws `WebAPITokenError.notAvailable`
    /// until a sign-in stores a refresh token.
    @ObservationIgnored public let webAPITokens: WebAPITokenProvider
    @ObservationIgnored private let connector: any SessionConnector
    @ObservationIgnored private let log: SessionLog
    @ObservationIgnored private var attempt = 0
    /// Set exactly while `state` is `.ready`.
    public private(set) var session: (any SessionHandle)?
    @ObservationIgnored private var events: Task<Void, Never>?
    /// The blob the current attempt loaded from or saved to the store.
    @ObservationIgnored private var knownBlob: Data?

    public static let readyBudget = Duration.seconds(2)

    public init(
        store: any CredentialStore,
        refreshTokenStore: any CredentialStore,
        connector: any SessionConnector = SpotSessionConnector(),
        tokenRefresher: any TokenRefresher = SpotTokenRefresher(),
        log: @escaping SessionLog = { logMessage(level: $0, category: "session", message: $1) }
    ) {
        self.store = store
        self.refreshTokenStore = refreshTokenStore
        webAPITokens = WebAPITokenProvider(store: refreshTokenStore, refresher: tokenRefresher)
        self.connector = connector
        self.log = log
    }

    isolated deinit {
        events?.cancel()
        session?.shutdown()
    }

    @discardableResult
    public func restore() -> Task<Void, Never> {
        let current = begin(.restoring)
        let started = ContinuousClock.now
        return Task { await runRestore(attempt: current, started: started) }
    }

    @discardableResult
    public func retry() -> Task<Void, Never> {
        restore()
    }

    @discardableResult
    public func connect(tokens: OAuthTokens) -> Task<Void, Never> {
        let current = begin(.connecting)
        let accessToken = tokens.accessToken
        let connector = connector
        return Task {
            guard current == attempt else { return }
            // librespot exits the process on a non-Premium login, so check first (ADR-005).
            do {
                if try await !connector.isPremium(accessToken: accessToken) {
                    guard current == attempt else { return }
                    log(.info, "Account is not Premium")
                    state = .notPremium
                    return
                }
            } catch {
                log(.warn, "Couldn't check the account product, connecting anyway: \(Self.summary(error))")
            }
            guard current == attempt else { return }
            do {
                let session = try await connector.connect(accessToken: accessToken)
                if adopt(session, attempt: current, started: nil), saveRefreshToken(of: tokens) {
                    await webAPITokens.seed(tokens)
                }
            } catch {
                guard current == attempt else { return }
                state = .failed(SessionFailure(error))
            }
        }
    }

    /// Leaves a failed or in-flight connect for the sign-in screen. A later
    /// successful sign-in overwrites the stored credentials.
    public func showSignIn() {
        _ = begin(.signedOut)
    }

    /// Ends the session before deleting so no reconnect can save the blob back.
    /// Safe to repeat; the session ends even if a Keychain delete throws, and
    /// both items are attempted before the first error is rethrown.
    public func signOut() throws {
        _ = begin(.signedOut)
        var failure: (any Error)?
        for item in [store, refreshTokenStore] {
            do {
                try item.delete()
            } catch {
                log(.warn, "Couldn't delete stored credentials on sign out: \(Self.summary(error))")
                failure = failure ?? error
            }
        }
        if let failure {
            throw failure
        }
        log(.info, "Signed out")
    }

    /// For app termination; the stored credentials stay.
    public func shutdown() {
        _ = begin(.signedOut)
    }

    public func systemDidWake() {
        session?.systemDidWake()
    }

    public func networkChanged(available: Bool) {
        session?.networkChanged(available: available)
    }

    /// Evicts down to `bytes` at once; the live session reconnects to pick
    /// up the limit, which stops the current track.
    public func setAudioCacheLimit(bytes: UInt64) throws {
        try connector.setAudioCacheLimit(bytes: bytes)
        session?.reconnect()
    }

    private func begin(_ next: SessionState) -> Int {
        attempt += 1
        events?.cancel()
        events = nil
        session?.shutdown()
        session = nil
        knownBlob = nil
        state = next
        connection = .online
        return attempt
    }

    private func runRestore(attempt current: Int, started: ContinuousClock.Instant) async {
        guard current == attempt else { return }
        let blob: Data?
        do {
            blob = try store.load()
        } catch {
            log(.warn, "Couldn't read stored credentials: \(Self.summary(error))")
            state = .failed(.keychain)
            return
        }
        guard let blob else {
            state = .signedOut
            return
        }
        knownBlob = blob
        let connector = connector
        do {
            let session = try await connector.connect(storedCredentials: blob)
            adopt(session, attempt: current, started: started)
        } catch {
            guard current == attempt else { return }
            switch error {
            case SessionError.CredentialsRejected, SessionError.InvalidStoredCredentials:
                deleteIfUnchanged(blob)
                state = .signedOut
            default:
                state = .failed(SessionFailure(error))
            }
        }
    }

    /// Another writer may have saved newer credentials meanwhile; keep those.
    private func deleteIfUnchanged(_ rejected: Data) {
        do {
            guard try store.load() == rejected else { return }
            try store.delete()
        } catch {
            log(.warn, "Couldn't delete stored credentials: \(Self.summary(error))")
        }
    }

    @discardableResult
    private func adopt(_ session: any SessionHandle, attempt current: Int, started: ContinuousClock.Instant?) -> Bool {
        guard current == attempt else {
            session.shutdown()
            return false
        }
        saveCredentials(of: session)
        self.session = session
        state = .ready
        observe(session, attempt: current)
        if let started {
            let elapsed = ContinuousClock.now - started
            let millis = Int(elapsed / .milliseconds(1))
            log(elapsed > Self.readyBudget ? .warn : .info, "Session restored in \(millis) ms")
        }
        return true
    }

    /// Without it only Web API extras (episode progress) go missing, so a failure is logged.
    private func saveRefreshToken(of tokens: OAuthTokens) -> Bool {
        do {
            try refreshTokenStore.save(Data(tokens.refreshToken.utf8))
            return true
        } catch {
            log(.warn, "Couldn't save the refresh token: \(Self.summary(error))")
            return false
        }
    }

    private func saveCredentials(of session: any SessionHandle, skippingKnown: Bool = false) {
        do {
            let blob = try session.storedCredentials()
            if skippingKnown, blob == knownBlob {
                return
            }
            try store.save(blob)
            knownBlob = blob
        } catch {
            log(.warn, "Couldn't save credentials: \(Self.summary(error))")
        }
    }

    private func observe(_ session: any SessionHandle, attempt current: Int) {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        events = Task { [weak self] in
            for await next in stream {
                guard let self, current == attempt else { return }
                handle(next)
            }
        }
        session.setObserver(observer: ConnectionStateRelay(continuation))
    }

    private func handle(_ next: ConnectionState) {
        switch next {
        case .connected:
            if case .reconnecting = connection {
                log(.info, "Reconnected")
            }
            connection = .online
            if let session {
                saveCredentials(of: session, skippingKnown: true)
            }
        case let .reconnecting(attempt, retryIn):
            let retryAt = Date.now.addingTimeInterval(TimeInterval(retryIn))
            connection = .reconnecting(attempt: Int(attempt), retryAt: retryAt)
            log(.info, "Reconnecting: attempt \(attempt), retry in \(retryIn) s")
        case .credentialsRejected:
            log(.warn, "Spotify rejected the stored credentials on reconnect")
            if let knownBlob {
                deleteIfUnchanged(knownBlob)
            }
            _ = begin(.signedOut)
        }
    }

    /// Error case names only: messages are not ours to vouch for.
    private static func summary(_ error: any Error) -> String {
        switch error {
        case let error as KeychainError: error.description
        case SessionError.CredentialsRejected: "CredentialsRejected"
        case SessionError.LoginFailed: "LoginFailed"
        case SessionError.InvalidStoredCredentials: "InvalidStoredCredentials"
        case SessionError.Network: "Network"
        case SessionError.Internal: "Internal"
        default: String(describing: type(of: error))
        }
    }
}
