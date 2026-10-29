import AppKit
import AuthenticationServices
import SpotCoreKit

/// Presents the Spotify login page in an `ASWebAuthenticationSession`.
/// Spotify redirects to the spotcore loopback listener over http, so the
/// session never sees its callback; cancelling `present` dismisses it.
final class WebAuthenticationBrowser: NSObject, SignInBrowser {
    /// Never registered or redirected to; the session just requires a scheme.
    private static let unusedCallbackScheme = "veya-oauth-unused"

    private final class Presentation {
        var session: ASWebAuthenticationSession?
        var continuation: CheckedContinuation<SignInBrowserResult, Never>?
        /// A cancel that lands before the session starts must still stop it from starting.
        var cancelled = false

        func resume(_ result: SignInBrowserResult) {
            continuation?.resume(returning: result)
            continuation = nil
        }

        func close() {
            cancelled = true
            resume(.closed)
            session?.cancel()
        }
    }

    func present(_ url: URL) async -> SignInBrowserResult {
        guard !Task.isCancelled else { return .closed }
        let presentation = Presentation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                presentation.continuation = continuation
                guard !presentation.cancelled else { return presentation.resume(.closed) }
                // A close() from us resumes first, so a late canceledLogin here is ignored.
                // @Sendable: AuthenticationServices calls this off the main thread, and the
                // default MainActor isolation would otherwise trap on its executor check.
                let session = ASWebAuthenticationSession(
                    url: url,
                    callbackURLScheme: Self.unusedCallbackScheme
                ) { @Sendable _, error in
                    let dismissed = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    Task { @MainActor in presentation.resume(dismissed ? .dismissedByUser : .unavailable) }
                }
                session.presentationContextProvider = self
                // A shared Mac must not sign the next person in as this account through the browser's cookies.
                session.prefersEphemeralWebBrowserSession = true
                presentation.session = session
                if !session.start() {
                    presentation.resume(.unavailable)
                }
            }
        } onCancel: {
            Task { @MainActor in presentation.close() }
        }
    }
}

extension WebAuthenticationBrowser: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for _: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
