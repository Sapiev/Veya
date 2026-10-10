import SpotCoreKit
import SwiftUI

struct ContentView: View {
    let session: SessionModel
    let signIn: SignInModel
    let metadataStore: MetadataStore?
    let recentSearches: RecentSearches
    let settings: PlaybackSettings
    let episodeProgress: any EpisodeProgressProvider
    let signOut: () -> Void

    var body: some View {
        content
            .onChange(of: signIn.state) { _, state in
                if state == .signedIn, let credentials = signIn.takeCredentials() {
                    session.connect(tokens: credentials.tokens)
                }
            }
            .onChange(of: session.state) { _, state in
                // Another account may sign in next; its searches are its own.
                if state == .signedOut { recentSearches.clear() }
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
            if let handle = session.session {
                AppShell(
                    session: handle,
                    webAPITokens: session.webAPITokens,
                    metadataStore: metadataStore,
                    recentSearches: recentSearches,
                    settings: settings,
                    episodeProgress: episodeProgress,
                    attachPlayer: { session.attach($0, startedOn: handle) }
                )
                .id(ObjectIdentifier(handle))
                .overlay(alignment: .top) {
                    ReconnectBanner(connection: session.connection)
                }
            }
        case .notPremium:
            NotPremiumView(signOut: signOut)
        case let .failed(failure):
            SessionFailedView(failure: failure, retry: { session.retry() }, signIn: { session.showSignIn() })
        }
    }
}

private struct NotPremiumView: View {
    let signOut: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.house")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Veya Needs Spotify Premium")
                .font(.title2)
            Text("Playback through Veya works only with a Premium account. Upgrade your plan with Spotify, or sign out and use a Premium account.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Sign Out", action: signOut)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

#Preview {
    ContentView(
        session: SessionModel(
            store: KeychainCredentialStore(service: "preview", account: "preview"),
            refreshTokenStore: KeychainCredentialStore(service: "preview", account: "preview-refresh")
        ),
        signIn: SignInModel(browser: WebAuthenticationBrowser()),
        metadataStore: nil,
        recentSearches: RecentSearches(defaults: UserDefaults(suiteName: "preview")!),
        settings: PlaybackSettings(defaults: UserDefaults(suiteName: "preview")!),
        episodeProgress: WebAPIEpisodeProgress { "" },
        signOut: {}
    )
}
