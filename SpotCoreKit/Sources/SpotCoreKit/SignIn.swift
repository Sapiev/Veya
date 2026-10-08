import Foundation
import Observation

/// One PKCE login attempt: open `authorizeURL()` in a browser, await `finish()`.
public protocol SignInFlow: Sendable {
    func authorizeURL() -> String
    func finish() async throws -> OAuthTokens
    /// Idempotent; frees the loopback port and makes `finish()` throw.
    func cancel()
    /// True once Spotify redirected back; the code exchange may still be running.
    func callbackReceived() -> Bool
}

extension LoginFlow: SignInFlow {
    public func authorizeURL() -> String {
        authorizeUrl()
    }
}

/// The generated struct would print both tokens; only non-secret fields show.
extension OAuthTokens: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "OAuthTokens(redacted, expiresInSecs: \(expiresInSecs), scopes: \(scopes))"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: ["expiresInSecs": expiresInSecs, "scopes": scopes])
    }
}

public typealias SignInFlowStarter = @Sendable () async throws -> any SignInFlow

public enum SignInBrowserResult: Sendable {
    case dismissedByUser
    /// Closed because the presenting task was cancelled.
    case closed
    case unavailable
}

/// Shows the Spotify login page. The callback goes to the Rust loopback
/// listener, so the browser never completes on its own.
@MainActor
public protocol SignInBrowser: AnyObject, Sendable {
    /// Returns once the browser is gone. Cancelling the calling task closes it,
    /// and must also work when cancellation lands before the page opens.
    func present(_ url: URL) async -> SignInBrowserResult
}

public enum SignInFailure: Error, Equatable, Sendable {
    case cancelled
    case denied
    case portInUse(port: UInt16)
    case network
    case other

    init(_ error: any Error) {
        switch error {
        case AuthError.Cancelled: self = .cancelled
        case AuthError.Denied: self = .denied
        case let AuthError.PortInUse(port): self = .portInUse(port: port)
        case AuthError.Network: self = .network
        case let failure as SignInFailure: self = failure
        default: self = .other
        }
    }
}

public enum SignInState: Equatable, Sendable {
    case idle
    case signingIn
    case signedIn
    case failed(SignInFailure)
}

/// Holds tokens until PBI-102 moves them to the Keychain. Printing,
/// dumping or reflecting it never reveals them.
public struct SignInCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let tokens: OAuthTokens

    public var description: String {
        "SignInCredentials(redacted)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

@MainActor
@Observable
public final class SignInModel {
    public private(set) var state: SignInState = .idle
    @ObservationIgnored public private(set) var credentials: SignInCredentials?

    @ObservationIgnored private let browser: any SignInBrowser
    @ObservationIgnored private let startFlow: SignInFlowStarter
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var activeFlow: (any SignInFlow)?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The last abandoned attempt; the next one waits for it so the port is free.
    @ObservationIgnored private var abandoned: Task<Void, Never>?

    public init(browser: any SignInBrowser, startFlow: @escaping SignInFlowStarter = SignInModel.startLoginFlow) {
        self.browser = browser
        self.startFlow = startFlow
    }

    public nonisolated static let startLoginFlow: SignInFlowStarter = {
        try await LoginFlow.start(config: defaultOauthConfig())
    }

    /// Cancels any attempt in flight first, so a double click or retry is safe.
    @discardableResult
    public func signIn() -> Task<Void, Never> {
        abandonAttempt()
        attempt += 1
        credentials = nil
        state = .signingIn
        let current = attempt
        let previous = abandoned
        abandoned = nil
        let task = Task {
            await previous?.value
            await run(attempt: current)
        }
        self.task = task
        return task
    }

    public func cancel() {
        guard state == .signingIn else { return }
        abandonAttempt()
        attempt += 1
        state = .idle
    }

    private func abandonAttempt() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        abandoned = task
        activeFlow?.cancel()
        activeFlow = nil
    }

    private func run(attempt current: Int) async {
        let result: Result<OAuthTokens, SignInFailure>
        do {
            let flow = try await startFlow()
            guard current == attempt else {
                flow.cancel()
                return
            }
            activeFlow = flow
            result = await race(flow)
        } catch {
            result = .failure(SignInFailure(error))
        }
        guard current == attempt else { return }
        activeFlow = nil
        task = nil
        switch result {
        case let .success(tokens):
            credentials = SignInCredentials(tokens: tokens)
            state = .signedIn
        case let .failure(failure):
            state = .failed(failure)
        }
    }

    private enum Event: Sendable {
        case finished(Result<OAuthTokens, SignInFailure>)
        case browser(SignInBrowserResult)
    }

    /// The exchange ending closes the browser. The browser ending first cancels
    /// the flow, unless Spotify already redirected back: then the exchange is kept.
    private func race(_ flow: any SignInFlow) async -> Result<OAuthTokens, SignInFailure> {
        guard let url = URL(string: flow.authorizeURL()) else {
            flow.cancel()
            return .failure(.other)
        }
        let browser = browser
        return await withTaskGroup(of: Event.self) { group in
            group.addTask {
                do {
                    return try await .finished(.success(flow.finish()))
                } catch {
                    return .finished(.failure(SignInFailure(error)))
                }
            }
            group.addTask {
                await .browser(browser.present(url))
            }
            switch await group.next() {
            case let .finished(result):
                group.cancelAll()
                return result
            case .browser where flow.callbackReceived():
                guard case let .finished(result) = await group.next() else { return .failure(.other) }
                return result
            case .browser(.unavailable):
                flow.cancel()
                return .failure(.other)
            case .browser, nil:
                flow.cancel()
                return .failure(.cancelled)
            }
        }
    }
}
