import Foundation
import Observation

/// A connected session; `storedCredentials()` is the opaque blob to persist.
public protocol SessionHandle: AnyObject, Sendable {
    func storedCredentials() throws -> Data
    func shutdown()
}

extension SpotSession: SessionHandle {}

public protocol SessionConnector: Sendable {
    func connect(accessToken: String) async throws -> any SessionHandle
    func connect(storedCredentials: Data) async throws -> any SessionHandle
}

public struct SpotSessionConnector: SessionConnector {
    public init() {}

    public func connect(accessToken: String) async throws -> any SessionHandle {
        try await SpotSession.connectWithToken(accessToken: accessToken)
    }

    public func connect(storedCredentials: Data) async throws -> any SessionHandle {
        try await SpotSession.connectWithStored(credentials: storedCredentials)
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
    case failed(SessionFailure)
}

public typealias SessionLog = @MainActor (LogLevel, String) -> Void

/// Store calls run synchronously on the main actor so a delete and a later
/// save can never reorder.
@MainActor
@Observable
public final class SessionModel {
    public private(set) var state: SessionState = .restoring

    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private let connector: any SessionConnector
    @ObservationIgnored private let log: SessionLog
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var session: (any SessionHandle)?

    public static let readyBudget = Duration.seconds(2)

    public init(
        store: any CredentialStore,
        connector: any SessionConnector = SpotSessionConnector(),
        log: @escaping SessionLog = { logMessage(level: $0, category: "session", message: $1) }
    ) {
        self.store = store
        self.connector = connector
        self.log = log
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
            do {
                let session = try await connector.connect(accessToken: accessToken)
                adopt(session, attempt: current, started: nil)
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

    /// For app termination; the stored credentials stay.
    public func shutdown() {
        _ = begin(.signedOut)
    }

    private func begin(_ next: SessionState) -> Int {
        attempt += 1
        session?.shutdown()
        session = nil
        state = next
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

    private func adopt(_ session: any SessionHandle, attempt current: Int, started: ContinuousClock.Instant?) {
        guard current == attempt else {
            session.shutdown()
            return
        }
        do {
            try store.save(session.storedCredentials())
        } catch {
            log(.warn, "Couldn't save credentials: \(Self.summary(error))")
        }
        self.session = session
        state = .ready
        if let started {
            let elapsed = ContinuousClock.now - started
            let millis = Int(elapsed / .milliseconds(1))
            log(elapsed > Self.readyBudget ? .warn : .info, "Session restored in \(millis) ms")
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
