import SpotCoreKit
import SwiftUI

struct ContentView: View {
    let session: SessionModel
    let signIn: SignInModel

    var body: some View {
        content
            .onChange(of: signIn.state) { _, state in
                if state == .signedIn, let credentials = signIn.takeCredentials() {
                    session.connect(tokens: credentials.tokens)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .restoring, .connecting:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .signedOut:
            SignInView(model: signIn)
        case .ready:
            SignedInView()
        case let .failed(failure):
            SessionFailedView(failure: failure, retry: { session.retry() }, signIn: { session.showSignIn() })
        }
    }
}

private struct SessionFailedView: View {
    let failure: SessionFailure
    let retry: () -> Void
    let signIn: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .frame(maxWidth: 360)

            VStack(spacing: 10) {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                Button("Sign In Again…", action: signIn)
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension SessionFailure {
    var message: String {
        switch self {
        case .network:
            String(localized: "Couldn't reach Spotify. Check your connection and try again.")
        case .loginFailed:
            String(localized: "Spotify didn't accept the sign-in. Sign in again or try later.")
        case .keychain:
            String(localized: "Veya couldn't read its saved sign-in from the Keychain.")
        case .other:
            String(localized: "Couldn't connect to Spotify. Try again.")
        }
    }
}

private struct SignedInView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("You're signed in.")
                .font(.title2)
            Text("spotcore \(version())")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView(
        session: SessionModel(store: KeychainCredentialStore(service: "preview", account: "preview")),
        signIn: SignInModel(browser: WebAuthenticationBrowser())
    )
}
