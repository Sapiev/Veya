import SpotCoreKit
import SwiftUI

struct SignInView: View {
    let model: SignInModel

    private var isSigningIn: Bool {
        model.state == .signingIn
    }

    private var failure: SignInFailure? {
        if case let .failed(failure) = model.state {
            failure
        } else {
            nil
        }
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Sign In to Veya")
                    .font(.largeTitle.weight(.semibold))
                Text("Veya needs a Spotify Premium account.")
                    .foregroundStyle(.secondary)
            }

            Button(failure == nil ? "Sign In with Spotify…" : "Try Again") {
                model.signIn()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(isSigningIn)

            status
                .frame(minHeight: 44, alignment: .top)
        }
        .multilineTextAlignment(.center)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var status: some View {
        if isSigningIn {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Continue in the Spotify window.")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") {
                    model.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        } else if let failure {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .frame(maxWidth: 360)
        }
    }
}

extension SignInFailure {
    var message: String {
        switch self {
        case .cancelled:
            String(localized: "Sign-in was cancelled.")
        case .denied:
            String(localized: "Spotify access wasn't granted.")
        case let .portInUse(port):
            String(
                localized: "Another app is using port \(Int(port)), which sign-in needs. Quit that app and try again."
            )
        case .network:
            String(localized: "Couldn't reach Spotify. Check your connection and try again.")
        case .other:
            String(localized: "Sign-in failed. Try again.")
        }
    }
}
