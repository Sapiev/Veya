import Foundation
import os
import SpotCoreKit
import Testing

/// Stands in for the 127.0.0.1:8898 listener a live flow holds.
private final class FakePort: Sendable {
    private let held = OSAllocatedUnfairLock(initialState: false)

    func claim() throws {
        try held.withLock { held in
            guard !held else { throw AuthError.PortInUse(port: 8898) }
            held = true
        }
    }

    func release() {
        held.withLock { $0 = false }
    }
}

private final class FakeFlow: SignInFlow, Sendable {
    private struct Box {
        var pending: Result<OAuthTokens, any Error>?
        var waiter: CheckedContinuation<OAuthTokens, any Error>?
        var cancelCount = 0
        var callbackReceived = false
    }

    private let box = OSAllocatedUnfairLock(initialState: Box())
    private let port: FakePort?
    let url: String

    init(
        url: String = "https://accounts.spotify.com/authorize?state=s",
        result: Result<OAuthTokens, any Error>? = nil,
        port: FakePort? = nil
    ) {
        self.url = url
        self.port = port
        box.withLock { $0.pending = result }
    }

    var cancelCount: Int {
        box.withLock { $0.cancelCount }
    }

    func receiveCallback() {
        box.withLock { $0.callbackReceived = true }
    }

    func callbackReceived() -> Bool {
        box.withLock { $0.callbackReceived }
    }

    func authorizeURL() -> String {
        url
    }

    func finish() async throws -> OAuthTokens {
        try await withCheckedThrowingContinuation { continuation in
            let ready = box.withLock { box -> Result<OAuthTokens, any Error>? in
                if let pending = box.pending {
                    return pending
                }
                box.waiter = continuation
                return nil
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }

    func cancel() {
        box.withLock { $0.cancelCount += 1 }
        complete(.failure(AuthError.Cancelled))
    }

    func complete(_ result: Result<OAuthTokens, any Error>) {
        let waiter = box.withLock { box -> CheckedContinuation<OAuthTokens, any Error>? in
            if box.pending == nil {
                box.pending = result
            }
            defer { box.waiter = nil }
            return box.waiter
        }
        port?.release()
        waiter?.resume(with: result)
    }
}

@MainActor
private final class FakeBrowser: SignInBrowser {
    var dismissImmediately = false
    /// Suspension points before the page opens, to let the flow finish first.
    var startDelay = 0
    private(set) var presented: [URL] = []
    private(set) var isOpen = false
    private var waiter: CheckedContinuation<SignInBrowserResult, Never>?

    func present(_ url: URL) async -> SignInBrowserResult {
        presented.append(url)
        for _ in 0 ..< startDelay {
            await Task.yield()
        }
        if dismissImmediately {
            return .dismissedByUser
        }
        guard !Task.isCancelled else { return .closed }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                isOpen = true
                waiter = continuation
            }
        } onCancel: {
            Task { @MainActor in self.resume(.closed) }
        }
    }

    func dismiss() {
        resume(.dismissedByUser)
    }

    private func resume(_ result: SignInBrowserResult) {
        isOpen = false
        waiter?.resume(returning: result)
        waiter = nil
    }
}

/// Hands out the given flows in order, then throws.
private func starter(_ flows: [any SignInFlow], startError: (any Error)? = nil) -> SignInFlowStarter {
    let queue = OSAllocatedUnfairLock(initialState: flows)
    return {
        if let startError {
            throw startError
        }
        return try queue.withLock { queue in
            guard !queue.isEmpty else { throw AuthError.Internal(message: "no fake flow left") }
            return queue.removeFirst()
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SignInModelTests {
    @Test func successfulSignInEndsSignedInAndClosesBrowser() async {
        let browser = FakeBrowser()
        let flow = FakeFlow(result: .success(tokens))
        let model = SignInModel(browser: browser, startFlow: starter([flow]))

        await model.signIn().value

        #expect(model.state == .signedIn)
        #expect(model.credentials?.tokens == tokens)
        #expect(browser.presented == [URL(string: flow.url)])
        #expect(!browser.isOpen)
    }

    @Test func browserOpeningAfterFlowFinishedIsStillClosed() async {
        let browser = FakeBrowser()
        browser.startDelay = 50
        let model = SignInModel(browser: browser, startFlow: starter([FakeFlow(result: .success(tokens))]))

        await model.signIn().value

        #expect(model.state == .signedIn)
        #expect(!browser.isOpen)
    }

    @Test(arguments: [
        (AuthError.Cancelled, SignInFailure.cancelled),
        (AuthError.Denied(reason: "access_denied"), .denied),
        (AuthError.PortInUse(port: 8898), .portInUse(port: 8898)),
        (AuthError.Network(message: "timed out"), .network),
        (AuthError.Exchange(message: "invalid_grant"), .other),
        (AuthError.InvalidConfig(message: "bad"), .other),
        (AuthError.AlreadyFinished, .other),
        (AuthError.Internal(message: "boom"), .other)
    ])
    func finishErrorMapsToFailure(error: AuthError, expected: SignInFailure) async {
        let browser = FakeBrowser()
        let model = SignInModel(browser: browser, startFlow: starter([FakeFlow(result: .failure(error))]))

        await model.signIn().value

        #expect(model.state == .failed(expected))
        #expect(model.credentials == nil)
        #expect(!browser.isOpen)
    }

    @Test func startErrorMapsToFailureWithoutOpeningBrowser() async {
        let browser = FakeBrowser()
        let model = SignInModel(browser: browser, startFlow: starter([], startError: AuthError.PortInUse(port: 8898)))

        await model.signIn().value

        #expect(model.state == .failed(.portInUse(port: 8898)))
        #expect(browser.presented.isEmpty)
    }

    @Test func malformedAuthorizeURLFailsAndCancelsFlow() async {
        let flow = FakeFlow(url: "")
        let model = SignInModel(browser: FakeBrowser(), startFlow: starter([flow]))

        await model.signIn().value

        #expect(model.state == .failed(.other))
        #expect(flow.cancelCount == 1)
    }

    @Test func dismissingBrowserCancelsFlow() async {
        let browser = FakeBrowser()
        browser.dismissImmediately = true
        let flow = FakeFlow()
        let model = SignInModel(browser: browser, startFlow: starter([flow]))

        await model.signIn().value

        #expect(model.state == .failed(.cancelled))
        #expect(flow.cancelCount == 1)
    }

    @Test func dismissingBrowserMidFlowCancelsFlow() async throws {
        let browser = FakeBrowser()
        let flow = FakeFlow()
        let model = SignInModel(browser: browser, startFlow: starter([flow]))

        let task = model.signIn()
        try await waitUntil { !browser.presented.isEmpty }
        browser.dismiss()
        await task.value

        #expect(model.state == .failed(.cancelled))
        #expect(flow.cancelCount == 1)
    }

    @Test func dismissingBrowserAfterCallbackStillSignsIn() async throws {
        let browser = FakeBrowser()
        let flow = FakeFlow()
        let model = SignInModel(browser: browser, startFlow: starter([flow]))

        let task = model.signIn()
        try await waitUntil { browser.isOpen }
        flow.receiveCallback()
        browser.dismiss()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.state == .signingIn)
        flow.complete(.success(tokens))
        await task.value

        #expect(model.state == .signedIn)
        #expect(model.credentials?.tokens == tokens)
        #expect(flow.cancelCount == 0)
    }

    @Test func retryAfterCancelWaitsForPreviousFlowToFreePort() async {
        let port = FakePort()
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let starts = OSAllocatedUnfairLock(initialState: 0)
        let model = SignInModel(browser: FakeBrowser()) {
            try port.claim()
            let isFirst = starts.withLock { count in
                count += 1
                return count == 1
            }
            if isFirst {
                await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
                return FakeFlow(port: port)
            }
            return FakeFlow(result: .success(tokens), port: port)
        }

        model.signIn()
        while gate.withLock({ $0 == nil }) {
            await Task.yield()
        }
        model.cancel()
        let retry = model.signIn()
        gate.withLock { $0 }?.resume()
        await retry.value

        #expect(model.state == .signedIn)
    }

    @Test func secondSignInCancelsFirstFlow() async throws {
        let browser = FakeBrowser()
        let first = FakeFlow()
        let second = FakeFlow(result: .success(tokens))
        let model = SignInModel(browser: browser, startFlow: starter([first, second]))

        let firstTask = model.signIn()
        try await waitUntil { browser.presented.count == 1 }
        await model.signIn().value
        await firstTask.value

        #expect(first.cancelCount == 1)
        #expect(model.state == .signedIn)
        #expect(model.credentials?.tokens == tokens)
    }

    @Test func retryAfterFailureSignsIn() async {
        let failing = FakeFlow(result: .failure(AuthError.Network(message: "down")))
        let succeeding = FakeFlow(result: .success(tokens))
        let model = SignInModel(browser: FakeBrowser(), startFlow: starter([failing, succeeding]))

        await model.signIn().value
        #expect(model.state == .failed(.network))

        await model.signIn().value
        #expect(model.state == .signedIn)
    }

    @Test func cancelReturnsToIdleAndFreesFlow() async throws {
        let browser = FakeBrowser()
        let flow = FakeFlow()
        let model = SignInModel(browser: browser, startFlow: starter([flow]))

        let task = model.signIn()
        try await waitUntil { !browser.presented.isEmpty }
        model.cancel()
        await task.value

        #expect(model.state == .idle)
        #expect(flow.cancelCount >= 1)
        #expect(!browser.isOpen)
    }

    @Test func cancelWhileStartingCancelsLateFlow() async {
        let flow = FakeFlow()
        let gate = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        let model = SignInModel(browser: FakeBrowser()) {
            await withCheckedContinuation { continuation in gate.withLock { $0 = continuation } }
            return flow
        }

        let task = model.signIn()
        while gate.withLock({ $0 == nil }) {
            await Task.yield()
        }
        model.cancel()
        gate.withLock { $0 }?.resume()
        await task.value

        #expect(model.state == .idle)
        #expect(flow.cancelCount == 1)
    }

    @Test func tokensNeverAppearInPrintableSurface() async throws {
        let model = SignInModel(browser: FakeBrowser(), startFlow: starter([FakeFlow(result: .success(tokens))]))
        await model.signIn().value
        let credentials = try #require(model.credentials)

        var dumped = ""
        dump(model, to: &dumped)
        dump(credentials, to: &dumped)
        dump(credentials.tokens, to: &dumped)
        let printed = [String(describing: model.state), String(reflecting: model.state), "\(model)"]
        let surfaces = [dumped, String(describing: credentials), String(reflecting: credentials)] + printed
            + [String(describing: credentials.tokens), credentials.tokens.debugDescription, "\(credentials.tokens)"]
        for surface in surfaces {
            #expect(!surface.contains("SECRET"), "leaked in: \(surface)")
        }
    }
}

extension SignInModelTests {
    @Test func takeCredentialsHandsTokensOnOnce() async {
        let model = SignInModel(browser: FakeBrowser(), startFlow: starter([FakeFlow(result: .success(tokens))]))

        await model.signIn().value

        #expect(model.takeCredentials()?.tokens == tokens)
        #expect(model.takeCredentials() == nil)
        #expect(model.credentials == nil)
    }
}
