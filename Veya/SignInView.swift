import SpotCoreKit
import SwiftUI

/// The welcome screen (`.auth`): copy and the Spotify button on the left, a tilted cover collage on the right.
struct SignInView: View {
    let model: SignInModel
    /// Signed in and connecting the session; the button keeps its busy state until the library screen can show.
    var connecting = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    /// The cover under the pointer; the window takes its colors from it, like from a playing track.
    @State private var hovered: [Artwork]?

    private var isBusy: Bool {
        connecting || model.state == .signingIn
    }

    /// Closing the Spotify window is the user's choice, so it reads as a quiet return, not an error.
    private var failure: SignInFailure? {
        if case let .failed(failure) = model.state, failure != .cancelled {
            failure
        } else {
            nil
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            HStack(spacing: Theme.s12) {
                copy(titleSize: min(max(36, width * 0.044), 60))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if width > 900 {
                    CoverCollage(hovered: $hovered)
                        .frame(maxWidth: 480)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.vertical, Theme.s12)
            .padding(.horizontal, min(max(32, width * 0.06), 96))
            .frame(width: width, height: proxy.size.height)
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .background { WelcomeBackground() }
        .modifier(AdaptiveColors(artwork: hovered ?? []))
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)) { appeared = true }
        }
    }

    private func copy(titleSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.s6) {
            Text("Welcome to Veya")
                .scaledFont(size: titleSize, weight: .heavy)
                .tracking(titleSize * -0.03)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text("Your Spotify library, playlists and liked songs in a player that takes its colors from the music.")
                .scaledFont(size: 17)
                .lineSpacing(6)
                .foregroundStyle(.primary.opacity(0.7))
                .frame(maxWidth: 340, alignment: .leading)
            SpotifyButton(isBusy: isBusy) { model.signIn() }
            // Always laid out so the footnote doesn't jump when a failure appears.
            Text(failure?.message ?? " ")
                .scaledFont(size: 14)
                .foregroundStyle(
                    scheme == .dark
                        ? Color(red: 1, green: 0x8A / 255, blue: 0x80 / 255)
                        : Color(red: 0xC0 / 255, green: 0x27 / 255, blue: 0x1D / 255)
                )
                .opacity(failure == nil ? 0 : 1)
                .animation(Theme.fast, value: failure)
                .accessibilityHidden(failure == nil)
                .frame(minHeight: 21, alignment: .top)
            Text("You'll sign in on Spotify's own page. Veya never sees your password.")
                .scaledFont(size: 13)
                .foregroundStyle(.primary.opacity(0.56))
                .frame(maxWidth: 340, alignment: .leading)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The pill-shaped Spotify button (`.auth-btn`), in Spotify's own green as the design asks.
private struct SpotifyButton: View {
    let isBusy: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var cursorPushed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.s3) {
                Image("SpotifyLogo")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(isBusy ? "Connecting to Spotify…" : "Continue with Spotify")
            }
        }
        .buttonStyle(SpotifyButtonStyle(hovering: hovering && !isBusy))
        .keyboardShortcut(.defaultAction)
        .disabled(isBusy)
        .opacity(isBusy ? 0.8 : 1)
        .accessibilityLabel("Continue with Spotify")
        .accessibilityValue(isBusy ? Text("Connecting to Spotify…") : Text(verbatim: ""))
        .accessibilityHint("Opens Spotify's sign-in page in your browser")
        .onHover { inside in
            hovering = inside
            if inside, !cursorPushed {
                NSCursor.pointingHand.push()
                cursorPushed = true
            } else if !inside, cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        // The view can go away while the pointer is over it, which never reports leaving.
        .onDisappear {
            if cursorPushed {
                NSCursor.pop()
                cursorPushed = false
            }
        }
        .animation(Theme.fast, value: hovering)
    }
}

private struct SpotifyButtonStyle: ButtonStyle {
    let hovering: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let scale: CGFloat = configuration.isPressed ? 0.98 : hovering ? 1.02 : 1
        configuration.label
            .scaledFont(size: 17, weight: .bold)
            .foregroundStyle(.black)
            .padding(.horizontal, Theme.s8)
            .frame(minWidth: 280, minHeight: 52)
            .background(
                hovering
                    ? Color(red: 0x1E / 255, green: 0xD7 / 255, blue: 0x60 / 255)
                    : Color(red: 0x1D / 255, green: 0xB9 / 255, blue: 0x54 / 255),
                in: .capsule
            )
            .contentShape(.capsule)
            .scaleEffect(reduceMotion ? 1 : scale)
            .animation(Theme.fast, value: configuration.isPressed)
    }
}

/// Nine covers in three columns, the middle one dropped by `--s6`, the whole grid turned 4° (`.auth-art`).
private struct CoverCollage: View {
    @Binding var hovered: [Artwork]?

    /// Spotify CDN image IDs (640 px) of the design's covers; the CDN needs no sign-in.
    private static let covers = [
        "71d62ea7ea8a5be92d3c1f62", "e2a0a166493a2bde5480a420", "f88b43d15fd14e9525338b59",
        "9e1cfc756886ac782e363d79", "bc18bdade69ec5ef0bb25b17", "9b9b36b0e22870b9f542d937",
        "34733f87148c2fbe0176abdb", "fd8d7a8d96871e791cb1f626", "2f8790ed72296c2614607575",
    ].map { [Artwork(url: "https://i.scdn.co/image/ab67616d0000b273\($0)", size: .large, width: 640, height: 640)] }

    var body: some View {
        Grid(horizontalSpacing: Theme.s3, verticalSpacing: Theme.s3) {
            ForEach(0 ..< 3, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< 3, id: \.self) { column in
                        tile(Self.covers[row * 3 + column])
                            .offset(y: column == 1 ? Theme.s6 : 0)
                    }
                }
            }
        }
        .rotationEffect(.degrees(-4))
        .accessibilityHidden(true)
    }

    /// A square slot sized by the column, so the cover fills it instead of growing the grid.
    private func tile(_ cover: [Artwork]) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ArtworkView(artwork: cover, side: proxy.size.width)
                }
            }
            .clipShape(.rect(cornerRadius: Theme.cardRadius))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
            .onHover { inside in
                if inside {
                    hovered = cover
                } else if hovered == cover {
                    hovered = nil
                }
            }
    }
}

/// The ambient wash with the welcome glow from the top right (`.auth::before`).
struct WelcomeBackground: View {
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            // CSS `radial-gradient(90% 70% at 85% 10%, …, transparent 65%)`: an ellipse with 0.9 w by 0.7 h radii.
            EllipticalGradient(
                colors: [Color(palette.glow).opacity(0.8), .clear],
                center: .center,
                startRadiusFraction: 0,
                endRadiusFraction: 0.65 / 2
            )
            .frame(width: size.width * 1.8, height: size.height * 1.4)
            .position(x: size.width * 0.85, y: size.height * 0.1)
        }
        .background(Color(palette.ambient))
        .ignoresSafeArea()
        .accessibilityHidden(true)
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
