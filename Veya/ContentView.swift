import SpotCoreKit
import SwiftUI

struct ContentView: View {
    let session: SessionModel
    let signIn: SignInModel
    let signOut: () -> Void

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
            SignedInView(signOut: signOut)
                .overlay(alignment: .top) {
                    ReconnectBanner(connection: session.connection)
                }
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

private struct ReconnectBanner: View {
    let connection: ConnectionStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var retryAt: Date? {
        if case let .reconnecting(_, retryAt) = connection {
            retryAt
        } else {
            nil
        }
    }

    var body: some View {
        ZStack {
            if let retryAt {
                banner(retryAt: retryAt)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0), value: retryAt != nil)
    }

    private func banner(retryAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = Int(retryAt.timeIntervalSince(context.date).rounded(.up))
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash")
                    .accessibilityHidden(true)
                Text("Offline - reconnecting…")
                if seconds > 0 {
                    Text("Retrying in \(seconds) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct SignedInView: View {
    let signOut: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("You're signed in.")
                .font(.title2)
            Text("spotcore \(version())")
                .foregroundStyle(.secondary)
            Button("Sign Out", action: signOut)
                .padding(.top, 16)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView(
        session: SessionModel(store: KeychainCredentialStore(service: "preview", account: "preview")),
        signIn: SignInModel(browser: WebAuthenticationBrowser()),
        signOut: {}
    )
}
