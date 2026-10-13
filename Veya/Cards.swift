import SpotCoreKit
import SwiftUI

/// The design's 172 pt card (`.card`): art with a shadow, title and subtitle, a fill on hover,
/// and for what plays a hover play button that repeats the card's own action.
struct MediaCard: View {
    static let width: CGFloat = 172
    private static let art = width - 2 * Theme.s2

    let title: String
    var subtitle: String?
    var subtitleLines = 1
    let artwork: [Artwork]
    var round = false
    var playable = false
    /// Search keeps its texts visible to accessibility and marks the arrow-key selection.
    var grouped = false
    var selected = false
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Group {
            if grouped {
                face
                    .onTapGesture(perform: open)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { open() }
            } else {
                Button(action: open) { face }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
            }
        }
        .overlay(alignment: .topTrailing) {
            if playable, hovering || selected {
                HoverPlay(action: open)
                    .padding(.top, Self.art - 44)
                    .padding(.trailing, 2 * Theme.s2)
            }
        }
        .onHover { hovering = $0 }
        .animation(Theme.fast, value: hovering)
    }

    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkView(artwork: artwork, side: Self.art)
                .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: Theme.smallRadius)))
                .shadow(color: .black.opacity(0.25), radius: 9, y: 6)
            Text(title)
                .modifier(Theme.cardTitle)
                .lineLimit(1)
                .padding(.top, Theme.s2)
            if let subtitle {
                Text(subtitle)
                    .modifier(Theme.cardSubtitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLines)
            }
        }
        .frame(width: Self.art, alignment: .leading)
        .padding(Theme.s2)
        .background(hovering || selected ? Color.fill : .clear, in: .rect(cornerRadius: Theme.cardRadius))
        .contentShape(.rect(cornerRadius: Theme.cardRadius))
    }
}

/// A horizontal row of cards that runs to the page edges (`.rail`).
struct CardRail<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: Theme.s4) { content() }
        }
        .scrollIndicators(.never)
        .contentMargins(.horizontal, Theme.s8, for: .scrollContent)
    }
}

/// The hover play button: hidden from accessibility because the card it sits on does the same.
struct HoverPlay: View {
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PlayFab(label: "Play", action: action)
            .accessibilityHidden(true)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6)))
    }
}
